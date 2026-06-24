---
title: "Sample: What A Loop Optimization Pass Needs To Know"
date: "2026-06-23"
entry_type: "course note"
track: "compilers"
status: "sample"
tags: ["compilers", "llvm", "optimization"]
sources:
  - "LLVM pass manager notes"
  - "Lecture segment on loop-invariant code motion"
next_questions:
  - "Which analyses are invalidated by LICM in LLVM's new pass manager?"
  - "How much of database expression compilation can reuse generic compiler passes?"
---

## Claim

A loop optimization pass is only as good as the analyses it can trust. The actual transformation is often smaller than the dependency chain required to prove that moving code is legal.

## Mechanism

Loop-invariant code motion needs at least three kinds of information:

1. Whether an instruction computes the same value on every iteration.
2. Whether moving it changes memory behavior or exception behavior.
3. Whether the destination dominates all uses and preserves program semantics.

The pass therefore depends on loop structure, dominance, alias analysis, and side-effect information. This makes compiler engineering feel close to database optimizer engineering: the hard part is not only finding a cheaper plan, but proving that the cheaper plan is equivalent.

## Evidence

The simplest safe case is arithmetic on values defined outside the loop:

```text
for row in batch:
  threshold = config.limit * 8
  if row.value > threshold:
    emit(row)
```

The multiplication can move before the loop if `config.limit` is immutable for the duration of the loop. If `config` is a pointer that may alias with writes inside the loop, the transformation needs stronger proof.

## Open Question

I want to trace one real LLVM pass from analysis requests to invalidation. That should clarify how much infrastructure a database JIT gets for free and where domain-specific query knowledge still matters.
