local Buffer = require('flux.ui.buffer')
local Highlight = require('flux.ui.highlight')
local render = require('flux.ui.render')
local formatting = require('flux.ui.status.formatting')
local help = require('flux.ui.status.help')
local log = require('flux.log')
local actions = require('flux.ui.status.actions')
local common = require('flux.ui.status.common')
local keymaps = require('flux.ui.status.keymaps')
local preview = require('flux.ui.status.preview')
local selection = require('flux.ui.status.selection')
local window = require('flux.ui.status.window')
local git = require('flux.git')

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
---@field diff_hunks FluxDiffHunk[]?
---@field diff_section GitStatusSectionName?
---@field diff_context_entry GitStatusEntry?
---@field diff_prev_winopts GitStatusWindowOptions?
---@field diff_left_prev_winopts GitStatusWindowOptions?
---@field diff_right_prev_winopts GitStatusWindowOptions?
---@field diff_wrap boolean
---@field diff_show_headers boolean
---@field diff_show_numbers boolean
---@field diff_layout 'stacked'|'split'|'auto'
---@field diff_layout_override 'stacked'|'split'?
---@field help_buf Buffer?
---@field help_win number?
---@field help_prev_win number?
---@field win number?
---@field win_prev_buf integer?
---@field win_prev_winopts GitStatusWindowOptions?
---@field target_win number?
---@field config FluxConfig
---@field groups table<string, string>
---@field highlights table<string, { ensure: fun() }>
---@field lines FluxRenderLine[]
---@field snapshot GitStatusSnapshot?
---@field filter string
---@field loading_message string?
---@field loading_frame integer
---@field loading_timer uv.uv_timer_t?
---@field autocmd_group integer?
local GitStatusWindow = {}
GitStatusWindow.__index = GitStatusWindow

---@return vim.api.keyset.highlight
local function diff_header_style()
    if vim.o.background == 'light' then
        return {
            fg = 0x8A8A8A,
            ctermfg = 245,
        }
    end

    return {
        fg = 0x6C7086,
        ctermfg = 243,
    }
end

---@return vim.api.keyset.highlight
local function diff_hunk_header_style()
    if vim.o.background == 'light' then
        return {
            fg = 0x5F6B7A,
            ctermfg = 60,
        }
    end

    return {
        fg = 0x7A88A1,
        ctermfg = 67,
    }
end

---@param name string
---@param style fun(): vim.api.keyset.highlight
---@return { ensure: fun() }
local function create_fixed_highlight(name, style)
    return {
        ensure = function()
            vim.api.nvim_set_hl(0, name, style())
        end,
    }
end

---@param config FluxConfig
---@return table<string, string>
local function create_highlight_groups(config)
    local groups = {}

    for key, spec in pairs(config.highlight_specs) do
        groups[key] = spec.name
    end

    groups.diff_header = config.diff_header_hl_name
    groups.diff_hunk_header = config.diff_hunk_header_hl_name

    return groups
end

---@param config FluxConfig
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

    highlights.diff_header =
        create_fixed_highlight(config.diff_header_hl_name, diff_header_style)
    highlights.diff_hunk_header = create_fixed_highlight(
        config.diff_hunk_header_hl_name,
        diff_hunk_header_style
    )

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

    -- If the flux buffer is still visible in any window on the current
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

    if common.is_valid_win(win) then
        window.restore_winopts(win, self.win_prev_winopts)
    end

    self.win = nil
    self.win_prev_buf = nil
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

---@param self GitStatusWindow
local function ensure_autocmds(self)
    if self.autocmd_group ~= nil then
        pcall(vim.api.nvim_del_augroup_by_id, self.autocmd_group)
    end

    self.autocmd_group = vim.api.nvim_create_augroup(
        string.format('flux_status_%d', self.buf.id),
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

    -- Re-attach keymaps when entering any window that shows the flux buffer.
    -- BufEnter alone is not sufficient: switching back to an already-visible
    -- flux window from a diff preview or file view may not re-trigger
    -- BufEnter if the buffer was never left (e.g. splits, focus changes).
    -- WinEnter covers those gaps and keeps =, o, etc. reliable.
    vim.api.nvim_create_autocmd('WinEnter', {
        group = self.autocmd_group,
        callback = function()
            if self.buf == nil or not self.buf:is_valid() then
                return
            end

            local win = vim.api.nvim_get_current_win()

            if vim.api.nvim_win_get_buf(win) ~= self.buf.id then
                return
            end

            -- Update window tracking when re-entering the status window
            -- from outside a BufEnter path (e.g. returning from a diff).
            -- Only update prev_winopts when they are nil (first entry), to
            -- avoid overwriting the original user options with flux-options.
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

    window.set_target_win(self, vim.api.nvim_get_current_win())

    if self.win and vim.api.nvim_win_is_valid(self.win) then
        -- Re-set the flux buffer in case an external operation swapped it out.
        if vim.api.nvim_win_get_buf(self.win) ~= self.buf.id then
            pcall(vim.api.nvim_win_set_buf, self.win, self.buf.id)
        end
        vim.api.nvim_set_current_win(self.win)
        window.configure_status_win(self.win)
        return
    end

    if self.config.options.status.layout == 'replace' then
        self.win, self.win_prev_buf, self.win_prev_winopts =
            window.replace_current_buffer(self.buf, self.config.options.status)
    else
        self.win, self.win_prev_winopts =
            window.create_status_win(self.buf, self.config.options.status)
    end

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

    -- Wipe non-plugin windows to keep the layout clean and avoid stale
    -- state from window transitions during diff operations.
    -- Only close windows when we have a valid entry to show.
    local commit_item = selection.current_commit_item(self)
    local entry_item = selection.current_entry_item(self)

    if commit_item == nil and entry_item == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    window.close_non_flux_windows(self)

    -- Verify the status window survived the cleanup.
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
function GitStatusWindow:enter_entry()
    local commit_item = selection.current_commit_item(self)

    if commit_item ~= nil then
        -- Commits open a diff — clean the layout first.
        window.close_non_flux_windows(self)

        return preview.preview_current_commit(self, {
            force = true,
            notify = true,
        })
    end

    local entry = selection.current_entry(self)

    if entry == nil then
        common.notify_warn('No git status entry under cursor')
        return false
    end

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    return window.open_entry(self, entry)
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

    if preview.has_open_diff(self) then
        preview.close_diff(self)
    end

    if self.config.options.status.layout == 'replace' then
        -- Open the file in the status window itself, then close.
        -- close() will detect the buffer changed and skip restoration.
        local root = git.root()
        local path = root ~= '' and vim.fs.joinpath(root, entry.path)
            or entry.path

        if vim.uv.fs_stat(path) == nil then
            common.notify_error(nil, 'Cannot open missing path: ' .. entry.path)

            return false
        end

        if self.win ~= nil and common.is_valid_win(self.win) then
            local current_path =
                vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(self.win))
            local normalize_path = vim.fs.normalize(path)

            if current_path ~= normalize_path then
                local buf = vim.fn.bufadd(path)
                vim.fn.bufload(buf)
                vim.api.nvim_win_set_buf(self.win, buf)
            end
        end

        self:close()

        return true
    end

    -- topleft mode: open in target window, then close status
    local ok = window.open_entry(self, entry)

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
        if
            self.config.options.status.layout == 'replace'
            and self.win_prev_buf ~= nil
        then
            -- Restore original buffer — but only if the status buffer is
            -- still showing in this window. If the user already replaced it
            -- (via o), skip restoration.
            local current_buf = vim.api.nvim_win_get_buf(self.win)

            if current_buf == self.buf.id then
                pcall(vim.api.nvim_win_set_buf, self.win, self.win_prev_buf)
            end

            window.restore_winopts(self.win, self.win_prev_winopts)
            vim.api.nvim_set_current_win(self.win)
        else
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
    end

    self.win = nil
    self.win_prev_buf = nil
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

---@param config FluxConfig
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
    self.diff_show_headers = config.options.preview.show_metadata
    self.diff_show_numbers = config.options.preview.show_line_numbers
    self.diff_layout = config.options.preview.diff_layout
    self.filter = ''
    self.loading_frame = 1
    self.target_win = vim.api.nvim_get_current_win()

    ensure_highlights(self)

    ---@type BufferOpts
    local buf_opts = { listed = false, scratch = true, name = 'Flux' }
    self.buf = Buffer.new(buf_opts)
    vim.bo[self.buf.id].buftype = 'nofile'
    vim.bo[self.buf.id].bufhidden = 'hide'
    vim.bo[self.buf.id].swapfile = false
    vim.bo[self.buf.id].filetype = 'flux'

    keymaps.attach(self, config.keymaps_status)
    self:render()

    if self.config.options.status.layout == 'replace' then
        self.win, self.win_prev_buf, self.win_prev_winopts =
            window.replace_current_buffer(self.buf, self.config.options.status)
    else
        self.win, self.win_prev_winopts =
            window.create_status_win(self.buf, self.config.options.status)
    end

    selection.move_to_first_entry(self)
    ensure_autocmds(self)

    return self
end

return GitStatusWindow
