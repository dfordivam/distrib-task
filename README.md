# distrib-task

# Build and run

```
  $ stack build

  # Run nodes which will communicate with each other
  # By default the Hierarchical Ring configuration is chosen
  $ stack exec node -- --host "127.0.0.1" --port "12340"
  $ stack exec node -- --host "127.0.0.1" --port "12341"
  $ stack exec node -- --host "127.0.0.1" --port "12342"

  # Create a simple config with all the nodes listed in tuples
  $ cat conf
    [ ("127.0.0.1", 12340)
    , ("127.0.0.1", 12341)
    , ("127.0.0.1", 12342)]

  # Run a supervisor node to send configuration to all
  # nodes and kick-start the communication
  $ stack exec node -- --host "127.0.0.1" --port "12330"\
      --with-seed 1 --send-for 10 --wait-for 1 --config conf

  # Specify one of these options to select a different implementation
  # singleserver, mesh, ring, safering, hierring
  
  $ stack exec node -- --host "127.0.0.1" --port "12340" mesh
  ...
  $ stack exec node -- --host "127.0.0.1" --port "12330"\
      --with-seed 1 --send-for 10 --wait-for 1 --config conf mesh

```

Also see the example scripts `server`, `nodes` and `conf` in the repo

# Implementation' Comparison

There are a number of implementations to try various network topologies. The focus of these implementations is to achieve maximum throughput with some resilience to network problems.

## Single Server

All leaf nodes communicate via a single server (supervisor node)

### Pros
- No redundant messages

### Cons
- Network stops if server goes down
- Bottleneck, server overloaded

## Dense Mesh / Fully connected

Every leaf node is connected to everyone else. 

### Pros
- Network works if any node goes down
- Simple protocol implementation

### Cons
- Lots of redundant communication
- Number of connection N^2
- Minimum throughput for number of messages sent

## Link List / Ring

All leaf nodes communicate in a ring formation.
Each node forwards the messages of previous nodes along with its own.

The ring configuration has a TimePulse concept. It is to allow each node to include only one message in a TimePulse, and every node gets a chance to send a message.

### Pros
- No redundant messages
- Work distributed
- Maximum throughput for number of messages sent

### Cons
- Network stops if any node goes down

## Safe Ring

This implementation has features like connecting to next available node in case one disconnects.
And the disconnected node can again become part of the ring, once it comes online.
This overcomes the biggest drawback of the normal ring network.

These parameters are configurable in this mode and Hierarchical Ring

* peerCallTimeout - In case a peer disconnects, wait for this time before starting connection with next peer.
* peerSearchTimeout - When starting connection with new peer, timeout and try next peer. 
* receiveTimeout - If does not receive any message, then send a reconnect request to previous peer. This is useful in recovering after a node temporarily disconnects.

## Hierarchical Ring

This consists of a cluster of nodes connected in a ring, and the clusters themselves again connected in a ring form.
Each cluster has a leader node which participates in the intercluster ring.
Inside each cluster the 'safe ring' implementation has been used to protect against node disconnection inside a cluster.

Adjustable Parameters

* peerCallTimeout
* peerSearchTimeout
* receiveTimeout
* nodesPerCluster

### Pros
- No redundant messages
- Work distributed
- Maximum throughput for number of messages sent
- Since clusters operate independently, a single node failure impacts only one cluster.

### Cons
- The leader nodes are a point of failure, which can stop
all inter cluster communication. Though intra cluster network will still continue to work.

To solve this problem, the clusters should be able to dynamically elect a new leader, and inform neigbouring cluster about this change. This has not been implemented here.
