{-# LANGUAGE TemplateHaskell #-}

import SingleServer.Supervisor
import SingleServer.LeafNode
import SingleServer.Types

import Options.Applicative
import Data.Semigroup ((<>))

import Control.Concurrent (threadDelay)
import Control.Monad (forever, forM, void)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Network.Transport as NT
import Control.Distributed.Process.Closure

import qualified Data.ByteString.Char8 as BS
import System.Random

data InputArgs = InputArgs
  { configForServer :: Maybe (String, ConfigData)
  , myHostName      :: String
  , myPortName      :: Int
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

  Right t <- createTransport (myHostName iArgs) (show $ myPortName iArgs)
    (\p -> (myHostName iArgs, p))
    defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  Right myEndPoint <- newEndPoint t

  liftIO $ print $ address myEndPoint
  case (configForServer iArgs) of
    Nothing -> startLeafNode node
    (Just (fileName,cd)) -> do
      fc <- liftIO $ readFile fileName
      let nodeList = read fc
      startSupervisorNode node cd nodeList
