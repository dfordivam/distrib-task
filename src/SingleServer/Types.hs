{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module SingleServer.Types where

import Control.Distributed.Process ( ProcessId)
import Data.Typeable
import Data.Binary
import GHC.Generics
import CommonCode

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: LeafNodeId
  }
  deriving (Generic, Typeable, Binary)

data NewMessage = NewMessage
  Double -- My message
  Int    -- Number of messages I already have
  deriving (Generic, Typeable, Binary)

type MessageReply = [Double]
