+++
title = "Systems Research Worklog"
url = "/worklog"
description = "A daily research worklog on databases, compilers, operating systems, and heterogeneous hardware."
lede = "A public notebook tracking my preparation for graduate research in modern systems: what I read, what I implemented, what I understood, and which questions remain open."
current_focus = "Database systems, compiler/runtime support, operating-system mechanisms, and heterogeneous hardware."
cadence = "Daily notes, with weekly synthesis when a thread matures."
application_context = "Prepared as evidence of research trajectory for graduate applications, including HPI, TU Darmstadt, TU Berlin, TU Munich, and TU Dresden."

[[review_path]]
title = "Start with the trajectory"
text = "Use the research threads to see how individual notes connect into a coherent systems agenda."

[[review_path]]
title = "Sample the latest entries"
text = "Daily posts are intentionally compact: source, claim, mechanism, uncertainty, and next action."

[[review_path]]
title = "Look for synthesis"
text = "Weekly summaries will connect papers, lectures, implementations, and experiments across subsystem boundaries."

[[research_threads]]
name = "Storage and Query Processing"
summary = "LSM/B-tree tradeoffs, transaction processing, indexing, recovery, vectorized execution, and analytical engines."
accent = "blue"

[[research_threads]]
name = "Compilers and Runtimes"
summary = "IR design, optimization passes, JIT/AOT tradeoffs, data layout, code generation, and runtime feedback loops."
accent = "green"

[[research_threads]]
name = "Operating Systems"
summary = "Scheduling, virtual memory, isolation, filesystems, observability, kernel/user boundaries, and resource control."
accent = "amber"

[[research_threads]]
name = "Heterogeneous Hardware"
summary = "GPU/accelerator execution, memory hierarchy, NUMA, SIMD, storage devices, and hardware-conscious systems design."
accent = "rose"

[[entry_contract]]
label = "Source"
text = "The paper, lecture, book chapter, benchmark, or codebase that prompted the note."

[[entry_contract]]
label = "Mechanism"
text = "The specific system behavior or design choice being examined."

[[entry_contract]]
label = "Evidence"
text = "A derivation, experiment, implementation detail, or comparison that supports the claim."

[[entry_contract]]
label = "Open question"
text = "What I still do not understand, and what I plan to read or build next."
+++

## Why This Exists

Graduate statements of purpose can compress too much into a polished narrative. This worklog is the supporting record: a chronological trail of how my research interests are forming through papers, courses, implementation notes, and small experiments.

The page is designed for quick evaluation. An admissions reader should be able to tell what I am studying, how consistently I study it, whether I can extract mechanisms from sources, and how my interests connect across databases, compilers, operating systems, and modern hardware.

