{-# LANGUAGE ScopedTypeVariables #-}

module SingleServer.LeafNode
  (startLeafNode)
  where

import CommonCode
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
                                   , expect
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
startLeafNode = startLeafNodeCommon leafClient

leafClient :: LeafInitData -> Process ()
leafClient leafData = do
  say "Starting Leaf client"
  spid <- searchRemotePid supervisorServerId
    (serverIp $ configData leafData)
  say $ "Doing call to:" ++ (show spid)
  working <- call spid (TestPing)
  say $ "Got ping response:" ++ (show $ (working :: Int))
  (_ :: StartMessaging) <- expect
  leafClientWork leafData spid

leafClientWork leafData spid = do
  startTime <- liftIO $ getCurrentTime
  let
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration $ configData leafData)
      startTime

    mainLoop (rng, old) = do
      let (d, newRng) = random rng
      -- Send message and sync with server
      newValues <- call spid (NewMessage d (length old))
      let
        new :: [Double]
        new = old ++ newValues
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then mainLoop (newRng, new)
        else return new

  allValues <- mainLoop ((getRngInit (configData leafData) (leafId leafData))
                        , [])

  liftIO $ printResult allValues (leafId leafData)
