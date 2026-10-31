local H = dofile("tests/helpers.lua")
local Rpc = require("kiro.acp.rpc")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function new_rpc(extra)
  return Rpc.new(vim.tbl_extend("force", { cmd = H.fake_cmd() }, extra or {}))
end

T["framing"] = MiniTest.new_set()

T["framing"]["buffers partial lines and splits multiple messages"] = function()
  local got = {}
  local rpc = new_rpc({ on_notify = function(m, p) got[#got + 1] = { m, p } end })
  rpc:_feed('{"jsonrpc":"2.0","method":"a","params":{"x"')
  eq(#got, 0)
  rpc:_feed(':1}}\n{"jsonrpc":"2.0","method":"b"}\n{"jsonrpc":"2.0","met')
  eq(#got, 2)
  eq(got[1], { "a", { x = 1 } })
  eq(got[2][1], "b")
  rpc:_feed('hod":"c"}\r\n')
  eq(#got, 3)
end

T["framing"]["ignores blank and invalid lines"] = function()
  local got = 0
  local rpc = new_rpc({ on_notify = function() got = got + 1 end })
  rpc:_feed("\n   \nnot json\n[1,2]\n")
  eq(got, 0)
  rpc:_feed('{"method":"ok"}\n')
  eq(got, 1)
end

T["framing"]["unknown agent request gets method-not-found"] = function()
  local sent
  local rpc = new_rpc()
  rpc.obj = { write = function(_, s) sent = vim.json.decode(s) end }
  rpc:_feed('{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{}}\n')
  eq(sent.id, 7)
  eq(sent.error.code, -32601)
end

T["process"] = MiniTest.new_set()

T["process"]["request/response roundtrip with the fake agent"] = function()
  local rpc = new_rpc()
  local ok = rpc:start()
  eq(ok, true)
  local result, err, done
  rpc:request("initialize", { protocolVersion = 1 }, function(e, r)
    err, result, done = e, r, true
  end)
  H.wait(function() return done end)
  eq(err, nil)
  eq(result.protocolVersion, 1)
  rpc:stop()
end

T["process"]["error responses are delivered"] = function()
  local rpc = new_rpc()
  rpc:start()
  local err, done
  rpc:request("nope/nothing", {}, function(e) err, done = e, true end)
  H.wait(function() return done end)
  eq(err.code, -32601)
  rpc:stop()
end

T["process"]["pending requests fail when the process exits"] = function()
  local rpc = new_rpc()
  local exit_code, intentional
  rpc.on_exit = function(c, i) exit_code, intentional = c, i end
  rpc:start()
  local sid
  rpc:request("session/new", {}, function(_, r) sid = r.sessionId end)
  H.wait(function() return sid end)
  local err
  rpc:request("session/prompt", { sessionId = sid, prompt = { { type = "text", text = "die" } } }, function(e) err = e end)
  H.wait(function() return err end)
  eq(err.closed, true)
  eq(err.code, Rpc.CLOSED)
  H.wait(function() return exit_code end)
  eq(exit_code, 3)
  eq(intentional, false)
end

T["process"]["start fails cleanly for a missing executable"] = function()
  local rpc = Rpc.new({ cmd = { "definitely-not-a-real-binary-xyz" } })
  local ok, err = rpc:start()
  eq(ok, false)
  eq(type(err), "string")
end

T["process"]["intentional stop is flagged"] = function()
  local rpc = new_rpc()
  local intentional
  rpc.on_exit = function(_, i) intentional = i end
  rpc:start()
  rpc:stop()
  H.wait(function() return intentional ~= nil end)
  eq(intentional, true)
end

return T
