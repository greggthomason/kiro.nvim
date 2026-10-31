-- Init file for running the test suite: nvim --headless -u scripts/minimal_init.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.o.swapfile = false

-- mini.test is fetched on first run into .deps/ (git-ignored).
local mini = root .. "/.deps/mini.test"
if not vim.uv.fs_stat(mini) then
  vim.fn.mkdir(root .. "/.deps", "p")
  local out = vim.fn.system({
    "git", "clone", "--filter=blob:none", "--depth=1",
    "https://github.com/nvim-mini/mini.test", mini,
  })
  if vim.v.shell_error ~= 0 then
    io.stderr:write("Failed to clone mini.test:\n" .. out .. "\n")
    vim.cmd("cquit 1")
  end
end
vim.opt.runtimepath:prepend(mini)

require("mini.test").setup({
  collect = { find_files = function() return vim.fn.globpath("tests", "test_*.lua", true, true) end },
})
