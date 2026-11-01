--- kiro.nvim - an ACP client that connects Neovim to Kiro.
local config = require("kiro.config")

local M = {}

---@type KiroSession|nil
local session
---@type KiroPanel|nil
local panel

---@return KiroSession
function M.session()
  if not session then
    session = require("kiro.session").new()
    session:subscribe(function(event)
      -- Kiro edits files on disk with its own tools; refresh any open buffers.
      if event == "files" and config.options.checktime then
        pcall(vim.cmd, "silent! checktime")
      end
    end)
  end
  return session
end

---@return KiroPanel
function M.panel()
  if not panel then
    panel = require("kiro.ui.panel").new(M.session())
  end
  return panel
end

---@param opts? KiroConfig
function M.setup(opts)
  config.setup(opts)
  M.apply_keymaps()
end

function M.apply_keymaps()
  local km = config.resolve_keymaps()
  if not km then
    return
  end
  local function map(mode, action, rhs, desc)
    if km[action] then
      vim.keymap.set(mode, km[action], rhs, { desc = desc, silent = true })
    end
  end
  map("n", "toggle", "<Cmd>KiroToggle<CR>", "Kiro: toggle panel")
  map("n", "ask", ":KiroAsk ", "Kiro: ask")
  -- ":" in visual mode inserts '<,'> automatically
  map("x", "selection", ":KiroSelection<CR>", "Kiro: send selection")
  map("n", "cancel", "<Cmd>KiroCancel<CR>", "Kiro: cancel")
end

--- Open the panel and focus the prompt.
function M.open()
  M.panel():open()
end

function M.toggle()
  M.panel():toggle()
end

--- Send a prompt right away.
---@param text string
---@param opts? { attach_file?: boolean }
function M.ask(text, opts)
  opts = opts or {}
  local context = require("kiro.context")
  local file = opts.attach_file and context.current_file() or nil
  if opts.attach_file and not file then
    vim.notify("kiro.nvim: current buffer is not a file; nothing attached", vim.log.levels.WARN)
  end
  local display = text
  if file then
    display = ("%s\n\n[attached: %s]"):format(text, file)
  end
  M.panel():open({ focus = "keep" })
  M.session():prompt(context.build_prompt(text, { file = file }), display)
end

--- Send (or stage) a range of the current buffer.
--- With `instruction` the prompt is sent immediately; without, the selection is
--- placed in the prompt buffer so it can be edited first.
---@param line1 integer
---@param line2 integer
---@param instruction? string
function M.selection(line1, line2, instruction)
  local context = require("kiro.context")
  local sel = context.get_selection(line1, line2)
  if not sel then
    vim.notify("kiro.nvim: nothing to send (empty selection)", vim.log.levels.WARN)
    return
  end
  local body = context.format_selection(sel)
  if instruction and vim.trim(instruction) ~= "" then
    local text = instruction .. "\n\n" .. body
    M.panel():open({ focus = "keep" })
    M.session():prompt(context.build_prompt(text), text)
  else
    M.panel():append_prompt(body)
  end
end

--- Cancel the current turn.
function M.cancel()
  if not session or not session:cancel() then
    vim.notify("kiro.nvim: nothing to cancel", vim.log.levels.INFO)
  end
end

--- Stop the agent process and start over with a fresh session.
--- With `session_id`, the next prompt resumes that session via ACP `session/load`
--- (its history is replayed into the transcript); without, a new session is created.
---@param session_id? string
function M.restart(session_id)
  if session_id ~= nil and session_id ~= "" then
    config.options.session_id = session_id
  end
  M.session():restart()
end

--- Open the panel and resume an existing session by id (via `session/load`).
---@param session_id string
function M.resume(session_id)
  M.restart(session_id)
  M.panel():open()
end

return M
