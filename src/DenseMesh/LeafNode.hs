{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PartialTypeSignatures #-}
module DenseMesh.LeafNode
  (startLeafNode)
  where

import Utils
import DenseMesh.Types

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
import Control.Concurrent (threadDelay, MVar
                          , newMVar, readMVar
                          , modifyMVar_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))

import Data.IORef
import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- A Dense Mesh is one in which all leaves send message to every other leaf
-- Simple architecture, with lot of redundancy

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

  dbRef <- liftIO $ newMVar []

  let
    workServer = defaultProcess
      { apiHandlers =
        [handleCast (messageFromPeer dbRef)
        , handleCall testPing]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }

  wpid <- spawnLocal $ serve
    (getRngInit (configData leafData) (leafId leafData))
    initWorkServer workServer
  register workServerId wpid

  ppids <- mapM (searchRemotePid workServerId) (peers leafData)
  spid <- searchRemotePid supervisorServerId (serverIp leafData)
  say $ "Doing call to peers"
  say $ "Doing call to:" ++ (show spid)
  working1 <- mapM ((flip call) TestPing) ppids
  working2 <- call spid (TestPing)
  say $ "Did call to:" ++ (show $ (working1 :: [Int]))
  say $ "Did call to:" ++ (show $ (working2 :: Int))

  -- Wait for StartMessaging
  reply <- expectTimeout 10000000
  say $ "Got reply:" ++ (show reply)
  case (reply :: Maybe ()) of
    Nothing ->
      say $ "timeout from leafclient: "
        ++ (show $ unLeafNodeId $ leafId leafData)
    _ -> do
      leafClientWork leafData ppids dbRef

-- start working
-- print result and gracefully exit?
leafClientWork leafData ppids dbRef = do
  say "starting leafClientWork"
  startTime <- liftIO $ getCurrentTime

  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime

    sendMsgLoop rng = do
      liftIO $ threadDelay (timeToMicros Millis 50)
      let (d, newRng) = random rng
          msg = NewMessage d
      -- Broadcast messages
      mapM ((flip cast) msg) ppids
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then sendMsgLoop newRng
        else return ()

  spawnLocal $ sendMsgLoop
    (getRngInit (configData leafData) (leafId leafData))

  liftIO $ threadDelay (timeToMicros Seconds (sendDuration + waitDuration))

  allValues <- liftIO $ do
    readMVar dbRef
  -- Calculate sum and exit
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
  say $ "leafClient Result: "
    ++ (show $ unLeafNodeId $ leafId leafData)
    ++ " => " ++ (show (length allValues, s))
  return ()


initWorkServer _ = do
  return $ InitOk () Infinity

testPing :: CallHandler _ TestPing Int
testPing s _ = do
  say "testPing"
  reply 4 s

messageFromPeer :: _ -> CastHandler _ NewMessage
messageFromPeer (dbRef)
  _ (NewMessage d) = do

  liftIO $ modifyMVar_ dbRef (\ds -> return $ d:ds)
  continue ()
