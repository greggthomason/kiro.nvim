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

--- Ask the user to pick one of the options offered by the agent.
---@param params table session/request_permission params
---@param on_done fun(result: table, label: string, handle: KiroPermissionHandle)
---@return KiroPermissionHandle
function M.request(params, on_done)
  local tool = params.toolCall or {}
  local options = params.options or {}

  ---@type KiroPermissionHandle
  local handle = { done = false }

  local function finish(result, label)
    if handle.done then
      return
    end
    handle.done = true
    on_done(result, label, handle)
  end

  function handle.cancel()
    finish({ outcome = { outcome = "cancelled" } }, "cancelled")
  end

  if #options == 0 then
    handle.cancel()
    return handle
  end

  local prompt = table.concat(M.describe(tool), "\n")
  vim.ui.select(options, {
    prompt = prompt,
    format_item = function(option)
      return option.name or option.optionId
    end,
  }, function(choice)
    if not choice then
      return handle.cancel()
    end
    finish({ outcome = { outcome = "selected", optionId = choice.optionId } }, choice.name or choice.optionId)
  end)

  return handle
end

return M
