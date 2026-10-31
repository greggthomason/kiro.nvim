local M = {}

function M.check()
  local config = require("kiro.config")
  vim.health.start("kiro.nvim")

  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim >= 0.12")
  else
    vim.health.error("Neovim 0.12+ is required")
  end

  local exe = config.options.cmd[1]
  if vim.fn.executable(exe) == 1 then
    vim.health.ok(("`%s` found: %s"):format(exe, vim.fn.exepath(exe)))
  else
    vim.health.error(("`%s` not found in $PATH"):format(exe), {
      "Install Kiro CLI, or set `cmd` in the kiro.nvim options",
    })
  end

  vim.health.info("Agent command: " .. table.concat(config.options.cmd, " "))
  if config.options.log then
    vim.health.info("Debug log: " .. require("kiro.log").path())
  end
end

return M
