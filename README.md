
# Comparison

## Single Server

### Pros
- No redundant messages

### Cons
- Network stops if server goes down
- Bottleneck, server overloaded

## Link List

### Pros
- No redundant messages
- Work distributed
- Maximum throughput for number of messages sent

### Cons
- Network stops if any node goes down
- Big latency if number of nodes is large

## Dense Mesh

### Pros
- Network works if any node goes down

### Cons
- Lots of redundant communication
  This explodes exponentially as number of nodes increase

- Minimum throughput for number of messages sent

## Safer/Smart Single Server

Make a cluster of N nodes where each node know every one else.
First node is leader and acts as server
If the leader goes down, the next node vote to be the leader.
If majority agrees to the vote, then it becomes leader.

More than N/2 nodes have to be down for this to stop working.

## Other P2P

## Sparse Mesh
Nodes connect to 2-5 peers

# Hybrid Network Topologies

- Avoid redundant message transfer
- Work even if nodes go down/network congestion

## Small Cluster of Nodes

Use Link-list in a small cluster

## Tree / Mesh of Clusters
