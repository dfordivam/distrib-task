{-# LANGUAGE ScopedTypeVariables #-}
module HierRing.Supervisor
  (startSupervisorNode)
  where

import HierRing.Types
import CommonCode

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
import Data.List (find)

startSupervisorNode
  :: LocalNode
  -> ConfigData
  -> IO ()
startSupervisorNode =
  (startSupervisorNodeCommon 5)
  supervisorServerSimple f
  where
    f cd i = LeafInitData cd i clId selfIp nextCls peers
      where
        clId = ClusterId $
          1 + (div (unLeafNodeId i - 1) nodesPerCluster)
        Just selfIp = snd <$> find ((== i) . fst) (nodesList cd)
        cls = zip (map ClusterId [1..])
          $ chunkList nodesPerCluster (nodesList cd)

        (nextCls1:_) = rotateExcl clId cls
        nextCls = (\(a,ns) -> (a, head ns)) nextCls1
        Just ps = snd <$> find ((== clId) . fst) cls
        peers = rotateExcl i ps

chunkList :: Int -> [a] -> [[a]]
chunkList _ [] = []
chunkList n xs = as : chunkList n bs where (as,bs) = splitAt n xs
