--- Building prompt content: plain text, file links and visual selections.
local M = {}

---@param text string
---@return table
function M.text_block(text)
  return { type = "text", text = text }
end

--- Absolute path of the current buffer's file, or nil for unnamed/special buffers.
---@param bufnr? integer
---@return string|nil
function M.current_file(bufnr)
  bufnr = bufnr or 0
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

--- ACP `resource_link` block with an absolute file:// URI.
---@param path string
---@return table
function M.file_link(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  return {
    type = "resource_link",
    uri = vim.uri_from_fname(abs),
    name = vim.fs.basename(abs),
  }
end

---@class KiroSelection
---@field text string
---@field path string|nil absolute path, nil if the buffer is unnamed
---@field line1 integer 1-based
---@field line2 integer 1-based
---@field filetype string

--- Read the selection for a command range. If the visual marks match the range,
--- the exact (charwise/blockwise) region is used; otherwise whole lines.
---@param line1 integer
---@param line2 integer
---@param bufnr? integer must be the current buffer
---@return KiroSelection|nil
function M.get_selection(line1, line2, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local count = vim.api.nvim_buf_line_count(bufnr)
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  if line1 < 1 or line1 > count then
    return nil
  end
  line2 = math.min(line2, count)

  local lines
  local start, finish = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if start[2] == line1 and finish[2] == line2 and vim.fn.visualmode() ~= "" then
    local ok, region = pcall(vim.fn.getregion, start, finish, { type = vim.fn.visualmode() })
    if ok and region then
      lines = region
    end
  end
  lines = lines or vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)

  local text = table.concat(lines, "\n")
  if not text:match("%S") then
    return nil
  end
  return {
    text = text,
    path = M.current_file(bufnr),
    line1 = line1,
    line2 = line2,
    filetype = vim.bo[bufnr].filetype,
  }
end

--- Render a selection as markdown for the prompt.
---@param sel KiroSelection
---@return string
function M.format_selection(sel)
  local where = sel.path or "[No Name]"
  local range = sel.line1 == sel.line2 and ("line %d"):format(sel.line1)
    or ("lines %d-%d"):format(sel.line1, sel.line2)
  -- Use a fence longer than any backtick run inside the text.
  local longest = 2
  for run in sel.text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", longest + 1)
  return ("%s (%s):\n%s%s\n%s\n%s"):format(where, range, fence, sel.filetype, sel.text, fence)
end

-- @file mentions -----------------------------------------------------------------

local TRAILING_PUNCT = "[%.,;:!%?%)%]}'\"]+$"

---@param path string
---@param cwd string
---@return string
local function absolute(path, cwd)
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  if path:sub(1, 1) ~= "/" then
    path = cwd .. "/" .. path
  end
  return vim.fs.normalize(path)
end

---@param path string
---@return boolean
local function is_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

--- Find `@path` mentions in prompt text and resolve them to existing files.
--- A mention starts at the beginning of the text or after whitespace (so emails
--- are ignored) and ends at whitespace; trailing punctuation is dropped when
--- that is what makes the path resolve. Paths are relative to `cwd`.
---@param text string
---@param cwd string
---@return string[] absolute paths, de-duplicated, in order of appearance
function M.extract_mentions(text, cwd)
  local found, seen = {}, {}
  for lead, token in (" " .. text):gmatch("(%s)@(%S+)") do
    local path
    for _, candidate in ipairs({ token, (token:gsub(TRAILING_PUNCT, "")) }) do
      if candidate ~= "" then
        local abs = absolute(candidate, cwd)
        if is_file(abs) then
          path = abs
          break
        end
      end
    end
    if path and not seen[path] then
      seen[path] = true
      found[#found + 1] = path
    end
  end
  return found
end

--- Completion candidates for the text after an `@`.
--- Open file buffers come first (when `base` has no directory part), then
--- directory entries below `cwd`. Directories end in "/" so completion can continue.
---@param base string text typed after the "@"
---@param cwd string
---@return string[]
function M.complete_paths(base, cwd)
  local dir_part, prefix = base:match("^(.*/)([^/]*)$")
  if not dir_part then
    dir_part, prefix = "", base
  end
  local show_hidden = prefix:sub(1, 1) == "."
  local items, seen = {}, {}
  local function add(item)
    if not seen[item] then
      seen[item] = true
      items[#items + 1] = item
    end
  end

  if dir_part == "" then
    local prefix_len = #cwd + 1
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) or ""
      if name ~= "" and vim.startswith(name, cwd .. "/") then
        local rel = name:sub(prefix_len + 1)
        if vim.startswith(rel, prefix) and is_file(name) then
          add(rel)
        end
      end
    end
  end

  local dir = dir_part == "" and cwd or absolute(dir_part, cwd)
  local entries = {}
  for name, type in vim.fs.dir(dir) do
    if vim.startswith(name, prefix) and (show_hidden or name:sub(1, 1) ~= ".") then
      if type == "link" then
        local stat = vim.uv.fs_stat(dir .. "/" .. name)
        type = stat and stat.type or type
      end
      if type == "directory" then
        entries[#entries + 1] = dir_part .. name .. "/"
      elseif type == "file" then
        entries[#entries + 1] = dir_part .. name
      end
    end
  end
  table.sort(entries)
  for _, e in ipairs(entries) do
    add(e)
  end
  return items
end

--- Build prompt content blocks.
--- `opts.file` adds one resource link; `opts.cwd` additionally turns every
--- `@path` mention in `text` into a resource link.
---@param text string
---@param opts? { file?: string, cwd?: string }
---@return table[]
function M.build_prompt(text, opts)
  opts = opts or {}
  local blocks = { M.text_block(text) }
  local linked = {}
  if opts.file then
    linked[vim.fn.fnamemodify(opts.file, ":p")] = true
    blocks[#blocks + 1] = M.file_link(opts.file)
  end
  if opts.cwd then
    for _, path in ipairs(M.extract_mentions(text, opts.cwd)) do
      if not linked[path] then
        linked[path] = true
        blocks[#blocks + 1] = M.file_link(path)
      end
    end
  end
  return blocks
end

return M
