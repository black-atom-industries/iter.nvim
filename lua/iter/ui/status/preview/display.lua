require('iter.ui.status.preview.types')

local common = require('iter.ui.status.common')
local diffs_nvim = require('iter.ui.diff.diffs_nvim')
local rail = require('iter.ui.status.preview.rail')
local window = require('iter.ui.status.window')
local buffers = require('iter.ui.status.preview.buffers')
local window_state = require('iter.ui.status.preview.window_state')
local preview_util = require('iter.ui.status.preview.util')
local log = require('iter.log')

local M = {}

---@param win number?
---@param enabled boolean
function M.set_split_line_numbers(win, enabled)
    if not common.is_valid_win(win) then
        return
    end

    vim.wo[win].number = enabled
    vim.wo[win].statuscolumn = enabled and '%l %s ' or '%s '
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_split_numbers(self)
    local enabled = false

    for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
        if common.is_valid_win(win) then
            enabled = not vim.wo[win].number
            break
        end
    end

    self.diff_split_show_numbers = enabled

    for _, win in ipairs({ self.diff_left_win, self.diff_right_win }) do
        M.set_split_line_numbers(win, enabled)
    end

    return true
end

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

    if common.is_valid_win(self.diff_right_win) then
        vim.api.nvim_set_current_win(self.diff_right_win)
        return true
    end

    if common.is_valid_win(self.diff_left_win) then
        vim.api.nvim_set_current_win(self.diff_left_win)
        return true
    end

    return false
end

---@param self GitStatusWindow
---@return number?
local function reuse_or_create_window_above(self)
    -- Try to find an existing window above the status drawer first.
    local window_mod = require('iter.ui.status.window')
    local above = window_mod.find_window_above(self.win)

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
    local transition_win
    local transition_prev_buf
    local transition_prev_winopts
    local transition_created_win = false

    -- Transition from split diff: convert the left window to stacked.
    if window_state.has_any_split_diff(self) then
        if common.is_valid_win(self.diff_right_win) then
            window_state.restore_or_close_diff_window(
                self,
                window_state.SPLIT_RIGHT_DIFF_STATE,
                false
            )
        end

        if common.is_valid_win(self.diff_left_win) then
            preview_util.diffoff(self.diff_left_win)
            transition_win = self.diff_left_win
            transition_prev_buf = self.diff_left_prev_buf
            transition_prev_winopts = self.diff_left_prev_winopts
            transition_created_win = self.diff_left_created_win == true
            window_state.clear_diff_window_state(
                self,
                window_state.SPLIT_LEFT_DIFF_STATE
            )
        end
    end

    local buf = buffers.ensure_stacked(self, actions)
    window_state.attach_autocmds(self, buf.id, actions, 'stacked')

    buffers.set_plain_lines(buf, lines)
    diffs_nvim.attach(buf.id)
    diffs_nvim.refresh(buf.id)

    local target_win
    local created_win = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
        vim.api.nvim_set_current_win(target_win)
    elseif window_state.has_open_stacked_diff(self) then
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

    if transition_win == target_win then
        self.diff_prev_buf = transition_prev_buf or previous_buf
        self.diff_prev_winopts = transition_prev_winopts
            or window.capture_winopts(target_win)
        self.diff_created_win = transition_created_win
    elseif not was_diff_preview then
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

---@param self GitStatusWindow
---@param split_diff GitSplitDiff
---@param preview_key string
---@param title string
---@param actions IterPreviewBufferActions
---@return boolean
function M.show_split(self, split_diff, preview_key, title, actions)
    local transition_win
    local transition_prev_buf
    local transition_prev_winopts
    local transition_created_win = false

    -- Transition from stacked diff: convert the stacked window to split left.
    if
        window_state.has_open_diff(self)
        and not window_state.has_open_split_diff(self)
    then
        transition_win = self.diff_win
        transition_prev_buf = self.diff_prev_buf
        transition_prev_winopts = self.diff_prev_winopts
        transition_created_win = self.diff_created_win == true
        window_state.clear_diff_window_state(
            self,
            window_state.STACKED_DIFF_STATE
        )
    end

    local left_buf = buffers.ensure_split(
        self,
        'Iter diff left',
        self.diff_left_buf,
        actions
    )
    local right_buf = buffers.ensure_split(
        self,
        'Iter diff right',
        self.diff_right_buf,
        actions
    )

    self.diff_left_buf = left_buf
    self.diff_right_buf = right_buf
    window_state.attach_autocmds(self, left_buf.id, actions, 'split')
    window_state.attach_autocmds(self, right_buf.id, actions, 'split')
    buffers.set_plain_lines(left_buf, split_diff.left.lines)
    buffers.set_plain_lines(right_buf, split_diff.right.lines)

    if split_diff.filetype ~= '' then
        vim.bo[left_buf.id].filetype = split_diff.filetype
        vim.bo[right_buf.id].filetype = split_diff.filetype
    end

    local target_win
    local left_created = false

    if transition_win ~= nil and common.is_valid_win(transition_win) then
        target_win = transition_win
        vim.api.nvim_set_current_win(target_win)
    elseif window_state.has_open_split_diff(self) then
        -- Reuse the existing left window directly.
        target_win = assert(self.diff_left_win)
        vim.api.nvim_set_current_win(target_win)
    else
        target_win = reuse_or_create_window_above(self)

        if target_win == nil then
            return false
        end

        -- Reusing existing window above, not creating.
    end

    target_win = assert(target_win)
    local was_left_preview = target_win == self.diff_left_win
        and vim.api.nvim_win_get_buf(target_win) == left_buf.id

    if transition_win == target_win then
        self.diff_left_prev_buf = transition_prev_buf
            or vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = transition_prev_winopts
            or window.capture_winopts(target_win)
        self.diff_left_created_win = transition_created_win
    elseif not was_left_preview then
        self.diff_left_prev_buf = vim.api.nvim_win_get_buf(target_win)
        self.diff_left_prev_winopts = window.capture_winopts(target_win)
        self.diff_left_created_win = left_created
    end

    if not set_preview_win_buf(self, target_win, left_buf.id, left_created) then
        return false
    end

    window.configure_split_diff_win(target_win)
    M.set_split_line_numbers(target_win, self.diff_split_show_numbers)
    vim.wo[target_win].wrap = self.diff_wrap
    vim.wo[target_win].winbar = title
        .. ' [1/2] '
        .. preview_util.winbar_text(split_diff.left.title)
    self.diff_left_win = target_win

    -- Create the right window by splitting the left.
    local right_win = self.diff_right_win
    local right_created = false

    if not common.is_valid_win(right_win) then
        right_win = create_preview_split(self, 'rightbelow vsplit')

        if right_win == nil then
            actions.close_diff()
            return false
        end

        right_created = true
    else
        right_win = assert(right_win)
        vim.api.nvim_set_current_win(right_win)
    end

    right_win = assert(right_win)
    local was_right_preview = vim.api.nvim_win_get_buf(right_win)
        == right_buf.id

    if not was_right_preview then
        self.diff_right_prev_buf = vim.api.nvim_win_get_buf(right_win)
        self.diff_right_prev_winopts = window.capture_winopts(right_win)
        self.diff_right_created_win = right_created
    end

    if
        not set_preview_win_buf(self, right_win, right_buf.id, right_created)
    then
        actions.close_diff()
        return false
    end

    window.configure_split_diff_win(right_win)
    M.set_split_line_numbers(right_win, self.diff_split_show_numbers)
    vim.wo[right_win].wrap = self.diff_wrap
    vim.wo[right_win].winbar = title
        .. ' [2/2] '
        .. preview_util.winbar_text(split_diff.right.title)
    self.diff_right_win = right_win

    preview_util.diffoff(self.diff_left_win)
    preview_util.diffoff(self.diff_right_win)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_right_win, function()
        vim.cmd('diffthis')
    end)
    vim.api.nvim_win_call(self.diff_left_win, function()
        vim.cmd('diffupdate')
        vim.cmd('syncbind')
    end)
    diffs_nvim.apply_diff_winhighlight(self.diff_left_win, 'old')
    diffs_nvim.apply_diff_winhighlight(self.diff_right_win, 'new')

    self.diff_preview_key = preview_key

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    return true
end

return M
