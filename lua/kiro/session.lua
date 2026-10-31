--- A chat session: owns the ACP client, the connection state and the transcript model.
local config = require("kiro.config")
local Client = require("kiro.acp.client")
local permission = require("kiro.permission")
local log = require("kiro.log")

---@alias KiroState "disconnected"|"connecting"|"ready"|"prompting"

---@class KiroEntry
---@field kind "user"|"agent"|"thought"|"tool"|"plan"|"info"|"error"
---@field text? string
---@field streaming? boolean
---@field id? string tool call id
---@field title? string
---@field status? string
---@field entries? table[] plan entries

---@class KiroSession
---@field state KiroState
---@field busy boolean
---@field transcript KiroEntry[]
---@field session_id string|nil
local Session = {}
Session.__index = Session

local STREAM_KINDS = {
  agent_message_chunk = "agent",
  agent_thought_chunk = "thought",
  user_message_chunk = "user",
}

---@param opts? { cmd?: string[], cwd?: string, env?: table, session_id?: string }
---@return KiroSession
function Session.new(opts)
  opts = opts or {}
  return setmetatable({
    -- Overrides only; unset values are read from the config when connecting,
    -- so a later `setup()` call still takes effect.
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    session_id = opts.session_id or config.options.session_id,
    state = "disconnected",
    busy = false,
    transcript = {},
    listeners = {},
    waiters = {},
    permissions = {},
  }, Session)
end

-- Events ---------------------------------------------------------------------

---@param fn fun(event: "transcript"|"state"|"files")
function Session:subscribe(fn)
  self.listeners[#self.listeners + 1] = fn
end

---@param event "transcript"|"state"|"files" "files" = files on disk may have changed
function Session:_emit(event)
  for _, fn in ipairs(self.listeners) do
    local ok, err = pcall(fn, event)
    if not ok then
      log.error("listener failed:", err)
    end
  end
end

---@param state KiroState
function Session:_set_state(state)
  if self.state ~= state then
    self.state = state
    self:_emit("state")
  end
end

-- Transcript -----------------------------------------------------------------

---@param entry KiroEntry
---@return KiroEntry
function Session:_append(entry)
  self.transcript[#self.transcript + 1] = entry
  self:_emit("transcript")
  return entry
end

--- Append streamed text, merging into the previous entry of the same kind.
---@param kind string
---@param text string
function Session:_stream(kind, text)
  local last = self.transcript[#self.transcript]
  if last and last.kind == kind and last.streaming then
    last.text = last.text .. text
    self:_emit("transcript")
  else
    self:_append({ kind = kind, text = text, streaming = true })
  end
end

function Session:_close_streams()
  for _, e in ipairs(self.transcript) do
    e.streaming = nil
  end
end

---@param id string
---@return KiroEntry|nil
function Session:_find_tool(id)
  for i = #self.transcript, 1, -1 do
    local e = self.transcript[i]
    if e.kind == "tool" and e.id == id then
      return e
    end
  end
end

---@param update table
function Session:_on_update(update)
  local kind = update.sessionUpdate
  local stream = STREAM_KINDS[kind]
  if stream then
    local content = update.content
    if content and content.type == "text" and content.text then
      self:_stream(stream, content.text)
    end
  elseif kind == "tool_call" then
    self:_append({
      kind = "tool",
      id = update.toolCallId,
      title = update.title or "tool call",
      status = update.status or "pending",
    })
  elseif kind == "tool_call_update" then
    local entry = update.toolCallId and self:_find_tool(update.toolCallId)
    if entry then
      entry.title = update.title or entry.title
      entry.status = update.status or entry.status
      self:_emit("transcript")
      if entry.status == "completed" or entry.status == "failed" then
        self:_emit("files")
      end
    end
  elseif kind == "plan" then
    local existing
    for _, e in ipairs(self.transcript) do
      if e.kind == "plan" then
        existing = e
      end
    end
    if existing then
      existing.entries = update.entries or {}
      self:_emit("transcript")
    else
      self:_append({ kind = "plan", entries = update.entries or {} })
    end
  end
  -- Other update kinds (modes, commands, ...) are ignored in v1.
end

-- Permissions ----------------------------------------------------------------

---@param params table
---@param respond fun(result: any, err: table|nil)
function Session:_on_permission(params, respond)
  local tool = params.toolCall or {}
  self:_append({ kind = "info", text = "Permission requested: " .. (tool.title or tool.toolCallId or "tool call") })
  local handle = permission.request(params, function(result, label, h)
    self.permissions[h] = nil
    self:_append({ kind = "info", text = "Permission: " .. label })
    respond(result)
  end)
  if not handle.done then
    self.permissions[handle] = true
  end
end

function Session:_cancel_permissions()
  local handles = vim.tbl_keys(self.permissions)
  for _, handle in ipairs(handles) do
    handle.cancel()
  end
end

-- Connection -----------------------------------------------------------------

---@param cb fun(err: table|nil)
function Session:connect(cb)
  if self.state == "ready" or self.state == "prompting" then
    return cb(nil)
  end
  self.waiters[#self.waiters + 1] = cb
  if self.state == "connecting" then
    return
  end
  self:_set_state("connecting")

  local function finish(err)
    if err then
      if self.client then
        self.client:stop()
        self.client = nil
      end
      self:_set_state("disconnected")
    else
      self:_set_state("ready")
    end
    local waiters = self.waiters
    self.waiters = {}
    for _, w in ipairs(waiters) do
      w(err)
    end
  end

  local function fail(err)
    err = err or { message = "unknown error" }
    finish({ message = Client.err_message(err), closed = err.closed })
  end

  local cmd = self.cmd or config.options.cmd
  local client
  client = Client.new({
    cmd = cmd,
    cwd = self.cwd or config.cwd(),
    env = self.env or config.options.env,
    on_update = function(update)
      self:_on_update(update)
    end,
    on_permission = function(params, respond)
      self:_on_permission(params, respond)
    end,
    on_stderr = function(data)
      self.stderr_tail = vim.trim((self.stderr_tail or "") .. data):sub(-500)
    end,
    on_exit = function(code, intentional)
      if self.client ~= client then
        return -- stale client (already replaced or stopped)
      end
      self.client = nil
      self:_cancel_permissions()
      if not intentional then
        local msg = ("%s exited unexpectedly (code %d)"):format(cmd[1], code)
        if self.stderr_tail and self.stderr_tail ~= "" then
          msg = msg .. ":\n" .. self.stderr_tail
        end
        self:_append({ kind = "error", text = msg })
      end
      self.stderr_tail = nil
      self:_close_streams()
      self.busy = false
      self:_set_state("disconnected")
    end,
  })
  self.client = client

  local ok, err = client:start()
  if not ok then
    return finish({ message = ("failed to start %s: %s"):format(cmd[1], err) })
  end

  local cwd = self.cwd or config.cwd()
  client:initialize(function(ierr)
    if ierr then
      return fail(ierr)
    end
    local function on_session(serr, sid)
      if serr then
        return fail(serr)
      end
      self.session_id = sid
      finish(nil)
    end
    if self.session_id then
      client:load_session(self.session_id, cwd, on_session)
    else
      client:new_session(cwd, on_session)
    end
  end)
end

-- Prompting ------------------------------------------------------------------

---@param blocks table[] ACP content blocks
---@param display? string text shown in the transcript
---@return boolean accepted
function Session:prompt(blocks, display)
  if self.busy then
    vim.notify("kiro.nvim: still working on the previous prompt", vim.log.levels.WARN)
    return false
  end
  self.busy = true
  self:_append({ kind = "user", text = display or "" })

  self:connect(function(err)
    if err then
      self.busy = false
      if not err.closed then
        self:_append({ kind = "error", text = err.message })
      end
      return
    end
    self:_set_state("prompting")
    self.client:prompt(blocks, function(perr, stop_reason)
      self.busy = false
      self:_close_streams()
      if perr then
        if not perr.closed then -- closed => the exit handler reports it
          self:_append({ kind = "error", text = Client.err_message(perr) })
          self:_set_state("ready")
        end
        return
      end
      if stop_reason == "cancelled" then
        self:_append({ kind = "info", text = "Cancelled" })
      elseif stop_reason and stop_reason ~= "end_turn" then
        self:_append({ kind = "info", text = "Stopped: " .. stop_reason })
      else
        self:_emit("transcript")
      end
      self:_set_state("ready")
      self:_emit("files")
    end)
  end)
  return true
end

--- Cancel the running prompt turn, if any.
---@return boolean cancelled
function Session:cancel()
  if not (self.client and self.state == "prompting") then
    return false
  end
  self:_cancel_permissions()
  self.client:cancel()
  return true
end

--- Stop the agent process (intentionally). A later prompt reconnects.
function Session:close()
  local client = self.client
  self.client = nil
  self:_cancel_permissions()
  if client then
    client:stop()
  end
  self.busy = false
  self.waiters = {}
  self:_close_streams()
  self:_set_state("disconnected")
end

--- Stop and forget the current ACP session so the next prompt starts fresh.
function Session:restart()
  self:close()
  self.session_id = config.options.session_id
  self:_append({ kind = "info", text = "Session restarted" })
end

function Session:is_connected()
  return self.state == "ready" or self.state == "prompting"
end

return Session
