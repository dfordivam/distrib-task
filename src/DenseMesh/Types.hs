{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module DenseMesh.Types where


import Control.Distributed.Process ( ProcessId)
import Data.Typeable
import Data.Binary
import GHC.Generics
import Utils

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: LeafNodeId
  , serverIp :: (String, Int)
  , peers :: [(String, Int)]
  }
  deriving (Generic, Typeable, Binary)

data NewMessage = NewMessage Double
  deriving (Generic, Typeable, Binary)
