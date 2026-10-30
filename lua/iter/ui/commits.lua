local float = require('iter.ui.float')
local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local model = require('iter.diff.model')
local render = require('iter.ui.render')
local uri = require('iter.uri')
local util = require('iter.util')
local View = require('iter.diff.view')

local M = {}

-- Commits the drawer lists, newest first.
local COMMITS = 100
-- The commit list waits longer than the file list, so moving through it
-- reads only the commit it stops on.
local PREVIEW_DELAY_MS = { commits = 150, files = 50 }
-- Per level, the actions the key hint line shows, in order, with their
-- short labels.
local HINTS = {
    commits = {
        { 'open', 'files' },
        { 'review', 'review' },
        { 'help', 'help' },
        { 'close', 'close' },
    },
    files = {
        { 'open', 'diff' },
        { 'review', 'review' },
        { 'split', 'split' },
        { 'help', 'help' },
        { 'close', 'back' },
    },
}
-- Window options of the pane while it shows the summary; the pane's own
-- come back when the drawer closes.
local SUMMARY_WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    list = false,
    spell = false,
    cursorline = false,
    wrap = true,
}

---@class IterCommitsOpenOptions
---@field pane integer window the drawer is anchored to and the preview shows in
---@field config IterConfig
---@field on_close? fun(commits: IterCommits)

---@class IterCommitsRange the commits a preview or review covers
---@field newest GitCommit
---@field oldest GitCommit
---@field count integer
---@field row integer drawer row of `newest`

---@class IterCommitsOpened the commits whose files the drawer lists
---@field range IterCommitsRange
---@field base string the oldest commit's parent, or the empty tree
---@field head string full sha of the newest commit
---@field files IterChange[]

---@alias IterCommitsLevel 'commits'|'files'

---@class IterCommits
---@field root string
---@field branch string 'HEAD' when detached
---@field pane integer
---@field config IterConfig
---@field keys table<string, string[]>
---@field commits GitCommit[] newest first
---@field level IterCommitsLevel the commit list, or the files of `opened`
---@field opened? IterCommitsOpened while the files level shows
---@field buf integer
---@field win integer
---@field float IterFloat
---@field view IterDiffView diff of the selected file, shown in the pane
---@field summary_buf integer the commits' summary, shown in the pane on the commits level
---@field prev_buf integer buffer the pane showed before the drawer
---@field saved_winopts? table<string, any> the pane's options from before the summary
---@field handlers table<string, fun()>
---@field help? IterHelp
---@field previewed? string what the pane shows: `base..head` of a summary, `base..head:path` of a file
---@field timer? uv.uv_timer_t runs the last scheduled preview
---@field group integer
---@field closed boolean
---@field on_close? fun(commits: IterCommits)
local Commits = {}
Commits.__index = Commits

--- The commits drawer of the current directory's repository, nil with a
--- warning when it has no commits.
---@param opts IterCommitsOpenOptions
---@return IterCommits?
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local root = git.root()

    if root == '' then
        util.warn('Not inside a git repository')
        return nil
    end

    local recent = git.recent(root, COMMITS)

    if recent == nil or #recent.commits == 0 then
        util.warn('No commits yet')
        return nil
    end

    if not util.can_leave(vim.api.nvim_win_get_buf(opts.pane)) then
        return nil
    end

    highlight.setup()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype = 'iter'
    util.name_buf(buf, uri.of('commits'))

    local summary_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[summary_buf].bufhidden = 'hide'
    vim.bo[summary_buf].modifiable = false
    vim.bo[summary_buf].filetype = 'iter'

    local config = opts.config
    local diff = config.options.diff
    local self = setmetatable({
        root = root,
        branch = git.head_branch(root) or 'HEAD',
        pane = opts.pane,
        config = config,
        keys = config.keys.commits,
        commits = recent.commits,
        level = 'commits',
        buf = buf,
        summary_buf = summary_buf,
        prev_buf = vim.api.nvim_win_get_buf(opts.pane),
        closed = false,
        on_close = opts.on_close,
    }, Commits)

    uri.own(buf, {
        owns = function(win)
            return win == self.win
        end,
        reload = function()
            self:render()
        end,
    })
    uri.own(summary_buf, {
        owns = function(win)
            return win == self.pane
        end,
        reload = function()
            self.previewed = nil
            self:preview()
        end,
        prev = function()
            return self.prev_buf
        end,
    })

    local auto = diff.layout == 'auto'
            and (vim.api.nvim_win_get_width(opts.pane) >= diff.split_breakpoint and 'split' or 'unified')
        or nil

    self.view = View.new({
        win = opts.pane,
        keys = config.keys.diff,
        expand_step = diff.expand_step,
        syntax_max_lines = diff.syntax_max_lines,
        word_diff = diff.word_diff,
        icon = config.options.icons.annotation,
        handlers = self:view_handlers(),
        layout = auto or diff.layout --[[@as IterDocLayout]],
        wrap = diff.wrap,
        on_layout = function()
            if self.float ~= nil then
                self.float:reposition({ left = self:left() or false })
            end
        end,
    })
    self.handlers = self:make_handlers()
    self:render()
    self.float = float.open({
        pane = opts.pane,
        buf = buf,
        zindex = config.options.drawer.zindex,
        height = config.options.drawer.height,
        min_lines = 5,
        left = self:left(),
        enter = true,
        chrome = true,
        title = self:header(),
        footer = self:footer(),
    })
    self.win = self.float.win

    for name, value in pairs({ wrap = false, cursorline = true }) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = self.win }
        )
    end

    vim.wo[self.win].winhighlight = vim.wo[self.win].winhighlight
        .. ',CursorLine:IterDrawerSelected'

    keymap.attach(buf, 'commits', self.keys, self.handlers)
    self:attach()
    self:preview()

    return self
end

--- The rows of the level: a commit per row, or a file of the opened
--- commits per row, one column in as the drawer's rows start.
function Commits:render()
    if not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end

    local lines

    if self.level == 'files' then
        local width = util.is_valid_win(self.win)
                and vim.api.nvim_win_get_width(self.win)
            or vim.api.nvim_win_get_width(self.pane)

        lines = vim.tbl_map(function(item)
            local line = render.line('')

            line.text = layout.file_cell(line, item, 0, width)

            return line
        end, self.opened.files)
    else
        local width = layout.author_width(self.commits)

        lines = vim.tbl_map(function(commit)
            return render.chunks_line({
                { ' ' },
                unpack(layout.commit_chunks(commit, width)),
            })
        end, self.commits)
    end

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, render.text_lines(lines))
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, lines)
end

--- The selected commits on the commits level: the visual selection's rows
--- while one is active in the drawer, else the cursor's row.
---@return IterCommitsRange
function Commits:range()
    local current = vim.api.nvim_get_current_win() == self.win
    local cursor = vim.api.nvim_win_get_cursor(self.win)[1]
    local first, last = cursor, cursor

    if current and vim.fn.mode():match('^[vV\22]') then
        local other = vim.fn.line('v')

        first, last = math.min(cursor, other), math.max(cursor, other)
    end

    return {
        newest = self.commits[first],
        oldest = self.commits[last],
        count = last - first + 1,
        row = first,
    }
end

--- `a1b2c3d` for one commit, `a1b2c3d..e4f5a6b` from the oldest to the
--- newest of several.
---@param range IterCommitsRange
---@return string
local function range_label(range)
    if range.count == 1 then
        return range.newest.sha
    end

    return range.oldest.sha .. '..' .. range.newest.sha
end

--- The header. The commits level names the branch, the number of commits
--- and, while several are selected, the selection; the files level names
--- the opened commit by its sha and subject, or the opened commits by
--- their count and range, then the number of files.
---@param range? IterCommitsRange
---@return [string, string][]
function Commits:header(range)
    if self.level == 'files' then
        local opened = self.opened.range
        local files = #self.opened.files
        local chunks = opened.count == 1
                and {
                    { opened.newest.sha, 'IterCommitSha' },
                    { ' ' .. opened.newest.subject },
                }
            or {
                { opened.count .. ' commits ', 'IterDrawerHint' },
                { range_label(opened), 'IterCommitSha' },
            }

        table.insert(chunks, {
            string.format(' · %d %s', files, files == 1 and 'file' or 'files'),
            'IterDrawerHint',
        })

        return chunks
    end

    local chunks = {
        { 'HEAD ', 'IterDrawerHint' },
        { self.branch, 'IterHead' },
        { ' · ' .. #self.commits .. ' commits', 'IterDrawerHint' },
    }

    if range ~= nil and range.count > 1 then
        table.insert(chunks, {
            string.format(
                ' · %d selected · %s',
                range.count,
                range_label(range)
            ),
            'IterDrawerHint',
        })
    end

    return chunks
end

--- The key hint line of the level.
---@return [string, string][]
function Commits:footer()
    local width = util.is_valid_win(self.win)
            and vim.api.nvim_win_get_width(self.win)
        or vim.api.nvim_win_get_width(self.pane)

    return layout.hints(
        keymap.list('commits', self.keys, self.handlers),
        HINTS[self.level],
        width - 1
    )
end

--- The old side's window of a split diff, which the drawer covers too.
---@return integer?
function Commits:left()
    local old = self.view.old

    if old ~= nil and util.is_valid_win(old.win) then
        return old.win
    end
end

--- Preview after the level's delay, dropping a preview scheduled before.
function Commits:schedule_preview()
    if self.timer == nil then
        self.timer = assert(vim.uv.new_timer())
    end

    self.timer:stop()
    self.timer:start(
        PREVIEW_DELAY_MS[self.level],
        0,
        vim.schedule_wrap(function()
            if not self.closed then
                self:preview()
            end
        end)
    )
end

--- Show the selected commits' summary on the commits level, the selected
--- file's diff on the files level.
function Commits:preview()
    if self.level == 'files' then
        local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
        local item = self.opened.files[lnum]

        if item ~= nil then
            self:show_file(item)
        end

        return
    end

    local range = self:range()

    if self.float ~= nil then
        self.float:reposition({ title = self:header(range) })
    end

    self:show_summary(range)
end

--- Show the summary of `range` in the pane: each commit's whole message,
--- then the files with the lines added and deleted.
---@param range IterCommitsRange
function Commits:show_summary(range)
    local base, err = git.parent_of(self.root, range.oldest.full_sha)

    if base == nil then
        util.error(err, 'Cannot read the parent of ' .. range.oldest.sha)
        return
    end

    local key = base .. '..' .. range.newest.full_sha
    local shown = util.is_valid_win(self.pane)
        and vim.api.nvim_win_get_buf(self.pane) == self.summary_buf

    if key == self.previewed and shown then
        return
    end

    local messages
    messages, err =
        git.messages(self.root, range.oldest.full_sha, range.newest.full_sha)

    if messages == nil then
        util.error(err, 'Cannot read the messages of ' .. range_label(range))
        return
    end

    local stats
    stats, err = git.stats(self.root, base, range.newest.full_sha)

    if stats == nil then
        util.error(err, 'Cannot read the changes of ' .. range_label(range))
        return
    end

    local lines = layout.commit_summary(messages, stats)

    vim.bo[self.summary_buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        self.summary_buf,
        0,
        -1,
        false,
        render.text_lines(lines)
    )
    vim.bo[self.summary_buf].modifiable = false
    render.apply(self.summary_buf, lines)
    util.name_buf(self.summary_buf, uri.of('commits', range_label(range)))
    self.previewed = key
    self:show_summary_buf()
end

--- Put the summary's buffer in the pane, in place of the diff.
function Commits:show_summary_buf()
    self.view:hide()

    if not util.is_valid_win(self.pane) then
        return
    end

    if vim.api.nvim_win_get_buf(self.pane) ~= self.summary_buf then
        if self.saved_winopts == nil then
            self.saved_winopts = {}

            for name in pairs(SUMMARY_WINOPTS) do
                self.saved_winopts[name] = vim.api.nvim_get_option_value(
                    name,
                    { scope = 'local', win = self.pane }
                )
            end
        end

        vim.api.nvim_win_set_buf(self.pane, self.summary_buf)
    end

    for name, value in pairs(SUMMARY_WINOPTS) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = self.pane }
        )
    end

    vim.api.nvim_win_set_cursor(self.pane, { 1, 0 })
end

--- Show the diff of `item`, a file of the opened commits, in the pane.
---@param item IterChange
function Commits:show_file(item)
    local opened = self.opened
    local key = opened.base .. '..' .. opened.head .. ':' .. item.path

    if key == self.previewed and self.view:is_shown() then
        return
    end

    local source, err =
        git.file_diff(self.root, item, self.config.options.diff.args)

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed = key
    self.view:show(model.build(item, source))
    self.view:set_name(
        uri.of('commits', range_label(opened.range) .. '/' .. item.path)
    )
end

--- List the files of the selected commits, from the oldest one's parent to
--- the newest one, and show the first file's diff.
function Commits:open_files()
    local range = self:range()

    if vim.fn.mode():match('^[vV\22]') then
        vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
    end

    local base, err = git.parent_of(self.root, range.oldest.full_sha)

    if base == nil then
        util.error(err, 'Cannot read the parent of ' .. range.oldest.sha)
        return
    end

    local head = range.newest.full_sha
    local files
    files, err = git.commit_changes(self.root, base, head)

    if files == nil then
        util.error(err, 'Cannot read the changes of ' .. range_label(range))
        return
    end

    if #files == 0 then
        util.warn(range_label(range) .. ' changes no files')
        return
    end

    self.level = 'files'
    self.opened = { range = range, base = base, head = head, files = files }
    self:switched(1)
end

--- Go back from the files to the commits, with the cursor on the newest
--- commit that was opened.
function Commits:back()
    local row = self.opened.range.row

    self.level = 'commits'
    self.opened = nil
    self.previewed = nil
    self:switched(row)
end

--- Render the new level with the cursor on `row`, and preview it.
---@param row integer
function Commits:switched(row)
    self:render()
    vim.api.nvim_win_set_cursor(self.win, { row, 0 })
    self.float:reposition({ title = self:header(), footer = self:footer() })
    self:preview()
end

---@return table<string, fun()>
function Commits:view_handlers()
    return {
        next_hunk = function()
            self.view:jump_hunk(1)
        end,
        prev_hunk = function()
            self.view:jump_hunk(-1)
        end,
        split = function()
            self.view:set_layout('split')
        end,
        unified = function()
            self.view:set_layout('unified')
        end,
        wrap = function()
            self.view:set_wrap(not self.view.wrap)
        end,
        focus_drawer = function()
            if util.is_valid_win(self.win) then
                vim.api.nvim_set_current_win(self.win)
            end
        end,
    }
end

---@return table<string, fun()>
function Commits:make_handlers()
    local view = self:view_handlers()

    return {
        open = function()
            if self.level == 'commits' then
                self:open_files()
                return
            end

            self:preview()

            if self.view:is_shown() then
                vim.api.nvim_set_current_win(self.view.win)
            end
        end,
        review = function()
            self:review()
        end,
        split = view.split,
        unified = view.unified,
        wrap = view.wrap,
        close = function()
            if self.level == 'files' then
                self:back()
            else
                self:close()
            end
        end,
        help = function()
            self:toggle_help()
        end,
        scroll_down = function()
            self:scroll('<C-d>')
        end,
        scroll_up = function()
            self:scroll('<C-u>')
        end,
    }
end

--- Scroll the summary or the diff by half a page, or by the count, and
--- leave the cursor and focus in the drawer.
---@param keys string `<C-d>` or `<C-u>`
function Commits:scroll(keys)
    local win = self.pane

    if self.level == 'files' then
        if not self.view:is_shown() then
            return
        end

        win = self.view.win
    end

    if not util.is_valid_win(win) then
        return
    end

    local count = vim.v.count > 0 and vim.v.count or ''
    local cmd = 'normal! ' .. count .. vim.keycode(keys)

    vim.api.nvim_win_call(win, function()
        vim.cmd(cmd)
    end)

    if self.level == 'files' then
        -- Scrollbind follows only the current window.
        self.view:sync(self.view)
    end
end

--- Close the drawer and open the review from the oldest selected or
--- opened commit, which the review includes, up to the worktree.
function Commits:review()
    local range = self.level == 'files' and self.opened.range or self:range()
    local sha = range.oldest.full_sha

    if vim.fn.mode():match('^[vV\22]') then
        vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
    end

    self:close()
    require('iter').review({ base = { kind = 'commit', sha = sha } })
end

--- Open the help float with the drawer's keys, or close it.
function Commits:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    self.help = help.open({
        view = 'commits',
        keys = self.keys,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

function Commits:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.commits.' .. self.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged' }, {
        group = self.group,
        buffer = self.buf,
        callback = function()
            self:schedule_preview()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = { tostring(self.win), tostring(self.pane) },
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = self.group,
        buffer = self.view.buf,
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
end

---@return boolean
function Commits:is_open()
    return not self.closed and util.is_valid_win(self.win)
end

--- Focus the drawer.
function Commits:focus()
    if util.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end
end

--- Close the float and give the pane back its buffer and options.
function Commits:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self.timer ~= nil then
        self.timer:stop()
        self.timer:close()
        self.timer = nil
    end

    if self.help ~= nil then
        self.help:close()
    end

    self.float:close()
    self.view:close()

    if util.is_valid_win(self.pane) then
        if vim.api.nvim_win_get_buf(self.pane) == self.summary_buf then
            local target = self.prev_buf

            if not vim.api.nvim_buf_is_valid(target) then
                target = vim.api.nvim_create_buf(true, false)
            end

            vim.api.nvim_win_set_buf(self.pane, target)
        end

        for name, value in pairs(self.saved_winopts or {}) do
            vim.api.nvim_set_option_value(
                name,
                value,
                { scope = 'local', win = self.pane }
            )
        end

        vim.api.nvim_set_current_win(self.pane)
    end

    for _, buf in ipairs({ self.buf, self.summary_buf }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

return M
