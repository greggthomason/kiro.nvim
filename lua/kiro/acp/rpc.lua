--- Newline-delimited JSON-RPC 2.0 over the stdio of a child process.
local log = require("kiro.log")

---@class KiroRpc
---@field cmd string[]
---@field pending table<integer, fun(err: table|nil, result: any)>
local Rpc = {}
Rpc.__index = Rpc

--- Error code used for requests that were in flight when the process went away.
Rpc.CLOSED = -32099

local DECODE_OPTS = { luanil = { object = true, array = true } }

---@class KiroRpcOpts
---@field cmd string[]
---@field cwd? string
---@field env? table<string,string>
---@field on_request? fun(method: string, params: any, respond: fun(result: any, err: table|nil)): boolean|nil
---@field on_notify? fun(method: string, params: any)
---@field on_exit? fun(code: integer, intentional: boolean)
---@field on_stderr? fun(data: string)

---@param opts KiroRpcOpts
---@return KiroRpc
function Rpc.new(opts)
  return setmetatable({
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    on_request = opts.on_request,
    on_notify = opts.on_notify,
    on_exit = opts.on_exit,
    on_stderr = opts.on_stderr,
    next_id = 1,
    pending = {},
    buf = "",
    intentional = false,
    exited = false,
  }, Rpc)
end

--- Spawn the process.
---@return boolean ok, string|nil err
function Rpc:start()
  log.path() -- resolve log path while on the main loop
  local ok, obj = pcall(vim.system, self.cmd, {
    stdin = true,
    text = true,
    cwd = self.cwd,
    env = self.env,
    stdout = vim.schedule_wrap(function(_, data)
      if data then
        self:_feed(data)
      end
    end),
    stderr = vim.schedule_wrap(function(_, data)
      if data then
        log.debug("stderr:", data)
        if self.on_stderr then
          self.on_stderr(data)
        end
      end
    end),
  }, function(res)
    vim.schedule(function()
      self:_on_exit(res.code)
    end)
  end)
  if not ok then
    return false, tostring(obj)
  end
  self.obj = obj
  return true
end

---@return boolean
function Rpc:is_running()
  return self.obj ~= nil and not self.exited
end

---@param msg table
---@return boolean ok
function Rpc:_send(msg)
  if not self.obj or self.exited then
    return false
  end
  msg.jsonrpc = "2.0"
  local line = vim.json.encode(msg)
  log.debug("->", line)
  return (pcall(self.obj.write, self.obj, line .. "\n"))
end

---@param method string
---@param params any
---@param cb fun(err: table|nil, result: any)
---@return integer id
function Rpc:request(method, params, cb)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = cb
  if not self:_send({ id = id, method = method, params = params }) then
    self.pending[id] = nil
    vim.schedule(function()
      cb({ code = Rpc.CLOSED, message = "agent process is not running", closed = true })
    end)
  end
  return id
end

---@param method string
---@param params any
function Rpc:notify(method, params)
  self:_send({ method = method, params = params })
end

---@param id integer|string
---@param result any
---@param err? table
function Rpc:respond(id, result, err)
  if err then
    self:_send({ id = id, error = err })
  else
    if result == nil then
      result = vim.NIL
    end
    self:_send({ id = id, result = result })
  end
end

--- Feed raw stdout data; complete lines are dispatched, partial lines are buffered.
---@param data string
function Rpc:_feed(data)
  self.buf = self.buf .. data
  while true do
    local nl = self.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self.buf:sub(1, nl - 1):gsub("\r$", "")
    self.buf = self.buf:sub(nl + 1)
    if line:match("%S") then
      self:_handle_line(line)
    end
  end
end

---@param line string
function Rpc:_handle_line(line)
  log.debug("<-", line)
  local ok, msg = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(msg) ~= "table" then
    log.error("invalid JSON from agent:", line)
    return
  end

  if msg.method ~= nil and msg.id ~= nil then
    self:_handle_request(msg)
  elseif msg.method ~= nil then
    if self.on_notify then
      local nok, nerr = pcall(self.on_notify, msg.method, msg.params)
      if not nok then
        log.error("notification handler failed:", nerr)
      end
    end
  elseif msg.id ~= nil then
    local cb = self.pending[msg.id]
    if cb then
      self.pending[msg.id] = nil
      local cok, cerr = pcall(cb, msg.error, msg.result)
      if not cok then
        log.error("response handler failed:", cerr)
      end
    end
  end
end

---@param msg table
function Rpc:_handle_request(msg)
  local answered = false
  local function respond(result, err)
    if answered then
      return
    end
    answered = true
    self:respond(msg.id, result, err)
  end
  local handled = false
  if self.on_request then
    local ok, res = pcall(self.on_request, msg.method, msg.params, respond)
    if not ok then
      log.error("request handler failed:", res)
      respond(nil, { code = -32603, message = "Internal error: " .. tostring(res) })
      return
    end
    handled = res ~= false
  end
  if not handled then
    respond(nil, { code = -32601, message = "Method not found: " .. msg.method })
  end
end

---@param code integer
function Rpc:_on_exit(code)
  if self.exited then
    return
  end
  self.exited = true
  local pending = self.pending
  self.pending = {}
  -- Report the exit first so owners can update state before in-flight requests fail.
  if self.on_exit then
    local ok, err = pcall(self.on_exit, code, self.intentional)
    if not ok then
      log.error("exit handler failed:", err)
    end
  end
  for _, cb in pairs(pending) do
    pcall(cb, { code = Rpc.CLOSED, message = "agent process exited (code " .. code .. ")", closed = true })
  end
end

--- Terminate the process. No error is reported for an intentional stop.
function Rpc:stop()
  if not self.obj or self.exited then
    return
  end
  self.intentional = true
  pcall(self.obj.write, self.obj, nil) -- close stdin
  pcall(self.obj.kill, self.obj, 15)
end

return Rpc
