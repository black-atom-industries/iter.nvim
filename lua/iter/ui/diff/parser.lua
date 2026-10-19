---@class IterDiffHunk
---@field index integer
---@field raw_header_row integer
---@field raw_start_row integer
---@field raw_end_row integer
---@field old_start integer
---@field old_count integer
---@field old_end integer
---@field new_start integer
---@field new_count integer
---@field new_end integer

local M = {}

---@param hunk_header string
---@return integer?, integer?, integer?, integer?
function M.parse_hunk_header(hunk_header)
    local old_start, old_count, new_start, new_count =
        hunk_header:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')

    if old_start == nil or new_start == nil then
        return nil, nil, nil, nil
    end

    return tonumber(old_start),
        old_count == '' and 1 or tonumber(old_count),
        tonumber(new_start),
        new_count == '' and 1 or tonumber(new_count)
end

---@param start integer
---@param count integer
---@return integer
local function range_end(start, count)
    return count > 0 and start + count - 1 or start
end

---@param lines string[]
---@return IterDiffHunk[]
function M.parse_hunks(lines)
    local hunks = {}
    local current

    for raw_row, text in ipairs(lines) do
        if vim.startswith(text, '@@') then
            if current ~= nil then
                current.raw_end_row = raw_row - 1
            end

            local old_start, old_count, new_start, new_count =
                M.parse_hunk_header(text)

            if
                old_start ~= nil
                and old_count ~= nil
                and new_start ~= nil
                and new_count ~= nil
            then
                current = {
                    index = #hunks + 1,
                    raw_header_row = raw_row,
                    raw_start_row = raw_row,
                    raw_end_row = #lines,
                    old_start = old_start,
                    old_count = old_count,
                    old_end = range_end(old_start, old_count),
                    new_start = new_start,
                    new_count = new_count,
                    new_end = range_end(new_start, new_count),
                }
                table.insert(hunks, current)
            end
        elseif current ~= nil and vim.startswith(text, 'diff ') then
            current.raw_end_row = raw_row - 1
            current = nil
        end
    end

    return hunks
end

return M
