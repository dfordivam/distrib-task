{-# LANGUAGE ScopedTypeVariables #-}
module DenseMesh.Supervisor
  (startSupervisorNode)
  where

import DenseMesh.Types
import Utils

import Control.Distributed.Process.ManagedProcess.Client (callChan, cast)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , call
                                                  , reply
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
import Control.Distributed.Process ( expectTimeout
                                   , whereisRemoteAsync
                                   , spawnLocal
                                   , receiveChan
                                   , link
                                   , register
                                   , say
                                   , NodeId(..)
                                   , Process
                                   , ProcessId
                                   , ReceivePort
                                   , WhereIsReply(..) )
import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))
import Control.Distributed.Process.Node ( runProcess
                                        , LocalNode)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Network.Transport     (EndPointAddress(..))
import Control.Concurrent (threadDelay
                          , MVar
                          , newEmptyMVar
                          , newMVar
                          , putMVar
                          , modifyMVar_
                          , modifyMVar
                          , readMVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (void, forever, forM)

-- Supervisor acts as both a client and a server
-- It first discovers all nodes and establishes connection with them
-- After the leaf nodes are ready
-- It kicks the messages exchange

startSupervisorNode
  :: LocalNode
  -> ConfigData
  -> NodesConfig
  -> (String, Int)
  -> IO ()
startSupervisorNode node cd nodeList@(n:[]) serverIp =
  putStrLn "Need atleast two nodes"

startSupervisorNode node cd nodeList@(n:ns) serverIp = runProcess node $ do
  spid <- spawnLocal supervisorServer
  register supervisorServerId spid

  kickSignalMVar <- liftIO $ newEmptyMVar
  initDoneMVar <- liftIO $ newMVar (length nodeList)

  forM (zip [1..] nodeList) $ \(i, leaf) -> spawnLocal $ do
    say $ "Searching leaf: " ++ (show leaf)
    leafPid <- searchRemotePid leafServerId leaf
    say $ "Found leaf: " ++ (show leaf)
    (_ :: ()) <- call leafPid
      (LeafInitData cd (LeafNodeId i)
        serverIp nodeList)
    -- Indicate if all leaves init correctly
    liftIO $ modifyMVar_ initDoneMVar (\c -> return (c - 1))

    -- wait for kick signal
    liftIO $ readMVar kickSignalMVar

    -- start nodes
    say $ "Start messaging: " ++ (show leaf)
    cast leafPid (StartMessaging)

  let waitLoop = do
        c <- readMVar initDoneMVar
        if c > 0
          then threadDelay 500000 >> waitLoop
          else putMVar kickSignalMVar ()
  liftIO $ waitLoop

  liftIO $ threadDelay (timeToMicros Seconds ((\(s,w,_) -> s + w) cd))

supervisorServer :: Process ()
supervisorServer = do
  let
    server = defaultProcess
      { apiHandlers = [handleCall testPing]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }
  say "Starting supervisor-server"
  serve () initServerState server

initServerState _ = do
  return $ InitOk () NoDelay

testPing :: CallHandler () TestPing Int
testPing _ _ = do
  say "testPing"
  reply 5 ()
