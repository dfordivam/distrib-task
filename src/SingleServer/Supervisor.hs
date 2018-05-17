{-# LANGUAGE ScopedTypeVariables #-}
module SingleServer.Supervisor
  (startSupervisorNode)
  where

import SingleServer.Types

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
import Control.Distributed.Process.Extras.Time (Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
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
import Data.Foldable (toList)
import qualified Data.ByteString.Char8 as BS (pack)
import qualified Data.Sequence as Seq
-- Supervisor acts as both a client and a server
-- It first discovers all nodes and establishes connection with them
-- Then it kicks the leaf nodes to send messages
-- this time it acts as a server, receiving messages and sending updated message list

startSupervisorNode
  :: LocalNode
  -> ConfigData
  -> NodesConfig
  -> IO ()
startSupervisorNode node cd nodeList = runProcess node $ do
  spid <- spawnLocal supervisorServer
  register "supervisor-server" spid

  kickSignalMVar <- liftIO $ newEmptyMVar
  initDoneMVar <- liftIO $ newMVar (length nodeList)

  forM (zip [1..] nodeList) $ \(i, leaf) -> spawnLocal $ do
    say $ "Searching leaf: " ++ (show leaf)
    leafPid <- searchLeafNode leaf
    say $ "Found leaf: " ++ (show leaf)
    (_ :: ()) <- call leafPid
      (LeafInitData cd i ("127.0.0.1",12346))
    -- Indicate if all leaves init correctly
    liftIO $ modifyMVar_ initDoneMVar (\c -> return (c - 1))

    -- wait for kick signal
    liftIO $ readMVar kickSignalMVar

    -- start nodes
    cast leafPid (StartMessaging)

  let waitLoop = do
        c <- readMVar initDoneMVar
        if c > 0
          then threadDelay 500000 >> waitLoop
          else putMVar kickSignalMVar ()
  liftIO $ waitLoop

  liftIO $ threadDelay 10000000

supervisorServer :: Process ()
supervisorServer = do
  s <- liftIO $ newMVar $ Seq.empty
  let
    server = defaultProcess
      { apiHandlers = [handleCall (newMessage s), handleCall testPing]
      , infoHandlers = []
      , unhandledMessagePolicy = Log
      }
  say "Starting supervisor-server"
  serve () initServerState server

initServerState _ = do
  return $ InitOk () NoDelay

type SupervisorServerState =
  (MVar (Seq.Seq Double))

testPing :: CallHandler () TestPing Int
testPing _ _ = do
  say "testPing"
  reply 1 ()

newMessage :: SupervisorServerState -> CallHandler () NewMessage MessageReply
newMessage (mainSeqMVar) _ (NewMessage d lastSyncPoint) = do
  -- append value
  -- send new values

  mainSeq <- liftIO $ modifyMVar mainSeqMVar $ \s -> do
    let newS = s Seq.|> d
    return (newS, newS)

  let newValues = toList $ snd $
        Seq.splitAt lastSyncPoint mainSeq
  reply (newValues) ()

searchLeafNode :: (String, Int) -> Process ProcessId
searchLeafNode leaf = do
  let addr = EndPointAddress $ BS.pack $
                   (fst leaf) ++ ":" ++ (show $ snd leaf)
                   ++ ":0"
      srvId = NodeId addr
  whereisRemoteAsync srvId "leaf-server"
  reply <- expectTimeout 1000000
  case reply of
    Just (WhereIsReply _ (Just sid)) -> return sid
    _ -> do
      say $ "Search Leaf Node: " ++ (show leaf)
      searchLeafNode leaf
