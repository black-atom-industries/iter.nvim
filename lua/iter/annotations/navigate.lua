local list = require('iter.annotations.list')
local marks = require('iter.annotations.marks')
local util = require('iter.util')

local M = {}

---@alias IterAnnotationSpot { line: integer, col: integer }

--- Where the line, range and passage annotations of `buf` start, by line and
--- column: a passage at its first column, a line or range at its first
--- non-blank character. Outdated annotations have no place.
---@param buf integer
---@return IterAnnotationSpot[]
function M.spots(buf)
    local target = marks.target(buf)

    if target == nil then
        return {}
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    ---@type IterAnnotationSpot[]
    local spots = {}

    for _, annotation in
        ipairs(require('iter.store').cached(target.root).annotations)
    do
        local a = annotation.anchor

        if
            (annotation.scope == 'line' or annotation.scope == 'range')
            and a.side == 'new'
            and a.path == target.path
        then
            local start, _, outdated, start_col =
                list.line_of(annotation, lines)

            if start ~= nil and not outdated then
                table.insert(spots, {
                    line = start,
                    col = start_col or (lines[start]:find('%S') or 1) - 1,
                })
            end
        end
    end

    table.sort(spots, function(a, b)
        if a.line ~= b.line then
            return a.line < b.line
        end

        return a.col < b.col
    end)

    return spots
end

--- Move the cursor of the current window to the next (`step` 1) or previous
--- (`step` -1) annotation of its buffer, wrapping at the ends.
---@param step 1|-1
function M.jump(step)
    local spots = M.spots(vim.api.nvim_get_current_buf())

    if #spots == 0 then
        util.warn('No annotations in this buffer')
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line, col = cursor[1], cursor[2]
    local found

    if step == 1 then
        for _, spot in ipairs(spots) do
            if spot.line > line or (spot.line == line and spot.col > col) then
                found = spot
                break
            end
        end

        found = found or spots[1]
    else
        for i = #spots, 1, -1 do
            local spot = spots[i]

            if spot.line < line or (spot.line == line and spot.col < col) then
                found = spot
                break
            end
        end

        found = found or spots[#spots]
    end

    vim.api.nvim_win_set_cursor(0, { found.line, found.col })
end

return M
