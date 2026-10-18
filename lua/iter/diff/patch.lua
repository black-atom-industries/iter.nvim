local parser = require('iter.ui.diff.parser')

local M = {}

--- `raw` as `vim.system` text mode returns it: one carriage return before
--- each line end dropped.
---@param raw string[]
---@return string[]
function M.text(raw)
    return vim.tbl_map(function(line)
        return (line:gsub('\r$', ''))
    end, raw)
end

--- The `--- a/<path>` line naming the path of a `+++ b/<path>` line.
---@param plus string
---@return string
local function minus_of(plus)
    local name = plus:sub(5)

    if vim.startswith(name, '"b/') then
        name = '"a/' .. name:sub(4)
    elseif vim.startswith(name, 'b/') then
        name = 'a/' .. name:sub(3)
    end

    return '--- ' .. name
end

--- The patch of hunk `index` of `raw`, git's diff text with `a/` and `b/`
--- prefixes: the header of its file section, then the hunk up to the next
--- one. Mode change lines are left out, as `git add -p` does, so a hunk
--- never carries a chmod. A renamed or copied file names its new path on
--- both sides, so applying the patch never moves the file. Nil when there
--- is no such hunk.
---@param raw string[]
---@param index integer
---@return string[]?
function M.hunk(raw, index)
    local hunk = parser.parse_hunks(raw)[index]

    if hunk == nil then
        return nil
    end

    local first = hunk.raw_header_row

    while first > 1 and not vim.startswith(raw[first], 'diff ') do
        first = first - 1
    end

    local header = {}
    local renamed = false
    local plus

    for row = first, #raw do
        local line = raw[row]

        if vim.startswith(line, '@@') then
            break
        end

        if
            vim.startswith(line, 'rename from ')
            or vim.startswith(line, 'copy from ')
        then
            renamed = true
        elseif vim.startswith(line, '+++ ') then
            plus = line
        end

        if
            not vim.startswith(line, 'old mode ')
            and not vim.startswith(line, 'new mode ')
        then
            table.insert(header, line)
        end
    end

    if renamed and plus ~= nil then
        header = { minus_of(plus), plus }
    end

    return vim.list_extend(
        header,
        vim.list_slice(raw, hunk.raw_header_row, hunk.raw_end_row)
    )
end

return M
