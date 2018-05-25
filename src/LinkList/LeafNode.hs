{-# LANGUAGE ScopedTypeVariables #-}
module LinkList.LeafNode
  (startLeafNode)
  where

import CommonCode
import LinkList.Types

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
                                   , expect
                                   , register
                                   , monitorPort
                                   , sendPortId
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , Process
                                   , SendPort
                                   , DiedReason(..)
                                   , ProcessId(..)
                                   , ReceivePort
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

import Data.IORef
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import qualified Data.Vector.Unboxed.Mutable as MUV
import qualified Data.Vector.Unboxed as UV
import System.Random (mkStdGen, random, StdGen)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)

-- A leaf node connects to one peer and broadcasts the message to it
-- the lead node server accepts broadcast message from another peer

startLeafNode :: LocalNode -> IO ()
startLeafNode = startLeafNodeCommon leafClient

leafClient :: ReceivePort StartMessaging -> LeafInitData -> Process ()
leafClient recvStartMsg leafData = do
  say "Starting Leaf client"

  (sendFwdMsg, recvFwdMsg) <- newChan
  (sendAddDb, recvAddDb) <- newChan

  let
    workServer = defaultProcess
      { apiHandlers =
        [handleCast (messageFromPeer
                     (sendFwdMsg
                     , sendAddDb
                     , leafData))
        , handleCall testPing2]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }

  register workServerId
    =<< (spawnLocal $ serve
    (getRngInit (configData leafData) (leafId leafData))
    initWorkServer workServer)

  let peer = snd $ head $ rotateExcl (leafId leafData)
        (nodesList $ configData leafData)
  ppid <- searchRemotePid workServerId peer
  spid <- searchRemotePid supervisorServerId
    (serverIp $ configData leafData)
  say $ "Doing call to:" ++ (show ppid)
  say $ "Doing call to:" ++ (show spid)
  working1 <- call ppid (TestPing)
  working2 <- call spid (TestPing)
  say $ "Did call to:" ++ (show $ (working1 :: Int))
  say $ "Did call to:" ++ (show $ (working2 :: Int))

  receiveChan recvStartMsg
  leafClientWork leafData ppid (recvFwdMsg, recvAddDb)

-- start working
-- print result and gracefully exit?
leafClientWork leafData ppid (recvFwdMsg, recvAddDb) = do
  say "starting leafClientWork"
  startTime <- liftIO $ getCurrentTime

  let
    totalNodes = (length $ nodesList $ configData leafData)
    myId = unLeafNodeId (leafId leafData)
    firstMsg = MessageList [(leafId leafData, TimePulse 0, 1)]

  dbRef <- liftIO $ do
    vec <- MUV.new totalNodes
    MUV.write vec (myId - 1) 1.0 -- Can be obtained from rng also
    newIORef $ Seq.singleton vec

  let
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration $ configData leafData)
      startTime

    fwdMsgLoop = do
      -- Send message and all data not sent earlier
      msg <- receiveChan recvFwdMsg
      cast ppid msg
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then fwdMsgLoop
        else return ()

    addToDb = do
      msg <- receiveChan recvAddDb
      liftIO $ do
        vec <- MUV.new totalNodes
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

  liftIO $ threadDelay (timeToMicros Seconds (sendDuration $ configData leafData))

  allVec <- liftIO $ do
    db <- readIORef dbRef
    mapM UV.freeze $ toList db
  -- Calculate sum and exit
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
      allValues = filter (/= 0.0) $ concat $ map UV.toList allVec
  liftIO $ printResult allValues (leafId leafData)

type WorkServerDb = Seq.Seq (MUV.IOVector Double)

initWorkServer rng = do
  return $ InitOk (rng, TimePulse 0) Infinity

testPing2 :: CallHandler (StdGen, TimePulse) TestPing Int
testPing2 s _ = do
  say "testPing2"
  reply 3 s

messageFromPeer
  :: (SendPort MessageList
     , SendPort [(LeafNodeId, TimePulse, Double)]
     , LeafInitData)
  -> CastHandler (StdGen, TimePulse) MessageList
messageFromPeer (fwdMsgChan, addDbChan, leafData)
  (rng, t) (MessageList ms) = do

  let (d, newRng) = random rng
      myMessage = (leafId leafData, newT, d)
      newT = TimePulse $ (unTimePulse t) + 1
      totalNodes = (length $ nodesList $ configData leafData)

  sendChan fwdMsgChan
    (MessageList $ myMessage : take (totalNodes - 2) ms)
  sendChan addDbChan (myMessage : ms)
  continue (newRng, newT)
