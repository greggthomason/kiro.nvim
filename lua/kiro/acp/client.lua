--- ACP client: protocol lifecycle on top of the JSON-RPC transport.
local Rpc = require("kiro.acp.rpc")

local PROTOCOL_VERSION = 1
local VERSION = "0.1.0"

---@class KiroClient
---@field rpc KiroRpc
---@field session_id string|nil
---@field agent_capabilities table
local Client = {}
Client.__index = Client

Client.VERSION = VERSION

---@class KiroClientOpts
---@field cmd string[]
---@field cwd? string
---@field env? table<string,string>
---@field on_update fun(update: table, params: table)
---@field on_permission fun(params: table, respond: fun(result: any, err: table|nil))
---@field on_exit fun(code: integer, intentional: boolean)

---@param opts KiroClientOpts
---@return KiroClient
function Client.new(opts)
  local self = setmetatable({
    agent_capabilities = {},
    auth_methods = {},
    session_id = nil,
    on_update = opts.on_update,
    on_permission = opts.on_permission,
  }, Client)

  self.rpc = Rpc.new({
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    on_exit = opts.on_exit,
    on_stderr = opts.on_stderr,
    on_notify = function(method, params)
      if method == "session/update" and params and params.update and self.on_update then
        self.on_update(params.update, params)
      end
    end,
    on_request = function(method, params, respond)
      if method == "session/request_permission" and self.on_permission then
        self.on_permission(params, respond)
        return true
      end
      return false -- fs/* and terminal/* are not advertised, so anything else is unsupported
    end,
  })
  return self
end

---@return boolean ok, string|nil err
function Client:start()
  return self.rpc:start()
end

---@param err table|nil
---@return string
function Client.err_message(err)
  if not err then
    return "unknown error"
  end
  local msg = err.message or "unknown error"
  if type(err.data) == "string" and err.data ~= "" then
    msg = msg .. ": " .. err.data
  end
  return msg
end

---@param cb fun(err: table|nil, result: table|nil)
function Client:initialize(cb)
  self.rpc:request("initialize", {
    protocolVersion = PROTOCOL_VERSION,
    -- No client-side file or terminal support in v1.
    clientCapabilities = {
      fs = { readTextFile = false, writeTextFile = false },
      terminal = false,
    },
    clientInfo = { name = "kiro.nvim", title = "kiro.nvim", version = VERSION },
  }, function(err, res)
    if err then
      return cb(err)
    end
    res = res or {}
    self.agent_capabilities = res.agentCapabilities or {}
    self.auth_methods = res.authMethods or {}
    self.agent_info = res.agentInfo
    cb(nil, res)
  end)
end

---@param cwd string absolute path
---@param cb fun(err: table|nil, session_id: string|nil)
function Client:new_session(cwd, cb)
  self.rpc:request("session/new", { cwd = cwd, mcpServers = {} }, function(err, res)
    if err then
      return cb(err)
    end
    self.session_id = res and res.sessionId
    cb(nil, self.session_id)
  end)
end

--- Resume an existing session. The agent replays history via session/update.
---@param session_id string
---@param cwd string absolute path
---@param cb fun(err: table|nil, session_id: string|nil)
function Client:load_session(session_id, cwd, cb)
  if not self.agent_capabilities.loadSession then
    return cb({ message = "the agent does not support session/load" })
  end
  self.rpc:request("session/load", { sessionId = session_id, cwd = cwd, mcpServers = {} }, function(err)
    if err then
      return cb(err)
    end
    self.session_id = session_id
    cb(nil, session_id)
  end)
end

---@param blocks table[] ACP content blocks
---@param cb fun(err: table|nil, stop_reason: string|nil)
function Client:prompt(blocks, cb)
  self.rpc:request("session/prompt", { sessionId = self.session_id, prompt = blocks }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res and res.stopReason)
  end)
end

function Client:cancel()
  if self.session_id then
    self.rpc:notify("session/cancel", { sessionId = self.session_id })
  end
end

function Client:stop()
  self.rpc:stop()
end

return Client
