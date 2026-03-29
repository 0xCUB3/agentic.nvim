# Provider Switch: Destroy & Recreate Session

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mutate-in-place provider switch with a
destroy-and-recreate approach that eliminates stale state bugs by
creating a fresh SessionManager, then replaying saved chat history
into the new buffer for visual continuity.

**Architecture:** On provider switch, save `ChatHistory.messages`
and context (files, code selections), destroy the old session via
`SessionRegistry.destroy_session`, create a new session via
`SessionRegistry.get_session_for_tab_page` (which builds a fresh
`SessionManager` + `ChatWidget`), restore history for ACP replay,
and replay messages visually into the new chat buffer using
existing `MessageWriter` methods.

**Tech Stack:** Lua 5.1 (LuaJIT 2.1), Neovim v0.11.0+ APIs,
agentic.nvim internal modules (SessionManager, SessionRegistry,
ChatHistory, MessageWriter, ACPPayloads, ChatWidget)

---

## Current behavior (what we're replacing)

`SessionManager:switch_provider()` mutates the existing instance
in-place:

1. Saves `chat_history` reference
1. Swaps `self.agent` to new provider's `ACPClient`
1. Soft-cancels old ACP session
1. Calls `self:new_session({ restore_mode = true })` — skips
   `_cancel_session()`, so `config_options` is not cleared
1. Restores history into `self._history_to_send`

**Problem:** Stale state leaks — `config_options`,
`message_writer` sender tracking, `permission_manager`,
`todo_list`, `file_list`, `code_selection` all carry over from
the old provider session.

## New behavior

1. Guard: reject if `is_generating` or `session_id` is nil
   (session still initializing — ACP `create_session` in flight)
1. Save `ChatHistory.messages`, file list, code selections,
   widget open state
1. Validate new provider is available BEFORE destroying old
   session (prevents data loss if provider binary not installed)
1. `SessionRegistry.destroy_session(tab_page_id)` — full cleanup
1. `Config.provider = new_provider`
1. `SessionRegistry.get_session_for_tab_page(tab_page_id)` —
   fresh `SessionManager` + `ChatWidget` + ACP session
1. Open the widget immediately if it was open before (user
   can start typing while session loads — "busy" animation
   shows, `can_submit_prompt()` blocks submission until ready)
1. Register `on_session_ready` callback on new session
1. When ACP session is created (welcome banner written):
   - Verify this session is still active for the tabpage
   - Restore `chat_history.messages` for persistence continuity
   - Restore `_history_to_send` for ACP replay on next prompt
   - Replay messages visually into the new chat buffer
   - Restore file list and code selections

## Design decisions

- **Diagnostics list is NOT preserved** across provider switches.
  Diagnostics are transient and buffer-specific — they'd be stale
  after buffer destruction. Users can re-add diagnostics.
- **Tool calls replay as final state only.** Multi-phase tool
  call updates (pending → completed) are collapsed to the final
  state during replay. This is acceptable — the history shows
  what happened, not the live animation.
- **Blocked during session creation.** If `session_id` is nil
  (ACP `create_session` still in flight), the switch is rejected
  with a clear notification. This prevents orphaned ACP sessions
  and data loss from destroying a half-initialized session. This
  also prevents rapid A→B→C switches — the user must wait for
  B's session to be created before switching to C.
- **Prompt submission blocked during session creation.** A new
  `can_submit_prompt()` method gates `_handle_input_submit` on
  `session_id ~= nil` (and other conditions like
  `_is_restoring_session`). This prevents the user from sending
  a message before `on_session_ready` fires, which would lose
  history and send `session/prompt` with a nil session ID.

## File structure

- Modify: `lua/agentic/session_manager.lua` — remove
  `switch_provider()`, add `on_session_ready()` callback,
  add `can_submit_prompt()` method, gate `_handle_input_submit`,
  add `_connection_error` field and `_handle_connection_error()`,
  start busy animation immediately, check agent state for
  sync/cached failures
- Modify: `lua/agentic/init.lua` — rewrite
  `apply_provider_switch()` to use destroy/recreate via registry
- Modify: `lua/agentic/ui/message_writer.lua` — add
  `replay_history_messages()` bulk method with per-message
  provider name
- Modify: `lua/agentic/session_manager.test.lua` — update/remove
  switch_provider tests, add on_session_ready,
  can_submit_prompt, and connection error tests
- Test: `lua/agentic/ui/message_writer.test.lua` — tests for
  replay method

---

## Task 0: Fix delayed "busy" animation and handle process crash

Two pre-existing issues:

1. The "busy" indicator only starts when `new_session()` runs
   (line 770), which is AFTER the subprocess spawns and ACP
   `initialize` completes. No visual feedback during startup.

2. If the process crashes before `on_ready` fires (or the
   cached client is already dead), `new_session()` never runs,
   `stop()` is never called — "busy" spins forever. The user
   sees an ephemeral `Logger.notify` popup but nothing in the
   chat buffer.

**Root cause for #1:** `SessionManager:new()` creates
`status_animation` at line 139 but never starts it.

**Root cause for #2:** `ACPClient._set_state("error"/"disconnected")`
is called but nothing propagates to `SessionManager`. The
`on_ready` callback never fires, so `new_session()` never
runs and `stop()` is never called.

**Failure modes (verified by tracing code):**

- **New client, sync failure:** `ACPClient:new()` calls
  `_connect()` synchronously. If `initialize` RPC fails,
  `_set_state("error")` fires, `_on_ready` never fires.
  `get_instance` returns a client in error state.
  `SessionManager` has `self.agent` set but `new_session()`
  never runs.

- **Cached dead client:** `AgentInstance.get_instance()`
  at line 28-31 fires `on_ready(client)` immediately on a
  cached client regardless of state. If client is in
  `"error"/"disconnected"`, `vim.schedule` → `new_session()`
  → `create_session` → `_send_request` → `transport:send()`
  returns false silently → callback never fires → hangs.

**Design: error state lives on SessionManager, not ACPClient.**
ACPClient is shared across tabpages — storing per-session
error state there would affect all sessions. Instead:

- `SessionManager` stores `_connection_error` (boolean)
- Checks `agent.state` at two points: after `get_instance`
  returns (sync failure), and inside the `on_ready` callback
  (cached dead client)
- No changes to `ACPClient` API needed

**Busy animation lifecycle (verified):**

| When | Start | Stop |
| --- | --- | --- |
| Widget opens | `new()` line 139 → **MISSING** | — |
| Session creation | `new_session()` line 770 | `create_session` callback line 775 |
| Session restore | `load_acp_session` line 1153 | `load_session` callback line 1175 |
| Prompt submit | line 651 | `send_prompt` callback line 690/732 |
| Streaming | line 233/244 | overridden by next state |
| **Process crash** | — | **MISSING** |

**Files:**

- Modify: `lua/agentic/session_manager.lua` — start busy
  immediately, add `_connection_error` field, check agent
  state at two points, write error to buffer

### Steps

- [ ] **Step 1: Read the failure paths**

Read and understand:

- `lua/agentic/acp/acp_client.lua:95-97` — `_connect()`
  called synchronously in constructor
- `lua/agentic/acp/acp_client.lua:536-543` — initialize
  failure sets state to `"error"`
- `lua/agentic/acp/acp_transport.lua:108-143` — process
  exit callback sets state to `"disconnected"`
- `lua/agentic/acp/acp_transport.lua:53-58` —
  `transport:send()` returns false silently on dead pipe
- `lua/agentic/acp/acp_client.lua:216` —
  `_send_request` ignores send() return value
- `lua/agentic/acp/agent_instance.lua:28-31` — cached
  client fires `on_ready` regardless of state

- [ ] **Step 2: Write failing tests**

Test: `lua/agentic/session_manager.test.lua`

```lua
it(
    "shows busy animation immediately on creation",
    function()
        local session = create_test_session()
        -- status_animation should already be started
        assert.is_not_nil(
            session.status_animation._state
        )
        assert.equal(
            "busy",
            session.status_animation._state
        )
    end
)

it(
    "sets _connection_error when agent is dead",
    function()
        local session = create_test_session()
        session.agent.state = "error"

        -- Trigger the on_ready callback path
        trigger_agent_ready()

        assert.is_true(session._connection_error)
        -- busy animation should be stopped
        assert.is_nil(session.status_animation._state)
    end
)
```

Run: `make test` — expected: FAIL

- [ ] **Step 3: Add immediate busy animation**

After `self.status_animation = StatusAnimation:new(...)` at
line 139, add:

```lua
self.status_animation:start("busy")
```

This is safe because `new_session()` at line 770 calls
`start("busy")` again (idempotent — `start()` does
`stop()` first).

- [ ] **Step 4: Add `_connection_error` field and error
  handling**

Add field to class annotation:

```lua
--- @field _connection_error boolean
```

Initialize in `new()` (alongside other fields at line 110):

```lua
_connection_error = false,
```

Add a helper method to handle the error:

```lua
--- Handle provider connection failure.
--- Stops busy animation and writes error to chat buffer.
function SessionManager:_handle_connection_error()
    self._connection_error = true
    self.status_animation:stop()
    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(
            "⚠️ Failed to connect to "
                .. self.agent.provider_config.name
                .. ". Check that the provider is"
                .. " installed and try again"
                .. " with a new session."
        )
    )
end
```

- [ ] **Step 5: Check agent state after get_instance
  (sync failure)**

After `self.agent = agent` at line 129, add:

```lua
if
    self.agent.state == "error"
    or self.agent.state == "disconnected"
then
    -- Process crashed or failed during construction.
    -- on_ready will never fire, so handle error now.
    -- Defer to ensure widget/animation are created first.
    vim.schedule(function()
        self:_handle_connection_error()
    end)
end
```

Note: This must be deferred via `vim.schedule` because at
line 129 the widget and status_animation haven't been
created yet — they're created at lines 133-139. Actually
this is a problem — we need to move this check AFTER the
widget/animation creation.

**Corrected placement:** After `status_animation:start("busy")`
(after the new line from Step 3), add the state check:

```lua
self.status_animation:start("busy")

-- Check for sync failure during ACPClient construction
if
    self.agent.state == "error"
    or self.agent.state == "disconnected"
then
    vim.schedule(function()
        self:_handle_connection_error()
    end)
end
```

Using `vim.schedule` here because the `on_ready` callback
(if cached and dead) also uses `vim.schedule`, keeping
consistent ordering.

- [ ] **Step 6: Check agent state in on_ready callback
  (cached dead client)**

Modify the `on_ready` callback at line 118-121 to check
agent state before calling `new_session()`:

```lua
local agent = AgentInstance.get_instance(
    Config.provider,
    function(_client)
        vim.schedule(function()
            -- Guard: cached client may be dead
            if
                self.agent.state == "error"
                or self.agent.state
                    == "disconnected"
            then
                self:_handle_connection_error()
                return
            end
            self:new_session()
        end)
    end
)
```

This catches the case where `get_instance` returns a
cached dead client and fires `on_ready` synchronously.
The `vim.schedule` callback checks state before proceeding.

- [ ] **Step 7: Run validate**

Run: `make validate` — expected: pass

- [ ] **Step 8: Commit**

```
fix: show busy animation immediately and handle
provider connection failure

- Start busy animation as soon as widget is created,
  not after ACP initialize completes
- Detect provider failure (process crash, initialize
  error, cached dead client) and stop animation, write
  error to chat buffer so users can recover
- Store _connection_error on SessionManager (per-session
  state, not on shared ACPClient)
```

---

## Task 1: Add `replay_history_messages()` to MessageWriter

MessageWriter currently writes messages one at a time. We need a
method that takes a `ChatHistory.messages[]` array and replays
them into the buffer using existing write methods.

**Files:**

- Modify: `lua/agentic/ui/message_writer.lua`
- Test: `lua/agentic/ui/message_writer.test.lua`

### Steps

- [ ] **Step 1: Read existing MessageWriter tests**

Read `lua/agentic/ui/message_writer.test.lua` and
`tests/AGENTS.md` to understand test patterns and how the
test helper creates MessageWriter instances.

- [ ] **Step 2: Write failing test for replay_history_messages**

The method should iterate `ChatHistory.messages[]` and write
each message to the buffer using `write_restoring_message()`
for user messages, `write_message()` for agent messages, and
`write_tool_call_block()` for tool calls. It should produce
the same visual output as if the messages had been received
live — sender headers ("## User", "### Agent"), message text,
and tool call blocks.

Test structure:

```lua
it(
    "replays user and agent messages with headers",
    function()
        --- @type agentic.ui.ChatHistory.Message[]
        local messages = {
            {
                type = "user",
                text = "hello",
                timestamp = 1000,
                provider_name = "Claude",
            },
            {
                type = "agent",
                text = "hi there",
                provider_name = "Claude",
            },
        }

        writer:replay_history_messages(messages)

        local lines = vim.api.nvim_buf_get_lines(
            bufnr, 0, -1, false
        )
        -- Verify user header, user text, agent header,
        -- agent text are all present in order
    end
)
```

Also write tests for:

- tool_call messages and mixed message types
  (user → agent → tool_call → agent)
- Agent headers show per-message provider name: replay
  messages from "Claude" then "Gemini", verify headers
  read "Agent - Claude" and "Agent - Gemini" respectively
- After replay, `_provider_name` is restored to the
  current provider (not the last replayed message's)

Run: `make test` — expected: FAIL (method doesn't exist)

- [ ] **Step 3: Implement replay_history_messages**

Add to `lua/agentic/ui/message_writer.lua`:

```lua
--- Replay saved chat history messages into the buffer.
--- Uses write_restoring_message for user messages
--- (suppresses timestamp), write_message for agent/thought
--- messages, and write_tool_call_block for tool calls.
--- Temporarily swaps _provider_name per message so agent
--- headers show the correct provider from history.
--- @param messages agentic.ui.ChatHistory.Message[]
function MessageWriter:replay_history_messages(messages)
    local ACPPayloads =
        require("agentic.acp.acp_payloads")
    local current_provider = self._provider_name

    for _, msg in ipairs(messages) do
        -- Show correct provider name per message
        if msg.provider_name then
            self._provider_name = msg.provider_name
        end

        if msg.type == "user" then
            self:write_restoring_message(
                ACPPayloads.generate_user_message(msg.text)
            )
        elseif msg.type == "agent" then
            self:write_message(
                ACPPayloads
                    .generate_agent_message(msg.text)
            )
        elseif msg.type == "thought" then
            self:write_message({
                sessionUpdate = "agent_thought_chunk",
                content = {
                    type = "text",
                    text = msg.text,
                },
            })
        elseif msg.type == "tool_call" then
            self:write_tool_call_block(msg)
        end
    end

    -- Restore current provider for new messages
    self._provider_name = current_provider
end
```

- [ ] **Step 4: Run tests**

Run: `make validate` — expected: all pass

- [ ] **Step 5: Commit**

```
feat(message-writer): add replay_history_messages method

Bulk-replay ChatHistory messages into buffer with proper
sender headers, used by provider switch to restore visual
chat state.
```

---

## Task 2: Add `on_session_ready` callback to SessionManager

`SessionManager:new()` creates the ACP session asynchronously
via `AgentInstance.get_instance(on_ready)` → `new_session()` →
`create_session()`. The caller in `apply_provider_switch` needs
to know when the session is created (welcome banner written,
config_options populated) before replaying messages.

**Files:**

- Modify: `lua/agentic/session_manager.lua`
- Test: `lua/agentic/session_manager.test.lua`

### Steps

- [ ] **Step 1: Read SessionManager:new() initialization flow**

Read `lua/agentic/session_manager.lua:97-207` and understand
the async flow: `AgentInstance.get_instance(on_ready)` →
`vim.schedule` → `self:new_session()`.

The `new_session()` callback at line 811 (`vim.schedule`) is
where the welcome banner is written and `on_created` fires.
This is the right hook point.

Also read the error path: `session_manager.lua:763-767` —
if `create_session` fails, `session_id` stays nil and the
`vim.schedule` block with welcome banner never runs.

- [ ] **Step 2: Write failing test**

```lua
it(
    "calls on_session_ready after session is created",
    function()
        local ready_called = false
        local session = create_test_session()

        session:on_session_ready(function()
            ready_called = true
        end)

        -- Simulate agent ready + session created
        trigger_agent_ready()

        assert.is_true(ready_called)
    end
)

it(
    "fires immediately if session already exists",
    function()
        local session = create_test_session_with_id()
        local ready_called = false

        session:on_session_ready(function()
            ready_called = true
        end)

        -- vim.schedule fires on next tick
        vim.wait(100, function()
            return ready_called
        end)

        assert.is_true(ready_called)
    end
)
```

Run: `make test` — expected: FAIL

- [ ] **Step 3: Implement on_session_ready**

Add a `_session_ready_callbacks` list to SessionManager.
When `new_session()` completes (after welcome banner), fire
all callbacks and clear the list. If session already exists,
fire immediately via `vim.schedule`.

Add field to class annotation:

```lua
--- @field _session_ready_callbacks fun()[]
```

Initialize in `new()`:

```lua
self._session_ready_callbacks = {}
```

Add method:

```lua
--- Register callback for when ACP session is ready.
--- Fires immediately (via vim.schedule) if session
--- already exists.
--- @param callback fun()
function SessionManager:on_session_ready(callback)
    if self.session_id then
        vim.schedule(callback)
        return
    end
    table.insert(
        self._session_ready_callbacks,
        callback
    )
end
```

In `new_session()`, inside the `vim.schedule` block after
the welcome banner is written and `on_created` fires
(after line 827), fire the callbacks:

```lua
-- After on_created callback
for _, cb in ipairs(self._session_ready_callbacks) do
    cb()
end
self._session_ready_callbacks = {}
```

**Error path:** If `create_session` fails (line 763-767),
`session_id` stays nil. Callbacks in
`_session_ready_callbacks` will never fire. This is
acceptable — the session is unusable anyway, and a new
`create_session` attempt can re-register callbacks. Log a
debug message in the error path to aid debugging.

**Cleanup:** Also add `self._session_ready_callbacks = {}`
to `_cancel_session()`. This prevents stale callbacks from
a failed `create_session` from firing if the user retries
via `/new` — the old callbacks would reference stale
closures from a previous `apply_provider_switch` call.

- [ ] **Step 4: Run validate**

Run: `make validate` — expected: pass

- [ ] **Step 5: Commit**

```
feat(session-manager): add on_session_ready callback

Allows callers to defer work until ACP session is created
and welcome banner is written. Used by provider switch to
replay history after session initialization.
```

---

## Task 3: Add `can_submit_prompt()` guard to SessionManager

`_handle_input_submit` currently has no guard against
`session_id == nil`. If the user opens the widget (via
`toggle()`) and types before `on_session_ready` fires,
the prompt is sent with a nil session ID and history is
lost. Add a `can_submit_prompt()` method that gates
submission on all required conditions.

**Files:**

- Modify: `lua/agentic/session_manager.lua`
- Test: `lua/agentic/session_manager.test.lua`

### Steps

- [ ] **Step 1: Read `_handle_input_submit` and identify
  all conditions that should block submission**

Read `lua/agentic/session_manager.lua:486-664`. Identify:

- `self.session_id == nil` — session not created yet
- `self._is_restoring_session` — session restore in
  progress
- `self.is_generating` — already processing a prompt

Note: `is_generating` is currently not checked in
`_handle_input_submit` either. It's only checked in
`switch_provider`. Consider whether to add it here too
(the agent will keep receiving prompts and queue them,
but the UI doesn't reflect this). Read how it behaves
today and decide during implementation.

- [ ] **Step 2: Write failing test**

```lua
it(
    "rejects prompt when connection error",
    function()
        local session = create_test_session_with_id()
        session._connection_error = true

        local ok, reason = session:can_submit_prompt()
        assert.is_false(ok)
        assert.matches("failed to connect", reason)
    end
)

it(
    "rejects prompt when session_id is nil",
    function()
        local session = create_test_session()
        session.session_id = nil

        local ok, reason = session:can_submit_prompt()
        assert.is_false(ok)
        assert.matches("loading", reason)
    end
)

it(
    "rejects prompt when restoring session",
    function()
        local session = create_test_session_with_id()
        session._is_restoring_session = true

        local ok, reason = session:can_submit_prompt()
        assert.is_false(ok)
        assert.matches("restored", reason)
    end
)

it(
    "allows prompt when session is ready",
    function()
        local session = create_test_session_with_id()

        assert.is_true(session:can_submit_prompt())
    end
)
```

Run: `make test` — expected: FAIL

- [ ] **Step 3: Implement can_submit_prompt**

```lua
--- Check if the session can accept a prompt submission.
--- @return boolean can_submit
--- @return string|nil reason
function SessionManager:can_submit_prompt()
    if self._connection_error then
        return false,
            "Provider failed to connect."
                .. " Start a new session to retry."
    end

    if not self.session_id then
        return false,
            "Session is loading, please wait."
    end

    if self._is_restoring_session then
        return false,
            "Session is being restored,"
                .. " please wait."
    end

    return true, nil
end
```

Gate `_handle_input_submit` at the top (after the `/new`
intercept):

```lua
function SessionManager:_handle_input_submit(input_text)
    -- ... existing /new intercept ...

    local can_submit, reason = self:can_submit_prompt()
    if not can_submit then
        Logger.notify(
            reason,
            vim.log.levels.WARN
        )
        return
    end

    -- ... rest of the method ...
end
```

**Important:** Do NOT clear the input buffer when
blocking. The user's text stays in the input so they can
submit again once the session is ready.

- [ ] **Step 4: Run validate**

Run: `make validate` — expected: pass

- [ ] **Step 5: Commit**

```
feat(session-manager): add can_submit_prompt guard

Blocks prompt submission when session_id is nil (session
still creating), during session restore, or when the
provider is disconnected/error. Shows a notification and
preserves the user's input text.
```

---

## Task 4: Rewrite `apply_provider_switch` and
`Agentic.new_session` in init.lua

Both provider switch and new session need the same
destroy/recreate pattern. Extract shared guards into a
helper, then implement both flows.

**Current `Agentic.new_session()` problems:**

- No `is_generating` guard — destroys mid-generation
- No `session_id == nil` guard — orphans in-flight
  `create_session` RPC
- The `/new` intercept in `_handle_input_submit` (line 493)
  calls `self:new_session()` directly — also no guards

**Depends on:** Task 1 (replay_history_messages), Task 2
(on_session_ready), Task 3 (can_submit_prompt)

**Files:**

- Modify: `lua/agentic/init.lua` — rewrite both
  `apply_provider_switch` and `Agentic.new_session`
- Modify: `lua/agentic/session_manager.lua:493` — update
  `/new` intercept to use guards

### Steps

- [ ] **Step 1: Verify file_list and code_selection APIs**

Read `lua/agentic/ui/file_list.lua` and
`lua/agentic/ui/code_selection.lua` to confirm:

- `file_list:get_files()` returns a serializable list
- How to add files back (method name may be `add()` not
  `add_file()`)
- `code_selection:get_selections()` returns a list
- How to add selections back

Actual method names (from review):

- `FileList:get_files()` returns `string[]`
- `FileList:add(path)` takes a `string`
- `CodeSelection:get_selections()` returns
  `agentic.Selection[]`
- `CodeSelection:add(selection)` takes an
  `agentic.Selection`

Verify these during implementation, adapt if different.

- [ ] **Step 2: Read current Agentic.new_session and callers**

Read `lua/agentic/init.lua:142-156` and the `/new`
intercept at `session_manager.lua:490-496`. Search for
all callers of `Agentic.new_session` and
`SessionRegistry.new_session` across the codebase.

- [ ] **Step 3: Extract shared guard helper**

Both `apply_provider_switch` and `Agentic.new_session`
need the same guards. Extract into a local helper:

```lua
--- Check if the current session can be safely destroyed.
--- @param tab_page_id integer
--- @return boolean can_destroy
--- @return agentic.SessionManager|nil old_session
local function can_destroy_session(tab_page_id)
    local old_session =
        SessionRegistry.sessions[tab_page_id]

    if not old_session then
        return true, nil
    end

    if old_session.is_generating then
        Logger.notify(
            "Cannot start a new session while"
                .. " generating."
                .. " Stop generation first.",
            vim.log.levels.WARN
        )
        return false, old_session
    end

    -- Block if session still initializing
    -- (create_session RPC in flight).
    -- Allow if connection failed — user wants to
    -- retry or switch provider.
    if
        not old_session.session_id
        and not old_session._connection_error
    then
        Logger.notify(
            "Session is still being created."
                .. " Please wait and try again.",
            vim.log.levels.WARN
        )
        return false, old_session
    end

    return true, old_session
end
```

- [ ] **Step 4: Rewrite apply_provider_switch**

```lua
--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    local tab_page_id =
        vim.api.nvim_get_current_tabpage()

    local can_destroy, old_session =
        can_destroy_session(tab_page_id)
    if not can_destroy then
        return
    end

    -- Validate new provider BEFORE destroying old
    -- session. Prevents data loss if provider binary
    -- is not installed.
    local ACPHealth =
        require("agentic.acp.acp_health")
    local provider_config =
        Config.acp_providers[provider_name]
    if
        not provider_config
        or not ACPHealth.is_command_available(
            provider_config.command
        )
    then
        Logger.notify(
            "Provider '"
                .. provider_name
                .. "' is not available."
                .. " Install it first.",
            vim.log.levels.ERROR
        )
        return
    end

    -- Save state from old session before destroy
    local saved_messages = {}
    local saved_files = {}
    local saved_selections = {}
    local was_open = false

    if old_session then
        saved_messages =
            old_session.chat_history.messages
        saved_files =
            old_session.file_list:get_files()
        saved_selections =
            old_session.code_selection
                :get_selections()
        was_open = old_session.widget:is_open()
    end

    -- Destroy old session (full cleanup)
    SessionRegistry.destroy_session(tab_page_id)

    -- Switch provider and create new session
    Config.provider = provider_name
    local new_session =
        SessionRegistry.get_session_for_tab_page(
            tab_page_id
        )

    if not new_session then
        return
    end

    -- Open widget IMMEDIATELY if it was open.
    if was_open then
        new_session.widget:show()
    end

    -- Defer restoration to on_session_ready.
    -- CRITICAL: _history_to_send must be set
    -- INSIDE this callback, not before.
    new_session:on_session_ready(function()
        -- Guard: session still active for tab
        if SessionRegistry.sessions[tab_page_id]
            ~= new_session
        then
            return
        end

        -- Restore history for ACP replay and
        -- persistence continuity
        if #saved_messages > 0 then
            new_session.chat_history.messages =
                saved_messages
            new_session._history_to_send =
                saved_messages
            new_session._is_first_message = true
        end

        -- Replay messages visually
        new_session.message_writer
            :replay_history_messages(
                saved_messages
            )

        -- Restore files and code selections
        for _, file in ipairs(saved_files) do
            new_session.file_list:add(file)
        end
        for _, sel in ipairs(saved_selections) do
            new_session.code_selection:add(sel)
        end
    end)
end
```

- [ ] **Step 5: Rewrite Agentic.new_session**

Clean new session — no history restore, no state carry-over.
Full destroy + create + show.

```lua
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    local tab_page_id =
        vim.api.nvim_get_current_tabpage()

    local can_destroy = can_destroy_session(tab_page_id)
    if not can_destroy then
        return
    end

    if opts and opts.provider then
        Config.provider = opts.provider
    end

    -- Full destroy + fresh create
    SessionRegistry.destroy_session(tab_page_id)

    local session =
        SessionRegistry.get_session_for_tab_page(
            tab_page_id
        )

    if session then
        if
            not opts
            or opts.auto_add_to_context ~= false
        then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts)
    end
end
```

- [ ] **Step 6: Update `/new` intercept in SessionManager**

The `/new` intercept at `session_manager.lua:493` currently
calls `self:new_session()` directly (the SessionManager
method, not the Agentic function). This bypasses all guards
and doesn't destroy/recreate the widget.

Update to delegate to `Agentic.new_session()`:

```lua
if input_text:match("^/new%s*") then
    local Agentic = require("agentic")
    Agentic.new_session()
    return
end
```

This ensures `/new` typed in the chat input goes through
the same guarded destroy/recreate path as the keybind.

- [ ] **Step 7: Run validate**

Run: `make validate` — expected: pass

- [ ] **Step 8: Commit**

```
feat: destroy/recreate for provider switch and new session

- Extract can_destroy_session guard (shared by both flows)
- apply_provider_switch: full destroy + create + replay
- Agentic.new_session: full destroy + create (clean slate)
- /new intercept delegates to Agentic.new_session for
  consistent guard behavior
```

---

## Task 5: Remove old switch_provider from SessionManager

**Depends on:** Task 4

**Files:**

- Modify: `lua/agentic/session_manager.lua` — delete
  `switch_provider()` method
- Modify: `lua/agentic/session_manager.test.lua` — remove or
  rewrite switch_provider tests

### Steps

- [ ] **Step 1: Read existing switch_provider tests**

Read `lua/agentic/session_manager.test.lua` and find all
tests related to `switch_provider`. Understand what behavior
they verify.

- [ ] **Step 2: Delete switch_provider method**

Remove `SessionManager:switch_provider()` (around lines
870-932). Also remove the `@field` annotation if it exists
in the class definition.

- [ ] **Step 3: Update or remove related tests**

Tests that called `session:switch_provider()` should be
removed. The new provider switch behavior is tested via
integration (Task 5).

- [ ] **Step 4: Run validate**

Run: `make validate` — expected: pass

- [ ] **Step 5: Commit**

```
refactor: remove SessionManager:switch_provider()

Provider switching now handled by init.lua via
destroy/recreate through SessionRegistry. Eliminates
stale state bugs from in-place mutation.
```

---

## Task 6: Integration testing and manual verification

Verify the full flow works end-to-end.

**Depends on:** Tasks 1-5

**Files:**

- Check: `lua/agentic/session_registry.lua` — verify no
  changes needed
- Check: all modified files from previous tasks

### Steps

- [ ] **Step 1: Run full validate**

Run: `make validate` — expected: all pass

- [ ] **Step 2: Manual testing**

Test these scenarios manually:

1. Start session with Provider A, send messages, switch to
   Provider B — verify: fresh models/modes, history
   replayed visually, history sent to B on next prompt
1. Start session with Provider A, don't send messages,
   switch to Provider B — verify: clean session, no stale
   config_options
1. Switch from Provider A → B → A — verify: each switch
   is clean, no stale state
1. Switch with widget closed — verify: widget stays closed
1. Switch with files/selections added — verify: preserved
1. Switch while generating — verify: rejected with warning
1. Switch to non-installed provider — verify: rejected
   with error, old session preserved
1. Switch while session is still creating (session_id
   nil) — verify: rejected with "still being created"
1. Send messages on Provider B after switch, then switch
   to Provider C — verify: B's messages + A's history
   are all preserved and replayed
1. Widget opens immediately after switch with "busy"
   animation — type in input before session is ready,
   submit — verify: blocked with "Session is loading"
   notification, input text preserved in buffer
1. Verify replayed agent headers show correct provider
   name from history (e.g., "Agent - Claude" for old
   messages, "Agent - Gemini" for new messages)
1. Start session with a provider that fails to connect —
   verify: busy stops, error written to chat buffer,
   prompt submission blocked with "failed to connect"
1. After connection failure, switch to a working
   provider — verify: switch allowed (not blocked by
   "still being created"), new session works normally
1. `/new` while generating — verify: rejected with
   "stop generation first"
1. `/new` while session still creating — verify: rejected
   with "still being created"
1. `/new` after normal session — verify: clean slate, no
   history, no stale state, fresh widget and buffers
1. `/new` after connection failure — verify: allowed,
   fresh session created

- [ ] **Step 3: Commit any fixes from manual testing**

---

## Unresolved questions

1. **File list / code selection restore** — The review found
   actual APIs are `FileList:add(path)` and
   `CodeSelection:add(selection)`, not `add_file`/`add_selection`.
   Verify exact signatures during Task 3 Step 1. If these store
   buffer-local state or line numbers, they may not be trivially
   restorable after buffer destruction — adapt accordingly.

1. **Tool call visual fidelity** — `write_tool_call_block()`
   during replay will create full tool call UI (extmarks,
   borders, status icons). This should work but may differ from
   live rendering since multi-phase updates are collapsed to
   final state. `ChatHistory.ToolCall.tool_call_id` is typed
   as optional — add a nil guard in `replay_history_messages`
   to skip tool calls without an ID. Acceptable tradeoff.

1. **Widget focus** — After replay, cursor should be in the
   input buffer. `widget:show()` handles this by default. Verify
   during manual testing.

1. **`create_session` failure** — If the new provider's
   `create_session` RPC fails, `on_session_ready` callbacks
   never fire. The user sees a dead session with no history
   replay. This is acceptable — the session is unusable anyway.
   `_cancel_session` clears `_session_ready_callbacks` so stale
   callbacks don't fire on retry. A future improvement could add
   an error callback.
