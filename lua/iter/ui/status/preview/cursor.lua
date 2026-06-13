local common = require('iter.ui.status.common')
local diff_position = require('iter.ui.diff.position')

local M = {}

---@class IterDiffCursor
---@field row integer

---@param self GitStatusWindow
---@return IterDiffCursor?
function M.current_diff_cursor(self)
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)
    local row = vim.api.nvim_win_get_cursor(current_win)[1]

    if self.diff_buf ~= nil and current_buf == self.diff_buf.id then
        return { row = row }
    end

    return nil
end

---@param self GitStatusWindow
---@return IterDiffSourcePosition?
function M.current_source_position(self)
    local entry = self.diff_context_entry

    if entry == nil then
        return nil
    end

    local cursor = M.current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    local raw_row = self.diff_raw_rows and self.diff_raw_rows[cursor.row]
    local line_number = diff_position.source_line_for_stacked_row(
        self.diff_raw_lines,
        self.diff_hunks,
        raw_row
    )

    if line_number == nil then
        return nil
    end

    return { path = entry.path, line = math.max(line_number, 1) }
end

---@param self GitStatusWindow
---@return IterDiffHunkPosition?
function M.current_hunk_position(self)
    local cursor = M.current_diff_cursor(self)

    if cursor == nil then
        return nil
    end

    local raw_row = self.diff_raw_rows and self.diff_raw_rows[cursor.row]

    return diff_position.hunk_position_for_raw_row(
        self.diff_raw_lines,
        self.diff_hunks,
        raw_row
    )
end

---@param win number
---@param row integer?
function M.set_cursor_row(win, row)
    if row == nil then
        return
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
    local clamped = math.min(math.max(row, 1), line_count)

    pcall(vim.api.nvim_win_set_cursor, win, { clamped, 0 })
end

---@param self GitStatusWindow
---@param position IterDiffHunkPosition?
function M.restore_hunk_position(self, position)
    if position == nil then
        return
    end

    local hunk =
        diff_position.hunk_by_index(self.diff_hunks, position.hunk_index)

    if hunk == nil then
        return
    end

    if common.is_valid_win(self.diff_win) then
        local row = diff_position.stacked_row_for_hunk_position(
            self.diff_raw_lines,
            self.diff_raw_rows,
            hunk,
            position.side,
            position.offset
        )

        local win = assert(self.diff_win)
        vim.api.nvim_set_current_win(win)
        M.set_cursor_row(win, row)
    end
end

return M
