---
title: "Sample: io_uring As A Storage Engine Interface"
date: "2026-06-22"
entry_type: "implementation note"
track: "operating systems"
status: "sample"
tags: ["operating-systems", "storage", "databases"]
sources:
  - "Linux io_uring documentation"
  - "Storage engine read path sketch"
next_questions:
  - "How should a storage engine balance io_uring queue depth against tail latency?"
  - "Can the same async path serve WAL writes, compaction reads, and user reads?"
---

## Claim

`io_uring` is interesting for database systems because it moves the storage interface closer to an explicit queueing model. That makes it easier to reason about concurrency, batching, and backpressure than a thread-per-blocking-call design.

## Mechanism

The application submits work into a submission queue and receives completions from a completion queue. A storage engine can use this to keep multiple reads in flight without tying each read to a blocked worker thread.

For an LSM engine, the natural places to test this are:

1. Point lookups that consult multiple candidate SSTables.
2. Compaction reads that stream through sorted files.
3. WAL writes where latency and durability policy interact.

## Evidence

The shape I want to prototype is:

```text
lookup(key)
  check memtable
  schedule candidate SSTable block reads
  consume completions
  decode blocks
  return newest visible value
```

This separates the logical read path from the physical I/O wait. The risk is that queue depth can improve throughput while making tail latency worse if urgent user reads sit behind background work.

## Open Question

The next step is to build a tiny block-cache simulator with foreground reads and background compaction reads. I want to observe when queueing helps and when it hides overload until P99 latency is already bad.
