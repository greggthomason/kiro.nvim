-- Fake ACP agent for tests. Run with: nvim -l tests/fake_agent.lua
-- Speaks newline-delimited JSON-RPC 2.0 on stdio. Behaviour depends on the prompt text:
--   "slow"   streams a chunk, then waits for session/cancel
--   "perm"   asks the client for permission, then reports the outcome
--   "blocks" echoes the received prompt blocks as JSON
--   "die"    exits abruptly with code 3
--   "bad"    emits a garbage line before answering
--   other    streams a plan, a tool call and an echo
local json = vim.json

local function send(msg)
  msg.jsonrpc = "2.0"
  io.stdout:write(json.encode(msg), "\n")
  io.stdout:flush()
end

local function update(sid, u)
  send({ method = "session/update", params = { sessionId = sid, update = u } })
end

local function chunk(sid, text, kind)
  update(sid, {
    sessionUpdate = kind or "agent_message_chunk",
    content = { type = "text", text = text },
  })
end

local function finish(id, reason)
  send({ id = id, result = { stopReason = reason } })
end

local counter = 0
local pending_prompt -- { id, sid } waiting for cancel
local perm_wait -- { prompt_id, sid } waiting for permission response

local function prompt_text(blocks)
  local out = {}
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" then
      out[#out + 1] = b.text
    end
  end
  return table.concat(out, "\n")
end

local function on_prompt(msg)
  local sid = msg.params.sessionId
  local blocks = msg.params.prompt
  local text = prompt_text(blocks)

  if text:find("die", 1, true) == 1 then
    os.exit(3)
  elseif text:find("slow", 1, true) == 1 then
    chunk(sid, "working...")
    pending_prompt = { id = msg.id, sid = sid }
  elseif text:find("perm", 1, true) == 1 then
    perm_wait = { prompt_id = msg.id, sid = sid }
    send({
      id = "perm-1",
      method = "session/request_permission",
      params = {
        sessionId = sid,
        toolCall = {
          toolCallId = "t-perm",
          title = "Write file",
          name = "fs_write",
          kind = "edit",
          status = "pending",
          locations = { { path = "/tmp/hello.txt", line = 1 } },
          rawInput = { command = "write /tmp/hello.txt" },
          content = {
            {
              type = "diff",
              path = "/tmp/hello.txt",
              oldText = "old line",
              newText = "new line",
            },
          },
        },
        options = {
          { optionId = "allow", name = "Allow once", kind = "allow_once" },
          { optionId = "reject", name = "Reject", kind = "reject_once" },
        },
      },
    })
  elseif text:find("blocks", 1, true) == 1 then
    chunk(sid, "blocks:" .. json.encode(blocks))
    finish(msg.id, "end_turn")
  else
    if text:find("bad", 1, true) == 1 then
      io.stdout:write("this is not json\n")
      io.stdout:flush()
    end
    update(sid, {
      sessionUpdate = "plan",
      entries = { { content = "Think", priority = "high", status = "completed" } },
    })
    update(sid, {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Reading file",
      kind = "read",
      status = "in_progress",
    })
    update(sid, { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" })
    chunk(sid, "Echo: ")
    chunk(sid, text)
    finish(msg.id, "end_turn")
  end
end

local function handle(msg)
  local method = msg.method
  if method == "initialize" then
    send({
      id = msg.id,
      result = {
        protocolVersion = 1,
        agentCapabilities = { loadSession = true, promptCapabilities = {} },
        authMethods = {},
        agentInfo = { name = "fake-agent", version = "0.0.0" },
      },
    })
  elseif method == "session/new" then
    counter = counter + 1
    send({ id = msg.id, result = { sessionId = "sess-" .. counter } })
  elseif method == "session/load" then
    local sid = msg.params.sessionId
    chunk(sid, "old question", "user_message_chunk")
    chunk(sid, "old answer")
    send({ id = msg.id, result = vim.NIL })
  elseif method == "session/prompt" then
    on_prompt(msg)
  elseif method == "session/cancel" then
    if pending_prompt then
      finish(pending_prompt.id, "cancelled")
      pending_prompt = nil
    end
  elseif method == nil and msg.id == "perm-1" and perm_wait then
    local outcome = msg.result and msg.result.outcome
    if outcome and outcome.outcome == "selected" then
      chunk(perm_wait.sid, "permission:" .. outcome.optionId)
      finish(perm_wait.prompt_id, "end_turn")
    else
      finish(perm_wait.prompt_id, "cancelled")
    end
    perm_wait = nil
  elseif msg.id ~= nil and method ~= nil then
    send({ id = msg.id, error = { code = -32601, message = "Method not found: " .. method } })
  end
end

for line in io.stdin:lines() do
  local ok, msg = pcall(json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(msg) == "table" then
    handle(msg)
  end
end
