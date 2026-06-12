local Buffer = require('iter.ui.buffer')
local Highlight = require('iter.ui.highlight')
local render = require('iter.ui.render')
local formatting = require('iter.ui.status.formatting')
local help = require('iter.ui.status.help')
local log = require('iter.log')
local actions = require('iter.ui.status.actions')
local common = require('iter.ui.status.common')
local keymaps = require('iter.ui.status.keymaps')
local preview = require('iter.ui.status.preview')
local selection = require('iter.ui.status.selection')
local window = require('iter.ui.status.window')
local git = require('iter.git')

---@class GitStatusWindow
---@field buf Buffer
---@field diff_buf Buffer?
---@field diff_win number?
---@field diff_left_buf Buffer?
---@field diff_right_buf Buffer?
---@field diff_left_win number?
---@field diff_right_win number?
---@field diff_prev_buf number?
---@field diff_left_prev_buf number?
---@field diff_right_prev_buf number?
---@field diff_created_win boolean
---@field diff_left_created_win boolean
---@field diff_right_created_win boolean
---@field diff_preview_key string?
---@field diff_raw_lines string[]?
---@field diff_raw_rows integer[]?
---@field diff_hunks IterDiffHunk[]?
---@field diff_section GitStatusSectionName?
---@field diff_context_entry GitStatusEntry?
---@field diff_prev_winopts GitStatusWindowOptions?
---@field diff_left_prev_winopts GitStatusWindowOptions?
---@field diff_right_prev_winopts GitStatusWindowOptions?
---@field diff_wrap boolean
---@field diff_split_show_numbers boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_layout_override 'stacked'|'split'?
---@field help_buf Buffer?
---@field help_win number?
---@field help_prev_win number?
---@field win number?
---@field win_prev_winopts GitStatusWindowOptions?
---@field _retain_win boolean?
---@field config IterConfig
---@field groups table<string, string>
---@field highlights table<string, { ensure: fun() }>
---@field lines IterRenderLine[]
---@field snapshot GitStatusSnapshot?
---@field filter string
---@field loading_message string?
---@field loading_frame integer
---@field loading_timer table?
---@field autocmd_group integer?
---@field _fs_watchers table[]?
---@field _refresh_timer table?
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

---@param config IterConfig
---@return table<string, string>
local function create_highlight_groups(config)
    local groups = {}

    for key, spec in pairs(config.highlight_specs) do
        groups[key] = spec.name
    end

    return groups
end

---@param config IterConfig
---@return table<string, { ensure: fun() }>
local function create_highlights(config)
    local highlights = {}

    for key, spec in pairs(config.highlight_specs) do
        highlights[key] = Highlight.new({
            namespace = config.highlight_namespace,
            name = spec.name,
            sources = spec.sources,
            fallback_fg = spec.fallback_fg,
            fallback_bg = spec.fallback_bg,
        })
    end

    return highlights
end

---@param self GitStatusWindow
local function ensure_highlights(self)
    assert(self.highlights ~= nil)

    for _, h in pairs(self.highlights) do
        h:ensure()
    end
end

---@param self GitStatusWindow
local function release_status_win(self)
    if self.win == nil then
        return
    end

    -- If the iter buffer is still visible in any window on the current
    -- tabpage, don't release — keep tracking so show() and diff operations
    -- can find the window. This prevents the scheduled BufLeave/BufHidden
    -- callback from nil'ing self.win during window transitions that
    -- temporarily shift focus away.
    if self.buf ~= nil and self.buf:is_valid() then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if
                vim.api.nvim_win_is_valid(win)
                and vim.api.nvim_win_get_buf(win) == self.buf.id
            then
                if self.win ~= win then
                    self.win = win
                end
                return
            end
        end
    end

    local win = self.win

    if win ~= nil and common.is_valid_win(win) and not self._retain_win then
        window.restore_winopts(win, self.win_prev_winopts)
    end

    self._retain_win = nil
    self.win = nil
    self.win_prev_winopts = nil
end

---@param self GitStatusWindow
local function refresh_highlights(self)
    ensure_highlights(self)

    if self.buf ~= nil and self.buf:is_valid() then
        render.apply(self.buf.id, self.lines)
    end

    if
        self.diff_buf ~= nil
        and self.diff_buf:is_valid()
        and preview.has_open_diff(self)
    then
        preview.refresh_current_entry(self)
    end
end

local REFRESH_DEBOUNCE_MS = 300

---@param self GitStatusWindow
local function start_fs_watchers(self)
    local root = git.root()
    if root == '' then
        return
    end

    local git_dir = root .. '/.git'

    local timer = vim.uv.new_timer()
    self._refresh_timer = timer

    local refresh = vim.schedule_wrap(function()
        if self.buf and self.buf:is_valid() then
            self:refresh()
        end
    end)

    local function debounced_refresh()
        timer:stop()
        timer:start(REFRESH_DEBOUNCE_MS, 0, refresh)
    end

    local watchers = {}
    self._fs_watchers = watchers

    local function watch(path)
        local w = vim.uv.new_fs_event()
        local ok = pcall(function()
            w:start(path, {}, function(err)
                if not err then
                    debounced_refresh()
                end
            end)
        end)
        if ok then
            table.insert(watchers, w)
        else
            w:close()
        end
    end

    watch(git_dir .. '/index')
    watch(git_dir .. '/logs/HEAD')
end

---@param self GitStatusWindow
local function stop_fs_watchers(self)
    if self._fs_watchers then
        for _, w in ipairs(self._fs_watchers) do
            if not w:is_closing() then
                w:stop()
                w:close()
            end
        end
        self._fs_watchers = nil
    end

    if self._refresh_timer then
        self._refresh_timer:stop()
        self._refresh_timer:close()
        self._refresh_timer = nil
    end
end

---@param self GitStatusWindow
local function ensure_autocmds(self)
    if self.autocmd_group ~= nil then
        pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
    end

    self.autocmd_group = vim.api.nvim_create_augroup(
        string.format('iter_status_%d', self.buf.id),
        { clear = true }
    )

    vim.api.nvim_create_autocmd('BufEnter', {
        group = self.autocmd_group,
        buffer = self.buf.id,
        callback = function()
            local win = vim.api.nvim_get_current_win()

            if self.win ~= win then
                self.win = win
                self.win_prev_winopts = window.capture_winopts(win)
            end

            window.configure_status_win(win)

            -- Refresh buffer-local keymaps on every entry to stay reliable
            -- through window navigation and bufhidden hide/show cycles.
            keymaps.attach_status(self.buf.id, self.config.keymaps_status, self)
        end,
    })

    -- Re-attach keymaps when entering any window that shows the iter buffer.
    -- BufEnter alone is not sufficient: switching back to an already-visible
    -- iter window from a diff preview or file view may not re-trigger
    -- BufEnter if the buffer was never left (e.g. splits, focus changes).
    -- WinEnter covers those gaps and keeps =, o, etc. reliable.
    vim.api.nvim_create_autocmd('WinEnter', {
        group = self.autocmd_group,
        callback = function()
            if self.buf == nil or not self.buf:is_valid() then
                return
            end

            local win = vim.api.nvim_get_current_win()
            local buf_id = vim.api.nvim_win_get_buf(win)

            if buf_id ~= self.buf.id then
                return
            end

            -- Update window tracking when re-entering the status window
            -- from outside a BufEnter path (e.g. returning from a diff).
            -- Only update prev_winopts when they are nil (first entry), to
            -- avoid overwriting the original user options with iter-options.
            if self.win ~= win then
                self.win = win
                if self.win_prev_winopts == nil then
                    self.win_prev_winopts = window.capture_winopts(win)
                end
            end

            window.configure_status_win(win)
            keymaps.attach_status(self.buf.id, self.config.keymaps_status, self)
        end,
    })

    vim.api.nvim_create_autocmd({ 'BufLeave', 'BufHidden' }, {
        group = self.autocmd_group,
        buffer = self.buf.id,
        callback = function()
            vim.schedule(function()
                if self.buf ~= nil and self.buf:is_valid() then
                    release_status_win(self)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd('ColorScheme', {
        group = self.autocmd_group,
        callback = function()
            refresh_highlights(self)
        end,
    })

    vim.api.nvim_create_autocmd('OptionSet', {
        group = self.autocmd_group,
        pattern = 'background',
        callback = function()
            refresh_highlights(self)
        end,
    })

    -- Re-attach the CursorMoved autocmd now that the group exists so it is
    -- properly owned and cleaned up on destroy.
    keymaps.attach_cursor_autocmd(self)
end

function GitStatusWindow:show()
    log.debug('show called')

    if not self.buf or not self.buf:is_valid() then
        log.error('Cannot show invalid GitStatus buffer')
        return
    end

    -- Re-register buffer-local keymaps on every show to ensure they survive
    -- bufhidden='hide' / show cycles without relying on autocmd persistence.
    keymaps.attach_status(self.buf.id, self.config.keymaps_status, self)

    if
        self.win
        and common.is_valid_win(self.win)
        and vim.api.nvim_win_get_buf(self.win) ~= self.buf.id
    then
        release_status_win(self)
    end

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        -- Re-set the iter buffer in case an external operation swapped it out.
        if vim.api.nvim_win_get_buf(self.win) ~= self.buf.id then
            pcall(vim.api.nvim_win_set_buf, self.win, self.buf.id)
        end
        vim.api.nvim_set_current_win(self.win)
        window.configure_status_win(self.win)
        return
    end

    self.win, self.win_prev_winopts =
        window.create_status_win(self.buf, self.config.options.status)

    selection.move_to_first_entry(self)
end

---@param state? GitStatusCursorState
---@return boolean
function GitStatusWindow:refresh(state)
    state = state or selection.capture_cursor_state(self)

    self:render()
    selection.restore_cursor_state(self, state)
    preview.refresh_current_entry(self, state)

    return true
end

---@return boolean
function GitStatusWindow:diff_entry()
    log.debug('diff_entry called')

    if preview.has_open_diff(self) then
        local commit_item = selection.current_commit_item(self)

        if commit_item ~= nil then
            local key = 'commit:' .. commit_item.commit.hash

            if self.diff_preview_key == key then
                preview.close_diff(self)

                return true
            end
        else
            local item = selection.current_entry_item(self)

            if item ~= nil then
                local key = table.concat({
                    item.section or '',
                    item.entry.orig_path or '',
                    item.entry.path,
                }, '\0')

                if self.diff_preview_key == key then
                    preview.close_diff(self)

                    return true
                end
            end
        end
    end

    local commit_item = selection.current_commit_item(self)
    local entry_item = selection.current_entry_item(self)

    if commit_item == nil and entry_item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    -- Verify the status window is still valid.
    if self.win == nil or not common.is_valid_win(self.win) then
        common.notify_error(nil, 'Status window was lost')
        return false
    end

    if commit_item ~= nil then
        return preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })
    end

    return preview.preview_current_entry(self, {
        force = true,
        notify = true,
        focus = true,
    })
end

---@return boolean
function GitStatusWindow:stage_entry()
    return actions.stage_entry(self)
end

---@return boolean
function GitStatusWindow:unstage_entry()
    return actions.unstage_entry(self)
end

---@return boolean
function GitStatusWindow:stage_all_entries()
    return actions.stage_all_entries(self)
end

---@return boolean
function GitStatusWindow:unstage_all_entries()
    return actions.unstage_all_entries(self)
end

---@return boolean
function GitStatusWindow:stage_selected_entries()
    return actions.stage_selected_entries(self)
end

---@return boolean
function GitStatusWindow:unstage_selected_entries()
    return actions.unstage_selected_entries(self)
end

---@param force boolean
---@return boolean
function GitStatusWindow:discard_entry(force)
    return actions.discard_entry(self, force)
end

---@return boolean
function GitStatusWindow:commit()
    return actions.commit(self)
end

---@return boolean
function GitStatusWindow:push()
    return actions.push(self)
end

---@return boolean
function GitStatusWindow:push_force()
    return actions.push_force(self)
end

---@return boolean
function GitStatusWindow:enter_entry()
    local entry = selection.current_entry(self)
    log.debug('enter_entry: ' .. (entry ~= nil and entry.path or 'nil'))

    local commit_item = selection.current_commit_item(self)

    if commit_item ~= nil then
        return preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })
    end

    if entry == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    -- Deleted files have no worktree path to open — show their diff instead.
    if not window.entry_is_openable(entry) then
        return preview.preview_current_entry(self, { notify = true })
    end

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    return window.open_entry(entry, self.win)
end

function GitStatusWindow:enter_entry_and_close()
    local commit_item = selection.current_commit_item(self)

    if commit_item ~= nil then
        -- Commits open a diff, not a file — use standard behavior.
        local ok = preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })

        if ok then
            self:close()
        end

        return ok
    end

    local entry = selection.current_entry(self)

    if entry == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    -- Deleted files have no worktree path to open — show their diff and
    -- keep the drawer, since the preview is anchored to it.
    if not window.entry_is_openable(entry) then
        return preview.preview_current_entry(self, { notify = true })
    end

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    local ok = window.open_entry(entry, self.win)

    if ok then
        self:close()
    end

    return ok
end

function GitStatusWindow:toggle_help()
    help.toggle(self)
end

---@return boolean closed
function GitStatusWindow:close()
    self:stop_loading()
    help.close(self)

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    if self.win ~= nil and common.is_valid_win(self.win) then
        window.restore_winopts(self.win, self.win_prev_winopts)

        local tabpage = vim.api.nvim_win_get_tabpage(self.win)

        if #vim.api.nvim_tabpage_list_wins(tabpage) <= 1 then
            common.notify_warn('Cannot close the last window')
            return false
        end

        local ok = pcall(vim.api.nvim_win_close, self.win, true)

        if not ok then
            common.notify_warn('Cannot close status window')
            return false
        end
    end

    self.win = nil
    self.win_prev_winopts = nil

    -- Clear layout override so a fresh open doesn't carry stale preferences.
    self.diff_layout_override = nil

    return true
end

---@param buf Buffer?
local function delete_owned_buffer(buf)
    if buf == nil or buf.id == nil or not vim.api.nvim_buf_is_valid(buf.id) then
        return
    end

    pcall(vim.api.nvim_buf_delete, buf.id, { force = true })
end

function GitStatusWindow:delete_owned_buffers()
    for _, field in ipairs(self.config.owned_buffer_fields) do
        delete_owned_buffer(self[field])
        self[field] = nil
    end
end

---@return boolean destroyed
function GitStatusWindow:destroy()
    stop_fs_watchers(self)

    if self.autocmd_group ~= nil then
        pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
        self.autocmd_group = nil
    end

    if not self:close() then
        return false
    end

    self.diff_layout_override = nil
    self:delete_owned_buffers()

    return true
end

function GitStatusWindow:filter_entries()
    vim.ui.input({
        prompt = 'Filter git status entries: ',
        default = self.filter,
    }, function(input)
        if input == nil then
            return
        end

        local state = selection.capture_cursor_state(self)
        state.follow_entry = false
        self.filter = vim.trim(input)
        self:refresh(state)
    end)
end

function GitStatusWindow:clear_filter()
    if self.filter == '' then
        return
    end

    local state = selection.capture_cursor_state(self)
    state.follow_entry = false
    self.filter = ''
    self:refresh(state)
end

function GitStatusWindow:render_cached()
    assert(self.buf ~= nil)
    assert(self.buf:is_valid())
    assert(self.groups ~= nil)

    self.snapshot = self.snapshot or git.status_snapshot()
    local loading_frame

    if self.loading_message ~= nil then
        loading_frame = self.config.spinner_frames[self.loading_frame]
    end

    self.lines = formatting.render(self.snapshot, self.groups, {
        filter = self.filter,
        loading_message = self.loading_message,
        loading_frame = loading_frame,
    })

    vim.bo[self.buf.id].modifiable = true
    self.buf:set_lines(render.text_lines(self.lines))
    render.apply(self.buf.id, self.lines)
end

function GitStatusWindow:render()
    self.snapshot = git.status_snapshot()
    self:render_cached()
end

---@param message string
function GitStatusWindow:start_loading(message)
    if self.loading_message ~= nil then
        return
    end

    self.loading_message = message
    self.loading_frame = 1
    self:render_cached()

    self.loading_timer = vim.uv.new_timer()

    if self.loading_timer == nil then
        return
    end

    self.loading_timer:start(
        120,
        120,
        vim.schedule_wrap(function()
            if self.loading_message == nil then
                return
            end

            self.loading_frame = (
                self.loading_frame % #self.config.spinner_frames
            ) + 1

            if self.buf ~= nil and self.buf:is_valid() then
                self:render_cached()
            end
        end)
    )
end

function GitStatusWindow:stop_loading()
    self.loading_message = nil

    if self.loading_timer ~= nil then
        self.loading_timer:stop()

        if not self.loading_timer:is_closing() then
            self.loading_timer:close()
        end

        self.loading_timer = nil
    end
end

---@param direction 'down'|'up'
---@return boolean
function GitStatusWindow:scroll_diff(direction)
    local current_win = vim.api.nvim_get_current_win()
    log.debug('scroll_diff: ' .. direction)

    -- Set scrolling flag to prevent debounced preview from running
    keymaps.set_scrolling(true)

    local preview_mod = require('iter.ui.status.preview')

    if not preview_mod.has_open_diff(self) then
        keymaps.set_scrolling(false)
        return false
    end

    -- Determine which window(s) to scroll
    local wins = {}

    if self.diff_win ~= nil and vim.api.nvim_win_is_valid(self.diff_win) then
        table.insert(wins, self.diff_win)
    end

    if
        self.diff_left_win ~= nil
        and vim.api.nvim_win_is_valid(self.diff_left_win)
    then
        table.insert(wins, self.diff_left_win)
    end

    if
        self.diff_right_win ~= nil
        and vim.api.nvim_win_is_valid(self.diff_right_win)
    then
        table.insert(wins, self.diff_right_win)
    end

    if #wins == 0 then
        keymaps.set_scrolling(false)
        return false
    end

    -- Scroll each diff window
    for _, win in ipairs(wins) do
        local win_height = vim.api.nvim_win_get_height(win)
        local scroll_amount = math.floor(win_height / 2)

        -- Build the normal! command with proper control characters
        -- Ctrl-D is byte 4, Ctrl-U is byte 21
        local ctrl_char = direction == 'down' and string.char(4)
            or string.char(21)
        local cmd = 'normal! ' .. scroll_amount .. ctrl_char

        vim.fn.win_execute(win, cmd)

        local after_win = vim.api.nvim_get_current_win()
        if after_win ~= current_win then
            vim.api.nvim_set_current_win(current_win)
        end
    end

    -- Clear scrolling flag after a short delay to allow j/k to register
    vim.defer_fn(function()
        keymaps.set_scrolling(false)
    end, 100)

    return true
end

---@param config IterConfig
---@return GitStatusWindow
function GitStatusWindow.new(config)
    local self = setmetatable({}, GitStatusWindow)

    self.config = config
    self.groups = create_highlight_groups(config)
    self.highlights = create_highlights(config)
    self.lines = {}
    self.diff_created_win = false
    self.diff_left_created_win = false
    self.diff_right_created_win = false
    self.diff_wrap = config.options.preview.wrap
    self.diff_split_show_numbers = true
    self.diff_layout = config.options.preview.diff_layout
    self.filter = ''
    self.loading_frame = 1

    ensure_highlights(self)

    ---@type BufferOpts
    local buf_opts = { listed = false, scratch = true, name = 'Iter' }
    self.buf = Buffer.new(buf_opts)
    vim.bo[self.buf.id].buftype = 'nofile'
    vim.bo[self.buf.id].bufhidden = 'hide'
    vim.bo[self.buf.id].swapfile = false
    vim.bo[self.buf.id].filetype = 'iter'

    keymaps.attach(self, config.keymaps_status)
    self:render()

    self.win, self.win_prev_winopts =
        window.create_status_win(self.buf, self.config.options.status)

    selection.move_to_first_entry(self)
    ensure_autocmds(self)
    start_fs_watchers(self)

    return self
end

return GitStatusWindow
