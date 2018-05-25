{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module CommonCode where


import Control.Distributed.Process ( spawnLocal
                                   , say
                                   , send
                                   , expectTimeout
                                   , register
                                   , newChan
                                   , sendChan
                                   , getSelfPid
                                   , sendPortId
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , expect
                                   , Process
                                   , ProcessId(..)
                                   , SendPort
                                   , ReceivePort
                                   , NodeId(..)
                                   , WhereIsReply(..))
import Control.Distributed.Process.Node ( runProcess
                                        , LocalNode)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , reply
                                                  , call
                                                  , cast
                                                  , callTimeout
                                                  , defaultProcess
                                                  , handleRpcChan
                                                  , handleCast
                                                  , handleCall
                                                  , continue
                                                  , statelessProcess
                                                  , statelessInit
                                                  , InitResult(..)
                                                  , UnhandledMessagePolicy(..)
                                                  , ChannelHandler
                                                  , ActionHandler
                                                  , CastHandler
                                                  , CallHandler
                                                  , ProcessDefinition(..) )
import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))

import Network.Transport     (EndPointAddress(..))
import Data.Typeable (Typeable)
import Data.Binary
import GHC.Generics
import System.Random (mkStdGen, random)
import Control.Monad (void, forever, forM, when)
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent (threadDelay
                          , MVar
                          , newEmptyMVar
                          , newMVar
                          , putMVar
                          , modifyMVar_
                          , modifyMVar
                          , readMVar)

import qualified Data.ByteString.Char8 as BS (pack)

searchRemotePid :: String -> (String, Int) -> Process ProcessId
searchRemotePid name addr@(h,p) = do
  let ep = EndPointAddress $ BS.pack $
                   h ++ ":" ++ (show p)
  -- XXX is 0 required?
                   ++ ":0"
      srvId = NodeId ep
  whereisRemoteAsync srvId name
  reply <- expectTimeout 1000000
  case reply of
    Just (WhereIsReply _ (Just sid)) -> return sid
    _ -> do
      say $ "Search Remote Pid Retry: " ++ (show addr)
      searchRemotePid name addr

data ConfigData = ConfigData
  { sendDuration :: Int
  , waitDuration :: Int
  , seedValue :: Int
  , serverIp :: (String, Int)
  , nodesList :: NodesList
  }
  deriving (Generic, Typeable, Binary, Show)

type NodesList = [(LeafNodeId, (String, Int))]

newtype LeafNodeId = LeafNodeId { unLeafNodeId :: Int }
  deriving (Generic, Typeable, Binary, Eq, Ord, Show)

data StartMessaging = StartMessaging
  deriving (Generic, Typeable, Binary)

data TestPing = TestPing
  deriving (Generic, Typeable, Binary)

data ExitSignal = ExitSignal
  deriving (Generic, Typeable, Binary)

getRngInit cd (LeafNodeId i)
  = mkStdGen seed
  where seed = s * i * 15485863 -- a prime number
        s = seedValue cd

leafServerId = "leaf-server"
workServerId = "work-server"
supervisorServerId = "supervisor-server"

-- 1 -> [1,2,3,4] == [2,3,4]
-- 2 -> [1,2,3,4] == [3,4,1]
-- This is used to determine peers in a ring configuration
rotateExcl :: (Eq k) => k -> [(k,l)] -> [(k,l)]
rotateExcl _ [] = error "Empty list in rotateExcl"
rotateExcl k ks = ks2 ++ ks1
  where (ks1, _:ks2) = break (\(i,_) -> i == k) ks

printResult :: [Double] -> LeafNodeId -> IO ()
printResult allValues i = do
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
  liftIO $ putStrLn $ "Result: "
    ++ (show $ unLeafNodeId i) ++ " : "
    ++ " => " ++ (show (length allValues, s))

-----------------------------------------------------
-- Common code run on all leaf nodes.
-- Overview
-- Setup server and wait for supervisor to connect
-- Get details (time, seed) from supervisor
-- Starts client process (leafClient) and connect back to supervisor server
-- Wait for kick-off signal from supervisor
-- Do message exchange
-- After timeout print sum, and exit

startLeafNodeCommon
  :: (Binary a, Typeable a)
  => (ReceivePort StartMessaging -> a -> Process ())
  -> LocalNode -> IO ()
startLeafNodeCommon leafClient node = runProcess node $ do
  say "Starting Leaf server"
  pid <- getSelfPid
  (sendStartMsg, recvStartMsg) <- newChan
  let
    -- Backgroud server, always running
    -- To get messages from supervisor
    leafServer = statelessProcess
      { apiHandlers = [ handleCall (initClient $ leafClient recvStartMsg)
                      , handleCast (startClient sendStartMsg)
                      , handleCast (doExitProcess pid)
                      ]
      , unhandledMessagePolicy = Log
      }

  register leafServerId
    =<< spawnLocal (serve () (statelessInit Infinity) leafServer)

  (_ :: ExitSignal) <- expect
  return ()

initClient
  :: (a -> Process ())
 -> CallHandler () a ()
initClient leafClient _ p = do
  spawnLocal $ leafClient p
  reply () ()

startClient :: SendPort StartMessaging -> CastHandler () StartMessaging
startClient sendStartMsg () _ = do
  sendChan sendStartMsg StartMessaging
  continue ()

doExitProcess :: ProcessId -> CastHandler () ExitSignal
doExitProcess pid _ ExitSignal = do
  send pid ExitSignal
  continue ()
-----------------------------------------------------

startSupervisorNodeCommon
  :: (Binary a, Typeable a)
  => Process ()
  -> (ConfigData -> LeafNodeId -> a)
  -> LocalNode
  -> ConfigData
  -> IO ()
startSupervisorNodeCommon
  supervisorServer
  makeLeafInitData
  node cd = runProcess node $ do

  register supervisorServerId
    =<< spawnLocal supervisorServer

  kickSignalMVar <- liftIO $ newEmptyMVar
  timeoutMVar <- liftIO $ newEmptyMVar
  initDoneMVar <- liftIO $ newMVar
    (length $ nodesList cd)

  forM (nodesList cd) $ \(i, leaf) -> spawnLocal $ do
    say $ "Searching leaf: " ++ (show leaf)
    leafPid <- searchRemotePid leafServerId leaf
    say $ "Found leaf: " ++ (show leaf)
    (_ :: ()) <- call leafPid
      (makeLeafInitData cd i)

    -- Indicate if all leaves init correctly
    liftIO $ modifyMVar_ initDoneMVar (\c -> return (c - 1))

    -- wait for kick signal
    liftIO $ readMVar kickSignalMVar

    -- start nodes
    say $ "Start messaging: " ++ (show leaf)
    cast leafPid (StartMessaging)

    -- wait for timeout
    liftIO $ readMVar timeoutMVar
    cast leafPid ExitSignal

  let waitLoop = do
        c <- readMVar initDoneMVar
        when (c > 0) $ threadDelay (timeToMicros Millis 10) >> waitLoop

  liftIO $ do
    waitLoop
    putMVar kickSignalMVar ()
    -- wait for send + wait duration
    threadDelay $ timeToMicros Seconds $
                 (sendDuration cd)
                 + (waitDuration cd)
    putMVar timeoutMVar ()
    -- Allow the ExitSignal send
    threadDelay (timeToMicros Seconds 1)

supervisorServerSimple :: Process ()
supervisorServerSimple = do
  let
    server = statelessProcess
      { apiHandlers = [handleCall testPing]
      , unhandledMessagePolicy = Log
      }
  serve () (statelessInit Infinity) server

testPing :: CallHandler () TestPing Int
testPing _ _ = do
  say "testPing"
  reply 5 ()
