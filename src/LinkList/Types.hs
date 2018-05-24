{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module LinkList.Types where


import Control.Distributed.Process ( ProcessId)
import Data.Typeable
import Data.Binary
import GHC.Generics
import CommonCode

-- Message design
-- The peer

-- Total Leaf Nodes - N
-- [n1, n2, ... nN]

-- Message transfer direction
-- n1 -> n2, n2 -> n3, .. , nN -> n1

-- Time ticks/network pulse, (Assuming T > N)
-- t1 ... tT

-- Messages created at ticks
-- t1 -> [m11, m21, .. , mN1]
-- t2 -> [m12, m22, .. , mN2]
-- ..
-- tT -> [m1T, m2T, .. , mNT]

-- After t1 state of nodes (_ means missing message)
-- Each node is missing N - 2 messages out of N
-- n1 -> [m11, _ , _ , .. , mN1]
-- n2 -> [m11, m21 , _ , .. , _]
-- ..
-- nN -> [_ , _ , _ , .. , m(N-1)1 , mN1]

-- After t2 state of nodes (_ means missing message)
-- Each node is missing (N - 2) + (N - 3) messages out of 2*N
-- n1 -> [m11, _ , _ , .. , m(N-1)1 , mN1]
--       [m12, _ , _ , .. , _ , mN2]

-- n2 -> [m11, m21 , _ , .. , _ , mN1]
--       [m12, m22 , _ , .. , _ , _]
-- ..
-- nN -> [_ , _ , _ , .. , m(N-1)1 , mN1]
--       [_ , _ , _ , .. , m(N-1)2 , mN2]

-- After t(N - 1) state of nodes (_ means missing message)
-- Each node is missing (N - 2) + (N - 3) + .. 1 messages out of N*N
-- n1 -> [m11, m21 , m31 , .. , m(N-1)1 , mN1] <- Complete!
--       [m11, m21 , m31 , .. , _ , mN1] <- 1 missing
-- ..
--       [m1(N-1), _ , _ , .. , _ , mN(N-1)] <- (N - 2) missing

-- If T > N, then all nodes will have (T - (N - 1)) * N messages completely!
-- If T >> N, then this value is very close to T*N

-- Message sent                          Message received
-- t1
-- n1 -> [m11]                           [mN1]
-- n2 -> [m21]                           [m11]
--
-- t2
-- n1 -> [mN1,m12]                       [m(N-1)1,mN2]
-- n2 -> [m11,m21]                       [mN1,m12]
--
-- t(N-1) -- After this time the length of message list is always (N-1)
-- n1 -> [m31,m42, .. , mN(N-2), m1(N-1)]
-- n2 -> [m41,m52, .. , mN(N-3), m1(N-2), m2(N-1)]
--
-- The last (N-2) messages have to be sent forward in next tick (basically drop 1 and send)
-- t(N)
-- n1 -> [m32,m43, .. , mN(N-1), m1(N)]
-- n2 -> [m42,m53, .. , mN(N-2), m1(N-1), m2(N)]
--
-- Note: In implementation the order is reversed, as it is easier to take (N-2)

newtype TimePulse = TimePulse {unTimePulse :: Int }
  deriving (Generic, Typeable, Binary)

data MessageList =
  MessageList [(LeafNodeId, TimePulse, Double)]
  deriving (Generic, Typeable, Binary)

data LeafInitData = LeafInitData
  { configData :: ConfigData
  , leafId :: LeafNodeId
  }
  deriving (Generic, Typeable, Binary)
