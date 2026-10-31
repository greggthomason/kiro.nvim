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

--- Build prompt content blocks.
---@param text string
---@param opts? { file?: string }
---@return table[]
function M.build_prompt(text, opts)
  opts = opts or {}
  local blocks = { M.text_block(text) }
  if opts.file then
    blocks[#blocks + 1] = M.file_link(opts.file)
  end
  return blocks
end

return M
