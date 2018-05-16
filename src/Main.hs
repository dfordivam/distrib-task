{-# LANGUAGE TemplateHaskell #-}

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

type NodesConfig = [(String, Int)]

logMessage :: String -> Process ()
logMessage msg = say $ "handling " ++ msg

remotable ['logMessage]

myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable

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
  node <- newLocalNode t myRemoteTable
  Right myEndPoint <- newEndPoint t

  liftIO $ print $ address myEndPoint
  runProcess node $ case (configFile iArgs) of
    Nothing -> nodeProcess myEndPoint
    (Just fileName) -> do
      fc <- liftIO $ readFile fileName
      let nodeList = read fc
      supervisorProcess nodeList myEndPoint

    -- -- Spawn another worker on the local node
    -- echoPid <- spawnLocal $ forever $ do
    --   -- Test our matches in order against each message in the queue
    --   receiveWait [match logMessage, match replyBack]

    -- -- The `say` function sends a message to a process registered as "logger".
    -- -- By default, this process simply loops through its mailbox and sends
    -- -- any received log message strings it finds to stderr.

    -- say "send some messages!"
    -- send echoPid "hello"
    -- self <- getSelfPid
    -- send echoPid (self, "hello")

    -- -- `expectTimeout` waits for a message or times out after "delay"
    -- m <- expectTimeout 1000000
    -- case m of
    --   -- Die immediately - throws a ProcessExitException with the given reason.
    --   Nothing  -> die "nothing came back!"
    --   Just s -> say $ "got " ++ s ++ " back!"

    -- -- Without the following delay, the process sometimes exits before the messages are exchanged.
    -- liftIO $ threadDelay 2000000

-- replyBack :: (ProcessId, String) -> Process ()
-- replyBack (sender, msg) = send sender msg

-- verify connection to all nodes specified in config file
supervisorProcess :: NodesConfig -> EndPoint -> Process ()
supervisorProcess nodeList myEndPoint = do
  -- Connect to all nodes and send them own addr
  void $ forM nodeList $ \(nAddr, nPort) -> do
    let nodeEP = EndPointAddress $ BS.pack $ nAddr ++ ":" ++ (show nPort)
                   ++ ":1"
    connEither <- liftIO $ connect myEndPoint nodeEP ReliableOrdered defaultConnectHints
    case connEither of
      (Left e) -> do
        say $ "Error in connect to node: " ++ (show (nAddr, nPort))
        say $ show e
      (Right conn) -> do
        say $ "Successfully connected to node: " ++ (show (nAddr, nPort))
        void $ liftIO $ NT.send conn $ [BS.pack $ show nodeList]
  liftIO $ threadDelay 2000000

nodeProcess myEndPoint = forever $ do
  ev <- liftIO $ receive myEndPoint
  case ev of
    (Received cId bs) -> do
      say $ mconcat $ map BS.unpack bs
    _ -> say "Some event"

  -- wait for connection from supervisor
