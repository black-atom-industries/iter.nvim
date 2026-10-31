--- The commits tab: the recent commits in the panel, the summary of the
--- commit under the cursor beside them; a commit's files as a tree in the
--- list's place, the diff of the file under the cursor beside them.

local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local model = require('iter.diff.model')
local panel = require('iter.ui.panel')
local render = require('iter.ui.render')
local review_tree = require('iter.ui.review_tree')
local tab = require('iter.ui.tab')
local tree = require('iter.ui.tree')
local uri = require('iter.uri')
local util = require('iter.util')
local View = require('iter.diff.view')

local M = {}

-- Commits the list shows, newest first.
local COMMITS = 100
-- The commit list waits longer than the file tree, so moving through it
-- reads only the commit it stops on.
local PREVIEW_DELAY_MS = { list = 150, files = 50 }
-- Lines of the list above its first commit: the title and the selection.
local LIST_TOP = 2

local selection_ns = vim.api.nvim_create_namespace('iter.commits.selection')

---@class IterCommitsOpenOptions
---@field config IterConfig
---@field on_close? fun(commits: IterCommits)

---@class IterCommitsRange the commits a preview or review covers
---@field newest GitCommit
---@field oldest GitCommit
---@field count integer
---@field index integer list index of `newest`

---@class IterCommitsOpened the commits whose files the tree lists
---@field range IterCommitsRange
---@field base string the oldest commit's parent, or the empty tree
---@field head string full sha of the newest commit
---@field files IterChange[]
---@field stats table<string, GitStat> by path
---@field added integer
---@field deleted integer

---@class IterCommits: IterTab
---@field win integer the main window: the summary or the diff
---@field root string
---@field branch string 'HEAD' when detached
---@field config IterConfig
---@field keys table<string, string[]>
---@field commits GitCommit[] newest first
---@field panel IterPanel
---@field list IterPanelPage the commit list
---@field files? IterReviewTree the files of `opened`, while the panel shows them
---@field opened? IterCommitsOpened
---@field view IterDiffView diff of the selected file in the main window
---@field summary_winopts? table<string, any> the main window's options from before the summary, while it shows
---@field handlers table<string, fun()>
---@field help? IterHelp
---@field previewed? string what the main window shows: `base..head` of a summary, `base..head:path` of a file
---@field quiet? boolean the tree's cursor moves come from the tab, which previews itself
---@field timer? uv.uv_timer_t runs the last scheduled preview
---@field group integer
---@field closed boolean
---@field on_close? fun(commits: IterCommits)
local Commits = {}
Commits.__index = Commits

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

--- The commits tab of the current directory's repository, nil with a
--- warning when it has no commits.
---@param opts IterCommitsOpenOptions
---@return IterCommits?
function M.open(opts)
    vim.validate('opts', opts, 'table')
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

    highlight.setup()

    local config = opts.config
    local opened, main = tab.open('iter commits')
    local self = setmetatable(opened, Commits) --[[@as IterCommits]]

    self.win = main
    self.root = root
    self.branch = git.head_branch(root) or 'HEAD'
    self.config = config
    self.keys = config.keys.commits
    self.commits = recent.commits
    self.closed = false
    self.on_close = opts.on_close

    vim.bo[self.buf].modifiable = false
    vim.bo[self.buf].filetype = 'iter'
    uri.own(self.buf, {
        owns = function(win)
            return win == self.win
        end,
        reload = function()
            self.previewed = nil
            self:preview()
        end,
    })

    local diff = config.options.diff
    local auto = diff.layout == 'auto'
            and (vim.api.nvim_win_get_width(self.win) >= diff.split_breakpoint and 'split' or 'unified')
        or nil

    self.view = View.new({
        win = self.win,
        keys = config.keys.diff,
        expand_step = diff.expand_step,
        syntax_max_lines = diff.syntax_max_lines,
        word_diff = diff.word_diff,
        icon = config.options.icons.annotation,
        handlers = self:view_handlers(),
        bufhidden = 'hide',
        layout = auto or diff.layout --[[@as IterDocLayout]],
        wrap = diff.wrap,
    })
    self.handlers = self:make_handlers()
    self.list = self:list_page()
    self.panel = panel.open({
        width = config.options.review.tree_width,
        on_close = function()
            self:close()
        end,
    })
    self:attach()
    self.panel:show(self.list)
    self.panel:focus()
    self:preview()

    return self
end

--- The commit list page: a title, the selection, a commit per line, and
--- the key hints at the bottom.
---@return IterPanelPage
function Commits:list_page()
    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    util.name_buf(buf, uri.of('commits'))
    uri.own(buf, {
        owns = function(win)
            return win == self.panel.win
        end,
        reload = function()
            self.panel:render()
        end,
    })
    keymap.attach(buf, 'commits', self.keys, self.handlers)

    return {
        buf = buf,
        render = function(_, width, height)
            self:render_list(width, height)
        end,
        on_cursor = function(_, lnum)
            local target =
                math.max(LIST_TOP + 1, math.min(lnum, LIST_TOP + #self.commits))

            if target ~= lnum then
                vim.api.nvim_win_set_cursor(0, { target, 0 })
            end

            self:render_selection()
            self:schedule_preview()
        end,
    }
end

--- The hint chunks of each line of a page for `width` cells.
---@param actions [string, string][][] action and label, one list per line
---@param width integer
---@return [string, string][][]
function Commits:hint_chunks(actions, width)
    local bound = keymap.list('commits', self.keys, self.handlers)

    table.insert(bound, {
        action = 'range',
        lhs = { 'V' },
        desc = '',
        modes = {},
    })

    return vim.tbl_map(function(line)
        return layout.hints(bound, line, width - 1)
    end, actions)
end

---@param width integer
---@param height integer
function Commits:render_list(width, height)
    local lines = {
        render.chunks_line({
            { ' Commits', 'IterDrawerTitle' },
            { ' ' },
            { self.branch, 'IterHead' },
            { ' · last ' .. #self.commits, 'IterDrawerHint' },
        }),
        render.line(''),
    }

    for _, commit in ipairs(self.commits) do
        table.insert(
            lines,
            render.chunks_line({
                { '  ' },
                unpack(layout.commit_short(commit, width - 3)),
            })
        )
    end

    layout.bottom_hints(
        lines,
        self:hint_chunks({
            {
                { 'open', 'files' },
                { 'range', 'range' },
                { 'review', 'review' },
            },
            { { 'close', 'close' }, { 'help', 'help' } },
        }, width),
        height
    )

    local buf = self.list.buf

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render.text_lines(lines))
    vim.bo[buf].modifiable = false
    render.apply(buf, lines)
    self:render_selection()
end

--- The list's second line: the number of selected commits and their range
--- while `V` selects several, else blank. Only that line changes, so the
--- visual selection stays.
function Commits:render_selection()
    local buf = self.list.buf
    local range = self:range()
    local text = range.count > 1
            and string.format(
                ' %d selected · %s',
                range.count,
                range_label(range)
            )
        or ''

    if vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] ~= text then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { text })
        vim.bo[buf].modifiable = false
    end

    vim.api.nvim_buf_clear_namespace(buf, selection_ns, 1, 2)

    if text ~= '' then
        vim.api.nvim_buf_set_extmark(buf, selection_ns, 1, 0, {
            end_col = #text,
            hl_group = 'IterDrawerHint',
        })
    end
end

--- The selected commits of the list: the visual selection's rows while
--- one is active in the panel, else the cursor's row.
---@return IterCommitsRange
function Commits:range()
    local win = self.panel.win
    local last_row = LIST_TOP + #self.commits

    ---@param lnum integer
    ---@return integer
    local function index(lnum)
        return math.max(LIST_TOP + 1, math.min(lnum, last_row)) - LIST_TOP
    end

    local cursor = util.is_valid_win(win)
            and vim.api.nvim_win_get_buf(win) == self.list.buf
            and index(vim.api.nvim_win_get_cursor(win)[1])
        or 1
    local first, last = cursor, cursor

    if
        vim.api.nvim_get_current_win() == win
        and vim.fn.mode():match('^[vV\22]')
    then
        local other = index(vim.fn.line('v'))

        first, last = math.min(cursor, other), math.max(cursor, other)
    end

    return {
        newest = self.commits[first],
        oldest = self.commits[last],
        count = last - first + 1,
        index = first,
    }
end

--- The lines above the tree of the opened commits: the commit's sha or
--- the range, its subject or the number of commits, then the number of
--- files and the lines added and deleted.
---@param width integer
---@return IterRenderLine[]
function Commits:files_header(width)
    local opened = self.opened --[[@as IterCommitsOpened]]
    local range = opened.range
    local about = range.count == 1 and range.newest.subject
        or (range.count .. ' commits')
    local subject = layout.fit(about, width - 1):gsub('%s+$', '')
    local files = #opened.files

    return {
        render.chunks_line({
            { ' Commits', 'IterDrawerTitle' },
            { ' ‹ ', 'IterDrawerHint' },
            { range_label(range), 'IterCommitSha' },
        }),
        render.chunks_line({ { ' ' .. subject } }),
        render.chunks_line({
            {
                string.format(
                    ' %d %s · ',
                    files,
                    files == 1 and 'file' or 'files'
                ),
                'IterDrawerHint',
            },
            { '+' .. opened.added, 'IterStage' },
            { ' ' },
            { '−' .. opened.deleted, 'IterUnstage' },
        }),
    }
end

--- The tree page of the opened commits' files.
---@return IterReviewTree
function Commits:files_page()
    local opened = self.opened --[[@as IterCommitsOpened]]
    local page = review_tree.new({
        view = 'commits',
        keys = self.keys,
        handlers = self.handlers,
        header = function(width)
            return self:files_header(width)
        end,
        decorate = function(file)
            local stat = opened.stats[file.path]

            return { right = stat and { layout.line_count(stat) } }
        end,
        hints = function()
            local split = self.view.layout == 'split'
                    and { 'unified', 'unified' }
                or { 'split', 'split' }

            return {
                { { 'open', 'diff' }, split, { 'review', 'review' } },
                { { 'close', 'commits' }, { 'help', 'help' } },
            }
        end,
        on_select = function(node)
            if not self.quiet and node.kind == 'file' then
                self:schedule_preview()
            end
        end,
    })

    page.root = tree.build(opened.files)
    util.name_buf(page.buf, uri.of('commits', range_label(opened.range)))
    uri.own(page.buf, {
        owns = function(win)
            return win == self.panel.win
        end,
        reload = function()
            self.panel:render()
        end,
    })

    return page
end

--- Preview after the page's delay, dropping a preview scheduled before.
function Commits:schedule_preview()
    if self.timer == nil then
        self.timer = assert(vim.uv.new_timer())
    end

    self.timer:stop()
    self.timer:start(
        PREVIEW_DELAY_MS[self.files and 'files' or 'list'],
        0,
        vim.schedule_wrap(function()
            if not self.closed then
                self:preview()
            end
        end)
    )
end

--- Show the selected commits' summary while the list shows, the selected
--- file's diff while the files show.
function Commits:preview()
    if self.files ~= nil then
        local file = self.files:file()

        if file ~= nil then
            self:show_file(file.items[1])
        end

        return
    end

    self:show_summary(self:range())
end

--- Show the summary of `range` in the main window: each commit's whole
--- message, then the files with the lines added and deleted.
---@param range IterCommitsRange
function Commits:show_summary(range)
    local base, err = git.parent_of(self.root, range.oldest.full_sha)

    if base == nil then
        util.error(err, 'Cannot read the parent of ' .. range.oldest.sha)
        return
    end

    local key = base .. '..' .. range.newest.full_sha
    local shown = util.is_valid_win(self.win)
        and vim.api.nvim_win_get_buf(self.win) == self.buf

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

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, render.text_lines(lines))
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, lines)
    util.name_buf(self.buf, uri.of('commits', range_label(range)) .. '#preview')
    self.previewed = key

    if not util.is_valid_win(self.win) then
        return
    end

    self.view:hide()
    self.summary_winopts =
        tab.show_summary(self.win, self.buf, self.summary_winopts)
    vim.api.nvim_win_set_cursor(self.win, { 1, 0 })
end

--- Show the diff of `item`, a file of the opened commits, in the main
--- window, with the window's own options from before the summary.
---@param item IterChange
function Commits:show_file(item)
    local opened = self.opened --[[@as IterCommitsOpened]]
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

    if self.summary_winopts ~= nil and util.is_valid_win(self.win) then
        tab.hide_summary(self.win, self.summary_winopts)
        self.summary_winopts = nil
    end

    self.previewed = key
    self.view:show(model.build(item, source))
    self.view:set_name(
        uri.of('commits', range_label(opened.range) .. '/' .. item.path)
    )
end

--- Show the files of the selected commits, from the oldest one's parent
--- to the newest one, as a tree in the list's place, and the diff of the
--- first file in tree order.
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

    local stats
    stats, err = git.stats(self.root, base, head)

    if stats == nil then
        util.error(err, 'Cannot read the changes of ' .. range_label(range))
        return
    end

    local opened = {
        range = range,
        base = base,
        head = head,
        files = files,
        stats = {},
        added = 0,
        deleted = 0,
    }

    for _, stat in ipairs(stats) do
        opened.stats[stat.path] = stat
        opened.added = opened.added + (stat.added or 0)
        opened.deleted = opened.deleted + (stat.deleted or 0)
    end

    self.opened = opened
    self.files = self:files_page()
    self:guard(self.files.buf)
    self.quiet = true
    self.panel:show(self.files)
    self.panel:set_cursor(
        self.files:line_of(tree.files(self.files.root)[1].path) or 1
    )
    self.quiet = false
    self:preview()
end

--- Go back from the files to the list, with the cursor on the newest
--- commit that was opened.
function Commits:back()
    local files = self.files --[[@as IterReviewTree]]
    local index = self.opened.range.index

    self.files, self.opened, self.previewed = nil, nil, nil
    self.panel:show(self.list)
    self.panel:set_cursor(LIST_TOP + index)
    files:close()
    self:preview()
end

--- On a directory of the files, close it or open it; on a file,
--- `collapse` goes to its directory and closes it.
---@param action 'toggle'|'collapse'|'expand'
function Commits:fold(action)
    local dir = self.files and self.files:fold(action)

    if dir == nil then
        return
    end

    self.quiet = true
    self.panel:render()

    local lnum = self.files:line_of(dir.path)

    if lnum ~= nil then
        self.panel:set_cursor(lnum)
    end

    self.quiet = false
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
            self:set_layout('split')
        end,
        unified = function()
            self:set_layout('unified')
        end,
        wrap = function()
            self.view:set_wrap(not self.view.wrap)
        end,
        focus_drawer = function()
            self.panel:focus()
        end,
    }
end

---@param name IterDocLayout
function Commits:set_layout(name)
    self.view:set_layout(name)
    self.panel:render()
end

---@return table<string, fun()>
function Commits:make_handlers()
    local view = self:view_handlers()

    return {
        open = function()
            if self.files == nil then
                self:open_files()
                return
            end

            local node = self.files:node()

            if node ~= nil and node.kind == 'dir' then
                self:fold('toggle')
                return
            end

            self:preview()

            if self.view:is_shown() then
                vim.api.nvim_set_current_win(self.win)
            end
        end,
        review = function()
            self:review()
        end,
        split = view.split,
        unified = view.unified,
        wrap = view.wrap,
        collapse = function()
            self:fold('collapse')
        end,
        expand = function()
            self:fold('expand')
        end,
        close = function()
            if self.files ~= nil then
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
--- leave the cursor and focus in the panel.
---@param keys string `<C-d>` or `<C-u>`
function Commits:scroll(keys)
    if not util.is_valid_win(self.win) then
        return
    end

    local count = vim.v.count > 0 and vim.v.count or ''
    local cmd = 'normal! ' .. count .. vim.keycode(keys)

    vim.api.nvim_win_call(self.win, function()
        vim.cmd(cmd)
    end)

    if self.view:is_shown() then
        -- Scrollbind follows only the current window.
        self.view:sync(self.view)
    end
end

--- Close the tab and open the review from the oldest selected or opened
--- commit, which the review includes, up to the worktree.
function Commits:review()
    local range = self.opened and self.opened.range or self:range()
    local sha = range.oldest.full_sha

    if vim.fn.mode():match('^[vV\22]') then
        vim.cmd.normal({ vim.keycode('<Esc>'), bang = true })
    end

    self:close()
    require('iter').review({ base = { kind = 'commit', sha = sha } })
end

--- Open the help float with the tab's keys, or close it.
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

    vim.api.nvim_create_autocmd('ModeChanged', {
        group = self.group,
        buffer = self.list.buf,
        callback = function()
            self:render_selection()
            self:schedule_preview()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = tostring(self.win),
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

    for _, buf in ipairs({ self.list.buf, self.buf, self.view.buf }) do
        self:guard(buf)
    end
end

--- Take the window back when another buffer takes the place of `buf`, one
--- of the tab's own, as `:edit` does.
---@param buf integer
function Commits:guard(buf)
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()

            if win == self.panel.win or win == self.win then
                vim.schedule(function()
                    self:take_back(win)
                end)
            end
        end,
    })
end

--- Show the page in the panel, or the summary or the diff in the main
--- window, again after a buffer from outside took `win`'s place. A file
--- buffer opens in the tab the commits came from instead.
---@param win integer
function Commits:take_back(win)
    if self.closed or not util.is_valid_win(win) then
        return
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local own = win == self.panel.win
            and (buf == self.list.buf or (self.files and buf == self.files.buf))
        or (buf == self.buf or buf == self.view.buf)

    if own then
        return
    end

    local path = vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf)
        or ''
    local line = vim.api.nvim_win_get_cursor(win)[1]

    if win == self.panel.win then
        self.panel:show(self.files or self.list)
    else
        vim.api.nvim_win_set_buf(win, self.buf)
        self.previewed = nil
        self:preview()
    end

    vim.api.nvim_win_call(win, function()
        vim.cmd.clearjumps()
    end)

    if path ~= '' then
        tab.open_file(self, path, line)
    end
end

---@return boolean
function Commits:is_open()
    return not self.closed and vim.api.nvim_tabpage_is_valid(self.tab)
end

--- Switch to the tab and focus the panel.
function Commits:focus()
    vim.api.nvim_set_current_tabpage(self.tab)
    self.panel:focus()
end

--- Close the tab and go back to the tab it came from.
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

    self.panel:close({ silent = true })
    tab.close(self)
    self.view:close()

    for _, page in ipairs({ self.list, self.files }) do
        if vim.api.nvim_buf_is_valid(page.buf) then
            vim.api.nvim_buf_delete(page.buf, { force = true })
        end
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

return M
