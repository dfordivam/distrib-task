{-# LANGUAGE ScopedTypeVariables #-}

module SingleServer.LeafNode
  (startLeafNode)
  where

import CommonCode
import SingleServer.Types

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
                                   , receiveChan
                                   , sendPortId
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , Process
                                   , DiedReason(..)
                                   , ProcessId(..)
                                   , ReceivePort
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

import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- Leaf node start as a server, ie it waits for supervisor to connect
-- After receiving relevant details and kick-off signal from supervisor
-- it acts as a client and send messages and receives replies


startLeafNode :: LocalNode -> IO ()
startLeafNode = startLeafNodeCommon leafClient

leafClient :: ReceivePort StartMessaging -> LeafInitData -> Process ()
leafClient recvStartMsg leafData = do
  say "Starting Leaf client"
  spid <- searchRemotePid supervisorServerId
    (serverIp $ configData leafData)
  say $ "Doing call to:" ++ (show spid)
  working <- call spid (TestPing)
  say $ "Got ping response:" ++ (show $ (working :: Int))
  receiveChan recvStartMsg
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
