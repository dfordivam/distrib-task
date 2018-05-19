{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module SingleServer.Types where

import Control.Distributed.Process ( ProcessId)
import Data.Typeable
import Data.Binary
import GHC.Generics
import Utils

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: Int
  , serverIp :: (String, Int)
  }
  deriving (Generic, Typeable, Binary)

data NewMessage = NewMessage Double Int
  deriving (Generic, Typeable, Binary)

type MessageReply = [Double]
