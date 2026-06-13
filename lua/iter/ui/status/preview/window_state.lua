local common = require('iter.ui.status.common')
local window = require('iter.ui.status.window')

local M = {}

---@param buf Buffer?
---@param win number?
---@return boolean
local function has_diff_side(buf, win)
    if buf == nil or not buf:is_valid() or not common.is_valid_win(win) then
        return false
    end

    win = assert(win)
    return vim.api.nvim_win_get_buf(win) == buf.id
end

---@param self GitStatusWindow
local function clear_diff_context(self)
    self.diff_raw_lines = nil
    self.diff_raw_rows = nil
    self.diff_hunks = nil
    self.diff_section = nil
    self.diff_context_entry = nil
end

---@type IterDiffWindowState
M.STACKED_DIFF_STATE = {
    win_field = 'diff_win',
    prev_buf_field = 'diff_prev_buf',
    prev_winopts_field = 'diff_prev_winopts',
    created_win_field = 'diff_created_win',
    buf_field = 'diff_buf',
}

---@param self GitStatusWindow
---@return boolean
function M.has_open_stacked_diff(self)
    return has_diff_side(self.diff_buf, self.diff_win)
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return M.has_open_stacked_diff(self)
end

---@param self GitStatusWindow
---@param buf integer
---@return IterDiffWindowState?
function M.diff_window_state_for_buf(self, buf)
    local state = M.STACKED_DIFF_STATE
    local diff_buf = self[state.buf_field]

    if diff_buf ~= nil and diff_buf.id == buf then
        return state
    end

    return nil
end

---@param self GitStatusWindow
---@param win number
---@return IterDiffWindowState?
function M.diff_window_state_for_win(self, win)
    local state = M.STACKED_DIFF_STATE

    if self[state.win_field] == win then
        return state
    end

    return nil
end

---@param self GitStatusWindow
---@param state IterDiffWindowState
function M.clear_diff_window_state(self, state)
    self[state.win_field] = nil
    self[state.prev_buf_field] = nil
    self[state.prev_winopts_field] = nil
    self[state.created_win_field] = false
end

---@param self GitStatusWindow
function M.clear_missing_diff_window_states(self)
    local state = M.STACKED_DIFF_STATE

    if not has_diff_side(self[state.buf_field], self[state.win_field]) then
        M.clear_diff_window_state(self, state)
    end
end

---@param self GitStatusWindow
---@param buf integer
function M.restore_replaced_diff_window(self, buf)
    local state = M.diff_window_state_for_buf(self, buf)

    if state == nil then
        return
    end

    local win = self[state.win_field]

    if not common.is_valid_win(win) then
        M.clear_diff_window_state(self, state)
        return
    end

    if vim.api.nvim_win_get_buf(win) == buf then
        return
    end

    window.restore_winopts(win, self[state.prev_winopts_field])
    M.clear_diff_window_state(self, state)
end

---@param self GitStatusWindow
---@param buf integer
---@param actions IterPreviewBufferActions
function M.attach_autocmds(self, buf, actions)
    if self.autocmd_group == nil then
        return
    end

    vim.api.nvim_clear_autocmds({
        group = self.autocmd_group,
        buffer = buf,
    })
    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = self.autocmd_group,
        buffer = buf,
        callback = function(args)
            vim.schedule(function()
                M.restore_replaced_diff_window(self, args.buf)
            end)
        end,
    })

    if actions ~= nil then
        local keymaps_mod = require('iter.ui.status.keymaps')

        vim.api.nvim_create_autocmd('BufEnter', {
            group = self.autocmd_group,
            buffer = buf,
            callback = function()
                keymaps_mod.attach_diff_stacked(
                    buf,
                    self.config.keymaps_diff_stacked,
                    actions
                )
            end,
        })

        -- Re-attach diff keymaps on WinEnter to cover cases where BufEnter
        -- doesn't fire (e.g. returning to an already-visible diff window
        -- after focusing another window in the same tabpage).
        vim.api.nvim_create_autocmd('WinEnter', {
            group = self.autocmd_group,
            callback = function()
                local win = vim.api.nvim_get_current_win()

                if not vim.api.nvim_win_is_valid(win) then
                    return
                end

                if vim.api.nvim_win_get_buf(win) ~= buf then
                    return
                end

                keymaps_mod.attach_diff_stacked(
                    buf,
                    self.config.keymaps_diff_stacked,
                    actions
                )
            end,
        })
    end
end

---@param self GitStatusWindow
---@return Buffer[]
function M.diff_buffers(self)
    local buffers = {}
    local buf = self[M.STACKED_DIFF_STATE.buf_field]

    if buf ~= nil and buf:is_valid() then
        table.insert(buffers, buf)
    end

    return buffers
end

---@param self GitStatusWindow
function M.clear_diff_buffers(self)
    self[M.STACKED_DIFF_STATE.buf_field] = nil
end

---@param buffers Buffer[]
function M.delete_diff_buffers(buffers)
    for _, buf in ipairs(buffers) do
        pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
    end
end

---@param self GitStatusWindow
---@param state IterDiffWindowState
---@param keep_win boolean
---@return boolean
function M.restore_or_close_diff_window(self, state, keep_win)
    local win = self[state.win_field]

    if not common.is_valid_win(win) then
        M.clear_diff_window_state(self, state)
        return false
    end

    if keep_win then
        window.restore_winopts(win, self[state.prev_winopts_field])
        M.clear_diff_window_state(self, state)
        return true
    end

    if
        self[state.created_win_field]
        and #vim.api.nvim_tabpage_list_wins(0) > 1
    then
        vim.api.nvim_win_close(win, true)
    elseif
        self[state.prev_buf_field]
        and vim.api.nvim_buf_is_valid(self[state.prev_buf_field])
    then
        vim.api.nvim_win_set_buf(win, self[state.prev_buf_field])
        window.restore_winopts(win, self[state.prev_winopts_field])
    elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(win, true)
    else
        window.restore_winopts(win, self[state.prev_winopts_field])
    end

    M.clear_diff_window_state(self, state)
    return true
end

---@param self GitStatusWindow
---@param current_state IterDiffWindowState
---@return Buffer[]
---@return number
function M.close_diff_windows_for_code(self, current_state)
    local buffers = M.diff_buffers(self)
    local code_win = self[current_state.win_field]

    M.restore_or_close_diff_window(self, current_state, true)

    self.diff_preview_key = nil
    clear_diff_context(self)
    M.clear_diff_buffers(self)
    M.clear_missing_diff_window_states(self)

    return buffers, code_win
end

return M
