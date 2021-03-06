{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module SafeRing.Types where


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

newtype TimePulse = TimePulse {unTimePulse :: Int }
  deriving (Generic, Typeable, Binary, Show, Ord, Eq)

data MessageList =
  MessageList [(LeafNodeId, TimePulse, Double)]
  deriving (Generic, Typeable, Binary)

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: LeafNodeId
  }
  deriving (Generic, Typeable, Binary)

data ReconnectRequest =
  ReconnectRequest (LeafNodeId, (String,Int))
  deriving (Generic, Typeable, Binary)

peerSearchTimeout = timeToMicros Seconds 2
peerCallTimeout = timeToMicros Seconds 2
receiveTimeout = timeToMicros Seconds 5
