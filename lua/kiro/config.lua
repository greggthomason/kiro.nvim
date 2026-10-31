---@class KiroConfig
---@field cmd string[] Command used to spawn the ACP agent
---@field cwd string|fun():string|nil Working directory for the session (default: current cwd)
---@field env table<string,string>|nil Extra environment for the agent process
---@field session_id string|nil Resume this session via `session/load` instead of creating a new one
---@field log boolean Write a debug log to stdpath("state")/kiro.log
---@field checktime boolean Run :checktime when a tool call or turn finishes, so buffers pick up files Kiro edited on disk
---@field ui { width: number, prompt_height: integer }
---@field keymaps boolean|table<string,string|false> Opt-in default keymaps

local M = {}

---@type KiroConfig
M.defaults = {
  cmd = { "kiro-cli", "acp" },
  cwd = nil,
  env = nil,
  session_id = nil,
  log = false,
  checktime = true,
  ui = {
    -- <= 1: fraction of the editor width; > 1: absolute number of columns
    width = 0.4,
    prompt_height = 8,
  },
  keymaps = false,
}

--- Keymaps applied when `keymaps = true` (or merged with a `keymaps` table).
M.default_keymaps = {
  toggle = "<leader>kk",
  ask = "<leader>ka",
  selection = "<leader>ks",
  cancel = "<leader>kc",
}

---@type KiroConfig
M.options = vim.deepcopy(M.defaults)

---@param o table
local function validate(o)
  vim.validate("cmd", o.cmd, function(v)
    return vim.islist(v) and #v > 0
  end, "non-empty list of strings")
  vim.validate("cwd", o.cwd, { "string", "function" }, true)
  vim.validate("env", o.env, "table", true)
  vim.validate("session_id", o.session_id, "string", true)
  vim.validate("log", o.log, "boolean")
  vim.validate("checktime", o.checktime, "boolean")
  vim.validate("ui", o.ui, "table")
  vim.validate("ui.width", o.ui.width, "number")
  vim.validate("ui.prompt_height", o.ui.prompt_height, "number")
  vim.validate("keymaps", o.keymaps, { "boolean", "table" })
end

---@param opts? table
---@return KiroConfig
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists must be replaced, never merged index-by-index.
  if opts.cmd then
    merged.cmd = vim.deepcopy(opts.cmd)
  end
  validate(merged)
  M.options = merged
  return M.options
end

--- Absolute working directory for new sessions.
---@return string
function M.cwd()
  local cwd = M.options.cwd
  if type(cwd) == "function" then
    cwd = cwd()
  end
  cwd = cwd or vim.fn.getcwd()
  return (vim.fn.fnamemodify(cwd, ":p"):gsub("(.)/$", "%1"))
end

--- Resolve the keymap option into a table of action -> lhs, or nil when disabled.
---@return table<string,string>|nil
function M.resolve_keymaps()
  local km = M.options.keymaps
  if not km then
    return nil
  end
  local resolved = vim.deepcopy(M.default_keymaps)
  if type(km) == "table" then
    for action, lhs in pairs(km) do
      resolved[action] = lhs or nil -- `false` disables a single mapping
    end
  end
  return resolved
end

return M
