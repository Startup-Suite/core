# ADR 0027: Active Agent Mutex — Simplified Attention Routing

**Status:** Accepted  
**Date:** 2026-03-24  
**Deciders:** Ryan Milvenan  
**Supersedes:** ADR 0013 (Attention Routing and Channel Policy), ADR 0017 (Silence Hardening)  

---

## Context

ADR 0013 introduced a three-mode attention system (`on_mention`, `collaborative`, `directed`) with sticky engagement, NLP silencing, triage models, cost degradation, and per-participant attention modes. In practice:

1. **Too many modes** — Three space-level modes, per-participant overrides, sticky engagement with drift detection, and silence heuristics create a combinatorial surface that's hard to reason about.
2. **Collaborative mode was never built** — The triage model, rolling buffer, and cheap-model review were specced but never implemented. The feature gap between spec and reality is wide.
3. **Sticky engagement creates ambiguity** — Users don't know if the agent is still engaged or has timed out. The agent doesn't know if the human is still talking to it. Messages go unanswered or get unexpected responses.
4. **Token waste** — Without clear mutual exclusion, multiple agents can process the same message. Even with one agent, the engagement state is opaque enough that the agent processes messages it shouldn't.
5. **Silence detection is fragile** — NLP-based silence detection ("quiet", "shut up") is pattern-matched and unreliable. Users want a button, not a guessing game.

The core insight: **attention routing is a mutex problem, not a policy problem.** At any moment, either exactly one agent is listening in a space, or none are. Everything else is complexity that doesn't serve the user.

---

## Decision

Replace the three-mode attention system with a single **active agent mutex** per space.

---

## Decision Details

### 1. The mutex model

Each non-execution space has one piece of mutable state:

```
active_agent: agent_participant_id | nil
```

| Condition | Routing |
|-----------|---------|
| `active_agent` is set | All non-@mention messages route to the active agent |
| `active_agent` is nil | No agent receives non-@mention messages |
| Message contains @mention | Route to the mentioned agent(s) — see §3 for multi-mention |

This replaces: `agent_attention`, `attention_mode`, sticky engagement state, silence state, triage buffers, engagement context, and the entire `chat_attention_state` table from ADR 0013.

### 2. Single @mention — acquire the mutex

When a message @mentions exactly one agent:

1. That agent becomes the `active_agent` for the space.
2. The message is dispatched to that agent.
3. Subsequent messages (without @mentions) route to the active agent.
4. The active agent remains engaged until:
   - A different agent is @mentioned (mutex transfers).
   - The user explicitly clears the mutex via UI toggle (see §5).
   - An inactivity timeout elapses (no human messages for N minutes).

The default timeout is **15 minutes** of human inactivity, configurable per space.

### 3. Multi @mention — parallel dispatch, then release

When a message @mentions two or more agents:

1. **Snapshot the conversation history** at the moment of dispatch.
2. **Dispatch to all mentioned agents simultaneously**, each receiving the same history snapshot. No agent sees another's response in its input context.
3. **All responses post to the space** as normal messages.
4. **The active agent is cleared** (`active_agent = nil`) after dispatch.

This ensures **no response bias** — each agent forms its opinion independently from the same input. The user then @mentions one agent to continue with their preferred thread.

If only one mentioned agent is actually present in the space, it falls through to the single-mention behavior (§2).

### 4. Primary agent — the default when nobody's active

Each space may designate a **primary agent**. This is the agent that responds when:

- No agent is currently active (mutex is nil).
- The "Watch" toggle is ON (see §5).
- A message arrives without any @mention.

The primary agent is set explicitly in space settings. If no primary is set, a space with no active agent is silent — agents only respond to @mentions.

A space's primary agent is stored on the space record, not inferred from roster position or join order.

### 5. The Watch toggle

The existing "watch" eye icon in the chat UI becomes the single user-facing control for agent engagement:

| Watch state | Behavior |
|-------------|----------|
| **ON** | The primary agent is the default active agent. Messages without @mentions route to it. Effectively "directed" mode from ADR 0013. |
| **OFF** | No agent responds unless @mentioned. The active agent is cleared on toggle-off. |

Watch is a **per-space setting**, not per-user. When one user toggles it, all users in that space see the change. This is a space-level policy decision.

Watch does not affect @mention routing. Even with Watch OFF, @mentioning an agent activates it normally.

### 6. DM spaces

Agent DMs (1:1 space with an agent) behave as if Watch is permanently ON and cannot be toggled off. The whole point of a DM with an agent is talking to it. The active agent is always set to the DM agent.

User-to-user DMs have no agent and no Watch toggle unless an agent is explicitly invited, at which point the space becomes a group and normal rules apply.

### 7. Execution spaces

Execution spaces (`kind: "execution"`) are exempt from the mutex model entirely. TaskRouter dispatches to the assigned agent via direct RuntimeChannel broadcast. The attention router does not process messages in execution spaces. This is unchanged from current behavior.

### 8. Interaction with roster

The existing `chat_space_agents` roster simplifies:

| Role | Meaning |
|------|---------|
| `primary` | The space's primary agent. At most one per space. Used when Watch is ON and no agent is explicitly active. |
| `member` | Present in the space, reachable via @mention, but never auto-engages. |

The `dismissed` role is removed. To remove an agent, remove it from the space. Re-adding is a first-class action, not an implicit side effect of @mentioning a dismissed agent.

### 9. What gets removed

| ADR 0013 concept | Disposition |
|------------------|-------------|
| Three attention modes (on_mention/collaborative/directed) | **Removed.** Replaced by Watch ON/OFF + active agent mutex. |
| Per-participant `attention_mode` | **Removed.** Routing is determined by space-level mutex, not per-participant config. |
| Sticky engagement with timeout and drift detection | **Removed.** Replaced by the active agent mutex, which is simpler and deterministic. |
| NLP silence detection ("quiet", "shut up") | **Removed.** Replaced by Watch toggle. |
| Collaborative triage (rolling buffer, cheap model review) | **Removed.** Never implemented; no longer needed. |
| `chat_attention_state` table | **Removed.** Active agent is a single field on the space or in ETS. |
| `agent_attention` column on spaces | **Repurposed** or removed. Replaced by `primary_agent_id` + Watch toggle. |
| Cost degradation / budget thresholds | **Removed.** Token cost is controlled by the mutex — only one agent processes any message. Budget controls can be layered later if needed. |

### 10. Schema changes

#### `chat_spaces` modifications

```sql
-- Add primary agent reference
ALTER TABLE chat_spaces ADD COLUMN primary_agent_id UUID REFERENCES agents(id);

-- Add watch toggle (defaults to false for channels, true for agent DMs)
ALTER TABLE chat_spaces ADD COLUMN watch_enabled BOOLEAN NOT NULL DEFAULT FALSE;
```

#### ETS or in-memory state

The active agent is **transient state** — it doesn't need to survive restarts. Store in ETS (or the existing `chat_attention_state` ETS table):

```
Key: space_id
Value: %{active_agent_participant_id: id, activated_at: DateTime, timeout_ref: reference}
```

On application restart, all spaces start with `active_agent = nil`. The primary agent (if Watch is ON) picks up naturally on the next message.

#### Columns to remove (migration)

```sql
ALTER TABLE chat_spaces DROP COLUMN IF EXISTS agent_attention;
ALTER TABLE chat_spaces DROP COLUMN IF EXISTS attention_config;
DROP TABLE IF EXISTS chat_attention_state;
-- Keep chat_participants.attention_mode for now (human participant notification preferences)
-- but stop using it for agent routing decisions.
```

---

## Implementation plan

### Phase 1: Core mutex

- Add `primary_agent_id` and `watch_enabled` to `chat_spaces`.
- Implement active agent ETS store (or repurpose existing attention state ETS).
- Replace `AttentionRouter.do_route/1` internals: check @mentions → active agent → primary agent (if watch ON) → nobody.
- Multi-mention: parallel dispatch with history snapshot.
- Timeout: `Process.send_after` per space, clears active agent on expiry, resets on human message.

### Phase 2: UI

- Watch toggle wired to `watch_enabled` on the space.
- Primary agent picker in space settings.
- Active agent indicator in chat header (shows who's listening, with a clear/X button).
- Remove NLP silence detection code paths.

### Phase 3: Cleanup

- Remove `agent_attention` and `attention_config` columns.
- Remove `chat_attention_state` table.
- Remove `collaborative` mode code paths (triage, buffer, cost degradation).
- Remove `dismissed` roster role.
- Simplify `AgentResponder` — no more engagement state checks, just check the mutex.

---

## Consequences

### Positive

- **One mental model** — "Who's listening?" has exactly one answer at all times.
- **Zero token waste** — Mutex guarantees at most one agent processes any message.
- **No magic** — No NLP silencing, no drift detection, no triage heuristics. Behavior is fully deterministic and user-controlled.
- **Multi-mention without bias** — Parallel dispatch with history snapshot isolation gives independent opinions.
- **Simple UI** — One toggle (Watch), one indicator (who's active), one gesture (@mention to switch).

### Negative

- **No proactive engagement** — Agents never volunteer. They respond when asked (active or @mentioned) or when Watch is ON. The "agent notices something interesting and chimes in" use case from ADR 0013's collaborative mode is gone.
- **@mention tax for first message** — In a channel with Watch OFF, you must @mention to start every conversation with an agent. This is intentional — it makes cost explicit.
- **No per-user Watch preference** — Watch is per-space. If one user wants the agent and another doesn't, they need different spaces.

### Risks

- 15-minute timeout may be too short (agent goes quiet mid-conversation) or too long (agent responds to messages clearly meant for humans). Mitigated by making timeout configurable per space.
- Multi-mention parallel dispatch adds implementation complexity in the attention router. Mitigated by the simplicity of the rest of the system — this is the one complex case.

---

## References

- ADR 0013: Attention Routing and Channel Policy (superseded)
- ADR 0017: Attention Router Silence Hardening (superseded)
- ADR 0008: Chat Backend Architecture
- ADR 0014: Agent Federation Protocol
- ADR 0025: Task Router and Execution Orchestration
- ADR 0026: Task Execution Spaces
