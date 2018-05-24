{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PartialTypeSignatures #-}
module DenseMesh.LeafNode
  (startLeafNode)
  where

import CommonCode
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
                                                  , statelessProcess
                                                  , statelessInit
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
import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
                                        , LocalNode)
import Control.Concurrent (threadDelay, MVar
                          , newMVar, readMVar
                          , modifyMVar_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void, when)
import Network.Transport     (EndPointAddress(..))

import Data.IORef
import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- A Dense Mesh is one in which all leaves send message to every other leaf
-- Simple architecture, with lot of redundancy

startLeafNode :: LocalNode -> IO ()
startLeafNode = startLeafNodeCommon leafClient

leafClient :: LeafInitData -> Process ()
leafClient leafData = do
  say "Starting Leaf client"

  dbRef <- liftIO $ newMVar []

  let
    workServer = statelessProcess
      { apiHandlers =
        [handleCast (messageFromPeer dbRef)
        , handleCall testPing]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }

  register workServerId
    =<< (spawnLocal $ serve () (statelessInit Infinity) workServer)

  let peers = map snd $ nodesList $ configData leafData
  ppids <- mapM (searchRemotePid workServerId) peers
  spid <- searchRemotePid supervisorServerId
    (serverIp $ configData leafData)

  say $ "Doing ping to peers"
  (_ :: [Int]) <- mapM ((flip call) TestPing) ppids
  (_ :: Int) <- call spid (TestPing)

  (_ :: StartMessaging) <- expect
  leafClientWork leafData ppids dbRef

leafClientWork leafData ppids dbRef = do
  say "starting leafClientWork"
  startTime <- liftIO $ getCurrentTime

  let
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration $ configData leafData)
      startTime

    sendMsgLoop rng = do
      liftIO $ threadDelay (timeToMicros Millis 50)
      let (d, newRng) = random rng
          msg = NewMessage d
      -- Broadcast messages
      mapM_ ((flip cast) msg) ppids
      t <- liftIO $ getCurrentTime
      when (sendEndTime > t) $ sendMsgLoop newRng

  sendMsgLoop
    (getRngInit (configData leafData) (leafId leafData))

  allValues <- liftIO $ do
    readMVar dbRef

  liftIO $ printResult allValues (leafId leafData)

messageFromPeer :: _ -> CastHandler _ NewMessage
messageFromPeer (dbRef) _ (NewMessage d) = do
  liftIO $ modifyMVar_ dbRef (\ds -> return $ d:ds)
  continue ()
