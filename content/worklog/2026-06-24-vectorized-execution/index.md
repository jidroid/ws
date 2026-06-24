---
title: "Sample: Vectorized Execution And Cache Behavior"
date: "2026-06-24"
entry_type: "paper note"
track: "databases"
status: "sample"
tags: ["databases", "query-processing", "hardware"]
sources:
  - "MonetDB/X100 paper"
  - "DuckDB execution format notes"
next_questions:
  - "Where does vectorized execution stop helping relative to compiled query execution?"
  - "How should an engine pick vector size when cache behavior and branch behavior disagree?"
---

## Claim

Vectorized execution is not only about doing fewer function calls. Its stronger effect is that it reshapes query execution into cache-sized, type-specialized loops that modern CPUs can predict, prefetch, and pipeline.

## Mechanism

Instead of interpreting one tuple through the full operator tree, the engine processes a batch of values at a time. Operators pass compact vectors of column values, validity masks, and selection vectors. This keeps the hot loop small and gives the CPU a more regular memory-access pattern.

The interesting design tension is vector size. A larger vector amortizes dispatch overhead better, but it can push intermediate state out of cache. A smaller vector may preserve locality, but it increases scheduling and operator-boundary overhead.

## Evidence

I sketched the cost model as three terms:

```text
total cost = operator dispatch + memory traffic + branch/control cost
```

Tuple-at-a-time execution pays dispatch and branch cost repeatedly. Full materialization can reduce dispatch overhead but may write too much intermediate data. Vectorized execution sits between them: it amortizes interpretation while keeping intermediate state bounded.

## Open Question

I still need to compare this with compiled query execution. My current hypothesis is that vectorized execution is easier to make robust across many query shapes, while compilation wins when the system can afford planning latency and generate tight code for a stable hot query.
