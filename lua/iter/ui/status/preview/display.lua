require('iter.ui.status.preview.types')

local common = require('iter.ui.status.common')
local diffs_nvim = require('iter.ui.diff.diffs_nvim')
local rail = require('iter.ui.status.preview.rail')
local window = require('iter.ui.status.window')
local buffers = require('iter.ui.status.preview.buffers')
local window_state = require('iter.ui.status.preview.window_state')

local M = {}

---@param self GitStatusWindow
---@param command string
---@return number?
local function create_preview_split(self, command)
    local current_win = vim.api.nvim_get_current_win()
    local ok, err = pcall(function()
        vim.cmd(command)
    end)

    if not ok then
        if common.is_valid_win(current_win) then
            pcall(vim.api.nvim_set_current_win, current_win)
        end

        common.notify_error(tostring(err), 'Cannot open diff preview')
        return nil
    end

    return vim.api.nvim_get_current_win()
end

---@param self GitStatusWindow
---@param win number
---@param buf integer
---@param created boolean
---@return boolean
local function set_preview_win_buf(self, win, buf, created)
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)

    if ok then
        return true
    end

    if
        created
        and common.is_valid_win(win)
        and #vim.api.nvim_tabpage_list_wins(0) > 1
    then
        pcall(vim.api.nvim_win_close, win, true)
    end

    if self.win ~= nil and common.is_valid_win(self.win) then
        pcall(vim.api.nvim_set_current_win, self.win)
    end

    common.notify_error(tostring(err), 'Cannot open diff preview')
    return false
end

---@param self GitStatusWindow
---@return boolean
function M.focus_open_diff(self)
    if common.is_valid_win(self.diff_win) then
        vim.api.nvim_set_current_win(self.diff_win)
        return true
    end

    return false
end

---@param self GitStatusWindow
---@return number?
local function reuse_or_create_window_above(self)
    -- Try to find an existing window above the status drawer first.
    local above = window.find_window_above(self.win)

    if above ~= nil then
        vim.api.nvim_set_current_win(above)
        return above
    end

    -- Nothing above — create a new split.
    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return create_preview_split(self, 'aboveleft split')
end

---@param self GitStatusWindow
---@param lines string[] raw unified diff lines (diffs.nvim parses them)
---@param preview_key string
---@param title string
---@param actions IterPreviewBufferActions
---@return boolean
function M.show_stacked(self, lines, preview_key, title, actions)
    local buf = buffers.ensure_stacked(self, actions)
    window_state.attach_autocmds(self, buf.id, actions)

    buffers.set_plain_lines(buf, lines)
    diffs_nvim.attach(buf.id)
    diffs_nvim.refresh(buf.id)

    local target_win
    local created_win = false

    if window_state.has_open_stacked_diff(self) then
        target_win = assert(self.diff_win)
        vim.api.nvim_set_current_win(target_win)
    else
        -- Always create a new window above the status drawer.
        target_win = reuse_or_create_window_above(self)

        if target_win == nil then
            return false
        end

        -- created_win is false here — we're reusing an existing window or
        -- the first-time create. window_state handles save/restore correctly
        -- based on whether the target was previously a diff window.
    end

    target_win = assert(target_win)
    local previous_buf = vim.api.nvim_win_get_buf(target_win)
    local was_diff_preview = previous_buf == buf.id
        and self.diff_win == target_win

    if not was_diff_preview then
        self.diff_prev_buf = previous_buf
        self.diff_prev_winopts = window.capture_winopts(target_win)
        self.diff_created_win = created_win
    end

    if not set_preview_win_buf(self, target_win, buf.id, created_win) then
        return false
    end

    window.configure_diff_win(target_win)
    rail.set(target_win, buf.id, lines)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = title
    self.diff_win = target_win
    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

return M
