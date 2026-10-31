local H = dofile("tests/helpers.lua")
local Session = require("kiro.session")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function new_session(extra)
  return Session.new(vim.tbl_extend("force", { cmd = H.fake_cmd() }, extra or {}))
end

local function kinds(s)
  return vim.tbl_map(function(e) return e.kind end, s.transcript)
end

local function text_blocks(text)
  return { { type = "text", text = text } }
end

local function wait_idle(s)
  H.wait(function() return not s.busy end)
end

T["prompt connects lazily and builds a transcript"] = function()
  local s = new_session()
  eq(s.state, "disconnected")
  local states = {}
  s:subscribe(function(ev) if ev == "state" then states[#states + 1] = s.state end end)
  eq(s:prompt(text_blocks("hi"), "hi"), true)
  wait_idle(s)
  eq(kinds(s), { "user", "plan", "tool", "agent" })
  eq(s.transcript[4].text, "Echo: hi")
  eq(s.transcript[3].status, "completed")
  eq(s.transcript[3].title, "Reading file")
  eq(states, { "connecting", "ready", "prompting", "ready" })
  eq(s.session_id, "sess-1")
  s:close()
end

T["agent chunks are merged and streaming is closed"] = function()
  local s = new_session()
  s:prompt(text_blocks("x"), "x")
  wait_idle(s)
  eq(s.transcript[4].streaming, nil)
  s:close()
end

T["a second prompt while busy is rejected"] = function()
  local s = new_session()
  local notified
  local orig = vim.notify
  vim.notify = function(msg) notified = msg end
  eq(s:prompt(text_blocks("slow"), "slow"), true)
  eq(s:prompt(text_blocks("again"), "again"), false)
  vim.notify = orig
  eq(notified ~= nil, true)
  H.wait(function() return s.state == "prompting" end)
  s:cancel()
  wait_idle(s)
  s:close()
end

T["cancel stops a running prompt"] = function()
  local s = new_session()
  s:prompt(text_blocks("slow"), "slow")
  H.wait(function() return s.state == "prompting" and #s.transcript >= 2 end)
  eq(s:cancel(), true)
  wait_idle(s)
  eq(s.transcript[#s.transcript], { kind = "info", text = "Cancelled" })
  eq(s.state, "ready")
  eq(s:cancel(), false)
  s:close()
end

T["multiple prompts reuse the same agent session"] = function()
  local s = new_session()
  s:prompt(text_blocks("one"), "one")
  wait_idle(s)
  s:prompt(text_blocks("two"), "two")
  wait_idle(s)
  eq(s.session_id, "sess-1")
  eq(s.transcript[#s.transcript].text, "Echo: two")
  s:close()
end

T["agent crash is reported and the session reconnects"] = function()
  local s = new_session()
  s:prompt(text_blocks("die"), "die")
  H.wait(function() return s.state == "disconnected" and #s.transcript >= 2 end)
  wait_idle(s)
  local last = s.transcript[#s.transcript]
  eq(last.kind, "error")
  eq(last.text:find("exited unexpectedly", 1, true) ~= nil, true)
  eq(s.state, "disconnected")
  s:prompt(text_blocks("hello"), "hello")
  wait_idle(s)
  eq(s.transcript[#s.transcript].text, "Echo: hello")
  s:close()
end

T["missing executable yields a readable error"] = function()
  local s = Session.new({ cmd = { "definitely-not-a-real-binary-xyz" } })
  s:prompt(text_blocks("hi"), "hi")
  wait_idle(s)
  local last = s.transcript[#s.transcript]
  eq(last.kind, "error")
  eq(last.text:find("failed to start", 1, true) ~= nil, true)
  eq(s.state, "disconnected")
end

T["invalid agent output does not break the stream"] = function()
  local s = new_session()
  s:prompt(text_blocks("bad"), "bad")
  wait_idle(s)
  eq(s.transcript[#s.transcript].text, "Echo: bad")
  s:close()
end

T["an injected session_id is resumed via session/load"] = function()
  local s = new_session({ session_id = "existing-42" })
  s:prompt(text_blocks("next"), "next")
  wait_idle(s)
  eq(s.session_id, "existing-42")
  -- replayed history, then the new turn
  eq(s.transcript[1], { kind = "user", text = "next" })
  local texts = vim.tbl_map(function(e) return e.text end, s.transcript)
  eq(vim.tbl_contains(texts, "old question"), true)
  eq(vim.tbl_contains(texts, "old answer"), true)
  eq(s.transcript[#s.transcript].text, "Echo: next")
  s:close()
end

T["permission: selecting an option is relayed to the agent"] = function()
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local s = new_session()
  s:prompt(text_blocks("perm"), "perm")
  wait_idle(s)
  vim.ui.select = orig
  local texts = vim.tbl_map(function(e) return e.text or "" end, s.transcript)
  eq(vim.tbl_contains(texts, "Permission: Allow once"), true)
  eq(vim.tbl_contains(texts, "permission:allow"), true)
  s:close()
end

T["permission: dismissing the menu cancels the request"] = function()
  local orig = vim.ui.select
  vim.ui.select = function(_, _, cb) cb(nil) end
  local s = new_session()
  s:prompt(text_blocks("perm"), "perm")
  wait_idle(s)
  vim.ui.select = orig
  eq(s.transcript[#s.transcript], { kind = "info", text = "Cancelled" })
  s:close()
end

T["permission: cancelling the turn resolves a pending menu"] = function()
  local orig = vim.ui.select
  local late_cb
  vim.ui.select = function(_, _, cb) late_cb = cb end
  local s = new_session()
  s:prompt(text_blocks("perm"), "perm")
  H.wait(function() return late_cb ~= nil end)
  eq(s:cancel(), true)
  wait_idle(s)
  eq(s.transcript[#s.transcript], { kind = "info", text = "Cancelled" })
  late_cb({ optionId = "allow", name = "Allow once" }) -- a late choice must be ignored
  vim.ui.select = orig
  eq(s.state, "ready")
  s:close()
end

T["restart stops the agent and the next prompt starts fresh"] = function()
  local s = new_session()
  s:prompt(text_blocks("one"), "one")
  wait_idle(s)
  s:restart()
  eq(s.state, "disconnected")
  eq(s.session_id, nil)
  s:prompt(text_blocks("two"), "two")
  wait_idle(s)
  eq(s.session_id, "sess-1") -- fresh agent process, fresh counter
  eq(s.transcript[#s.transcript].text, "Echo: two")
  s:close()
end

return T
