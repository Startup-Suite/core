# ADR 0019: Principal Agent and Space Agent Roster

**Status:** Proposed  
**Date:** 2026-03-20  
**Deciders:** Ryan, Zip  
**Extends:** ADR 0013 (Attention Routing and Channel Policy)  

---

## Context

ADR 0013 introduced the concept of a principal agent per space and three
attention modes (on_mention, collaborative, directed). It described principal
agent delegation as "an implementation detail of the agent runtime, not a chat
policy concern."

In practice, we need a concrete model for:

1. **Which agent is the principal in a space** — the default responder for
   unaddressed messages.
2. **Which agents are available for direct @-mention** — the space's agent
   roster visible to users.
3. **How the UI surfaces agent presence** — showing the principal prominently
   while making the full roster discoverable.
4. **How @-mention routing interacts with the principal model** — direct
   references bypass the principal, because @ is an explicit address.
5. **How federated (external runtime) agents participate as principals** —
   the principal can be a local agent or a remote one connected via the
   Federation runtime channel.

---

## Decision

### 1. Space Agent Roster

Every space has an explicit agent roster. Each entry defines an agent's role
in that space.

```elixir
%Platform.Chat.SpaceAgent{
  id: Ecto.UUID,
  space_id: Ecto.UUID,        # belongs_to Space
  agent_id: Ecto.UUID,        # belongs_to Agent (Platform.Agents.Agent)
  role: :string,              # "principal" | "member"
  inserted_at: :utc_datetime_usec,
  updated_at: :utc_datetime_usec
}
```

**Constraints:**
- Exactly one `role: "principal"` per space (enforced at the application layer
  and by a partial unique index on `(space_id) WHERE role = 'principal'`).
- Zero or many `role: "member"` entries per space.
- An agent can be principal in one space and member in another.
- A space with no roster entries has no agent participation.

### 2. Attention Routing Rules

The attention router resolves which agent(s) receive a message based on the
space's roster and the message content:

| Message type | Routing |
|---|---|
| `@AgentName ...` | Direct delivery to the named agent, regardless of role. Agent must be in the space roster (principal or member). |
| `@AgentA @AgentB ...` | Deliver to both. Each agent receives the message independently. |
| No @ mention | Deliver to the principal agent. If no principal is configured, no agent receives it. |
| `@AgentName` where agent is not in roster | No delivery. Optionally: system hint "AgentName is not available in this space." |

**@ is an explicit address.** It always overrides the default routing. A user
can talk directly to any rostered agent without going through the principal.
The principal has no interception, gatekeeping, or veto power over direct
@-mentions.

**The principal is the default, not the gatekeeper.** It handles the
"ambient" conversation — messages not addressed to anyone specific. This is
the natural continuation of ADR 0013's attention modes:

- `directed` mode: every message goes to the principal (no @ needed)
- `collaborative` mode: unaddressed messages go through triage for the principal
- `on_mention` mode: only @-mentions trigger any agent

Members always require explicit @-mention regardless of the space's attention
mode. The attention mode setting governs only the principal's behavior on
unaddressed messages.

### 3. Sticky Engagement and Roster

ADR 0013's sticky engagement applies per-agent, not per-role:

- If a user @-mentions a member agent, that agent enters sticky engagement
  for the thread/topic. The principal is not involved.
- If a user talks to the principal (via default routing or @-mention), the
  principal enters sticky engagement.
- Multiple agents can be in sticky engagement simultaneously if the user
  addressed them in the same conversation context.
- When an agent's sticky engagement expires, routing reverts to the default
  rules (unaddressed → principal).

### 4. Principal Agent Delegation

The principal agent may delegate work to member agents. Delegation is the
principal's decision, not a platform routing rule.

**Delegation paths:**

| Path | Mechanism | User visibility |
|---|---|---|
| Task assignment | Principal creates a task via Platform.Tasks, assigns to member agent | Visible in Tasks kanban |
| Execution run | Principal triggers a run, member agent is the runner | Visible in run status |
| Direct message | Agent-to-agent messaging (future: Platform.Agents.AgentMessaging) | Not visible in chat unless agent posts result |
| Chat handoff | Principal posts "let me hand this to @CodeBot" and the member takes over sticky engagement | Visible in chat |

The principal decides when and how to delegate. The platform provides the
mechanisms but does not automatically route work to member agents.

**Important:** A member agent posting in chat is always attributed to itself,
never to the principal. If CodeBot writes a code review, it shows as CodeBot's
message. The principal doesn't ventriloquize.

### 5. Presence UI

#### Top bar (shell)

The principal agent's status is shown in the top bar as the space-level
indicator:

```
┌─────────────────────────────────────────────────┐
│  ⚡ Suite       [Zip ● active]         [Ryan]   │
└─────────────────────────────────────────────────┘
```

Status states:
- `● active` — agent is connected and responsive (green)
- `● busy` — agent is processing / in a run (amber)
- `● idle` — agent is connected but not engaged (dim green)
- `○ offline` — agent runtime is disconnected (gray)

#### Expanded roster (tap/hover)

Tapping or hovering the principal status indicator reveals the full space
agent roster:

```
┌───────────────────────────────┐
│  Zip            ● active      │  ← principal
│  ─────────────────────────── │
│  @CodeBot       ● idle        │  ← members
│  @Reviewer      ○ offline     │
│  @Deployer      ● busy        │
└───────────────────────────────┘
```

On mobile, this is a bottom sheet. On desktop, a dropdown popover.

Design principles:
- **Principal is always first and visually distinct** (slightly larger, no @
  prefix, separator line below).
- **Members show @ prefix** as a visual cue that they're @-mentionable.
- **Status is live** — presence updates via PubSub from
  `Platform.Federation.RuntimePresence` for federated agents and from
  local agent process health for local agents.
- **Tapping a member agent** in the roster inserts `@AgentName ` into the
  message composer (convenience for @-mentioning).

#### Chat participant list

In the space's full participant list (sidebar or members panel), agents are
shown alongside human participants with a badge indicating their role:

```
Ryan Milvenan        (owner)
Zip                  (agent · principal)
CodeBot              (agent)
Reviewer             (agent)
```

### 6. Federated Agents as Principals

A federated agent (connected via an external runtime through the
RuntimeChannel) can serve as principal. The contract is:

- The external runtime receives attention signals for unaddressed messages
  (same as today's `AgentResponder.dispatch/3`).
- The external runtime can post replies via `RuntimeChannel.handle_in("reply", ...)`
  (already implemented).
- The external runtime can call Suite tools via
  `RuntimeChannel.handle_in("tool_call", ...)` (already implemented).
- Presence is tracked via `RuntimePresence.track/1` on channel join and
  `RuntimePresence.untrack/1` on channel leave (already implemented).

No new protocol is needed. The existing RuntimeChannel contract supports
principal agent behavior. The only addition is the roster model that marks
which agent is principal.

### 7. Configuration and Administration

#### Setting the principal

The principal is set when configuring a space:

```elixir
Platform.Chat.set_principal_agent(space_id, agent_id)
# Removes any existing principal, sets the new one
# Returns {:ok, %SpaceAgent{}} | {:error, changeset}
```

#### Adding/removing members

```elixir
Platform.Chat.add_space_agent(space_id, agent_id, role: "member")
Platform.Chat.remove_space_agent(space_id, agent_id)
```

#### Listing the roster

```elixir
Platform.Chat.list_space_agents(space_id)
# Returns [%SpaceAgent{role: "principal", agent: %Agent{...}}, ...]
```

#### UI configuration

In the Control Center or space settings:
- Dropdown to select principal agent (from configured agents)
- Checklist to add/remove member agents
- Attention mode selector (on_mention / collaborative / directed) — applies
  to the principal only

---

## Schema Changes

### New table: `chat_space_agents`

```sql
CREATE TABLE chat_space_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id UUID NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  role VARCHAR NOT NULL DEFAULT 'member',
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chat_space_agents_space_agent_unique UNIQUE (space_id, agent_id)
);

-- Exactly one principal per space
CREATE UNIQUE INDEX chat_space_agents_principal_unique
  ON chat_space_agents (space_id) WHERE role = 'principal';
```

### Migration of existing data

Existing `chat_participants` with `is_agent: true` should be migrated to
`chat_space_agents` entries. The first (or only) agent participant in each
space becomes the principal. This preserves current behavior where spaces
typically have a single agent.

---

## Consequences

### Positive

- Clean mental model: one principal + N members per space
- @-mention always works as expected — explicit address, no gatekeeping
- Principal is the default voice, keeping chat clean without suppressing
  direct access to specialized agents
- Presence UI is simple (one indicator) but discoverable (expand for roster)
- Federated agents work as principals with no protocol changes
- Roster doubles as the @-mention autocomplete source

### Negative / Trade-offs

- Adds a new table and join queries for agent routing
- Principal uniqueness constraint requires careful handling during
  reassignment (remove old, set new — use Ecto.Multi)
- Spaces without a principal have no default agent behavior — must be
  explicit

### Risks

- Users may expect member agents to respond proactively without @-mention
  (they won't — only the principal does that)
- In large spaces with many agents, the roster could become noisy (mitigate:
  limit roster size, or paginate)
- Delegation UX is still somewhat invisible — users may not understand why
  a member agent suddenly starts talking (mitigate: principal announces
  handoffs)

---

## References

- ADR 0013: Attention Routing and Channel Policy (§6 principal agent)
- ADR 0014: Agent Federation and External Runtimes
- ADR 0007: Agent Runtime Architecture
- `Platform.Federation.RuntimePresence` — existing presence tracking
- `PlatformWeb.RuntimeChannel` — existing federated agent communication
- `Platform.Chat.AttentionRouter` — existing attention routing
