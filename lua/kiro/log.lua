local M = {}

local path

--- Location of the debug log. Must be first called from the main loop.
---@return string
function M.path()
  if not path then
    path = vim.fs.joinpath(vim.fn.stdpath("state"), "kiro.log")
  end
  return path
end

---@param level string
---@param ... any
function M.write(level, ...)
  if not require("kiro.config").options.log then
    return
  end
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[#parts + 1] = type(v) == "string" and v or vim.inspect(v)
  end
  vim.fn.mkdir(vim.fs.dirname(M.path()), "p")
  local f = io.open(M.path(), "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] ", table.concat(parts, " "), "\n")
    f:close()
  end
end

function M.debug(...)
  M.write("debug", ...)
end

function M.error(...)
  M.write("error", ...)
end

return M
