{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
module SafeRing.LeafNode
  (startLeafNode)
  where

import Utils
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
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))

import qualified Data.Map as Map
import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- A leaf node connects to one peer and broadcasts the message to it
-- the lead node server accepts broadcast message from another peer

-- STEPS overview
-- Setup server and wait for supervisor to connect
-- Get details (time, seed, peer) from supervisor
-- Starts client and work-server process, and connect to the peer
-- inform supervisor on success
-- Wait for kick-off signal from supervisor
-- Do message exchange with peer, serve another peer
-- After timeout print sum, and exit client and work-server process

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
  let
    workServer = statelessProcess
      { apiHandlers =
        [handleCall (messageFromPeer sendFwdMsg)
        , handleCall testPing]
      , unhandledMessagePolicy = Log
      }

  pid <- getSelfPid
  wpid <- spawnLocal $ do
    link pid
    serve () (statelessInit Infinity) workServer
  register workServerId wpid

  leafMainClient recvMsgChan leafData

testPing :: CallHandler _ TestPing Int
testPing s _ = do
  say "testPing"
  reply 3 s

messageFromPeer :: _ -> CallHandler _ MessageList ()
messageFromPeer fwdMsgChan _ (MessageList ms) = do
  sendChan fwdMsgChan ms
  reply () ()

leafMainClient recvMsgChan leafData = do
  startTime <- liftIO $ getCurrentTime

  (sendAddDb, recvAddDb) <- newChan
  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime
    peers = peerList leafData
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
              (Left (msg,rng1)) ->
                connectToPeer nextPeer (Just msg) rng1
              _ -> return ()
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
              m <- receiveChan recvMsgChan
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
              (AsyncDone _) -> fwdMsgLoop Nothing newRngt
              _ -> return $ Left (msg, newRngt)
            else return (Right ())

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
