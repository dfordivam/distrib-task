module SingleServer.LeafNode
  (startLeafNode)
  where

import SingleServer.Types

import Network.Transport.TCP (createTransport, defaultTCPParameters)
import Control.Distributed.Process.ManagedProcess ( serve
                                                  , reply
                                                  , call
                                                  , callTimeout
                                                  , defaultProcess
                                                  , handleRpcChan
                                                  , handleCast
                                                  , handleCall
                                                  , handleInfo
                                                  , InitResult(..)
                                                  , UnhandledMessagePolicy(..)
                                                  , ChannelHandler
                                                  , ActionHandler
                                                  , CastHandler
                                                  , CallHandler
                                                  , ProcessDefinition(..) )
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
import Control.Distributed.Process.ManagedProcess.Server (replyChan, continue)
import Control.Distributed.Process.Extras.Time (Delay(..))
import Control.Distributed.Process.Node ( initRemoteTable
                                        , runProcess
                                        , newLocalNode
                                        , LocalNode)
import Control.Concurrent (threadDelay, MVar)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (forever, forM_, void)
import Network.Transport     (EndPointAddress(..))

import System.Random (mkStdGen, random)
import Data.Time.Clock (getCurrentTime
                       , addUTCTime)
import qualified Data.ByteString.Char8 as BS (pack)
-- Leaf node start as a server, ie it waits for supervisor to connect
-- After receiving relevant details and kick-off signal from supervisor
-- it acts as a client and send messages and receives replies

startLeafNode :: LocalNode -> IO ()
startLeafNode node = runProcess node $ do
  say "Starting Leaf server"
  pId <- spawnLocal $ serve () (initServerState) leafServer
  register "leaf-server" pId
  say $ "Server launched at: " ++ show (nodeAddress . processNodeId $ pId)
  liftIO $ forever $ threadDelay 1000000000

initServerState _ = do
  return $ InitOk Nothing Infinity

type LeafServerState = Maybe (LeafInitData, ProcessId)

leafServer = defaultProcess
  { apiHandlers = [ handleCall initClient
                  , handleCast startClient
                  ]
  , infoHandlers = []
  , unhandledMessagePolicy = Log
  }

initClient :: CallHandler LeafServerState LeafInitData ()
initClient _ p = do
  pid <- spawnLocal $ leafClient p
  reply () (Just $ (p, pid))

startClient :: CastHandler LeafServerState StartMessaging
startClient Nothing s = do
  say "Error: startClient without data"
  continue Nothing

startClient s@(Just (_, pid)) _ = do
  send pid ()
  continue s

leafClient :: LeafInitData -> Process ()
leafClient leafData = do
  say "Starting Leaf client"
  pid <- searchLeafNode (serverIp leafData)
  say $ "Doing call to:" ++ (show pid)
  working <- call pid (TestPing)
  say $ "Did call to:" ++ (show $ (working :: Int))
  reply <- expectTimeout 10000000
  case (reply :: Maybe ()) of
    Nothing ->
      say $ "timeout from leafclient: "
        ++ (show $ leafId leafData)
    _ -> do
      leafClientWork leafData pid

  -- case (working :: Maybe Int) of
  --   Nothing -> do
  --     say $ "No response from server"
  --       ++ (show $ leafId leafData)
  --     liftIO $ threadDelay 10000000
  --     return ()
  --   _ -> do
  --     say $ "leafClient ready: "
  --       ++ (show $ leafId leafData)
  --     -- wait for kick off signal
  --     reply <- expectTimeout 1000000
  --     case (reply :: maybe ()) of
  --       nothing ->
  --         say $ "timeout from leafclient: "
  --           ++ (show $ leafid leafdata)
  --       _ -> do
  --         leafclientwork leafdata pid

-- start working
-- print result and gracefully exit?
leafClientWork leafData pid = do
  startTime <- liftIO $ getCurrentTime
  let
    (sendDuration, waitDuration, _)
      = configData leafData
    sendEndTime = addUTCTime
      (fromIntegral $ sendDuration)
      startTime

    mainLoop (rng, old) = do
      let (d, newRng) = random rng
      newValues <- call pid (NewMessage d (length old))
      let
        new :: [Double]
        new = old ++ newValues
      t <- liftIO $ getCurrentTime
      if sendEndTime > t
        then mainLoop (newRng, new)
        else return new
  allValues <- mainLoop ((getRngInit leafData), [])
  -- Calculate sum and exit
  let s = sum $ map (uncurry (*)) $ zip [1..] allValues
  say $ "leafClient Result: "
    ++ (show $ leafId leafData)
    ++ " => " ++ (show (length allValues, s))
  return ()

getRngInit (LeafInitData (_,_,s) i _)
  = mkStdGen seed
  where seed = s * i * 15485863 -- a prime number

searchLeafNode :: (String, Int) -> Process ProcessId
searchLeafNode leaf = do
  let addr = EndPointAddress $ BS.pack $
                   (fst leaf) ++ ":" ++ (show $ snd leaf)
                   ++ ":0"
      srvId = NodeId addr
  say "trying"
  whereisRemoteAsync srvId "supervisor-server"
  say "sent"
  reply <- expectTimeout 1000000
  say "221"
  case reply of
    Just (WhereIsReply _ (Just sid)) -> return sid
    _ -> do
      say $ "Search supervisor Node: " ++ (show leaf)
      searchLeafNode leaf
