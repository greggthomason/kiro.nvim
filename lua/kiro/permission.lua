--- Permission prompts for `session/request_permission`, presented with vim.ui.select.
local M = {}

---@class KiroPermissionHandle
---@field done boolean
---@field cancel fun()

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

  local title = tool.title or tool.toolCallId or "tool call"
  vim.ui.select(options, {
    prompt = "Kiro wants to: " .. title,
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
