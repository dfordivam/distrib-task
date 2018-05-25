{-# LANGUAGE ScopedTypeVariables #-}
module SingleServer.Supervisor
  (startSupervisorNode)
  where

import SingleServer.Types
import CommonCode

import Control.Distributed.Process.ManagedProcess.Client (callChan, cast)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , call
                                                  , reply
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

import qualified Data.Sequence as Seq

-- Supervisor acts as both a client and a server
-- It first discovers all nodes and establishes connection with them
-- After receiving ping from all nodes, it kick-start the leaf nodes communication
-- this time it acts as a server, receiving messages and sending updated message list


startSupervisorNode
  :: LocalNode
  -> ConfigData
  -> IO ()
startSupervisorNode =
  (startSupervisorNodeCommon 1)
  supervisorServer
  (\cd i -> LeafInitData cd i)

supervisorServer :: Process ()
supervisorServer = do
  s <- liftIO $ newMVar $ Seq.empty
  let
    server = statelessProcess
      { apiHandlers = [handleCall (newMessage s)
                      , handleCall testPing]
      , unhandledMessagePolicy = Log
      }
  say "Starting supervisor-server"
  serve () (statelessInit Infinity) server

newMessage
  :: (MVar (Seq.Seq Double))
  -> CallHandler () NewMessage MessageReply
newMessage (mainSeqMVar) _ (NewMessage d lastSyncPoint) = do
  -- append value
  -- send new values

  mainSeq <- liftIO $ modifyMVar mainSeqMVar $ \s -> do
    let newS = s Seq.|> d
    return (newS, newS)

  let newValues = toList $ snd $
        Seq.splitAt lastSyncPoint mainSeq
  reply (newValues) ()

