local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

--- Command that launches the fake ACP agent.
---@return string[]
function H.fake_cmd()
  return { vim.v.progpath, "-l", H.root .. "/tests/fake_agent.lua" }
end

--- Wait (processing events) until `cond()` is truthy.
---@param cond fun():any
---@param ms? integer
---@return boolean
function H.wait(cond, ms)
  return vim.wait(ms or 5000, cond, 10)
end

return H
