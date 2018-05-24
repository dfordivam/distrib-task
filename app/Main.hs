import qualified SingleServer.Supervisor as SS
import qualified SingleServer.LeafNode   as SS
import qualified SingleServer.Types      as SS

import qualified LinkList.Supervisor as LL
import qualified LinkList.LeafNode   as LL
import qualified LinkList.Types      as LL

import qualified DenseMesh.Supervisor as DM
import qualified DenseMesh.LeafNode   as DM
import qualified DenseMesh.Types      as DM

import qualified SafeRing.Supervisor as SR
import qualified SafeRing.LeafNode   as SR
import qualified SafeRing.Types      as SR

import qualified HierRing.Supervisor as HR
import qualified HierRing.LeafNode   as HR
import qualified HierRing.Types      as HR

import CommonCode

import Options.Applicative
import Data.Semigroup ((<>))

import Control.Distributed.Process.Node (newLocalNode, initRemoteTable)
import Control.Monad.IO.Class (liftIO)

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Network.Transport as NT

data InputArgs = InputArgs
  { configForServer :: Maybe (String, (Int,Int,Int))
  , myHostName      :: String
  , myPort          :: Int
  , implType        :: Maybe ImplType
  }
  deriving (Show)

data ImplType
  = SingleServer
  | Ring
  | Mesh
  | SafeRing
  | HierRing
  deriving (Show)

inputArgs :: Parser InputArgs
inputArgs = InputArgs
  <$> optional ((\a b c d -> (d, (a,b,c)))
    <$> option auto (long "send-for" <> help "Send duration in sec" <> metavar "INT")
    <*> option auto (long "wait-for" <> help "Wait duration in sec" <> metavar "INT")
    <*> option auto (long "with-seed" <> help "Seed value in integer" <> metavar "INT")
    <*> strOption (long "config" <> help "Config file" <> metavar "FILE"))

  <*> strOption (long "host" <> help "Hostname" <> metavar "STRING")
  <*> option auto (long "port" <> help "Port" <> metavar "INT")
  <*> optional (subparser
      ((command "singleserver" (info (pure SingleServer) (progDesc "singleserver")))
        <> (command "ring" (info (pure Ring) (progDesc "ring")))
        <> (command "safering" (info (pure SafeRing) (progDesc "safering")))
        <> (command "mesh" (info (pure Mesh) (progDesc "mesh")))
        <> (command "hier" (info (pure HierRing) (progDesc "hier")))))

getImplFn Nothing =
  (HR.startLeafNode, HR.startSupervisorNode)
getImplFn (Just HierRing) =
  (HR.startLeafNode, HR.startSupervisorNode)
getImplFn (Just SingleServer) =
  (SS.startLeafNode, SS.startSupervisorNode)
getImplFn (Just Ring) =
  (LL.startLeafNode, LL.startSupervisorNode)
getImplFn (Just Mesh) =
  (DM.startLeafNode, DM.startSupervisorNode)
getImplFn (Just SafeRing) =
  (SR.startLeafNode, SR.startSupervisorNode)

main :: IO ()
main = do
  let opts = info (inputArgs <**> helper) fullDesc
  iArgs <- execParser opts
  let (f1,f2) = getImplFn $ implType iArgs

  Right t <- createTransport (myHostName iArgs) (show $ myPort iArgs)
    (\p -> (myHostName iArgs, p))
    defaultTCPParameters
  node <- newLocalNode t initRemoteTable

  case (configForServer iArgs) of
    Nothing -> f1 node
    (Just (fileName, (a,b,c))) -> do
      fc <- liftIO $ readFile fileName
      let
        serverIp = (myHostName iArgs, myPort iArgs)
        cd = ConfigData a b c serverIp
          $ zip (map LeafNodeId [1..]) $ read fc
      f2 node cd
