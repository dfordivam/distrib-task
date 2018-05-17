import SingleServer.Supervisor
import SingleServer.LeafNode
import SingleServer.Types

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
    Nothing -> startLeafNode node
    (Just (fileName,cd)) -> do
      fc <- liftIO $ readFile fileName
      let nodeList = read fc
      startSupervisorNode node cd nodeList
