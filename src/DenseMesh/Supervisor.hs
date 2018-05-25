{-# LANGUAGE ScopedTypeVariables #-}
module DenseMesh.Supervisor
  (startSupervisorNode)
  where

import DenseMesh.Types
import CommonCode

import Control.Distributed.Process.Node (LocalNode)
-- Supervisor acts as both a client and a server
-- It first discovers all nodes and establishes connection with them
-- After the leaf nodes are ready
-- It kicks the messages exchange

startSupervisorNode
  :: LocalNode
  -> ConfigData
  -> IO ()
startSupervisorNode =
  (startSupervisorNodeCommon 2)
  supervisorServerSimple
  (\cd i -> LeafInitData cd i)
