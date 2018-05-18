{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PartialTypeSignatures #-}
module LinkList.LeafNode
  (startLeafNode)
  where

import Utils
import LinkList.Types

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , reply
                                                  , call
                                                  , cast
                                                  , callTimeout
                                                  , defaultProcess
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
                                   , send
                                   , newChan
                                   , sendChan
                                   , receiveChan
                                   , expectTimeout
                                   , register
                                   , monitorPort
                                   , sendPortId
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
import Control.Concurrent (threadDelay, MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))

import Data.IORef
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import qualified Data.Vector.Unboxed.Mutable as MUV
import qualified Data.Vector.Unboxed as UV
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
  pId <- spawnLocal $ serve () (initServerState) leafServer
  register leafServerId pId
  say $ "Server launched at: " ++ show (nodeAddress . processNodeId $ pId)
  liftIO $ forever $ threadDelay 1000000000

initServerState _ = do
  return $ InitOk Nothing Infinity

type LeafServerState = Maybe (LeafInitData, ProcessId)

-- Backgroud server, always running
-- To get messages from supervisor
leafServer = defaultProcess
  { apiHandlers = [ handleCall initClient
                  , handleCast startClient
                  ]
  , infoHandlers = []
  , unhandledMessagePolicy = Log
  }

initClient :: CallHandler LeafServerState LeafInitData ()
initClient _ p = do
  pid <- spawnLocal $ leafClient p
  reply () (Just $ (p, pid))

startClient :: CastHandler LeafServerState StartMessaging
startClient Nothing s = do
  say "Error: startClient without data"
  continue Nothing

startClient s@(Just (_, pid)) _ = do
  send pid ()
  continue s

leafClient :: LeafInitData -> Process ()
leafClient leafData = do
  say "Starting Leaf client"
  say "Starting Leaf-work server"

  (sendFwdMsg, recvFwdMsg) <- newChan
  (sendAddDb, recvAddDb) <- newChan

  let
    workServer = defaultProcess
      { apiHandlers =
        [handleCast (messageFromPeer
                     (sendFwdMsg
                     , sendAddDb
                     , leafData))
        , handleCall testPing]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }

  wpid <- spawnLocal $ serve
    (getRngInit (configData leafData) (leafId leafData))
    initWorkServer workServer
  register workServerId wpid

  ppid <- searchRemotePid workServerId (peerIp leafData)
  spid <- searchRemotePid supervisorServerId (serverIp leafData)
  say $ "Doing call to:" ++ (show ppid)
  say $ "Doing call to:" ++ (show spid)
  working1 <- call ppid (TestPing)
  working2 <- call spid (TestPing)
  say $ "Did call to:" ++ (show $ (working1 :: Int))
  say $ "Did call to:" ++ (show $ (working2 :: Int))

  -- Wait for StartMessaging
  reply <- expectTimeout 10000000
  say $ "Got reply:" ++ (show reply)
  case (reply :: Maybe ()) of
    Nothing ->
      say $ "timeout from leafclient: "
        ++ (show $ unLeafNodeId $ leafId leafData)
    _ -> do
      leafClientWork leafData ppid (recvFwdMsg, recvAddDb)

-- start working
-- print result and gracefully exit?
leafClientWork leafData ppid (recvFwdMsg, recvAddDb) = do
  say "starting leafClientWork"
  startTime <- liftIO $ getCurrentTime

  let
    myId = unLeafNodeId (leafId leafData)
    firstMsg = MessageList [(leafId leafData, TimePulse 0, 1)]

  dbRef <- liftIO $ do
    vec <- MUV.new (totalNodes leafData)
    MUV.write vec (myId - 1) 1.0 -- Can be obtained from rng also
    newIORef $ Seq.singleton vec

  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime

    fwdMsgLoop = do
      -- Send message and all data not sent earlier
      msg <- receiveChan recvFwdMsg
      newValues <- cast ppid msg
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then fwdMsgLoop
        else return ()

    addToDb = do
      msg <- receiveChan recvAddDb
      liftIO $ do
        vec <- MUV.new (totalNodes leafData)
        mapM (modDb vec) msg
      addToDb

    modDb vec (LeafNodeId l, TimePulse t, v) = do
      db <- readIORef dbRef
      case (Seq.lookup t db) of
        Nothing -> do
          MUV.write vec (l - 1) v
          writeIORef dbRef (db Seq.|> vec)
        (Just vec2) -> do
          MUV.write vec2 (l - 1) v
          writeIORef dbRef (Seq.update t vec2 db)

  spawnLocal $ fwdMsgLoop
  spawnLocal $ addToDb
  -- This triggers the messaging
  say "Sending trigger"
  cast ppid firstMsg

  liftIO $ threadDelay (timeToMicros Seconds (sendDuration + waitDuration))

  allVec <- liftIO $ do
    db <- readIORef dbRef
    mapM UV.freeze $ toList db
  -- Calculate sum and exit
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
      allValues = filter (/= 0.0) $ concat $ map UV.toList allVec
  say $ "leafClient Result: "
    ++ (show $ unLeafNodeId $ leafId leafData)
    ++ " => " ++ (show (length allValues, s))
  return ()

type WorkServerDb = Seq.Seq (MUV.IOVector Double)

initWorkServer rng = do
  return $ InitOk (rng, TimePulse 0) Infinity

testPing :: CallHandler _ TestPing Int
testPing s _ = do
  say "testPing"
  reply 3 s

messageFromPeer :: _ -> CastHandler _ MessageList
messageFromPeer (fwdMsgChan, addDbChan, leafData)
  (rng, t) (MessageList ms) = do

  let (d, newRng) = random rng
      myMessage = (leafId leafData, newT, d)
      newT = TimePulse $ (unTimePulse t) + 1

  sendChan fwdMsgChan
    (MessageList $ myMessage : take ((totalNodes leafData) - 2) ms)
  sendChan addDbChan (myMessage : ms)
  continue (newRng, newT)
