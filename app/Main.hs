{-# LANGUAGE TemplateHaskell #-}

import SingleServer.Supervisor
import SingleServer.LeafNode

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
  { sendDuration :: Int
  , waitDuration  :: Int
  , inputSeed    :: Int
  , configFile   :: Maybe String
  , myHostName   :: String
  , myPortName   :: Int
  }
  deriving (Show)

inputArgs :: Parser InputArgs
inputArgs = InputArgs
  <$> option auto (long "send-for" <> help "Send duration in sec" <> metavar "INT")
  <*> option auto (long "wait-for" <> help "Wait duration in sec" <> metavar "INT")
  <*> option auto (long "with-seed" <> help "Seed value in integer" <> metavar "INT")
  <*> optional (strOption (long "config" <> help "Config file" <> metavar "FILE"))
  <*> strOption (long "host" <> help "Hostname" <> metavar "STRING")
  <*> option auto (long "port" <> help "Port" <> metavar "INT")

main :: IO ()
main = do
  let opts = info (inputArgs <**> helper)
        (fullDesc <> progDesc "Task")
  iArgs <- execParser opts
  print iArgs

  let rGen = mkStdGen $ inputSeed iArgs
  let (r1, rGen1) = random rGen
  let (r2, rGen2) = random rGen1
  print (r1 :: Double)
  print (r2 :: Double)

  Right t <- createTransport (myHostName iArgs) (show $ myPortName iArgs)
    (\p -> (myHostName iArgs, p))
    defaultTCPParameters
  node <- newLocalNode t initRemoteTable
  Right myEndPoint <- newEndPoint t

  liftIO $ print $ address myEndPoint
  case (configFile iArgs) of
    Nothing -> startLeafNode node
    (Just fileName) -> do
      fc <- liftIO $ readFile fileName
      let nodeList = read fc
          cd = (sendDuration iArgs, waitDuration iArgs, inputSeed iArgs)
      startSupervisorNode node cd nodeList
