-- Init for child Neovim instances spawned by UI tests.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false
vim.cmd("runtime plugin/kiro.lua")
