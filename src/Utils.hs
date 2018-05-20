{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Utils where


import Control.Distributed.Process ( spawnLocal
                                   , say
                                   , send
                                   , expectTimeout
                                   , register
                                   , monitorPort
                                   , sendPortId
                                   , processNodeId
                                   , whereisRemoteAsync
                                   , Process
                                   , DiedReason(..)
                                   , ProcessId(..)
                                   , NodeId(..)
                                   , WhereIsReply(..))

import Network.Transport     (EndPointAddress(..))
import Data.Typeable
import Data.Binary
import GHC.Generics
import System.Random (mkStdGen, random)

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

type ConfigData = (Int, Int, Int)
type NodesConfig = [(String, Int)]

newtype LeafNodeId = LeafNodeId { unLeafNodeId :: Int }
  deriving (Generic, Typeable, Binary, Eq, Ord, Show)

data StartMessaging = StartMessaging
  deriving (Generic, Typeable, Binary)

data TestPing = TestPing
  deriving (Generic, Typeable, Binary)

getRngInit (_,_,s) (LeafNodeId i)
  = mkStdGen seed
  where seed = s * i * 15485863 -- a prime number

leafServerId = "leaf-server"
workServerId = "work-server"
supervisorServerId = "supervisor-server"
