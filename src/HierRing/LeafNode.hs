{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
module HierRing.LeafNode
  (startLeafNode)
  where

import CommonCode
import HierRing.Types

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , reply
                                                  , call
                                                  , cast
                                                  , callTimeout
                                                  , statelessProcess
                                                  , statelessInit
                                                  , handleRpcChan
                                                  , handleCast
                                                  , handleCall
                                                  , handleInfo
                                                  , InitResult(..)
                                                  , UnhandledMessagePolicy(..)
                                                  , ChannelHandler
                                                  , ActionHandler
                                                  , CastHandler
                                                  , CallHandler
                                                  , ProcessDefinition(..) )
import Control.Distributed.Process ( spawnLocal
                                   , say
                                   , link
                                   , newChan
                                   , sendChan
                                   , receiveChan
                                   , getSelfPid
                                   , register
                                   , catchExit
                                   , die
                                   , exit
                                   , receiveChanTimeout
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , Process
                                   , DiedReason(..)
                                   , ProcessId(..)
                                   , ReceivePort
                                   , NodeId(..)
                                   , WhereIsReply(..))
import Control.Distributed.Process.ManagedProcess.Server (replyChan, continue)
import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
                                        , LocalNode)
import Control.Distributed.Process.Async (AsyncResult(..)
                                         , wait
                                         , waitCancelTimeout
                                         , waitTimeout
                                         , async
                                         , task)
import Control.Concurrent (threadDelay, MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void, when)
import Network.Transport     (EndPointAddress(..))

import qualified Data.Map as Map
import System.Random (mkStdGen, random
                     , StdGen)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- A cluster consists of a bunch on nodes in ring configuration
-- Each cluster has a leader node
-- The leader nodes of all clusters also form ring

-- A leader node sends the message after receiving a complete TimePulse
-- The message has to be sent every TimePulse
-- Every TimePulse it receives a cluster message which it fwds to its own leaf node peer
-- and also the next cluster leader node

-- For non-leader leaf node, run a single client and fwd all cluster messages
-- for leader leaf node, run two independent clients
-- leafMailClient communicates normally with peers (only fwd own cluster messages)
-- it creates a ClusterMessage and send to leafClusterClient
-- it fwds [ClusterMessage] received from leafClusterClient to its peers

--
-- leafClusterClient receives [ClusterMessage] from another cluster leader
-- it prepends one of its own ClusterMessage and fwds to next cluster leader
-- it sends the complete received [ClusterMessage] to leafMailClient

-- A leaf node connects to one peer and sends the message to it
-- the lead node server accepts message from another peer

startLeafNode :: LocalNode -> IO ()
startLeafNode = startLeafNodeCommon leafClient

leafClient :: ReceivePort StartMessaging -> LeafInitData -> Process ()
leafClient recvStartMsg leafData = do
  say "Starting Leaf client"

  (sendFwdMsg, recvMsgChan) <- newChan
  (sendClsMsg, recvClsMsg) <- newChan
  (sendRecReq, recReqRecvChan) <- newChan
  let
    workServer = statelessProcess
      { apiHandlers =
        [ handleCall (messageFromPeer sendFwdMsg)
        , handleCast (messageFromLeader sendClsMsg)
        , handleCast (reconnectReqHandler sendRecReq)
        , handleCall testPing]
      , unhandledMessagePolicy = Log
      }

  pid <- getSelfPid
  wpid <- spawnLocal $ do
    link pid
    serve () (statelessInit Infinity) workServer
  register workServerId wpid

  (incomingClsMsg, getIncomingClsMsg) <- newChan
  (sendOwnClsMsg, recvOwnClsMsg) <- newChan

  -- The first node in a cluster is made leader
  let isLeader = all ((leafId leafData) < )
        $ map fst $ peerList leafData
  if isLeader
    then void $ spawnLocal
      $ leafClusterClient recvClsMsg recvOwnClsMsg
        incomingClsMsg leafData
    else return ()

  receiveChan recvStartMsg
  leafMainClient recvMsgChan recReqRecvChan
    getIncomingClsMsg sendOwnClsMsg isLeader leafData

reconnectReqHandler :: _ -> CastHandler _ ReconnectRequest
reconnectReqHandler recReqRecvChan _ r = do
  sendChan recReqRecvChan r
  continue ()

messageFromPeer :: _ -> CallHandler _ MessageList ()
messageFromPeer fwdMsgChan _ ms = do
  sendChan fwdMsgChan ms
  reply () ()

messageFromLeader :: _ -> CastHandler _ [ClusterMessage]
messageFromLeader fwdMsgChan _ (ms) = do
  sendChan fwdMsgChan ms
  continue ()

data FwdMsgResult
  = SendTimeOver
  | Reconnect (LeafNodeId, (String,Int))
    (StdGen, TimePulse)
  | RetryNextPeer MessageList (StdGen, TimePulse)

-- Intra cluster communication
-- same as SafeRing implementation
leafMainClient
  recvMsgChan       -- Intra-cluster msg from peer
  recReqRecvChan    -- reconnect request from intra-cluster peer
  getIncomingClsMsg -- inter-cluster msg
  sendOwnClsMsg     -- inter-cluster msg
  isLeader
  leafData = do

  startTime <- liftIO $ getCurrentTime
  let
    peers = peerList leafData
    prevPeer = head $ reverse peers
  prevNode <- searchRemotePid workServerId (snd prevPeer)

  (sendAddDb, recvAddDb) <- newChan
  let
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration $ configData leafData)
      startTime

    ---------------------------------------------------
    connectToPeer peer maybeMsg rngt = do
      say $ "Searching peer: " ++ (show peer)
      r <- waitCancelTimeout peerSearchTimeout
        =<< (async $ task $ do
          ppid <- searchRemotePid workServerId (snd peer)
          (_ :: Int) <- call ppid TestPing
          return ppid)

      let (nextPeer:_) = rotateExcl peerId peers
          peerId = fst peer

      case r of
        (AsyncDone ppid) ->
          leafMessagePeer peerId ppid maybeMsg rngt
            >>= \case
              (RetryNextPeer msg rng1) ->
                connectToPeer nextPeer (Just msg) rng1
              (Reconnect prevPeer rng2) -> do
                say "Reconnecting"
                connectToPeer prevPeer Nothing rng2
              SendTimeOver -> return ()
              -- Assume work is done if no exception
        _ ->
          connectToPeer nextPeer maybeMsg rngt
    ---------------------------------------------------


    ---------------------------------------------------
    leafMessagePeer peerId ppid maybeMsg rngt = do
      -- Send message and all data not sent earlier
      (msg, newRngt) <- case maybeMsg of
        (Just m) -> return (m, rngt)
        Nothing -> do
          rcpid <- spawnLocal $ do
            liftIO $ threadDelay receiveTimeout
            cast prevNode
              (ReconnectRequest $ (leafId leafData
                , selfIp leafData))
            say "Sent reconnect request"

          -- Blocking call
          -- Everything blocks if no message is received
          -- ie If the previous node is also disconnected
          -- ideally we could try pinging other nodes in the cluster
          (MessageList m c) <- receiveChan recvMsgChan
          exit rcpid ()

          clsMsg <- if isLeader
            then receiveChanTimeout 0 getIncomingClsMsg
            else return Nothing

          let (d, newRng) = random $ fst rngt
              (m1,_) = break
                (\(LeafMessage (i,_,_)) -> i == peerId) m
              newT = TimePulse $ 1 +
                (unTimePulse $ snd rngt)
              myM = LeafMessage
                (leafId leafData, newT, d)
              allMsgs = myM : m
              fwdMsgs = myM : m1
              newRngt = (newRng, newT)

          sendChan sendAddDb (Just allMsgs)
          when isLeader $
            sendChan sendOwnClsMsg
              (ClusterMessage (clusterId leafData) allMsgs)

          -- Add the cluster messages to own DB
          let
            myC = if isLeader
                  then (maybe [] id clsMsg)
                  else c
          forM_ myC
            (\(ClusterMessage _ c)
             -> sendChan sendAddDb (Just c))

          return (MessageList fwdMsgs myC
                 , newRngt)

      liftIO $ threadDelay (timeToMicros Millis 20)
      -- Call the sink node, if timeout then die
      status <- waitCancelTimeout peerCallTimeout
        =<< (async $ task $ do
            (_ :: ()) <- call ppid msg
            return ())
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then case status of
          (AsyncDone _) -> do
            recReq <- receiveChanTimeout 0
              recReqRecvChan
            case recReq of
              Nothing ->
                leafMessagePeer peerId ppid Nothing newRngt
              (Just (ReconnectRequest r)) ->
                return $ Reconnect r newRngt
          _ -> return $ RetryNextPeer msg newRngt
        else return SendTimeOver

    ---------------------------------------------------

    addToDb db = do
      msg <- receiveChan recvAddDb
      case msg of
        Nothing -> return db
        (Just ms) -> addToDb $ Map.union db
          (Map.fromList $ map
           (\(LeafMessage (a,b,c)) -> ((b,a),c)) ms)
    ---------------------------------------------------

  addTask <- async $ task $ addToDb (Map.empty)

  let
    firstMsg = MessageList firstMsg1 []
    firstMsg1 = [LeafMessage (leafId leafData, TimePulse 0, d)]
    (d, newRng) = random initRng
    initRng = (getRngInit (configData leafData) (leafId leafData))

  when isLeader $
    sendChan sendOwnClsMsg
      (ClusterMessage (clusterId leafData) firstMsg1)
  sendChan sendAddDb (Just firstMsg1)
  connectToPeer (head peers) (Just firstMsg) (newRng, TimePulse 0)

  sendChan sendAddDb Nothing
  wait addTask
    >>= \case
    (AsyncDone db) -> reportResult db leafData
    _ -> return ()

reportResult db leafData = do
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
      allValues = map snd $ Map.toList db
  liftIO $ printResult allValues (leafId leafData)

-- Inter cluster communication
-- This code is same as ring
leafClusterClient recvClsMsg recvOwnClsMsg incomingClsMsg leafData = do
  say "Starting Leaf Cluster Client"
  startTime <- liftIO $ getCurrentTime
  ppid <- searchRemotePid workServerId
    (snd $ snd $ nextCluster $ leafData)

  say "connected to next cluster"
  let
    nextClsId = (fst $ nextCluster $ leafData)
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration $ configData leafData)
      startTime

  let
    fwdMsgLoop isFirst = do
      msg <- if isFirst
        -- First time we only have our own message to send
        then return []
        else do
          msg <- receiveChan recvClsMsg
          sendChan incomingClsMsg msg
          return msg
      m <- receiveChan recvOwnClsMsg
      let
        (m1,_) = break
          (\(ClusterMessage i _) -> i == nextClsId) msg
        mNew :: [ClusterMessage]
        mNew = m : m1

      cast ppid mNew
      t <- liftIO $ getCurrentTime
      when (sendEndTime > t) $ fwdMsgLoop False

  fwdMsgLoop True
  say "Finish leafClusterClient"
