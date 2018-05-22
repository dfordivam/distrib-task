{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
module HierRing.LeafNode
  (startLeafNode)
  where

import Utils
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
                                   , NodeId(..)
                                   , WhereIsReply(..))
import Control.Distributed.Process.ManagedProcess.Server (replyChan, continue)
import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
                                        , LocalNode)
import Control.Distributed.Process.Async (AsyncResult(..)
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
startLeafNode node = runProcess node $ do
  say "Starting Leaf server"
  pId <- spawnLocal $ serve ()
    (statelessInit Infinity) leafServer
  register leafServerId pId
  say $ "Server launched at: " ++ show (nodeAddress . processNodeId $ pId)
  liftIO $ forever $ threadDelay 1000000000

type LeafServerState = Maybe (LeafInitData, ProcessId)

-- Backgroud server, always running
-- To get messages from supervisor
leafServer = statelessProcess
  { apiHandlers = [ handleCall initClient
                  ]
  , unhandledMessagePolicy = Log
  }

initClient :: CallHandler () LeafInitData ()
initClient _ p = do
  pid <- spawnLocal $ leafClient p
  reply () ()

leafClient :: LeafInitData -> Process ()
leafClient leafData = do
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

  let isLeader = all ((leafId leafData) < )
        $ map fst $ peerList leafData
  if isLeader
    then void $ spawnLocal
      $ leafClusterClient recvClsMsg recvOwnClsMsg
        incomingClsMsg leafData
    else return ()

  leafMainClient recvMsgChan recReqRecvChan
    getIncomingClsMsg sendOwnClsMsg leafData

testPing :: CallHandler _ TestPing Int
testPing s _ = do
  say "testPing"
  reply 3 s

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

leafMainClient recvMsgChan recReqRecvChan
  getIncomingClsMsg sendOwnClsMsg leafData
  = do
  startTime <- liftIO $ getCurrentTime
  let
    isLeader = all ((leafId leafData) < ) $ map fst peers
    peers = peerList leafData
    prevPeer = head $ reverse peers
  prevNode <- searchRemotePid workServerId (snd prevPeer)

  (sendAddDb, recvAddDb) <- newChan
  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
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
      let
        fwdMsgLoop maybeMsg rngt = do
          -- Send message and all data not sent earlier
          (msg, newRngt) <- case maybeMsg of
            Nothing -> do
              -- Everything blocks if no message is received
              rcpid <- spawnLocal $ do
                liftIO $ threadDelay receiveTimeout
                cast prevNode
                  (ReconnectRequest $ (leafId leafData
                    , selfIp leafData))
                say "Sent reconnect request"

              -- Blocking call
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
            (Just m) -> return (m, rngt)

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
                    fwdMsgLoop Nothing newRngt
                  (Just (ReconnectRequest r)) ->
                    return $ Reconnect r newRngt
              _ -> return $ RetryNextPeer msg newRngt
            else return SendTimeOver

      say "Starting fwdMsgLoop"
      fwdMsgLoop maybeMsg rngt
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
  say "Starting Leaf Process"
  sendChan sendAddDb (Just firstMsg1)
  connectToPeer (head peers) (Just firstMsg) (newRng, TimePulse 0)

  sendChan sendAddDb Nothing
  waitCancelTimeout (timeToMicros Seconds waitDuration) addTask
    >>= \case
      (AsyncDone db) -> reportResult db leafData
      _ -> do
        say "timeout in addToDB"
        return ()

reportResult db leafData = do
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
      allValues = map snd $ Map.toList db
  say $ "leafClient Result: "
    ++ (show $ unLeafNodeId $ leafId leafData)
    ++ " => " ++ (show (length allValues, s))

leafClusterClient recvClsMsg recvOwnClsMsg incomingClsMsg leafData = do
  say "Starting Leaf Cluster Client"
  startTime <- liftIO $ getCurrentTime
  ppid <- searchRemotePid workServerId
    (snd $ snd $ nextCluster $ leafData)

  say "connected to next cluster"
  let
    nextClsId = (fst $ nextCluster $ leafData)
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime

  let
    fwdMsgLoop isFirst = do
      -- Send message and all data not sent earlier
      msg <- if isFirst
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
