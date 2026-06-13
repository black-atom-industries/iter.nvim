require('iter.ui.status.preview.types')

local diff_parser = require('iter.ui.diff.parser')
local diff_position = require('iter.ui.diff.position')
local diffs_nvim = require('iter.ui.diff.diffs_nvim')
local git = require('iter.git')
local log = require('iter.log')
local common = require('iter.ui.status.common')
local selection = require('iter.ui.status.selection')
local preview_cursor = require('iter.ui.status.preview.cursor')
local preview_hunks = require('iter.ui.status.preview.hunks')
local preview_buffers = require('iter.ui.status.preview.buffers')
local display = require('iter.ui.status.preview.display')
local window = require('iter.ui.status.window')
local window_state = require('iter.ui.status.preview.window_state')
local preview_util = require('iter.ui.status.preview.util')
local keymaps = require('iter.ui.status.keymaps')

local M = {}

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusEntryItem?
local function entry_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.entry_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param row integer?
---@return GitStatusCommitItem?
local function commit_item_at_row(self, row)
    if row == nil then
        return nil
    end

    local line = self.lines[row]

    if line == nil then
        return nil
    end

    return selection.commit_item_from_data(line.data)
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusEntryItem?
local function refresh_entry_item(self, state)
    local item = selection.current_entry_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.item_key ~= nil then
        item = entry_item_at_row(
            self,
            selection.row_for_item_key(self, state.item_key)
        )

        if item ~= nil then
            return item
        end
    end

    if state.entry_key ~= nil then
        return entry_item_at_row(
            self,
            selection.row_for_entry_key(self, state.entry_key)
        )
    end

    return nil
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return GitStatusCommitItem?
local function refresh_commit_item(self, state)
    local item = selection.current_commit_item(self)

    if item ~= nil then
        return item
    end

    if state == nil then
        return nil
    end

    if state.commit_key ~= nil then
        return commit_item_at_row(
            self,
            selection.row_for_commit_key(self, state.commit_key)
        )
    end

    return nil
end

---@class IterDiffSourcePosition
---@field path string
---@field line integer

---@class IterDiffWindowState
---@field win_field string
---@field prev_buf_field string
---@field prev_winopts_field string
---@field created_win_field string
---@field buf_field string

---@param commit GitCommit
---@return string
local function commit_diff_title(commit)
    return preview_util.winbar_text(
        'commit: ' .. commit.hash .. ' ' .. commit.message
    )
end

---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@return string
local function diff_title(entry, section)
    local prefix = section or 'diff'
    local path = entry.orig_path ~= nil
            and (entry.orig_path .. ' -> ' .. entry.path)
        or entry.path

    return preview_util.winbar_text(prefix .. ': ' .. path)
end

---@param self GitStatusWindow
---@param lines string[]?
---@param raw_rows integer[]?
---@param diff_hunks IterDiffHunk[]?
---@param section GitStatusSectionName?
---@param entry GitStatusEntry?
local function set_diff_context(
    self,
    lines,
    raw_rows,
    diff_hunks,
    section,
    entry
)
    self.diff_raw_lines = lines
    self.diff_raw_rows = raw_rows
    self.diff_hunks = diff_hunks
    self.diff_section = section
    self.diff_context_entry = entry
end

---@param self GitStatusWindow
---@return IterPreviewActions
local function preview_actions(self)
    return {
        close_diff = function()
            M.close_diff(self)
        end,
        jump_hunk = function(delta)
            M.jump_hunk(self, delta)
        end,
        toggle_wrap = function()
            M.toggle_wrap(self)
        end,
        stage_current_hunk = function()
            M.stage_current_hunk(self)
        end,
        unstage_current_hunk = function()
            M.unstage_current_hunk(self)
        end,
        discard_current_hunk = function()
            M.discard_current_hunk(self)
        end,
        open_split_diff = function()
            M.open_split_diff(self)
        end,
        goto_code = function()
            M.goto_code(self)
        end,
        toggle_help = function()
            self:toggle_help()
        end,
        has_open_diff = function()
            return M.has_open_diff(self)
        end,
        focus_open_diff = function()
            display.focus_open_diff(self)
        end,
        refresh = function(cursor_state)
            self:refresh(cursor_state)
        end,
    }
end

---@param self GitStatusWindow
---@param delta integer
---@return boolean
function M.jump_hunk(self, delta)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    if not common.is_valid_win(self.diff_win) then
        return false
    end

    local win = assert(self.diff_win)
    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    local lines = vim.api.nvim_buf_get_lines(self.diff_buf.id, 0, -1, false)
    local start = delta > 0 and cursor_row + 1 or cursor_row - 1
    local stop = delta > 0 and #lines or 1

    for row = start, stop, delta do
        if vim.startswith(lines[row] or '', '@@') then
            vim.api.nvim_win_set_cursor(win, { row, 0 })
            return true
        end
    end

    common.notify_warn('No more hunks')
    return false
end

---@param self GitStatusWindow
---@return boolean
function M.toggle_wrap(self)
    if not M.has_open_diff(self) then
        common.notify_warn('Diff preview is not open')
        return false
    end

    self.diff_wrap = not self.diff_wrap

    if common.is_valid_win(self.diff_win) then
        vim.wo[self.diff_win].wrap = self.diff_wrap
    end

    return true
end

--- Open a side-by-side view of the current entry by delegating to
--- diffs.nvim's `:Diff ++layout=split` (plugin-aligned paired windows).
--- The view is owned by diffs.nvim; iter does not track its windows.
---@param self GitStatusWindow
---@return boolean
function M.open_split_diff(self)
    local item = selection.current_entry_item(self)

    if item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if not diffs_nvim.is_available() then
        common.notify_error(diffs_nvim.error_msg, 'Cannot open split diff')
        return false
    end

    -- :Diff's public object forms always compare against the worktree, so
    -- the staged edge (HEAD vs index) cannot be expressed.
    if item.section == 'staged' then
        common.notify_warn(
            'diffs.nvim cannot show the staged edge side-by-side; '
                .. 'use the stacked preview'
        )
        return false
    end

    local entry = item.entry

    if not window.entry_is_openable(entry) then
        common.notify_warn('Split diff needs a worktree file')
        return false
    end

    if M.has_open_diff(self) then
        M.close_diff(self)
    end

    if not window.open_entry(entry, self.win) then
        return false
    end

    local ok, err = pcall(vim.cmd, 'Diff ++layout=split')

    if not ok then
        common.notify_error(tostring(err), 'Cannot open split diff')
        return false
    end

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.has_open_diff(self)
    return window_state.has_open_stacked_diff(self)
end

---@param self GitStatusWindow
---@param commit GitCommit
---@param opts? { force: boolean? }
---@return boolean
function M.open_commit_diff(self, commit, opts)
    opts = opts or {}

    local preview_key = 'commit:' .. commit.hash

    -- A commit's diff is immutable for its hash, so an already-open preview
    -- never needs a re-render — even on forced refreshes (fs events would
    -- otherwise flicker the buffer with identical content).
    if M.has_open_diff(self) and self.diff_preview_key == preview_key then
        return true
    end

    if not diffs_nvim.is_available() then
        common.notify_error(diffs_nvim.error_msg, 'Cannot show commit diff')
        return false
    end

    local lines, err = git.show_commit(commit)

    if err ~= nil then
        common.notify_error(err, 'Cannot show commit diff')
        return false
    end

    if #lines == 0 then
        lines = { 'No diff for commit ' .. commit.hash }
    end

    set_diff_context(self, nil, nil, nil, nil, nil)

    local ok = display.show_stacked(
        self,
        lines,
        preview_key,
        commit_diff_title(commit),
        preview_actions(self)
    )

    if ok and self.diff_buf ~= nil then
        preview_buffers.clear_goto_code_keymap(self.diff_buf.id)
    end

    return ok
end

---@param self GitStatusWindow
function M.close_diff(self)
    log.debug('close_diff called')

    if window_state.has_open_stacked_diff(self) then
        window_state.restore_or_close_diff_window(
            self,
            window_state.STACKED_DIFF_STATE,
            false
        )
    end

    -- Always clean up diff state, even when the diff window was closed
    -- externally (e.g. via :close) and the restore helpers returned false.
    window_state.clear_missing_diff_window_states(self)
    self.diff_preview_key = nil
    set_diff_context(self, nil, nil, nil, nil, nil)

    if self.win ~= nil and common.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)

        -- Re-attach status keymaps after diff close. Window/buffer transitions
        -- during diff operations can cause buffer-local keymaps to be lost;
        -- BufEnter may not fire if we never left the status buffer.
        keymaps.attach_status(self.buf.id, self.config.keymaps_status, self)
    end
end

---@param self GitStatusWindow
---@return Buffer
function M.ensure_diff_buf(self)
    return preview_buffers.ensure_stacked(self, preview_actions(self))
end

---@param self GitStatusWindow
---@param entry GitStatusEntry
---@param section GitStatusSectionName?
---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function M.open_diff(self, entry, section, opts)
    opts = opts or {}

    local preview_key =
        table.concat({ section or '', entry.orig_path or '', entry.path }, '\0')
    local has_open_preview = window_state.has_open_stacked_diff(self)

    log.debug(
        'open_diff: '
            .. entry.path
            .. ' same_key='
            .. tostring(self.diff_preview_key == preview_key)
    )

    if has_open_preview and self.diff_preview_key == preview_key then
        if opts.focus then
            log.debug('open_diff: focusing existing diff')
            return display.focus_open_diff(self)
        end

        if not opts.force then
            log.debug('open_diff: returning true (same preview, not forced)')
            return true
        end
    end

    if not diffs_nvim.is_available() then
        common.notify_error(diffs_nvim.error_msg, 'Cannot show diff')
        return false
    end

    local lines, err = git.diff(entry, section)

    if err ~= nil then
        common.notify_error(err, 'Cannot show diff')
        return false
    end

    -- Forced refreshes (fs events, ColorScheme) often re-produce the exact
    -- same diff. Rewriting the buffer anyway would flicker and make
    -- diffs.nvim re-highlight from scratch, so skip when nothing changed.
    if
        has_open_preview
        and self.diff_preview_key == preview_key
        and self.diff_raw_lines ~= nil
        and vim.deep_equal(lines, self.diff_raw_lines)
    then
        log.debug('open_diff: content unchanged, skipping re-render')
        return true
    end

    local parsed_hunks = diff_parser.parse_hunks(lines)

    -- The stacked buffer holds the raw unified diff verbatim (diffs.nvim
    -- parses it for highlighting), so buffer rows map 1:1 to raw diff rows.
    local raw_rows = {}

    for row = 1, #lines do
        raw_rows[row] = row
    end

    local display_lines = #lines > 0 and lines
        or { 'No diff for ' .. entry.path }

    diff_parser.assign_stacked_rows(parsed_hunks, raw_rows)

    local ok = display.show_stacked(
        self,
        display_lines,
        preview_key,
        diff_title(entry, section),
        preview_actions(self)
    )

    if ok then
        set_diff_context(self, lines, raw_rows, parsed_hunks, section, entry)

        if self.diff_buf ~= nil then
            preview_buffers.set_goto_code_keymap(
                self.diff_buf.id,
                preview_actions(self)
            )
        end
    end

    return ok
end

---@param path string
local function edit_without_jumplist(path)
    vim.cmd('keepalt keepjumps edit ' .. vim.fn.fnameescape(path))
end

---@param self GitStatusWindow
---@return boolean
function M.goto_code(self)
    log.debug('goto_code')
    local position = preview_cursor.current_source_position(self)

    if position == nil then
        common.notify_warn('No source line under cursor')
        return false
    end

    -- For staged diffs the computed line number refers to the index version.
    -- If the file also has unstaged changes, translate through the unstaged
    -- diff so the cursor lands on the correct worktree line.
    if self.diff_section == 'staged' and self.diff_context_entry ~= nil then
        local unstaged_lines = git.diff(self.diff_context_entry, 'unstaged')

        if #unstaged_lines > 0 then
            local parsed_unstaged_hunks =
                diff_parser.parse_hunks(unstaged_lines)
            position = {
                path = position.path,
                line = diff_position.old_line_to_new_line(
                    unstaged_lines,
                    parsed_unstaged_hunks,
                    position.line
                ),
            }
        end
    end

    local root = git.root()
    local path = root ~= '' and vim.fs.joinpath(root, position.path)
        or position.path

    if vim.fn.filereadable(path) == 0 then
        common.notify_warn('Cannot open ' .. position.path)
        return false
    end

    local win = vim.api.nvim_get_current_win()
    local state = window_state.diff_window_state_for_win(self, win)

    if state == nil then
        common.notify_warn('Diff preview is not open')
        return false
    end

    local diff_buffers, code_win =
        window_state.close_diff_windows_for_code(self, state)

    vim.api.nvim_set_current_win(code_win)
    edit_without_jumplist(path)
    preview_cursor.set_cursor_row(code_win, position.line)

    window_state.delete_diff_buffers(diff_buffers)

    return true
end

---@param self GitStatusWindow
---@return boolean
function M.stage_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'stage',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.unstage_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'unstage',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@return boolean
function M.discard_current_hunk(self)
    return preview_hunks.apply_current_hunk(
        self,
        'discard',
        preview_actions(self)
    )
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean?, focus: boolean? }
---@return boolean
function M.preview_current_entry(self, opts)
    opts = opts or {}

    local item = selection.current_entry_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No git status entry under cursor')
        end

        return false
    end

    return M.open_diff(self, item.entry, item.section, {
        force = opts.force,
        focus = opts.focus,
    })
end

---@param self GitStatusWindow
---@param state GitStatusCursorState?
---@return boolean?
function M.refresh_current_entry(self, state)
    if not M.has_open_diff(self) then
        return
    end

    local preview_key = self.diff_preview_key or ''

    if vim.startswith(preview_key, 'commit:') then
        local item = refresh_commit_item(self, state)

        if item == nil then
            return
        end

        return M.open_commit_diff(self, item.commit, {
            force = true,
        })
    end

    local item = refresh_entry_item(self, state)

    if item == nil then
        return
    end

    return M.open_diff(self, item.entry, item.section, {
        force = true,
    })
end

---@param self GitStatusWindow
---@param opts? { force: boolean?, notify: boolean? }
---@return boolean
function M.preview_current_commit(self, opts)
    opts = opts or {}

    local item = selection.current_commit_item(self)

    if item == nil then
        if opts.notify ~= false then
            common.notify_warn('No unpushed commit under cursor')
        end

        return false
    end

    return M.open_commit_diff(self, item.commit, {
        force = opts.force,
    })
end

return M
