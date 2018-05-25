{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
module SafeRing.LeafNode
  (startLeafNode)
  where

import CommonCode
import SafeRing.Types

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
                                   , expect
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , Process
                                   , DiedReason(..)
                                   , ReceivePort
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
                                         , wait
                                         , async
                                         , task)
import Control.Concurrent (threadDelay, MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))
import Data.List (find)

import qualified Data.Map as Map
import System.Random (mkStdGen, random
                     , StdGen)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)


startLeafNode :: LocalNode -> IO ()
startLeafNode = startLeafNodeCommon leafClient

leafClient :: ReceivePort StartMessaging -> LeafInitData -> Process ()
leafClient recvStartMsg leafData = do
  say "Starting Leaf client"

  (sendFwdMsg, recvMsgChan) <- newChan
  (sendRecReq, recReqRecvChan) <- newChan
  let
    workServer = statelessProcess
      { apiHandlers =
        [handleCall (messageFromPeer sendFwdMsg)
        , handleCast (reconnectReqHandler sendRecReq)
        , handleCall testPing]
      , unhandledMessagePolicy = Log
      }

  pid <- getSelfPid
  register workServerId
    =<< (spawnLocal $ do
    link pid
    serve () (statelessInit Infinity) workServer)

  receiveChan recvStartMsg
  leafMainClient recvMsgChan recReqRecvChan leafData

reconnectReqHandler :: _ -> CastHandler _ ReconnectRequest
reconnectReqHandler recReqRecvChan _ r = do
  sendChan recReqRecvChan r
  continue ()

messageFromPeer :: _ -> CallHandler _ MessageList ()
messageFromPeer fwdMsgChan _ (MessageList ms) = do
  sendChan fwdMsgChan ms
  reply () ()

data FwdMsgResult
  = SendTimeOver
  | Reconnect (LeafNodeId, (String,Int))
    (StdGen, TimePulse)
  | RetryNextPeer ([(LeafNodeId, TimePulse, Double)]
                  , (StdGen, TimePulse))

leafMainClient recvMsgChan recReqRecvChan leafData = do
  startTime <- liftIO $ getCurrentTime
  let
    Just selfIp = snd <$> find
      ((== (leafId leafData)) . fst)
      (nodesList $ configData leafData)
    peers = rotateExcl (leafId leafData)
      $ nodesList $ configData leafData
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

      let (_:nextPeer:_) = n ++ p
          peerId = fst peer
          (p,n) = break (== peer) peers

      case r of
        (AsyncDone ppid) ->
          leafMessagePeer peerId ppid maybeMsg rngt
            >>= \case
              (RetryNextPeer (msg,rng1)) ->
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
                    , selfIp))
                say "Sent reconnect request"
              m <- receiveChan recvMsgChan
              exit rcpid ()
              let (d, newRng) = random $ fst rngt
                  (m1,_) = break
                    (\(i,_,_) -> i == peerId) m
                  newT = TimePulse $ 1 +
                    (unTimePulse $ snd rngt)
                  myM = (leafId leafData, newT, d)
                  allMsgs = myM : m
                  fwdMsgs = myM : m1
                  newRngt = (newRng, newT)
              sendChan sendAddDb (Just allMsgs)
              return (fwdMsgs, newRngt)
            (Just m) -> return (m, rngt)

          -- Call the sink node, if timeout then die
          status <- waitCancelTimeout peerCallTimeout
            =<< (async $ task $ do
                (_ :: ()) <- call ppid (MessageList msg)
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
              _ -> return $ RetryNextPeer (msg, newRngt)
            else return SendTimeOver

      say "Starting fwdMsgLoop"
      fwdMsgLoop maybeMsg rngt
    ---------------------------------------------------

    addToDb db = do
      msg <- receiveChan recvAddDb
      case msg of
        Nothing -> return db
        (Just ms) -> addToDb $ Map.union db
          (Map.fromList $ map (\(a,b,c) -> ((a,b),c)) ms)
    ---------------------------------------------------

  addTask <- async $ task $ addToDb (Map.empty)

  let
    firstMsg = [(leafId leafData, TimePulse 0, d)]
    (d, newRng) = random initRng
    initRng = (getRngInit (configData leafData) (leafId leafData))

  say "Starting Leaf Process"
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
