# Architecture

Julia Forever is a native Julia harness. Pi is a reference for differential tests of the B1 user-facing surface; it does not determine the internal architecture and is not needed to run or deploy Julia Forever. Julia code mode accepts Julia programs. Once B1 surface parity is established, development and deployment are intended to proceed independently of Pi.

## Core

The target is a typed state machine. A conversation's state and committed inputs are data; transitions determine the next state and planned effects. Model calls, tool calls, storage, clocks, and other external operations execute outside the transition. Their observations return as inputs. A planned effect must be committed before execution, so recovering a conversation can distinguish pending work from recorded outcomes.

Replay reconstructs state from committed history without running effects. Finite history snapshots and replay trajectories should implement Julia's iterator interfaces and be repeatable; a live subscription has a separate cursor and lifetime. Filtering a history reads data, while an experiment that executes new work must be explicit. Experiments and counterfactual evaluation belong in separate packages.

Julia tasks and bounded channels coordinate local work. A replaceable execution backend can dispatch typed work to local or `Distributed` workers; it does not put tasks, channels, sockets, credentials, or captured closures into durable state. Distributed operation needs explicit worker registration, compatible environments, ownership, recovery, and authorization; Julia does not supply those product guarantees automatically.

Storage backends should be replaceable. Recorded transitions and outcomes should be exportable as JSON and HTML logs. Native Julia packages provide extension and plugin functionality. A durable backend needs atomic state/effect commits, idempotency or reconciliation at external boundaries, and a way to handle outcomes that are uncertain after a crash; it cannot make an external effect exactly once by itself.

## Current implementation

The command and `Agent` currently use a synchronous prototype loop. Standalone session history and a local JSONL durable store with checkpointed task phases exist, but they are not yet connected to the agent. Code mode runs Julia in a separate process with the caller's permissions; it is not a sandbox. The current implementation does not yet provide the target transition kernel, interchangeable state backend, distributed agent execution, JSON/HTML history exports, or a native plugin interface. See the linked module documentation in the README for the exact tested boundaries.

B1 coverage and parity are not yet established. Existing differential cases cover selected agent, provider, tool, and session behavior at a pinned Pi revision. They do not establish full surface parity, and a configured platform job is not evidence of a successful run.
