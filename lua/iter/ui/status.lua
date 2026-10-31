--- The status as a sidebar: the changed files as a tree in the panel at the
--- tab's left edge, and the diff of the file under the cursor in the window
--- the status opened from, which gets its buffer, options and view back when
--- the status closes.

local changes = require('iter.changes')
local commits = require('iter.ui.commits')
local file_actions = require('iter.ui.file_actions')
local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local layout = require('iter.ui.layout')
local panel = require('iter.ui.panel')
local Preview = require('iter.ui.preview')
local render = require('iter.ui.render')
local review_tree = require('iter.ui.review_tree')
local tab = require('iter.ui.tab')
local tree = require('iter.ui.tree')
local uri = require('iter.uri')
local util = require('iter.util')
local watch = require('iter.watch')

---@class IterStatusOpenOptions
---@field pane integer window the diff shows in
---@field config IterConfig
---@field path? string absolute path of a file to put the cursor on when it changed
---@field on_close? fun(status: IterStatus)

---@class IterStatusOrigin what the pane showed when the status opened
---@field buf integer
---@field view vim.fn.winsaveview.ret
---@field layout string `winrestcmd()` of the tab
---@field wins integer[] the tab's windows

---@class IterStatus
---@field tab integer
---@field pane integer
---@field origin IterStatusOrigin
---@field config IterConfig
---@field keys table<string, string[]>
---@field panel IterPanel
---@field tree IterReviewTree
---@field preview IterPreview
---@field view IterDiffView
---@field changes IterChanges
---@field recent? GitRecent
---@field ages? string the commit ages the panel shows
---@field stats table<string, GitStat> line counts against HEAD by path
---@field summary_buf integer the summary of the commit under the cursor, shown in the pane
---@field summary_winopts? table<string, any> the pane's options from before the summary, while it shows
---@field summarized? string full sha of the commit the summary shows
---@field watch? IterWatch
---@field help? IterHelp
---@field preview_timer? uv.uv_timer_t
---@field group integer
---@field quiet boolean cursor moves the code makes schedule no preview
---@field closed boolean
---@field on_close? fun(status: IterStatus)
local Status = {}
Status.__index = Status

-- A commit's summary waits longer than a file's diff, so moving through
-- the commits reads only the one the cursor stops on.
local PREVIEW_DELAY_MS = { file = 50, commit = 150 }

--- The sidebar's width: `review.tree_width`, at most half the editor, at
--- least 10.
---@param config IterConfig
---@return integer
local function sidebar_width(config)
    return math.max(
        10,
        math.min(
            config.options.review.tree_width,
            math.floor(vim.o.columns / 2)
        )
    )
end

---@param opts IterStatusOpenOptions
---@return IterStatus?
function Status.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local pane = opts.pane

    if not util.can_leave(vim.api.nvim_win_get_buf(pane)) then
        return nil
    end

    highlight.setup()

    local tabpage = vim.api.nvim_win_get_tabpage(pane)
    local self = setmetatable({
        tab = tabpage,
        pane = pane,
        origin = {
            buf = vim.api.nvim_win_get_buf(pane),
            view = vim.api.nvim_win_call(pane, vim.fn.winsaveview),
            layout = vim.api.nvim_win_call(pane, vim.fn.winrestcmd),
            wins = vim.api.nvim_tabpage_list_wins(tabpage),
        },
        config = opts.config,
        keys = opts.config.keys.drawer,
        stats = {},
        quiet = false,
        closed = false,
        on_close = opts.on_close,
    }, Status)

    self.preview = Preview.new({
        win = pane,
        config = opts.config,
        handlers = self:view_handlers(),
        source = {
            changes = function()
                return self.changes
            end,
            files = function()
                return self:files()
            end,
            shown = function()
                self:shown()
            end,
        },
        on_cursor = function()
            self:follow_view()
        end,
        on_layout = function()
            self:render()
        end,
    })
    self.view = self.preview.view
    self.tree = review_tree.new({
        view = 'drawer',
        keys = self.keys,
        handlers = self:handlers(),
        header = function(width)
            return self:header(width)
        end,
        decorate = function(file)
            local stat = self.stats[file.path]

            return {
                icon = tree.stage_icon(file.stage),
                right = stat and layout.line_counts(stat),
            }
        end,
        hints = function()
            return {
                {
                    { 'stage', 'stage' },
                    { 'unstage', 'unstage' },
                    { 'discard', 'discard' },
                },
                {
                    { 'open', 'open' },
                    { 'review', 'review' },
                    { 'help', 'help' },
                },
            }
        end,
        footer = function(width)
            local section = layout.commits(self.recent, width, os.time(), true)
            local items = {}

            self.ages = layout.commit_ages(self.recent)

            for index, row in ipairs(section.rows) do
                items[index] = row.commit
            end

            if #section.lines > 0 then
                table.insert(section.lines, render.line(''))
            end

            return section.lines, items
        end,
        on_select = function(node, commit)
            if self.quiet then
                return
            elseif commit ~= nil then
                self:schedule_preview(PREVIEW_DELAY_MS.commit)
            elseif node ~= nil and node.kind == 'file' then
                self:schedule_preview(PREVIEW_DELAY_MS.file)
            end
        end,
    })
    self.summary_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.summary_buf].bufhidden = 'hide'
    vim.bo[self.summary_buf].modifiable = false
    vim.bo[self.summary_buf].filetype = 'iter'

    if not self:load() then
        self.closed = true
        self.preview:close()
        self.tree:close()
        vim.api.nvim_buf_delete(self.summary_buf, { force = true })
        return nil
    end

    self.panel = panel.open({
        width = sidebar_width(opts.config),
        on_close = function()
            self:close()
        end,
    })
    util.name_buf(self.tree.buf, uri.of('status'))
    uri.own(self.tree.buf, {
        owns = function(win)
            return win == self.panel.win
        end,
        reload = function()
            if self:is_open() then
                self:show_tree()
            end
        end,
    })
    util.name_buf(self.summary_buf, uri.of('status') .. '#preview')
    uri.own(self.summary_buf, {
        owns = function(win)
            return win == self.pane
        end,
        reload = function()
            self:show_summary(true)
        end,
        prev = function()
            return self.origin.buf
        end,
    })

    self.quiet = true
    self.panel:show(self.tree)
    self.quiet = false

    local path = opts.path
    local root = self.changes.root

    if path ~= nil and vim.startswith(path, root .. '/') then
        path = path:sub(#root + 2)
    end

    if path == nil or self:file_at(path) == nil then
        local first = self:paths()[1]

        path = first and first.path
    end

    if path ~= nil then
        self:select_path(path)
        self:show_selection(true)
    else
        local newest = self.tree:nearest(1, 1)

        if newest ~= nil then
            self.quiet = true
            self.panel:set_cursor(newest)
            self.quiet = false
        end
    end

    self:attach()
    self.panel:focus()
    self.watch = watch.start({
        root = root,
        poll_ms = opts.config.options.refresh.poll_ms,
        on_change = function(reason)
            self:refresh(reason)
        end,
    })

    return self
end

--- Read the status, the line counts against HEAD and the recent commits.
--- Once loaded, the status stays on its root whatever the cwd becomes.
---@return boolean loaded
function Status:load()
    local snapshot =
        git.status_snapshot(self.changes and self.changes.root or nil)

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false
    end

    self.changes = changes.build(snapshot)
    require('iter.statusline').update(self.changes)
    self.recent = git.recent(
        snapshot.root,
        self.config.options.drawer.commits,
        self.recent
    )
    self.stats = {}

    -- Without a commit there is no HEAD to count against.
    for _, stat in ipairs(git.stats(snapshot.root, 'HEAD') or {}) do
        self.stats[stat.path] = stat
    end

    self.tree.root = tree.build(
        vim.list_extend(
            vim.list_extend({}, self.changes.unstaged),
            self.changes.staged
        )
    )

    return true
end

--- `HEAD <branch>  ↑n ↓m  <upstream>`, then the number of files with how
--- many of them are staged and partly staged.
---@param width integer
---@return IterRenderLine[]
function Status:header(width)
    local files = self:paths()
    local staged, partly = 0, 0

    for _, file in ipairs(files) do
        if file.stage == 'staged' then
            staged = staged + 1
        elseif file.stage == 'partly' then
            partly = partly + 1
        end
    end

    local parts = {
        #files == 0 and 'no changes'
            or string.format('%d %s', #files, #files == 1 and 'file' or 'files'),
    }

    if staged > 0 then
        table.insert(parts, staged .. ' staged')
    end

    if partly > 0 then
        table.insert(parts, partly .. ' partly')
    end

    return {
        render.chunks_line(
            vim.list_extend(
                { { ' ' } },
                layout.status_head(self.changes.branch, self.recent, width - 1)
            )
        ),
        render.chunks_line({
            { ' ' .. table.concat(parts, ' · '), 'IterDrawerHint' },
        }),
    }
end

--- The files of the status in tree order, one per path, nested
--- repositories left out.
---@return IterTreeFile[]
function Status:paths()
    return vim.tbl_filter(function(file)
        return not file.items[1].dir
    end, tree.files(self.tree.root))
end

--- The changes in tree order, a partly staged path's Unstaged change before
--- its Staged one.
---@return IterChange[]
function Status:files()
    local items = {}

    for _, file in ipairs(self:paths()) do
        vim.list_extend(items, file.items)
    end

    return items
end

--- The file of the tree at `path`.
---@param path string
---@return IterTreeFile?
function Status:file_at(path)
    for _, file in ipairs(self:paths()) do
        if file.path == path then
            return file
        end
    end

    return nil
end

--- Render the tree, the cursor kept on a row.
function Status:render()
    if self.closed or self.panel == nil or not self.panel:is_open() then
        return
    end

    self.quiet = true
    self.panel:render()

    local lnum = self.tree.lnum
    local target = self.tree:nearest(lnum, 1)

    if target ~= nil and target ~= lnum then
        self.panel:set_cursor(target)
    end

    self.quiet = false
end

--- Show the tree in the panel again, with the cursor on the file it had.
function Status:show_tree()
    local file = self.tree:file()

    self.quiet = true
    self.panel:show(self.tree)
    self.quiet = false

    if file == nil or not self:select_path(file.path) then
        self:render()
    end
end

--- Put the cursor on the row of `path`, a file or directory path, opening
--- the directories above it; the diff doesn't follow.
---@param path string
---@return boolean found
function Status:select_path(path)
    self.tree:open_to(path)
    self:render()

    local lnum = self.tree:line_of(path)

    if lnum == nil then
        return false
    end

    self.quiet = true
    self.panel:set_cursor(lnum)
    self.quiet = false

    return true
end

--- Show what is under the cursor after `delay` ms, replacing a preview
--- scheduled before that still waits.
---@param delay integer
function Status:schedule_preview(delay)
    if self.closed then
        return
    end

    self.preview_timer = self.preview_timer or assert(vim.uv.new_timer())
    self.preview_timer:stop()
    self.preview_timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            if self.closed then
                return
            elseif self.tree:extra() ~= nil then
                self:show_summary(false)
            else
                self:show_selection(false)
            end
        end)
    )
end

--- Show the diff of the file under the cursor, all its changes. A directory
--- leaves the pane as it is; a clean tree gives the pane its buffer back.
---@param force boolean also when the view shows the file already
function Status:show_selection(force)
    if not self:is_open() then
        return
    end

    local file = self.tree:file()

    if file == nil then
        if #self:paths() == 0 then
            self.preview.previewed = nil
            self.view:hide()
            self:hide_summary()
        end

        return
    end

    self:hide_summary()
    self.view:set_focus(nil)
    self.preview:show(file.items, force)
end

--- Show the summary of the commit under the cursor in the pane in the
--- diff's place: its whole message, then the files with the lines added
--- and deleted.
---@param force boolean also when the pane shows it already
function Status:show_summary(force)
    local commit = self.tree:extra()

    if
        commit == nil
        or not self:is_open()
        or not util.is_valid_win(self.pane)
    then
        return
    end

    if
        not force
        and commit.full_sha == self.summarized
        and vim.api.nvim_win_get_buf(self.pane) == self.summary_buf
    then
        return
    end

    local lines, err = commits.summary(self.changes.root, commit, commit)

    if lines == nil then
        util.error(err)
        return
    end

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
    self.summarized = commit.full_sha
    self.preview.previewed = nil
    self.view:hide()
    self.summary_winopts =
        tab.show_summary(self.pane, self.summary_buf, self.summary_winopts)
    vim.api.nvim_win_set_cursor(self.pane, { 1, 0 })
end

--- Give the pane its options and its buffer back while it shows the
--- summary, so a diff shown next borrows them from the user's buffer.
function Status:hide_summary()
    if self.summary_winopts == nil then
        return
    end

    if util.is_valid_win(self.pane) then
        tab.hide_summary(self.pane, self.summary_winopts)

        if
            vim.api.nvim_win_get_buf(self.pane) == self.summary_buf
            and vim.api.nvim_buf_is_valid(self.origin.buf)
        then
            vim.api.nvim_win_set_buf(self.pane, self.origin.buf)
        end
    end

    self.summary_winopts = nil
end

--- Name the view after what it shows, `iter://status/<path>` or in
--- all-files mode `iter://status#all`.
function Status:shown()
    local file = self.view.files[1]

    if self.preview.all_files then
        self.view:set_name(uri.of('status') .. '#all')
    elseif file ~= nil then
        self.view:set_name(uri.of('status', file.path))
    end
end

--- In all-files mode, put the tree's cursor on the file under the diff's
--- cursor, without showing it again.
function Status:follow_view()
    if not self.preview.all_files or not self:is_open() then
        return
    end

    local shown = self.view:file()
    local file = self.tree:file()

    if shown == nil or (file ~= nil and file.path == shown.path) then
        return
    end

    local target = self:file_at(shown.path)

    if target ~= nil then
        self.preview.previewed = Preview.keys(target.items)
        self:select_path(target.path)
    end
end

--- Show every file in one buffer (`on`), or the file under the cursor alone.
---@param on boolean
function Status:set_all_files(on)
    local file = self.tree:file()

    self:hide_summary()
    self.preview:set_all_files(on, file and file.items)
    self:render()
end

--- Reload the status, keep the cursor on its path, or on `target`, a
--- relative path, and show its diff afresh. A poll that finds the files
--- unchanged renders only when the counts or the commits changed, and reads
--- the diff again when its file was written from outside.
---@param reason? IterWatchReason nil after an action of the status
---@param target? string
function Status:refresh(reason, target)
    if not self:is_open() then
        return
    end

    local before, before_stats, before_recent =
        self.changes, self.stats, self.recent
    local file = self.tree:file()
    local path = target or (file and file.path)

    if not self:load() then
        return
    end

    local same = vim.deep_equal(before, self.changes)

    if reason == 'poll' and same then
        if
            self.recent ~= before_recent
            or layout.commit_ages(self.recent) ~= self.ages
            or not vim.deep_equal(before_stats, self.stats)
        then
            self:render()
        end

        if self.tree:extra() ~= nil and self:showing() then
            self:show_summary(false)
        end

        file = self.tree:file()

        if
            file ~= nil
            and Preview.keys(file.items) == self.preview.previewed
            and self.preview:stat(file.items[1])
                ~= self.preview.previewed_stat
        then
            self:show_selection(true)
        end

        return
    end

    if path == nil or not self:select_path(path) then
        self:render()
    end

    if self.tree:extra() ~= nil then
        if self:showing() then
            self:show_summary(true)
        end
    elseif
        self:showing() or vim.api.nvim_get_current_win() == self.panel.win
    then
        self:show_selection(true)
    end

    if reason == nil or not same then
        util.emit('IterRefresh', {
            root = self.changes.root,
            paths = changes.paths(self.changes),
        })
    end
end

--- Whether the pane shows the status's diff or a commit's summary.
---@return boolean
function Status:showing()
    if not util.is_valid_win(self.pane) then
        return false
    end

    local buf = vim.api.nvim_win_get_buf(self.pane)

    return buf == self.view.buf or buf == self.summary_buf
end

--- What the file actions work on.
---@return IterFileActionContext
function Status:action_context()
    return { changes = self.changes, config = self.config }
end

--- Refresh after `result`, an action's, and fire `User IterStage` for it.
---@param result? IterFileActionResult
function Status:after_action(result)
    if result == nil then
        return
    end

    if not result.ok then
        util.error(result.err, result.fallback)
    end

    self:refresh()

    if result.ok and result.action ~= nil then
        util.emit('IterStage', {
            root = self.changes.root,
            paths = result.paths,
            action = result.action,
        })
    end
end

--- Stage (`stage`) or unstage (`unstage`) the row under the cursor: a file,
--- all of a partly staged one, or every file below a directory.
---@param kind 'stage'|'unstage'
function Status:stage_row(kind)
    local node = self.tree:node()

    if node == nil then
        return
    end

    local ctx = self:action_context()

    if node.kind == 'file' then
        self:after_action(file_actions[kind](ctx, node.items))
        return
    end

    local items = file_actions.below(tree.files(node), kind)

    if kind == 'stage' and #items == 0 then
        util.warn('Nothing to stage')
        return
    end

    self:after_action(file_actions[kind](ctx, items))
end

--- The file under the cursor for an action that works on one file; warns
--- on a directory.
---@return IterTreeFile?
function Status:row_file()
    local node = self.tree:node()

    if node ~= nil and node.kind == 'dir' then
        util.warn('Works on a file, not a directory')
        return nil
    end

    return node --[[@as IterTreeFile?]]
end

--- On a directory, close it or open it; on a file, `collapse` goes to its
--- directory and closes it.
---@param action 'toggle'|'collapse'|'expand'
function Status:fold(action)
    local dir = self.tree:fold(action)

    if dir ~= nil then
        self:select_path(dir.path)
    end
end

--- Close the status and edit `rel`, a path of the repository, in the pane,
--- at `line` when given. A deleted file keeps the status open.
---@param rel string
---@param line? integer
function Status:edit(rel, line)
    local path = vim.fs.joinpath(self.changes.root, rel)

    if vim.uv.fs_stat(path) == nil then
        util.warn(rel .. ' is deleted')
        return
    end

    if not util.can_leave(self.origin.buf, path) then
        return
    end

    self:close()
    util.edit_at(path, line, rel)
end

---@return table<string, fun()>
function Status:view_handlers()
    return {
        focus_drawer = function()
            self.panel:focus()
        end,
        expand = function()
            self.preview:open_row(function(path, line)
                self:edit(path, line)
            end)
        end,
        mode = function()
            self:set_all_files(not self.preview.all_files)
        end,
        split = function()
            self.preview:set_layout('split')
        end,
        unified = function()
            self.preview:set_layout('unified')
        end,
        wrap = function()
            self.preview:toggle_wrap()
        end,
    }
end

---@return table<string, fun()>
function Status:handlers()
    return {
        open = function()
            local node = self.tree:node()
            local commit = self.tree:extra()

            if commit ~= nil then
                self:close()
                require('iter').commits({ sha = commit.full_sha })
            elseif node == nil then
                return
            elseif node.kind == 'dir' then
                self:fold('toggle')
            elseif not node.items[1].dir then
                self:edit(node.path)
            end
        end,
        stage = function()
            self:stage_row('stage')
        end,
        unstage = function()
            self:stage_row('unstage')
        end,
        discard = function()
            local file = self:row_file()

            if file == nil then
                return
            end

            local item = file.items[1]

            for _, other in ipairs(file.items) do
                if other.side == 'unstaged' then
                    item = other
                end
            end

            self:after_action(file_actions.discard(self:action_context(), item))
        end,
        ignore = function()
            local file = self:row_file()

            if file ~= nil then
                self:after_action(
                    file_actions.ignore(self:action_context(), file.items[1])
                )
            end
        end,
        review = function()
            local file = self.tree:file()
            local commit = self.tree:extra()
            local target = commit
                    and { base = { kind = 'commit', sha = commit.full_sha } }
                or file
                    and { path = vim.fs.joinpath(self.changes.root, file.path) }

            self:close()
            require('iter').review(target)
        end,
        mode = function()
            self:set_all_files(not self.preview.all_files)
        end,
        split = function()
            self.preview:set_layout('split')
        end,
        unified = function()
            self.preview:set_layout('unified')
        end,
        wrap = function()
            self.preview:toggle_wrap()
        end,
        collapse = function()
            self:fold('collapse')
        end,
        expand = function()
            self:fold('expand')
        end,
        close = function()
            self:close()
        end,
        help = function()
            self:toggle_help()
        end,
        scroll_down = function()
            self.preview:scroll('<C-d>')
        end,
        scroll_up = function()
            self.preview:scroll('<C-u>')
        end,
    }
end

--- Open the help float with the status's keys, or close it.
function Status:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    self.help = help.open({
        view = 'drawer',
        keys = self.keys,
        handlers = self.tree.opts.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

--- After a resize: the 'auto' diff layout, the tree for the new size, even
--- split panes and wrapped lines.
function Status:resized()
    if not self:is_open() then
        return
    end

    self.preview:resized()
    self:render()
    self.view:even_widths()
    self.view:rewrap()
end

function Status:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.status.' .. self.tree.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = self.group,
        callback = function(args)
            if
                args.event == 'WinResized'
                and not vim.iter(vim.v.event.windows):any(function(win)
                    return util.is_valid_win(win)
                        and vim.api.nvim_win_get_tabpage(win) == self.tab
                end)
            then
                return
            end

            self:resized()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = tostring(self.pane),
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    -- The view's buffer goes when another buffer takes the pane.
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
function Status:is_open()
    return not self.closed and self.panel:is_open()
end

--- Focus the sidebar and reload.
function Status:focus()
    self.panel:focus()
    self:refresh()
end

--- Put the cursor on the file at `path`, relative to the root, and show its
--- diff; warn when it isn't in the changes.
---@param path string
function Status:reveal(path)
    if self:file_at(path) == nil then
        util.warn(path .. ' is not in the changes')
        return
    end

    self:select_path(path)
    self:show_selection(false)
end

--- Whether the tab's windows, the panel left out, are the ones it had when
--- the status opened.
---@param self IterStatus
---@return boolean
local function same_windows(self)
    if not vim.api.nvim_tabpage_is_valid(self.tab) then
        return false
    end

    local wins = vim.tbl_filter(function(win)
        return win ~= self.panel.win
    end, vim.api.nvim_tabpage_list_wins(self.tab))

    return vim.deep_equal(wins, self.origin.wins)
end

--- Close the sidebar and give the pane back its buffer, options and view,
--- and the tab its layout.
function Status:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self.watch ~= nil then
        self.watch:stop()
    end

    if self.preview_timer ~= nil then
        self.preview_timer:stop()
        self.preview_timer:close()
        self.preview_timer = nil
    end

    if self.help ~= nil then
        self.help:close()
    end

    local pane, origin = self.pane, self.origin
    local taken = self:showing()

    self.preview:close()
    self:hide_summary()

    if taken and vim.api.nvim_buf_is_valid(origin.buf) then
        vim.api.nvim_win_set_buf(pane, origin.buf)
        vim.api.nvim_win_call(pane, function()
            vim.fn.winrestview(origin.view)
        end)
    end

    local restore = util.is_valid_win(pane) and same_windows(self)

    self.panel:close({ silent = true })
    self.tree:close()

    if vim.api.nvim_buf_is_valid(self.summary_buf) then
        vim.api.nvim_buf_delete(self.summary_buf, { force = true })
    end

    if restore then
        vim.api.nvim_win_call(pane, function()
            vim.cmd(origin.layout)
        end)
    end

    if
        util.is_valid_win(pane)
        and vim.api.nvim_win_get_tabpage(pane)
            == vim.api.nvim_get_current_tabpage()
    then
        vim.api.nvim_set_current_win(pane)
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

return Status
