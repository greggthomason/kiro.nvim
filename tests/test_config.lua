local H = dofile("tests/helpers.lua")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["setup merges options"] = function()
  local config = require("kiro.config")
  config.setup({ ui = { width = 60 }, log = true })
  eq(config.options.ui.width, 60)
  eq(config.options.ui.prompt_height, 6)
  eq(config.options.log, true)
  eq(config.options.cmd, { "kiro-cli", "acp" })
  config.setup({})
end

T["cmd list is replaced, not merged"] = function()
  local config = require("kiro.config")
  config.setup({ cmd = { "x" } })
  eq(config.options.cmd, { "x" })
  config.setup({})
end

T["invalid options are rejected"] = function()
  local config = require("kiro.config")
  MiniTest.expect.error(function() config.setup({ cmd = {} }) end)
  MiniTest.expect.error(function() config.setup({ log = "yes" }) end)
  config.setup({})
end

T["keymaps are disabled by default"] = function()
  local config = require("kiro.config")
  config.setup({})
  eq(config.resolve_keymaps(), nil)
end

T["keymaps = true uses defaults, tables override and can disable"] = function()
  local config = require("kiro.config")
  config.setup({ keymaps = true })
  eq(config.resolve_keymaps(), config.default_keymaps)
  config.setup({ keymaps = { toggle = "<leader>x", cancel = false } })
  local km = config.resolve_keymaps()
  eq(km.toggle, "<leader>x")
  eq(km.cancel, nil)
  eq(km.ask, config.default_keymaps.ask)
  config.setup({})
end

T["cwd is absolute without trailing slash"] = function()
  local config = require("kiro.config")
  config.setup({ cwd = "/tmp/" })
  eq(config.cwd(), "/tmp")
  config.setup({ cwd = function() return "/usr/local" end })
  eq(config.cwd(), "/usr/local")
  config.setup({})
end

T["fake agent command is runnable"] = function()
  eq(vim.fn.filereadable(H.root .. "/tests/fake_agent.lua"), 1)
end

return T
