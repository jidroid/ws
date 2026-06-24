---
title: "Sample: Join Algorithms From A Database Systems Lecture"
date: "2026-06-24"
entry_type: "course note"
track: "databases"
status: "sample"
tags: ["databases", "query-processing", "course-note"]
sources:
  - "Database systems lecture on join processing"
  - "Textbook section on hash join and sort-merge join"
next_questions:
  - "How do real optimizers estimate memory pressure for hash joins?"
  - "When does sort-merge join become preferable because sorted output is useful downstream?"
---

## Claim

Join algorithms are best understood as different ways of spending memory, ordering, and I/O. The algorithm choice is not just about big-O complexity; it depends on whether the inputs are indexed, sorted, partitionable, and likely to fit in memory.

## Mechanism

Nested-loop join is simple and general, but it becomes expensive unless the inner side has an index or the outer side is very small. Hash join pays a build cost to make equality probes cheap, which works well when the build side fits in memory or can be partitioned. Sort-merge join pays sorting cost, but can be attractive when inputs are already ordered or when later operators benefit from sorted output.

## Evidence

The lecture example became clearer when I rewrote each join as a resource tradeoff:

```text
nested loop:  low setup, high repeated access
hash join:    memory for fast equality lookup
merge join:   ordering for sequential comparison
```

This framing connects directly to query planning. The optimizer is choosing not only an algorithm, but also a set of assumptions about cardinality, available memory, physical order, and reuse of intermediate properties.

## Open Question

I want to connect this to vectorized execution next. A hash join in a vectorized engine is not only a logical algorithm; it also has to decide how to batch probes, represent selection vectors, and handle cache misses during random hash-table access.

