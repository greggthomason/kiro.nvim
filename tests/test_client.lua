local H = dofile("tests/helpers.lua")
local Client = require("kiro.acp.client")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function new_client(extra)
  local c = Client.new(vim.tbl_extend("force", {
    cmd = H.fake_cmd(),
    on_update = function() end,
    on_permission = function() end,
    on_exit = function() end,
  }, extra or {}))
  assert(c:start())
  return c
end

local function connect(c)
  local sid
  c:initialize(function(err)
    assert(not err)
    c:new_session("/tmp", function(e, id)
      assert(not e)
      sid = id
    end)
  end)
  H.wait(function() return sid end)
  return sid
end

T["handshake yields a session id and capabilities"] = function()
  local c = new_client()
  local sid = connect(c)
  eq(sid, "sess-1")
  eq(c.agent_capabilities.loadSession, true)
  c:stop()
end

T["prompt streams updates then returns the stop reason"] = function()
  local updates = {}
  local c = new_client({ on_update = function(u) updates[#updates + 1] = u end })
  connect(c)
  local reason
  c:prompt({ { type = "text", text = "hello" } }, function(err, r)
    assert(not err)
    reason = r
  end)
  H.wait(function() return reason end)
  eq(reason, "end_turn")
  local kinds = vim.tbl_map(function(u) return u.sessionUpdate end, updates)
  eq(kinds, { "plan", "tool_call", "tool_call_update", "agent_message_chunk", "agent_message_chunk" })
  c:stop()
end

T["cancel ends a running prompt with 'cancelled'"] = function()
  local c = new_client()
  connect(c)
  local reason
  c:prompt({ { type = "text", text = "slow" } }, function(_, r) reason = r end)
  vim.wait(100)
  c:cancel()
  H.wait(function() return reason end)
  eq(reason, "cancelled")
  c:stop()
end

T["permission requests are forwarded and answered"] = function()
  local c = new_client({
    on_permission = function(params, respond)
      eq(params.toolCall.title, "Write file")
      respond({ outcome = { outcome = "selected", optionId = "allow" } })
    end,
  })
  connect(c)
  local texts = {}
  c.on_update = function(u)
    if u.content then texts[#texts + 1] = u.content.text end
  end
  local reason
  c:prompt({ { type = "text", text = "perm" } }, function(_, r) reason = r end)
  H.wait(function() return reason end)
  eq(reason, "end_turn")
  eq(texts, { "permission:allow" })
  c:stop()
end

T["session/load replays history and reuses the id"] = function()
  local updates = {}
  local c = new_client({ on_update = function(u) updates[#updates + 1] = u.sessionUpdate end })
  local loaded
  c:initialize(function()
    c:load_session("abc", "/tmp", function(err, id) loaded = err or id end)
  end)
  H.wait(function() return loaded end)
  eq(loaded, "abc")
  eq(c.session_id, "abc")
  eq(updates, { "user_message_chunk", "agent_message_chunk" })
  c:stop()
end

T["advertises no fs or terminal capabilities"] = function()
  local sent
  local c = Client.new({ cmd = { "x" }, on_update = function() end, on_exit = function() end })
  c.rpc.obj = { write = function(_, s) sent = vim.json.decode(s) end }
  c:initialize(function() end)
  eq(sent.params.clientCapabilities.terminal, false)
  eq(sent.params.clientCapabilities.fs.readTextFile, false)
  eq(sent.params.clientCapabilities.fs.writeTextFile, false)
  eq(sent.params.protocolVersion, 1)
end

return T
