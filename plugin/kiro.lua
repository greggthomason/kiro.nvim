if vim.g.loaded_kiro then
  return
end
vim.g.loaded_kiro = 1

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("kiro.nvim requires Neovim 0.12+", vim.log.levels.ERROR)
  return
end

local function kiro()
  return require("kiro")
end

vim.api.nvim_create_user_command("Kiro", function()
  kiro().open()
end, { desc = "Open the Kiro chat panel" })

vim.api.nvim_create_user_command("KiroToggle", function()
  kiro().toggle()
end, { desc = "Toggle the Kiro chat panel" })

vim.api.nvim_create_user_command("KiroAsk", function(args)
  kiro().ask(args.args, { attach_file = args.bang })
end, {
  nargs = "+",
  bang = true,
  desc = "Send a prompt to Kiro (! attaches the current file)",
})

vim.api.nvim_create_user_command("KiroSelection", function(args)
  kiro().selection(args.line1, args.line2, args.args)
end, {
  range = true,
  nargs = "*",
  desc = "Send the selection to Kiro (optional instruction as argument)",
})

vim.api.nvim_create_user_command("KiroCancel", function()
  kiro().cancel()
end, { desc = "Cancel the current Kiro turn" })

vim.api.nvim_create_user_command("KiroRestart", function()
  kiro().restart()
end, { desc = "Restart the Kiro agent with a fresh session" })
