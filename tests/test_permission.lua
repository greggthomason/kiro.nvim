local permission = require("kiro.permission")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function joined(tool)
  return table.concat(permission.describe(tool), "\n")
end

local function has(tool, needle)
  return joined(tool):find(needle, 1, true) ~= nil
end

T["describe uses the kind to form a verb and shows the title"] = function()
  local lines = permission.describe({ title = "Write file", kind = "edit" })
  eq(lines[1], "Kiro wants to edit: Write file")
end

T["describe falls back when the kind is unknown"] = function()
  local lines = permission.describe({ title = "Do thing" })
  eq(lines[1], "Kiro wants to: Do thing")
end

T["describe falls back to the toolCallId when there is no title"] = function()
  local lines = permission.describe({ toolCallId = "t-9" })
  eq(lines[1], "Kiro wants to: t-9")
end

T["describe surfaces the command from rawInput"] = function()
  eq(has({ title = "Run", kind = "execute", rawInput = { command = "rm -rf build" } }, "Input: rm -rf build"), true)
end

T["describe joins an argv array from rawInput"] = function()
  eq(has({ rawInput = { cmd = { "ls", "-la", "/tmp" } } }, "Input: ls -la /tmp"), true)
end

T["describe lists affected file locations"] = function()
  local tool = { kind = "edit", locations = { { path = "/tmp/a.txt", line = 3 }, { path = "/tmp/b.txt" } } }
  eq(has(tool, "Files: /tmp/a.txt:3, /tmp/b.txt"), true)
end

T["describe renders a proposed diff"] = function()
  local tool = {
    kind = "edit",
    content = { { type = "diff", path = "/tmp/c.txt", oldText = "before", newText = "after" } },
  }
  local out = joined(tool)
  eq(out:find("Diff: /tmp/c.txt", 1, true) ~= nil, true)
  eq(out:find("  - before", 1, true) ~= nil, true)
  eq(out:find("  + after", 1, true) ~= nil, true)
end

T["describe renders attached text content"] = function()
  local tool = {
    content = { { type = "content", content = { type = "text", text = "hello there" } } },
  }
  eq(has(tool, "Content: hello there"), true)
end

T["describe multi-line input is indented under a label line"] = function()
  local lines = permission.describe({ rawInput = { command = "line1\nline2" } })
  local joined_lines = table.concat(lines, "\n")
  eq(joined_lines:find("Input:\n    line1\n    line2", 1, true) ~= nil, true)
end

T["describe tolerates an empty tool call"] = function()
  local lines = permission.describe({})
  eq(lines[1], "Kiro wants to: a tool call")
end

T["float_lines numbers options after the details"] = function()
  local lines, first = permission.float_lines(
    { "Kiro wants to run: ls", "Input: a\nb" },
    { { name = "Allow once" }, { optionId = "deny" } }
  )
  eq(lines, { "Kiro wants to run: ls", "Input: a", "b", "", " [1] Allow once", " [2] deny" })
  eq(first, 5)
end

return T
