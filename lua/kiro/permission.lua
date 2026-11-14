--- Permission prompts for `session/request_permission`, presented with vim.ui.select.
local M = {}

---@class KiroPermissionHandle
---@field done boolean
---@field cancel fun()

local KIND_VERB = {
  read = "read",
  edit = "edit",
  delete = "delete",
  move = "move",
  search = "search",
  execute = "run",
  think = "think",
  fetch = "fetch",
  switch_mode = "switch mode",
  other = "use a tool",
}

--- Pick the command string out of a tool's raw input, trying the common keys
--- agents use (command / cmd / script), falling back to a compact JSON dump.
---@param raw any
---@return string|nil
local function raw_input_summary(raw)
  if type(raw) ~= "table" then
    if raw == nil or raw == vim.NIL then
      return nil
    end
    return tostring(raw)
  end
  for _, key in ipairs({ "command", "cmd", "script", "content", "text" }) do
    local v = raw[key]
    if type(v) == "string" and v ~= "" then
      return v
    end
    if type(v) == "table" then -- e.g. argv array
      local parts = {}
      for _, item in ipairs(v) do
        parts[#parts + 1] = tostring(item)
      end
      if #parts > 0 then
        return table.concat(parts, " ")
      end
    end
  end
  local ok, encoded = pcall(vim.json.encode, raw)
  if ok and encoded and encoded ~= "{}" then
    return encoded
  end
  return nil
end

---@param lines string[]
---@param label string
---@param value string
local function add_block(lines, label, value)
  local split = vim.split(value:gsub("\r", ""), "\n", { plain = true })
  if #split == 1 then
    lines[#lines + 1] = label .. ": " .. split[1]
  else
    lines[#lines + 1] = label .. ":"
    for _, l in ipairs(split) do
      lines[#lines + 1] = "    " .. l
    end
  end
end

--- Build human-readable detail lines describing what the agent wants to do.
---@param tool table toolCall (a ToolCallUpdate per ACP)
---@return string[]
function M.describe(tool)
  tool = tool or {}
  local lines = {}

  local verb = tool.kind and KIND_VERB[tool.kind]
  local title = tool.title or tool.toolCallId or "a tool call"
  if verb then
    lines[#lines + 1] = ("Kiro wants to %s: %s"):format(verb, title)
  else
    lines[#lines + 1] = "Kiro wants to: " .. title
  end
  if tool.name and tool.name ~= "" then
    lines[#lines + 1] = "Tool: " .. tool.name
  end

  -- Files the tool call touches.
  local locs = {}
  for _, loc in ipairs(tool.locations or {}) do
    if type(loc) == "table" and loc.path then
      local p = loc.path
      if loc.line then
        p = p .. ":" .. tostring(loc.line)
      end
      locs[#locs + 1] = p
    end
  end
  if #locs > 0 then
    lines[#lines + 1] = "Files: " .. table.concat(locs, ", ")
  end

  -- The command / arguments the tool was invoked with.
  local raw = raw_input_summary(tool.rawInput)
  if raw then
    add_block(lines, "Input", raw)
  end

  -- Content the agent has attached: inline text or a proposed diff.
  for _, item in ipairs(tool.content or {}) do
    if type(item) == "table" then
      if item.type == "diff" and item.path then
        lines[#lines + 1] = "Diff: " .. item.path
        if type(item.oldText) == "string" then
          for _, l in ipairs(vim.split(item.oldText:gsub("\r", ""), "\n", { plain = true })) do
            lines[#lines + 1] = "  - " .. l
          end
        end
        if type(item.newText) == "string" then
          for _, l in ipairs(vim.split(item.newText:gsub("\r", ""), "\n", { plain = true })) do
            lines[#lines + 1] = "  + " .. l
          end
        end
      elseif item.type == "content" and type(item.content) == "table" and item.content.type == "text" then
        add_block(lines, "Content", item.content.text or "")
      end
    end
  end

  return lines
end

---@param option table
---@return string
local function option_label(option)
  return option.name or option.optionId
end

--- Lines shown in the permission float: the tool details, a blank line, then one
--- numbered line per option. Every returned line is free of newlines.
---@param detail string[]
---@param options table[]
---@return string[] lines, integer first_option_line 1-based
function M.float_lines(detail, options)
  local lines = {}
  for _, l in ipairs(detail) do
    vim.list_extend(lines, vim.split((l:gsub("\r", "")), "\n", { plain = true }))
  end
  lines[#lines + 1] = ""
  local first = #lines + 1
  for i, option in ipairs(options) do
    local label = option_label(option):gsub("[\r\n]+", " ")
    lines[#lines + 1] = (" [%d] %s"):format(i, label)
  end
  return lines, first
end

--- Show the permission request in a centered float.
---@param detail string[]
---@param options table[]
---@param on_choice fun(option: table|nil) called once; nil means dismissed
---@return fun() close closes the float without calling `on_choice`
local function open_float(detail, options, on_choice)
  local lines, first = M.float_lines(detail, options)
  local prev_win = vim.api.nvim_get_current_win()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local editor_h = vim.o.lines - vim.o.cmdheight
  local width = math.min(math.max(math.floor(vim.o.columns * 0.6), 40), vim.o.columns - 2)
  local border = require("kiro.config").options.ui.border
  if border == "none" or border == "" then
    border = "single" -- title/footer need a border
  end
  local hint = #options > 1 and ("1-%d choose  <CR> select  q cancel"):format(math.min(#options, 9))
    or "<CR>/1 choose  q cancel"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = border,
    title = " Kiro: permission requested ",
    title_pos = "center",
    footer = " " .. hint .. " ",
    footer_pos = "center",
    width = width,
    height = 1,
    row = 0,
    col = math.floor((vim.o.columns - width) / 2),
    zindex = 100,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.cmd.stopinsert()

  -- Size to the wrapped content, capped to most of the editor, then center.
  local max_h = math.max(math.floor(editor_h * 0.8) - 2, 3)
  local height = math.min(math.max(vim.api.nvim_win_text_height(win, {}).all, 1), max_h)
  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    height = height,
    row = math.max(math.floor((editor_h - height - 2) / 2), 0),
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.api.nvim_win_set_cursor(win, { first, 0 })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  local function choose(option)
    if closed then
      return
    end
    close()
    on_choice(option)
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for i = 1, math.min(#options, 9) do
    map(tostring(i), function() choose(options[i]) end)
  end
  map("<CR>", function()
    local idx = vim.api.nvim_win_get_cursor(win)[1] - first + 1
    if options[idx] then
      choose(options[idx])
    end
  end)
  for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
    map(lhs, function() choose(nil) end)
  end

  -- Closing the window some other way (:close, :only, ...) counts as dismissing.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        closed = true
        vim.schedule(function() on_choice(nil) end)
      end
    end,
  })

  return close
end

--- Ask the user to pick one of the options offered by the agent. Uses a floating
--- window by default; `permission_ui = "select"` falls back to vim.ui.select.
---@param params table session/request_permission params
---@param on_done fun(result: table, label: string, handle: KiroPermissionHandle)
---@return KiroPermissionHandle
function M.request(params, on_done)
  local tool = params.toolCall or {}
  local options = params.options or {}

  ---@type KiroPermissionHandle
  local handle = { done = false }
  local close = function() end

  local function finish(result, label)
    if handle.done then
      return
    end
    handle.done = true
    close()
    on_done(result, label, handle)
  end

  function handle.cancel()
    finish({ outcome = { outcome = "cancelled" } }, "cancelled")
  end

  if #options == 0 then
    handle.cancel()
    return handle
  end

  local function on_choice(choice)
    if not choice then
      return handle.cancel()
    end
    finish({ outcome = { outcome = "selected", optionId = choice.optionId } }, option_label(choice))
  end

  local detail = M.describe(tool)
  if require("kiro.config").options.permission_ui == "select" then
    vim.ui.select(options, { prompt = table.concat(detail, "\n"), format_item = option_label }, on_choice)
  else
    close = open_float(detail, options, on_choice)
  end

  return handle
end

return M
