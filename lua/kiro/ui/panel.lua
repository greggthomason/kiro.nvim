--- Right-hand chat panel: read-only transcript on top, editable prompt below.
local config = require("kiro.config")
local context = require("kiro.context")

---@class KiroPanel
---@field session KiroSession
---@field tbuf integer|nil transcript buffer
---@field pbuf integer|nil prompt buffer
---@field twin integer|nil transcript window
---@field pwin integer|nil prompt window
local Panel = {}
Panel.__index = Panel

local AGENT_KINDS = { agent = true, tool = true, thought = true, plan = true }
local PLAN_MARK = { completed = "[x]", in_progress = "[~]", pending = "[ ]" }
local STATE_LABEL = {
  disconnected = "disconnected",
  connecting = "connecting...",
  ready = "ready",
  prompting = "thinking...",
}

---@param session KiroSession
---@return KiroPanel
function Panel.new(session)
  local self = setmetatable({ session = session, render_pending = false }, Panel)
  session:subscribe(function()
    self:schedule_render()
  end)
  return self
end

-- Rendering ------------------------------------------------------------------

---@param text string|nil
---@return string[]
local function split(text)
  return vim.split((text or ""):gsub("\r", ""), "\n", { plain = true })
end

---@param entries KiroEntry[]
---@return string[]
function Panel.format(entries)
  local lines = {}
  local function add(...)
    for _, l in ipairs({ ... }) do
      lines[#lines + 1] = l
    end
  end
  local prev
  for _, e in ipairs(entries) do
    if e.kind == "user" then
      add("## You")
      vim.list_extend(lines, split(e.text))
      add("")
    elseif e.kind == "agent" then
      if not (prev and AGENT_KINDS[prev.kind]) then
        add("## Kiro")
      end
      vim.list_extend(lines, split(e.text))
      add("")
    elseif e.kind == "thought" then
      if not (prev and AGENT_KINDS[prev.kind]) then
        add("## Kiro")
      end
      for _, l in ipairs(split(e.text)) do
        add("> " .. l)
      end
      add("")
    elseif e.kind == "tool" then
      if not (prev and AGENT_KINDS[prev.kind]) then
        add("## Kiro")
      end
      add(("- tool: %s (%s)"):format(e.title or "tool call", e.status or "pending"), "")
    elseif e.kind == "plan" then
      if not (prev and AGENT_KINDS[prev.kind]) then
        add("## Kiro")
      end
      add("Plan:")
      for _, p in ipairs(e.entries or {}) do
        add(("- %s %s"):format(PLAN_MARK[p.status] or "[ ]", p.content or ""))
      end
      add("")
    elseif e.kind == "error" then
      local err_lines = split(e.text)
      add("> **Error:** " .. err_lines[1])
      for i = 2, #err_lines do
        add("> " .. err_lines[i])
      end
      add("")
    else -- info
      for _, l in ipairs(split(e.text)) do
        add("> " .. l)
      end
      add("")
    end
    prev = e
  end
  return lines
end

function Panel:schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.schedule(function()
    self.render_pending = false
    self:render()
  end)
end

function Panel:render()
  if self.tbuf and vim.api.nvim_buf_is_valid(self.tbuf) then
    local lines = Panel.format(self.session.transcript)
    -- Follow the stream unless the user scrolled up inside the focused transcript.
    local follow = true
    if self.twin and vim.api.nvim_win_is_valid(self.twin) and vim.api.nvim_get_current_win() == self.twin then
      local row = vim.api.nvim_win_get_cursor(self.twin)[1]
      follow = row >= vim.api.nvim_buf_line_count(self.tbuf)
    end
    vim.bo[self.tbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.tbuf, 0, -1, false, lines)
    vim.bo[self.tbuf].modifiable = false
    if follow and self.twin and vim.api.nvim_win_is_valid(self.twin) then
      pcall(vim.api.nvim_win_set_cursor, self.twin, { math.max(#lines, 1), 0 })
    end
  end
  self:update_status()
end

function Panel:update_status()
  if self.twin and vim.api.nvim_win_is_valid(self.twin) then
    vim.wo[self.twin].winbar = (" Kiro  [%s] "):format(STATE_LABEL[self.session.state] or self.session.state)
  end
end

-- Buffers and windows ----------------------------------------------------------

---@param name string
---@return integer
local function make_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

function Panel:ensure_buffers()
  if not (self.tbuf and vim.api.nvim_buf_is_valid(self.tbuf)) then
    self.tbuf = make_buf("kiro://transcript")
    vim.bo[self.tbuf].modifiable = false
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = self.tbuf, nowait = true, silent = true, desc = desc })
    end
    map("q", function() self:close() end, "Kiro: close panel")
    map("i", function() self:focus_prompt() end, "Kiro: focus prompt")
    map("<C-c>", function() require("kiro").cancel() end, "Kiro: cancel")
  end
  if not (self.pbuf and vim.api.nvim_buf_is_valid(self.pbuf)) then
    self.pbuf = make_buf("kiro://prompt")
    local function map(modes, lhs, fn, desc)
      vim.keymap.set(modes, lhs, fn, { buffer = self.pbuf, silent = true, desc = desc })
    end
    map({ "n", "i" }, "<C-s>", function() self:send() end, "Kiro: send prompt")
    map("n", "<CR>", function() self:send() end, "Kiro: send prompt")
    map("n", "<C-c>", function() require("kiro").cancel() end, "Kiro: cancel")
  end
end

---@param win integer
local function style_win(win)
  for opt, val in pairs({
    wrap = true,
    linebreak = true,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    spell = false,
    list = false,
    cursorline = false,
  }) do
    vim.wo[win][opt] = val
  end
end

---@return boolean
function Panel:is_open()
  return self.twin ~= nil and vim.api.nvim_win_is_valid(self.twin)
end

---@param opts? { focus?: "prompt"|"keep" }
function Panel:open(opts)
  opts = opts or {}
  if self:is_open() then
    if opts.focus ~= "keep" then
      self:focus_prompt()
    end
    return
  end
  self:ensure_buffers()
  local origin = vim.api.nvim_get_current_win()
  local ui = config.options.ui
  local width = ui.width <= 1 and math.floor(vim.o.columns * ui.width) or math.floor(ui.width)
  width = math.max(width, 20)

  self.twin = vim.api.nvim_open_win(self.tbuf, false, { split = "right", win = -1, width = width })
  self.pwin = vim.api.nvim_open_win(self.pbuf, false, {
    split = "below",
    win = self.twin,
    height = math.max(math.floor(ui.prompt_height), 1),
  })
  for _, w in ipairs({ self.twin, self.pwin }) do
    style_win(w)
    vim.wo[w].winfixwidth = true
  end
  vim.wo[self.pwin].winfixheight = true
  vim.wo[self.pwin].winbar = " Prompt  (<C-s> send, <CR> in normal mode) "

  self.augroup = vim.api.nvim_create_augroup("KiroPanel", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed == self.twin or closed == self.pwin then
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })

  self:render()
  if opts.focus == "keep" then
    if vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  else
    vim.api.nvim_set_current_win(self.pwin)
  end
end

function Panel:close()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, key in ipairs({ "twin", "pwin" }) do
    local win = self[key]
    self[key] = nil
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

function Panel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function Panel:focus_prompt()
  if not self:is_open() then
    return self:open()
  end
  vim.api.nvim_set_current_win(self.pwin)
end

-- Prompt -----------------------------------------------------------------------

---@return string
function Panel:get_prompt()
  if not (self.pbuf and vim.api.nvim_buf_is_valid(self.pbuf)) then
    return ""
  end
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(self.pbuf, 0, -1, false), "\n"))
end

---@param text string
function Panel:set_prompt(text)
  self:ensure_buffers()
  vim.api.nvim_buf_set_lines(self.pbuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

--- Append text to the prompt, open the panel and move the cursor to the end.
---@param text string
function Panel:append_prompt(text)
  self:open()
  local existing = self:get_prompt()
  self:set_prompt(existing == "" and text or (existing .. "\n\n" .. text))
  local last = vim.api.nvim_buf_line_count(self.pbuf)
  vim.api.nvim_win_set_cursor(self.pwin, { last, 0 })
end

--- Send whatever is in the prompt buffer.
function Panel:send()
  local text = self:get_prompt()
  if text == "" then
    return
  end
  if self.session:prompt(context.build_prompt(text), text) then
    self:set_prompt("")
  end
end

return Panel
