---
author: "jidin dinesh"
title: "log structured merge tree"
url: "/lsm"
summary: "deep dive into lsm"
date: "2025-12-29"
---
## intro

{{< blockquote author="alex petrov, database internals" >}} "if there was an absolutely optimal storage engine for every conceivable use case, everyone would just use it. but since it does not exist, we need to choose wisely." {{< /blockquote >}}


database design is all about tradeoffs. these tradeoffs are made depending on the type of workload (read heavy vs write heavy, analytical vs transaction processing, so on and so forth) for which the database must be specially performant in.

b-trees are the storage engine for many of the widely used databases--especially those optimised for oltp, point lookups, and range scans (postgresql, mysql, mariadb, oracle, sql server). b-trees bound the cost of both reads and writes by doing all the required work synchronously--favouring, predictable per-operation latency over peak write throughput. since b-trees are balanced, high-fanout order indexes;point lookups require O(log<sub>b</sub>n) page accesses while range scans required O(log<sub>b</sub>n + k) where b is the branching factor (fanout) and k is the number of tree entries scanned.

maintaining an ordered index has severe implications for write performance. in an ordered index, writes become random i/o instead of sequential i/0 since data must be written to specific pages to comply with the enforced order. in b-tree, updates are done in-place--the existing record (or page) is modified directly at its current physical location on disk. the cost of performing two i/o per write (one i/o to read the target page in + one i/o to modify and write it back) and the overhead of maintaining the ordered index adds up as the number of writes to the database increases, bogging down the overall write throughput. in b-tree model, the updates are done immediately, at random places (dictated by the index) on the disk in an in-place manner[^1].

log structured merge (lsm) trees, at their core convert this random i/o problem into a sequential i/o problem. instead of performing updates in-place, writes are batched, updates (to pages) are deferred and made out-of-place (updates are written as new versions of the data at a different physical localtion; older data is left untouched). in lsm model, the updates are deferred, sequential, and done out-of-place.

lsm tree has an in-memory component along with an on-disk representation of it. 
1. memtable is the in-memory datastructure capable of maintaining key ordering. its purpose is to serve fast reads and writes for recent data. all writes are appended sequentially to a write-ahead log(wal) before being applied to the memtable, since the memtable on its own it's durable.
2. sorted string tables (sstables) are the immutable, sorted, on-disk files.

differential indexes are auxiliary index structures that track recent changes separately from a large, stable base index, allowing the storage engine to avoid expensive updates to the base index on every write. a differential index keeps all the recent inserts, updates, and deletes in a small, fast-to-update datastructure while the base index remains read-optimised and relatively static. lsm tree is a multi-level differential index where changes cascade from memory to disk over time and disk data is never overwritten. the memtable (differential index) contains all the recent updates that haven't been yet merged into the consolidate base index. sstables constitute the base index representing the stable merged state of the data[^2]. 

```text
newest
│
├── memtable                ← differential
├── L0 sstables             ← differential
├── L1 sstables             ← differential (usually)
│
├── L2 / L3 / ... / ln      ← base
│
oldest
```

## memtable

the memtable is the in-memory representation of the most recent writes applied to the lsm tree, before those writes are flushed to disk as sst files. conceptually, the memtable serves as the first-class write target and the freshest source of truth for reads. all reads must consult the memtable before accessing the on-disk sst files, since the memtable can contain newer versions of the data.

when a memtable reaches its configured size limit, it transitions from mutable to immutable. to avoid write stalls, the storage system immediately switches to a new writable memtable when the current one becomes full, while the full memtable gets flushed asynchronously in the background. once the flush completes, the immutable memtable is destroyed. at any time, only one memtable accepts writes. one or more immutable memtables may coexist to serve reads. in practice, most lsm engines implement something that is effectively a memtable pool in order to minimise flush-induced stalls.

```
memtablepool
 ├─ one active mutable memtable (accepts writes)
 ├─ immutable memtable #1 (being flushed)
 ├─ other immutable memtables  (queued to be flushed)
 └─ ...
```


at its core, memtable is implemented using a data structure that can store records sorted in total order by key, like red-black tree, avl tree, skiplist, or similar. since sstables are immutable sorted structures, the memtable must be able to emit its contents in sorted order during a flush. for example, if the memtable is implemented as a balanced binary search tree, an in-order traversal yields sorted keys in O(n) time.

### functional requirements of memtable

1. atomic writes

every individual "put" or "delete" operation must be atomic. when multiple threads update the value of the same key, the memtable shouldn't end up in an inconsistent/incorrect state.

2. linearizability (read your writes)

writes must be globally ordered and atomic. once a write is acknowledged, any subsequent reads (from any thread) must reflect that write or a later one if it happened. thread-local buffers that are merged shouldn't be used as a memtable data structure because of this; if thread a writes a value, thread b must be able to see it immediately upon completion, regardless of which core or thread-local buffer it originated from.

3. snapshot isolation/consistent reads

during a range scan or a large read, the memtable must provide a consistent view of the data at a specific point in time, even if other threads are writing to it during the reads.

4. bidirectional operation

beyond point reads, memtable must support efficient forward and reverse range scans. this is necessary because user queries often involve ordering data. even if the user never requests a range scan, the storage system requires one to be done to create a sstable. the memtable must be able to produce an ordered stream of its contents to ensure that the resulting on-disk file is sorted; this makes use of hash table as memtable tricky.

5. support for versioning (mvcc)

to handle updates, the memtable must store multiple versions of the same key (typically using timestamps).

### non-functional requirements of memtable

1. high write throughput (low contention)

the memtable must minimise the use of global "stop-the-world" locks. modern implementations often use lock-free skip lists or wait-free datastructures to allow concurrent writes.

2. low read latency

reads should not be blocked by writes. 

3. bounded memory usage

the memtable must accurately track its memory footprint to trigger a flush at the configured size limit, before the system runs out of allocated ram.

4. predictable p99 latency

the switch to the new mutable memtable after one memtable gets full shouldn't cause latency spikes in the database.

5. non-blocking long-lived iterators

in a real world lsm backed storage engine, the background flush or a large use scan can take seconds to complete. these iterators must not hold a lock that prevents new writes; this implies coarse-grained locking shouldn't be done (eg. a single mutex over the whole memtable)

### skip lists as memtable

few reasons why skip lists have become a popular and widely used choice for the memtable datastructure in modern lsm based storage engines; rocksdb, cassandra, hbase, scylladb, cockroachdb's pebble, tidesdb to name a few.

1. lock-free concurrency

balancing a tree requires rotations. a rotation is a structural change that can affect the entire path from a leaf to the root. in a multi-threaded environment, performing a rotation requires locking large sections of the tree to maintain pointer integrity. this creates massive contention and kills p99 latency. in contrast, a skip list is updated by simply swapping pointers at a different levels. skip list can be implemented using atomic compare-and-swap (cas) operations.

2. simplified snapshot isolation (mvcc)

skip lists are inherently more "iterator-friendly" for mvcc. since nodes are never moved (unlike tree rotations), a reader can capture a pointer to a node and be guaranteed that the next pointers will always lead to a valid sorted sequence, even if other threads are inserting new nodes behind or ahead of it. to support mvcc, skip lists typically store keys as (keyname, sequencenumber). 

3. allocation efficiency and cache friendliness

modern lsm engines often use arena allocation for memtables. the frequent node rebalancing and deletions lead to memory fragmentation in trees. since nodes are never rebalanced or moved in skip lists, we can allocate memory linearly in an arena. this improves cache locality as the nodes created around the same time are often physically close in memory[^3].

4. efficient bidirectional iteration

a skip list node implementation can be easily tweaked to support both prev() and next() operations.

5. probabilistic balancing

strictly balanced trees guarantee a height of exactly log<sub>b</sub>n where b is the fanout but the cost of maintaining that guarantee under intense write pressure is high. skip list use probabilistic balancing and it gives the performance win of O(log<sub>1/p</sub>n) search performance on average without ever needing to perform a "global" rebalance. while there is a theoretical worst-case of O(n), the statistical probability of a skip list becoming significantly unbalanced is mathematically negligible in production workloads.

lsm engines solve this problem using arena allocation. instead of allocating memory for each node individually, the engine request a large contiguous block of memory (eg. 8mb) from the operating system. when a new skip list node is created, the system simply returns the current "top" of the arena and moves the pointer forward by the size of the node. this ensures that nodes created around the same time are physically adjacent in memory, improving the cache locality by reducing pointer-chasing delays. arena allocation also simplifies memory deallocation of already flushed memtables, since essentially it is an O(1) operation.

### write-ahead log (wal)

every write operation performs two steps:

step 1: append the write operation (eg., set "user:123" = "laura") to the end of the wal.
step 2: once the log entry is safely on disk (often after a fsync call), apply the write operation on the memtable.

these steps are conceptually sequential but they are not always done synchronously. the "synchronicity" depends entirely on your durability-vs-performance configuration. the strict synchronous path with maximum safety is when fsync() is evoked after every append to the wal, forcing the hardware to move data from the os cache to the physical disk. the write operation is applied to the memtable only after the disk "confirms" the data has been persisted on disk. the asynchronous path with maximum throughput is when the writes to the wal are buffered--the storage engine instead of forcing a disk sync, keeps the data in the os' page cache, immediately applies the write operation on the memtable and returns "success" acknowledgement back to the client application. modern engines like rocksdb and pebble use a "pipelined write" approach. instead of one thread doing step 1 then step 2, the engine pipelines these steps. one thread (the wal lead) can be busy flushing a large batch of accumulated writes to the log log, while another thread (the memtable lead) simultaneously inserts the previous batch of already-wal-written updates to the memtable. while the logical order of execution remains "wal first", the hardware does both steps at once for difference data sets.

the wal exists solely to reconstruct the memtable after a crash. each wal record includes:
1. a crc-32 checksum for data integrity verification
2. a record type indicator (eg: is it a full wal record or a fragment)
3. operation data (operation identifier, key-value pairs, tombstones etc)

upon restart after a crash, the storage system will:
1. scan all wal files in chronological order
2. validate each record using checksum
3. reconstruct the exact memtable state
4. resume operation without any data loss

## sstable

flushing the in-memory memtable to a persistent, immutable on-disk structure (sstable) is typically triggered by one of the following conditions:

1. individual buffer saturation: once an active memtable reaches it pre-defined memory limit, it is marked as immutable and a background process begins flushing its contents to disk in a single pass while avoiding random i/o and expensive in-place updates. 

2. global memory pressure: to prevent the database from consuming all available system ram, storage engines often track the aggregate size of all memtables across the entire database and if the combined memory usage exceeds a global limit, the engine will preemptively flush the largest memtable to disk, even if that specific bugger hasn't reached its individual capacity yet.

3. to prevent the wal from growing indefinitely--leading to extremely long recovery times--the engine will trigger a flush of the oldest memtable. once that data is safely persisted as a sstable, the corresponding segments of the wal are purged[^4].

having the on-disk files as immutable, significantly simplifies the concurrency control. immutable files can be read concurrently without requiring locks or on the data. readers never block writers and readers never block each other. in contrast, mutable data datastructures (eg. b-tree) rely on hierarchical locks to preserve on-disk data integrity--these systems allow multiple concurrent readers but writers require exclusive locks over portions of the tree, leading to complex concurrency control and contention management.

sstable is a file on disk containing key-value pairs sorted by key. it:
1. is immutable once written
2. is capable of storing duplicated keys
3. is agnostic to key and value types, with both treated as arbitrary byte resulting and has no padding requirements for keys or values
4. never modifies on-disk data in case of updates or deletes. updates writes a new version of the key inot the memtable which is later flushed to a new sstable. deletes are represented by appending a tombstone[^5] record that marks the key as deleted. during reads, the system always searches from the newest-to-oldest, ensuring that the most recent value or associated tombstone is found before any older version, preserving correctness without modifying historical data.

sstable file structure is designed for sequential disk writes, efficient point lookups, range scans, and compaction. physically, it is laid out as a data section followed by index, filter, metadata, and footer section--each serving a distinct role in minimizing i/o and read amplification.

```
sstable file
├── data section (data blocks)
├── index section
├── filter section (bloom filter)
├── metadata / summary
└── footer
```

the data section is divided into fixed-size data blocks. each data block stores a sorted sequence of key-value entries and is the smallest independently readable unit of the sstable. as the keys and values are variable length, blocks include length metadata so that a reader knows how far to advance when scanning. data blocks are commonly prefix-compressed and checksummed. compression is applied at the block level using techniques like snappy, lz4, zstd, zlib, or bz2. restart arrays make binary search possible inside a compressed data block. at each restart point, the key is stored in full without any prefix compression. the restart array is simply a list of offsets within the block that point to these full-key entries.

```
data block
├── entry 1: (key₁, value₁)
├── entry 2: (key₂, value₂)
├── ...
├── entry n
├── entry metadata (lengths / offsets)
├── restart points (optional)
└── checksum
```

sstables include a sparse index section that maps key--often the last key in each data block--to their byte offset within the block. this index typically contains one entry per block or per every nth key, allowing the storage engine to locate the correct disk block with minimal i/o. each sstable can also contain a bloom filter that quickly determines whether a key definitely doesn't exist in that sst file--allowing the storage engine to skip both the index and data blocks entirely for negative lookups. metadata section has information such as the minimum, maximum keys, key range coverage, and other statistics used by query planning and compaction logic--enabling entire files to be skipped from being read if they cannot satisfy the read predicates. the footer is a small, fixed-size section whose job is to make the file self-describing and safely readable. as the footer section has a fixed-size and known byte layout, the storage engine can read the last few bytes of the sst file and immediately know where all its important sections are without having to scan the entire file or rely on external state. it typically contains:
1. a pointer (byte offset) to the index block
2. a pointer (byte offset) to the bloom filter block
3. version or format identifier
4. a magic number that uniquely identifies the file as a valid sstable

segment is a higher level logical organizational idea--contiguous group of data blocks, often corresponding to a streaming write from a memtable flush or to a logical key range within a large sstable. segments are not the units of reads--data blocks are--but they help with efficient range scans and compaction. it is helpful to thnk of a sstable not as a single, never-changing file but as a collection of immutable segments created and merged over time. each time the storage engine flushes its memtable, a new segment is created. segments are immutable snapshots of the database state at a point in time. during reads, segments are examined from newest-to-oldest to locate the latest version of a given key.

```
segment
├── data block
├── data block
├── data block
├── local metadata
└── optional local index
```

if all the sstable created over time were all organized as a flat collection, then:
1. reads would need to check many (worst-case, all) sst files
2. disk usage would grow due to dulpicates and obsolete value entries
3. compaction would become expensive and unpredictable

instead, organizing the sstables into multiple levels bounds read cost, controls disk usage, and makes compaction predictable and efficient. this design decision balances write throughput against read latency and space efficiency. the core invariants of leveled organixzation are:
1. newer data lives in higher levels; order data moves downwards by compaction
2. each level is larger than the previous one by a constant factor
3. except for level 0, sstables in a level have non-overlapping key ranges

leveL0 (L0) contains sstables created directly from memtable flushes. these sstables are individually sorted but may have overlapping key rangs. allowing overlap at this level avoids need for coordination during flushes, yielding higher write throughput. however, reads may need to check all L0 sstable because of the overlap--the total size of L0 is bounded to prevent excessive read amplification. lower levels (L1 to ln) contain data that has been compacted and merged from higher levels. sstables within a level have non-overlapping key ranges, which ensures that for any given key, at most only one sstable needs to be checked per level during a read. 


```
+-------------------------------------------------------------+
|                          on disk                            |
+-------------------------------------------------------------+

+-------------------------------------------------------------+
| level 0 (L0) – mutable flush level                           |
+-------------------------------------------------------------+
| +-------------------+  +-------------------+  +-----------+ |
| | sstable L0-1      |  | sstable L0-2      |  | sstable n | |
| |                   |  |                   |  |           | |
| | - overlapping     |  | - overlapping     |  | - overlap | |
| | - recently flushed|  | - unordered ranges|  |           | |
| | - smallest size   |  |                   |  |           | |
| +-------------------+  +-------------------+  +-----------+ |
|                                                             |
+-------------------------------------------------------------+

+-------------------------------------------------------------+
| level 1 (L1) – sorted, non-overlapping                      |
+-------------------------------------------------------------+
| +---------------------------------------------------------+ |
| | sstable L1-1                                            | |
| | - sorted key range                                      | |
| | - no overlap within level                               | |
| | - larger than L0 files                                  | |
| +---------------------------------------------------------+ |
|                                                             |
+-------------------------------------------------------------+

+-------------------------------------------------------------+
| level 2 (L2)                                                |
+-------------------------------------------------------------+
| +---------------------------------------------------------+ |
| | sstable L2-1                                            | |
| | - wider key range                                       | |
| | - lower update frequency                                | |
| | - higher read amplification                             | |
| +---------------------------------------------------------+ |
|                                                             |
+-------------------------------------------------------------+

+-------------------------------------------------------------+
| level n (ln) – cold data                                   |
+-------------------------------------------------------------+
| +---------------------------------------------------------+ |
| | sstable ln-1                                            | |
| | - largest files                                        | |
| | - rarely compacted                                     | |
| | - highest data density                                  | |
| +---------------------------------------------------------+ |
|                                                             |
+-------------------------------------------------------------+
```


immutability inevitably leads to many sstables accumulating on disk over time. compaction addresses this by:
1. merging multiple segments into a single, larger segment
2. deduplicating keys by keeping only the newest version
3. discarding tombstones once it is safe to do so
4. deleting old segments from higher levels once the new compacted segment has been written to the lower level(s).
compaction restores space efficiency and preserves the invariant of non-overlapping key ranges in lower levels.

## read, write paths

{{< figure src="read-path.webp" class="responsive-img">}}

{{< figure src="write-path.webp" class="responsive-img">}}

## compaction

amplification quantifies how much extra work the system has to perform relative to the logical operation requested.
read amplification is defined as the ratio of bytes read from storage to retrieve a value, relative to the actual size of the value. read amplification often manifests as the number of files, blocks, or disk i/o operations required to service a single logical read. write amplification is defined as the ratio of bytes written to storage to persist a value, relative to the actual size of the value. write amplification arises when a logical write causes multiple physical writes, due to reorganization or compaction. space amplification is defined as the ration of the size of data on dick to the size of the logical data stored. 

[RUM conjecture](https://openproceedings.org/2016/conf/edbt/paper-12.pdf) states, any storage engine can optimize at most two of:
1. read amplification
2. write (update) amplification
3. space (memory) amplification

optimizing two necessarily worsens the third.

### amplification in b-tree vs lsm based storage engines

in b-tree storage engines, a single logical write may:
1. update a leaf page
2. trigger a page split if the page is full
3. require parent node updates with new separator key(s)

these operations can cascade up the tree, potentially reaching the root, as a result:
1. one logical write can multiple page writes
2. writes are random i/o due to scattered page locations
3. write amplification comes from structural maintenance

write amplification is usually moderate but unpredictable, depending on page occupancy and split frequency.

in lsm engines, the same key-value pair maybe rewritten many times before reaching its final level. consequently, write amplification is dominated by compaction, is tunable but often higher than in b-tree. 

reads in b-trees follow a single, well-defined path--one page per level from root to leaf and the tree height is small due to high fanout. this results in low, predictable read amplification, efficient point and range scans. read amplification is bounded by the tree height, largely independent of the data size, can be further reduced by caching the upper-level pages. whereas reads in lsm engines must account for multiple data locations:
1. mutable and immutable memtables
2. multiple sstables across levels

even with the optimisations like use of bloom filters, sparse indexes--the read amplification is still high. lsm engines trade higher read amplification for greater write throughput.

space amplification in b-tree mainly comes from partially filled fixed-size pages and internal fragmentation. space amplification is lsm engines is caused by multiple version of the same key existing across sstables, tombstones and out-of-date duplicate entries being retained until compaction. in lsm engines, space amplification depends on:
1. compaction strategy
2. level size ratio
3. workload characteristics

without compaction, several pathological behaviors will emerge in lsm backed storage engines:
1. unbounded disk growth
2. increased read amplification
3. high space amplification

compaction is done to address these issues by:
1. reclaim disk space by purging older versions of keys and tombstones
2. reducing the total number of sstables
3. enforcing non-overlapping key ranges

at its core, compaction is a merge sort operation over sstables. compaction selects  a subset of sstables as input, merging them into one or more new sstables. during the merge, the records are processed in key order, typically using a merge heap (eg., a priority queue). when multiple records with the same key are encountered, the system selects the record with the highest sequence number or timestamp, representing the most recent write. older versions are discarded and tombstones suppress older versions of the keys and may themselves be dropped once it is safe to do so. the output of compaction is smaller number of new sstables, containing only the latest versions of keys with non-overlapping key-range organisation between the sstables. once the new sstables are fully written, the original input sstables are deleted and their disk space is reclaimed. compaction is performed by dedicated compaction thread pool that runs asynchronously in the background while foreground application reads and writes continue concurrently. compaction is triggered based on heuristics such as:
1. sstable counts at each level
2. sstable size thresholds

lsm compaction closely resembles *generational garbage collection*, guided by the *weak generational hypothesis*--most objects die young.
recently flushed sstables contain many short-lived versions of the keys that will undergo frequent compaction. the "young" sstables have inherently higher churn and rewrite rate. older sstables contain mostly stable, long-lived data and are compacted infrequently. this is similar to the garbage collection design where the "young" objects are frequently garbage collected and have a high death rate as opposed to the "older" objects that are rarely garbage collected and will live for long. this analogy is useful to see why lsm trees can sustain higher write throughput as most write amplification is concentrated just on the young data, while older data remains relatively untouched. 

### tiered compaction

tiered/size-based compaction groups sstables by size rather than key-range. when a fixed number of sstables of similar size accumulate, they are merged into a single larger sstable. this hierarchical process repeats as increasingly larger files accumulate over time. each level has its size limit, and for each level there is a limitation of how many sstables it can have--when a level's capacity is reached, all sstables in that level are merged and moved downwards to the lower level. sstables within the same level may have overlapping key ranges. the key difference between tiered compaction and leveled compaction is that tiered compaction merges from only within a level (L<sub>i</sub> -> L<sub>i+1</sub>) whereas in leveled compaction, sstables merge across consecutive levels (L<sub>i</sub> + L<sub>i+1</sub> -> L<sub>i+1</sub>).

tiered compaction offers lower write amplification compared to leveled compaction, as the data is rewritten fewer times. tiered compaction is particularly well-suited for write-heavy workloads because it minimises write amplification by ensuring that new data is only ever merged with similarly sized data, preventing small writes from forcing large overall rewrites, and amortizing the compaction cost into infrequent, sequential bulk merges rather than continuous cross-level reorganization. the main trade-off of this strategy is high read amplification due to the overlapping sstables and higher space amplification. in tiered compaction, sstables within the same level may overlap arbitrarily and compaction only occurs within a level, never across levels. a sstable is not merged into a lower level until the entire level has similarly sized sstables. this creates a structural delay, letting obsolete data persist for longer time--if a key is updated repeatedly, each version can land in a different sstable; these sstables may reside in different tiers, obsolete versions cannot be safely dropped until all sstables containing overlapping key ranges are merged together.

```
                               writes
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│                             Tier 0                           │
│  small SSTables of similar size                               │
│  overlapping key ranges allowed                               │
│                                                              │
│  ┌──────────┐                                                │
│  │ SST 1    │ [  0 – 300 ]                                   │
│  └──────────┘                                                │
│  ┌──────────┐                                                │
│  │ SST 2    │ [200 – 500 ]                                   │
│  └──────────┘                                                │
│  ┌──────────┐                                                │
│  │ SST 3    │ [100 – 400 ]                                   │
│  └──────────┘                                                │
│  ┌──────────┐                                                │
│  │ SST 4    │ [250 – 600 ]                                   │
│  └──────────┘                                                │
│  ┌──────────┐                                                │
│  │ SST 5    │ [ 50 – 350 ]                                   │
│  └──────────┘                                                │
│                                                              │
│  (stack grows; key ranges may heavily overlap)                │
└───────────────┬──────────────────────────────────────────────┘
                │ compaction triggered when stack is full
                ▼
┌──────────────────────────────────────────────────────────────┐
│                             Tier 1                           │
│  larger SSTables (merged output)                              │
│  still overlapping with other Tier 1 files                   │
│                                                              │
│  ┌──────────────────────────────┐                            │
│  │ SSTable A                    │                            │
│  │ ~5× larger than Tier 0 files │                            │
│  │ [  0 – 600 ]                 │                            │
│  └──────────────────────────────┘                            │
└───────────────┬──────────────────────────────────────────────┘
                │
                ▼
┌──────────────────────────────────────────────────────────────┐
│                             Tier 2                           │
│  even larger SSTables                                        │
│  fewer files, but overlap still allowed                      │
└──────────────────────────────────────────────────────────────┘
```

### leveled compaction

leveled compaction organizes data into a sequence of levels (L0, L1, L2...), each with strict size and key-range invariants. as data moves down the levels, it becomes progressively denser--covering greater fraction of all possible keys in their range. each level typically grows exponentially across level (fanout) and has a maximum total size. L0 files may overlap arbitrarily but levels L1 and above are guaranteed to have non-overlapping key ranges, ensuring that within these levels, at most one sstable needs to be checked for any given key. when a level l<sub>i</sub> exceeds its size or sstable count threshold, one or more sstables from l<sub>i</sub>, any overlapping sstable from l<sub>i+1</sub> are selected and merged. if the merge output exceed the maximum sstable size of l<sub>i+1</sub>, then it is split into multiple fixed-size sstables which are non-overlapping and the original input sstables are deleted.

read amplification is much lower than tiered compaction and is bounded by (number of L0 files + (number of levels-1)). space amplification is also lower because obsolete entries and tombstones are cleaned up aggressively. leveled compaction is suited for read-heavy workloads as it aggressively maintains non-overlapping, dense sstables across levels, ensuring that each key lookup touches at most one sstable per level and delivering predictable, low-latency reads ath the cost of higher write amplication.

```
                               writes
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│                              L0                              │
│  many small SSTables                                          │
│  arbitrary overlap allowed                                   │
│                                                              │
│  ┌───────┐ ┌───────┐ ┌───────┐ ┌───────┐                     │
│  │ S0a   │ │ S0b   │ │ S0c   │ │ S0d   │                     │
│  │[50–90]│ │[0–40] │ │[30–70]│ │[10–80]│                     │
│  └───────┘ └───────┘ └───────┘ └───────┘                     │
└───────────────┬──────────────────────────────────────────────┘
                │ flush / compaction
                ▼
┌──────────────────────────────────────────────────────────────┐
│                              L1                              │
│  fixed total size (e.g., 100 MB)                              │
│  non-overlapping key ranges                                  │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ SSTable A    │  │ SSTable B    │  │ SSTable C    │       │
│  │ [  0 – 100 ] │  │ [101 – 200 ] │  │ [201 – 300 ] │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│         ▲                   ▲                   ▲           │
│         │                   │                   │           │
│   one SSTable per level consulted per key         │           │
└───────────────┬──────────────────────────────────────────────┘
                │ compaction triggered when L1 exceeds limit
                ▼
┌──────────────────────────────────────────────────────────────┐
│                              L2                              │
│  larger total size (fanout ≈ 8×)                              │
│  larger, denser SSTables                                      │
│                                                              │
│  ┌──────────────────────┐  ┌──────────────────────┐         │
│  │ SSTable D            │  │ SSTable E            │         │
│  │ [  0 – 150 ]         │  │ [151 – 300 ]         │         │
│  │ dense key coverage   │  │ dense key coverage   │         │
│  └──────────────────────┘  └──────────────────────┘         │
└──────────────────────────────────────────────────────────────┘
```

rockdb uses a hybrid compaction strategy: L0 is tiered, allowing fast memtable flushes and levels >= L1 are leveled, preserving bounding read amplification.

```
| dimension           | leveled compaction | tiered compaction  |
| ------------------- | ------------------ | ------------------ |
| write amplification | high               | low                |
| read amplification  | low                | high               |
| space amplification | low                | high               |
| key-range overlap   | none (≥ L1)        | allowed everywhere |
| compaction input    | `Li + Li+1`        | `Li only`          |
| compaction output   | written to `Li+1`  | written to `Li+1`  |
| workload fit        | read-heavy         | write-heavy        |
```

## optimisations

modern lsm implementations employ a layered set of optimizations to reduce read amplification. these optimisations progressively narrow down the search space while reducing disk i/o and bounding cpu overhead.

1. compaction is the primary mechanism for controlling read amplification
2. in-memory indexes: each sstable maintains a sparse index that is loaded into memory. this index maps key ranges to their disk offsets. 
3. bloom filters to avoid reading sstables that definitely cannot contain the target key. most lsm engines have a bloom filter for each sstable. bloom filers are especially effective in the early levels as these levels contain relatively fewer keys and very low false-positive rate can be achieved with minimal memory. since these levels are consulted first, eliminating i/o here yields disproportionate latency gains-- as shown by [dayan et. al, 2017](https://nivdayan.github.io/monkeykeyvaluestore.pdf). allocating more bits to early-level bloom filters instead of allocating uniform number of bits for each level minimizes the overall read cost. while bloom filters reduce disk i/o, they introduce cpu overhead. each bloom filter check requires hasing the lookup key and as the number of sstables grow, repeated hashing becomes expensive. a key insight to reduce the cpu overhead involved is by sharing the computed hash digest across bloom filters at the different levels. this requires coordinating the bloom filter implementations across levels but significantly reduces the cpu overhead as described in [zhu et al., 2023](https://cs-people.bu.edu/zczhu/files/SHaMBa-VLDB-PhD-Workshop.pdf).
4. block-level caching further reduces read amplification by avoiding repeated disk reads for hot data.
5. lsm engines such as leveldb and rocksdb maintain a manifest file that records the set of all sstables across level, their key range, and lifecycle related metadata. this is loaded into memory and cached, enabling the engine to quickly determine which sstables could possibly contain a given key. the manifest is updated only on metadata changes, never on the normal read or write path.

## outro

"how a two component lsm-tree grows

to trace the metamorphosis of an lsm-tree from the beginning of its growth, let us begin with a first insertion to the c<sub>0</sub> tree component in memory"

o'neil et al. in their 1996 lsm paper asked the question of "what if we stopped paying cost of random i/o for every update and instead amortized over time". they proposed two designs: the two-component lsm tree, with a memory-resident c<sub>0</sub> optimised for cpu efficiency and a disk-resident c<sub>1</sub> optimised for sequential i/o; and the multi-component generalization where data flows through increasingly larger disk components. updates first accumulate in memory and then migrate to disk via the rolling merge cursor, which slowly circulates through disk blocks. the rolling merge cursor is a conceptual mechanism that manages the continuous, asynchronous migration of data between different components of the lsm-tree. rather than performing a single massive update, the system uses this cursor to move data in small, manageable steps to the memory usage in check. the efficiency of this process is captured by the batch-merge parameter (M), representing the average number of entries merged from c<sub>0</sub> into each page of c<sub>1</sub>. a higher M reduces disk arm movement and lowers the per-insert i/o cost. in multi-component trees (c<sub>0</sub>, c<sub>1</sub>, c<sub>2</sub>,...,c<sub>k</sub>) , there are asynchronous rolling merge processes occurring between every adjacent pair of components. the paper motivates the use of more than two components by showing that when c<sub>1</sub> is extremely large, the memory required for c<sub>0</sub> to maintain batching efficiency becomes too expensive and that increasing the number of components allows the memory-resident c<sub>0</sub> to be significantly smaller while maintaining high i/o efficiency. 

there are several stark differences between the design proposed by o'neil et al. (1996) and modern implementations found in engines like rocksdb, pebble, and wiredtiger. the most significant differences lie in the merge mechanism, the disk component structure, and the concurrency control.

1. rolling merge vs. discrete compaction
the paper proposes a conceptual cursor that moves data from c<sub>0</sub> to c<sub>1</sub> by reading "emptying blocks" and writing "filling blocks" in a constant, circulating stream. modern engines like rocksdb and pebble do not use a circulating cursor. instead, they use compaction, a discrete event triggered when a level or "sstable" reaches a size threshold. they merge entire files (sorted string tables) at once rather than using a continuous rolling cursor.

2. b-tree-like directory vs. immutable sstables
the c<sub>1</sub> component is described as having a "directory structure comparable to a b-tree," but "optimized for sequential disk access". it uses "multi-page blocks" and "single-page nodes" to allow for both point lookups and range scans. real-world implementations typically use sorted string tables (sstables). these are immutable, sorted files. unlike the paper's c<sub>1</sub> component, which is a single, large, growing tree structure, modern lsm engines manage thousands of small, immutable files organized into levels.

3. concurrency and locking
the paper proposes node-level locking to handle concurrency. when the rolling merge cursor modifies a node, it is locked in "write mode," and finds are blocked or redirected. because modern engines use immutable files (sstables), they don't need to lock nodes during merges. instead, they use mvcc (multi-version concurrency control). a background compaction process creates a new version of the data, and the system simply switches a pointer to the new file once it is ready, allowing "finds" to continue without interruption or locking.

google’s work in the early 2000s provided the first convincing proof that log-structured merge trees could operate efficiently in a distributed environment at massive scale. the lsm-tree paper (o’neil et al., 1996) provided the theory and asymptotic guarantees for write efficiency by converting random updates into sequential i/o and deferring maintenance through batch merges. what it did not provide was a concrete, fault-tolerant, distributed implementation capable of surviving real-world workloads, machine failures, and operational complexity. google supplied the required machinery for this. the sstable format (≈2003) established immutable, ordered files as the fundamental on-disk unit. bigtable (chang et al., 2006)[https://static.googleusercontent.com/media/research.google.com/en//archive/bigtable-osdi06.pdf] layered these files behind the tablet abstraction, combining in-memory buffering, on-disk sstables, and background compactions into a system that scaled across thousands of machines. 

## other log-structured storage systems

bitcask, wisckey, and jungle illustrate how log-structured storage can be specialized by relaxing ordering, separating data, or changing on-disk indexes. all retain the core log-structured principle—sequential writes and deferred reorganization—while exploring different points in the read/write/space trade-off space.

### [bitcask: unordered log-structured storage](https://riak.com/assets/bitcask-intro.pdf)

bitcask is a purely append-only, unordered key–value store originally developed for riak. it can be viewed as an extreme point in the log-structured design space: an lsm-like system with no memtables, no sstables, and no sorted structure on disk. all updates are appended sequentially to log files. when a log file reaches a size threshold, it is sealed and a new log is created. the system maintains an in-memory hash map from key -> (file, offset), pointing to the latest version of each key. reads are therefore a single random seek, and writes are sequential appends only. space is reclaimed through periodic log compaction, which rewrites only live key–value pairs into new log files. bitcask is well-suited for workloads that require a persistent unordered map with high write throughput and point reads.

### [wisckey: key–value separation](https://www.usenix.org/system/files/conference/fast16/fast16-papers-lu.pdf)

wisckey addresses the high write amplification of lsm-trees by separating keys from values. keys (and value pointers) are stored in a sorted lsm-tree, while values are written to an unsorted, append-only value log (vlog). during compaction, only the small key–pointer entries are rewritten; large values remain in the vlog and are garbage-collected independently. this design significantly reduces write amplification, especially when values are large, while preserving efficient point lookups and range queries over keys. wisckey is particularly effective for write-heavy workloads with large values.

### [jungle: lsm-tree with copy-on-write b+-tree](https://www.usenix.org/system/files/hotstorage19-paper-ahn.pdf)

jungle targets the classic tiered lsm-tree trade-off: low write amplification but high read amplification due to multiple overlapping sstables per level. instead of maintaining each level as a set of sstables, jungle uses an append-only (copy-on-write) b+-tree per level. like tiered compaction, jungle avoids compacting a level into itself, preserving low write amplification between levels. however, the b+-tree structure allows efficient key lookups within a level, eliminating the need to search multiple sstables at read time.
as a result, jungle achieves, write amplification comparable to tiered lsm-trees and read amplification closer to leveled lsm-trees

[^1]: note on CoW, partitioned tree
[^2]: the exact boundary between the differential and the base index depend on factors like the fanout, compaction strategy used in the lsm tree implementation. fanout (size ratios) control how much data accumulates on a level before compaction is triggered. when the size ratio is relatively small, compaction will occur frequently, moving data downward quickly--keeping the differential index small while the base index begins higher up in the tree. in contrast, a larger size ration results in infrequent compactions, causing data to linger longer in the upper level, creating a larger differential region while the base index begins deeper down in the tree. the compaction strategy determines how aggressively newer data is merged downwards, which directly determines how long the data remains "differential".
[^3]: skip lists are often overlooked in favour of b-trees due to poor cache locality. the main issue is pointer chasing. a skiplist is essentially a multi-level linked list and in a standard implementation, each new node is allocated on the general system heap (using malloc), resulting in spatial fragmentation as the nodes are scattered across ram, and when the cpu follows a pointer to the next node, that memory address is rarely in the L1/L2 cache. the cpu then has to stall to fetch data from dram, these cache misses accumulate in to a significant performance penalty given that a skip list has multiple levels in it.
[^4]: as seen in scenarios 2 and 3, a memtable can be flushed before it is full. this is one reason the generated sst file can be smaller than the corresponding memtable. another reason for sst files being smaller than the flushed memtable that created it, is use of block based compression.
[^5]: counterintutively, delete operations initially consume disk space. the actual data is physically removed only after compaction when obsolete updates and tombstones are merged away.


