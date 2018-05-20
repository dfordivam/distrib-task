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

import Utils

import Options.Applicative
import Data.Semigroup ((<>))

import Control.Distributed.Process.Node (newLocalNode, initRemoteTable)
import Control.Monad.IO.Class (liftIO)

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Network.Transport as NT

data InputArgs = InputArgs
  { configForServer :: Maybe (String, ConfigData)
  , myHostName      :: String
  , myPort          :: Int
  }
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

main :: IO ()
main = do
  let opts = info (inputArgs <**> helper) fullDesc
  iArgs <- execParser opts
  print iArgs

  Right t <- createTransport (myHostName iArgs) (show $ myPort iArgs)
    (\p -> (myHostName iArgs, p))
    defaultTCPParameters
  node <- newLocalNode t initRemoteTable

  case (configForServer iArgs) of
    Nothing -> SR.startLeafNode node
    (Just (fileName,cd)) -> do
      fc <- liftIO $ readFile fileName
      let nodeList = read fc
          serverIp = (myHostName iArgs, myPort iArgs)
      SR.startSupervisorNode node cd nodeList serverIp
