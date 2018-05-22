{-# LANGUAGE ScopedTypeVariables #-}
module HierRing.Supervisor
  (startSupervisorNode)
  where

import HierRing.Types
import Utils

import Control.Distributed.Process.ManagedProcess.Client (callChan, cast)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , call
                                                  , reply
                                                  , statelessProcess
                                                  , statelessInit
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
startSupervisorNode node cd nodeList@(n:n2:n3:ns) serverIp = runProcess node $ do
  spid <- spawnLocal supervisorServer
  register supervisorServerId spid

  let
    nodes = zip (map LeafNodeId [1..]) nodeList
    cls = zip (map ClusterId [1..])
      $ chunkList nodesPerCluster nodes

  forM cls $ \(clsId, nodes) -> do
    let (nextCls1:_) = rotateExcl clsId cls
        nextCls = (\(a,ns) -> (a, head ns)) nextCls1
    forM nodes $ \(i, leaf) -> spawnLocal $ do
      say $ "Searching leaf: " ++ (show leaf)
      leafPid <- searchRemotePid leafServerId leaf
      say $ "Found leaf: " ++ (show leaf)
      let peerList = rotateExcl i nodes
      (_ :: ()) <- call leafPid
        (LeafInitData cd i clsId leaf serverIp
         nextCls peerList)
      return ()

  liftIO $ threadDelay (timeToMicros Seconds ((\(s,w,_) -> s + w) cd))

startSupervisorNode node cd nodeList@(n:n2:[]) serverIp =
  putStrLn "Need atleast three nodes"

supervisorServer :: Process ()
supervisorServer = do
  let
    server = statelessProcess
      { apiHandlers = [handleCall testPing]
      , unhandledMessagePolicy = Log
      }
  say "Starting supervisor-server"
  serve () (statelessInit Infinity) server

testPing :: CallHandler () TestPing Int
testPing _ _ = do
  say "testPing"
  reply 2 ()

chunkList :: Int -> [a] -> [[a]]
chunkList _ [] = []
chunkList n xs = as : chunkList n bs where (as,bs) = splitAt n xs
