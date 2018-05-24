{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module HierRing.Types where


import Control.Distributed.Process.Extras.Time (timeToMicros, TimeUnit(..), Delay(..))

import Control.Distributed.Process ( ProcessId)
import Data.Typeable
import Data.Binary
import GHC.Generics
import CommonCode

-- Avoid stop of messaging in network failures
--
-- Measures
-- Connect to next node if sink node disconnects
-- Reconfigure ring if network problem between two nodes
-- reconnect the disconnected node in the ring

newtype ClusterId = ClusterId {unClusterId :: Int }
  deriving (Generic, Typeable, Binary, Show, Ord, Eq)

newtype TimePulse = TimePulse {unTimePulse :: Int }
  deriving (Generic, Typeable, Binary, Show, Ord, Eq)

data LeafMessage = LeafMessage (LeafNodeId, TimePulse, Double)
  deriving (Generic, Typeable, Binary, Show)

data ClusterMessage = ClusterMessage ClusterId [LeafMessage]
  deriving (Generic, Typeable, Binary, Show)

data MessageList = MessageList [LeafMessage] [ClusterMessage]
  deriving (Generic, Typeable, Binary)

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: LeafNodeId
  , clusterId :: ClusterId
  , selfIp :: (String, Int)
  , nextCluster :: (ClusterId, (LeafNodeId, (String, Int)))
  , peerList :: [(LeafNodeId, (String, Int))]
  }
  deriving (Generic, Typeable, Binary)

data ReconnectRequest =
  ReconnectRequest (LeafNodeId, (String,Int))
  deriving (Generic, Typeable, Binary)

peerSearchTimeout = timeToMicros Seconds 2
peerCallTimeout = timeToMicros Seconds 2
receiveTimeout = timeToMicros Seconds 5

nodesPerCluster :: Int
nodesPerCluster = 3
