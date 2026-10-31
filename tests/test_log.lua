local H = dofile("tests/helpers.lua")
local config = require("kiro.config")
local log = require("kiro.log")
local Session = require("kiro.session")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function lines()
  return vim.uv.fs_stat(log.path()) and vim.fn.readfile(log.path()) or {}
end

local function run_prompt()
  local s = Session.new({ cmd = H.fake_cmd() })
  s:prompt({ { type = "text", text = "hi" } }, "hi")
  H.wait(function() return not s.busy end)
  s:close()
end

-- The log lives in the real state dir, so this test only inspects what it appends.
T["logging is off by default and writes protocol traffic when enabled"] = function()
  config.setup({})
  local before = #lines()
  run_prompt()
  eq(#lines(), before)

  config.setup({ log = true })
  run_prompt()
  local all = lines()
  config.setup({})
  eq(#all > before, true)
  local added = table.concat(vim.list_slice(all, before + 1), "\n")
  eq(added:find('"method":"initialize"', 1, true) ~= nil, true)
  eq(added:find("session/prompt", 1, true) ~= nil, true)
end

return T
