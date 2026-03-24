# ADR 0028: Declarative Task Router Watcher

**Status:** Accepted  
**Date:** 2026-03-24  
**Deciders:** Ryan Milvenan  
**Supersedes:** Assignment persistence from ADR 0025 §rehydration, `task_router_assignments` table  
**Related:** ADR 0025 (Task Router), ADR 0026 (Execution Spaces)  

---

## Context

ADR 0025 introduced the TaskRouter — a per-task GenServer responsible for dispatch, heartbeat, and escalation. The current model starts a router imperatively via `Platform.Orchestration.assign_task/2`, which must be called at the right moment by the right code path.

This has failed in practice:

1. **Missed start paths** — `assign_task` is only wired into `tasks_live.ex` on the `"planning"` transition. Tasks created directly at `planning` status (via tool call), tasks transitioned to `in_progress` by plan approval, and tasks assigned agents after creation all silently miss the router start. The task sits in `in_progress` with an approved plan and nobody executing it.

2. **Redundant persistence** — The `task_router_assignments` table was added to survive restarts, with a `Rehydrator` GenServer that queries it on boot. But the task record itself already contains the assignee and status — the assignment table is a denormalized copy of data that already exists.

3. **Imperative fragility** — Every new code path that affects task status or assignee must remember to call `assign_task` or `unassign_task`. This is a category of bug that can't be fixed by fixing one call site — it requires ensuring every possible path is covered, which is structurally unreliable.

The core insight: **a router should exist whenever the conditions warrant it.** The conditions are already in the task record. The router is a derived consequence of state, not an imperative action.

---

## Decision

Replace the imperative `assign_task`/`unassign_task` model with a **declarative TaskRouterWatcher** that reacts to task state changes and ensures the correct set of routers is always running.

---

## Decision Details

### 1. The invariant

At all times, the following must hold:

```
For every task T where:
  T.assignee_type == "agent"
  AND T.assignee_id is not nil
  AND T.status in ["planning", "in_progress", "in_review"]
→ A TaskRouter process MUST be running for T.

For every task T where:
  T.status in ["backlog", "ready", "done", "blocked"]
  OR T.assignee_type != "agent"
  OR T.assignee_id is nil
→ A TaskRouter process MUST NOT be running for T.
```

### 2. TaskRouterWatcher

A new GenServer: `Platform.Orchestration.TaskRouterWatcher`.

**On start (init):**
1. Subscribe to `tasks:board` PubSub topic.
2. Query the DB for all tasks matching the "should have a router" condition.
3. For each, resolve the agent's runtime and start a TaskRouter via the existing DynamicSupervisor.
4. Log the count of routers started.

**On `{:task_updated, task}` event:**
1. Evaluate: should this task have a router?
2. If yes and no router running → resolve runtime, start router.
3. If no and router is running → stop router.
4. If yes and router already running → no-op (router handles internal state changes via its own PubSub subscription).

**On `{:plan_updated, plan}` event:**
- No action needed. The watcher cares about task state, not plan state. The running router handles plan events internally.

**Runtime resolution:**
The watcher resolves `task.assignee_id` (agent UUID) → `Agent.runtime_id` (FK) → `AgentRuntime.runtime_id` (string). This is the same lookup currently in `tasks_live.ex`. Extract to a shared helper: `Platform.Orchestration.resolve_runtime_for_task/1`.

### 3. What gets removed

| Component | Disposition |
|-----------|-------------|
| `Platform.Orchestration.assign_task/2` | **Removed.** Watcher handles starts. |
| `Platform.Orchestration.unassign_task/1` | **Removed.** Watcher handles stops. |
| `task_router_assignments` table | **Removed** (migration to drop). No longer needed — task record is the source of truth. |
| `Platform.Orchestration.TaskRouterAssignment` schema | **Removed.** |
| `Platform.Orchestration.Rehydrator` | **Removed.** Watcher's init replaces it. |
| `tasks_live.ex` orchestration trigger | **Removed.** The `if new_status == "planning"` block that calls `assign_task` is deleted. The watcher picks up the transition via PubSub. |
| `TaskRouter.persist_assignment/3` | **Removed.** Router no longer writes to assignment table. |

### 4. TaskRouter simplification

The TaskRouter itself is unchanged in its core behavior (dispatch, heartbeat, escalation). The only changes:

- Remove `persist_assignment/3` call from `init/1`.
- Remove any references to `TaskRouterAssignment`.
- The `terminate/2` callback no longer needs to mark an assignment as completed — the watcher will know the router stopped and can re-evaluate if needed.

### 5. DynamicSupervisor interaction

`TaskRouterSupervisor` stays as-is. It manages router processes with `strategy: :one_for_one, restart: :transient`. The watcher calls `TaskRouterSupervisor.start_assignment/2` and `stop_assignment/1` — the same API, just called by the watcher instead of by external code.

If a router crashes and the supervisor restarts it, the watcher doesn't need to act — the supervisor handles restarts. If a router crashes and is NOT restarted (`:transient` means it's not restarted on normal exit), the next `{:task_updated, ...}` event or a periodic reconciliation will re-evaluate and start it.

### 6. Periodic reconciliation (belt and suspenders)

The watcher runs a periodic reconciliation every 5 minutes:

1. Query DB for all tasks that should have routers.
2. Query Registry for all running routers.
3. Start any missing routers.
4. Stop any orphaned routers (router running but task no longer qualifies).

This catches any edge case where a PubSub event was missed (process restart, network partition, etc.). The reconciliation is idempotent — starting an already-running router returns `{:error, {:already_started, pid}}`, which is harmless.

### 7. Supervision tree

```
Platform.Application
  └── Platform.Orchestration.Supervisor (one_for_one)
        ├── Platform.Orchestration.TaskRouterSupervisor (DynamicSupervisor)
        └── Platform.Orchestration.TaskRouterWatcher (GenServer)
```

The watcher starts AFTER the DynamicSupervisor so it can immediately start routers in its init.

---

## Implementation plan

### Phase 1: TaskRouterWatcher

- Create `Platform.Orchestration.TaskRouterWatcher` GenServer.
- Extract `resolve_runtime_for_task/1` helper.
- Add to supervision tree.
- Add periodic reconciliation timer (5 min).
- Add tests: watcher starts routers on init, starts/stops on task_updated, reconciliation catches drift.

### Phase 2: Remove imperative paths

- Remove `assign_task/2` and `unassign_task/1` from `Platform.Orchestration`.
- Remove `tasks_live.ex` orchestration trigger.
- Remove `Rehydrator` module.
- Remove `TaskRouterAssignment` schema and migration to drop table.
- Remove `persist_assignment/3` from `TaskRouter.init/1`.
- Update tests.

---

## Consequences

### Positive

- **No missed starts** — impossible to forget to start a router. If the task state says "agent assigned + active status", a router runs. Period.
- **No missed stops** — same invariant in reverse. Task moves to done → router stops. No cleanup code needed at every transition site.
- **No redundant persistence** — task record is the single source of truth. No denormalized assignment table to keep in sync.
- **Restart-safe** — watcher queries DB on boot. No separate rehydration mechanism needed.
- **Self-healing** — periodic reconciliation catches any drift from missed events.

### Negative

- **PubSub dependency** — watcher must receive task_updated events. If PubSub is down, routers won't start until reconciliation runs. Mitigated by the 5-minute reconciliation interval.
- **Slight startup delay** — on application boot, the watcher queries the DB and starts all routers sequentially. For a large number of active tasks, this could add a few seconds to startup. Acceptable at current scale.

### Risks

- **Registry collision** — if the watcher tries to start a router that's already running (e.g., PubSub event arrives twice), the DynamicSupervisor returns `{:error, {:already_started, pid}}`. The watcher must handle this gracefully (it already is — `start_assignment` uses the Registry).

---

## References

- ADR 0025: Task Router and Execution Orchestration
- ADR 0026: Task Execution Spaces
- Erlang/OTP: "Let it crash" philosophy — the watcher ensures the correct set of processes exists, the supervisor ensures they stay alive
