module SingleServer.LeafNode
  (startLeafNode)
  where

import Utils
import SingleServer.Types

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , reply
                                                  , call
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
import Control.Distributed.Process.Extras.Time (Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
                                        , LocalNode)
import Control.Concurrent (threadDelay, MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))

import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- Leaf node start as a server, ie it waits for supervisor to connect
-- After receiving relevant details and kick-off signal from supervisor
-- it acts as a client and send messages and receives replies

-- STEPS overview
-- Setup server and wait for supervisor to connect
-- Get details (time, seed) from supervisor
-- Starts client process and connect back to supervisor server
-- Wait for kick-off signal from supervisor
-- Do message exchange with supervisor server
-- After timeout print sum, and exit client process

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
  spid <- searchRemotePid supervisorServerId (serverIp leafData)
  say $ "Doing call to:" ++ (show spid)
  working <- call spid (TestPing)
  say $ "Did call to:" ++ (show $ (working :: Int))
  reply <- expectTimeout 10000000
  say $ "Got reply:" ++ (show reply)
  case (reply :: Maybe ()) of
    Nothing ->
      say $ "timeout from leafclient: "
        ++ (show $ leafId leafData)
    _ -> do
      leafClientWork leafData spid

-- start working
-- print result and gracefully exit?
leafClientWork leafData pid = do
  startTime <- liftIO $ getCurrentTime
  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime

    mainLoop (rng, old) = do
      let (d, newRng) = random rng
      -- Send message and sync with server
      newValues <- call pid (NewMessage d (length old))
      let
        new :: [Double]
        new = old ++ newValues
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then mainLoop (newRng, new)
        else return new
    myId = LeafNodeId (leafId leafData)
  allValues <- mainLoop ((getRngInit (configData leafData) myId), [])
  -- Calculate sum and exit
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
  say $ "leafClient Result: "
    ++ (show $ leafId leafData)
    ++ " => " ++ (show (length allValues, s))
  return ()
