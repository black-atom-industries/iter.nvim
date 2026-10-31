local changes = require('iter.changes')
local file_actions = require('iter.ui.file_actions')
local float = require('iter.ui.float')
local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local Preview = require('iter.ui.preview')
local render = require('iter.ui.render')
local uri = require('iter.uri')
local util = require('iter.util')
local watch = require('iter.watch')

---@alias IterDrawerRow table<string, IterChange> buffer line → item per column id

---@class IterDrawerOpenOptions
---@field pane integer window the float is anchored to
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field side? IterSide side to look for `path` on first
---@field on_close? fun(drawer: IterDrawer)

---@class IterDrawer
---@field keys table<string, string[]>
---@field pane integer
---@field win integer
---@field buf integer
---@field float IterFloat
---@field preview IterPreview diff of the selected file, shown in the pane
---@field view IterDiffView the preview's view
---@field watch? IterWatch refreshes the drawer on external changes
---@field help? IterHelp
---@field handlers table<string, fun()> drawer actions by name
---@field config IterConfig
---@field changes IterChanges
---@field recent? GitRecent the recent commits, nil without a commit
---@field ages string the commit ages of the last render
---@field section_buf? integer buffer of the Recent commits, pinned under the files
---@field rows IterDrawerRow[]
---@field cells table<string, IterLayoutCell>[]
---@field column string id of the selected column
---@field lnum integer selected line
---@field layout IterLayoutMode
---@field preview_timer? uv.uv_timer_t runs the last scheduled preview; closed with the drawer
---@field group integer
---@field closed boolean
---@field on_close? fun(drawer: IterDrawer)
local Drawer = {}
Drawer.__index = Drawer

-- Text lines the drawer keeps in a pane too short for `drawer.height`.
Drawer.MIN_LINES = 5

local SELECTED_NS = vim.api.nvim_create_namespace('iter.drawer.selected')

local PREVIEW_DELAY_MS = 50
-- Actions the key hint line shows in a file column, in order, with their
-- short labels.
local HINTS = {
    { 'stage', 'stage' },
    { 'unstage', 'unstage' },
    { 'discard', 'discard' },
    { 'ignore', 'ignore' },
    { 'open', 'open' },
    { 'review', 'review' },
    { 'mode', 'all files' },
    { 'split', 'split' },
    { 'help', 'help' },
}

local key = Preview.key

---@class IterDrawerColumn
---@field id IterSide
---@field title string
---@field items IterChange[]

--- The columns left to right, each listing the changes of its side:
--- Unstaged and Staged.
---@return IterDrawerColumn[]
function Drawer:columns()
    local result = self.changes

    return {
        { id = 'unstaged', title = 'Unstaged', items = result.unstaged },
        { id = 'staged', title = 'Staged', items = result.staged },
    }
end

--- Column ids left to right, `first` moved to the front when given.
---@param first? string
---@return string[]
function Drawer:column_ids(first)
    local ids = first and { first } or {}

    for _, column in ipairs(self:columns()) do
        if column.id ~= first then
            table.insert(ids, column.id)
        end
    end

    return ids
end

--- Every item in drawer order: column by column, left to right.
---@return IterChange[]
function Drawer:ordered()
    local items = {}

    for _, column in ipairs(self:columns()) do
        vim.list_extend(items, column.items)
    end

    return items
end

--- `layout.status_head`, with `<n> changes` at the right edge. A file in more
--- than one column counts once. Stacked, the counts are per column, since a
--- lower title may sit below the visible lines.
---@param drawer IterDrawer
---@return [string, string][]
local function header_chunks(drawer)
    local columns = drawer:columns()
    local count = #changes.paths(drawer.changes)
    local total =
        string.format('%d %s', count, count == 1 and 'change' or 'changes')
    local parts = { total }

    if drawer.layout == 'stacked' and count > 0 then
        parts = {}

        for _, column in ipairs(columns) do
            table.insert(
                parts,
                string.format('%d %s', #column.items, column.title:lower())
            )
        end
    end

    -- The header starts one column in.
    local width = drawer:width() - 1

    return layout.status_head(
        drawer.changes.branch,
        drawer.recent,
        width,
        table.concat(parts, ' · '),
        total
    )
end

---@param opts IterDrawerOpenOptions
---@return IterDrawer?
function Drawer.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.side', opts.side, 'string', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    if not util.can_leave(vim.api.nvim_win_get_buf(opts.pane)) then
        return nil
    end

    highlight.setup()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    util.name_buf(buf, uri.of('status'))

    local self = setmetatable({
        keys = opts.config.keys.drawer,
        pane = opts.pane,
        buf = buf,
        config = opts.config,
        rows = {},
        cells = {},
        ages = '',
        column = 'unstaged',
        lnum = 1,
        layout = 'columns',
        closed = false,
        on_close = opts.on_close,
    }, Drawer)

    self:own(buf)

    local view_handlers = {
        focus_drawer = function()
            if util.is_valid_win(self.win) then
                vim.api.nvim_set_current_win(self.win)
            end
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

    self.preview = Preview.new({
        win = opts.pane,
        config = opts.config,
        handlers = view_handlers,
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
            if self.float ~= nil and not self.closed then
                self.float:reposition({
                    left = self:left() or false,
                    footer = self:footer(),
                })
            end
        end,
    })
    self.view = self.preview.view

    if not self:load() then
        self.preview:close()
        vim.api.nvim_buf_delete(buf, { force = true })

        return nil
    end

    self.column = self:columns()[1].id
    self.handlers = self:make_handlers()
    self.float = float.open({
        pane = opts.pane,
        buf = buf,
        zindex = opts.config.options.drawer.zindex,
        height = opts.config.options.drawer.height,
        enter = true,
        chrome = true,
        rule = true,
    })
    self.win = self.float.win
    vim.api.nvim_set_option_value(
        'wrap',
        false,
        { scope = 'local', win = self.win }
    )

    self:render()
    self:restore_selection(self:find_path(opts.path, opts.side))
    self:attach()
    self:show_selection(true)
    self.watch = watch.start({
        root = self.changes.root,
        poll_ms = opts.config.options.refresh.poll_ms,
        on_change = function(reason)
            self:refresh(reason)
        end,
    })

    return self
end

---@return table<string, fun()>
function Drawer:make_handlers()
    local function act(method)
        return function()
            self[method](self)
        end
    end

    local handlers = {
        open = act('open_file'),
        review = act('open_review'),
        stage = act('stage'),
        unstage = act('unstage'),
        discard = act('discard'),
        ignore = act('ignore'),
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
        close = act('close'),
        help = act('toggle_help'),
        scroll_down = function()
            self.preview:scroll('<C-d>')
        end,
        scroll_up = function()
            self.preview:scroll('<C-u>')
        end,
        column_left = function()
            self:step_column(-1)
        end,
        column_right = function()
            self:step_column(1)
        end,
    }

    return handlers
end

function Drawer:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.drawer.' .. self.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = self.group,
        buffer = self.buf,
        callback = function()
            self:follow_cursor(vim.api.nvim_get_current_win())
        end,
    })
    keymap.attach(self.buf, 'drawer', self.keys, self.handlers)

    vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = self.group,
        callback = function()
            self:resized()
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
    -- The status drawer's buffer goes when another buffer takes the float.
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = self.group,
        buffer = self.buf,
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
end

---@return boolean
function Drawer:is_open()
    return not self.closed
        and util.is_valid_win(self.win)
        and vim.api.nvim_buf_is_valid(self.buf)
end

--- Read the status afresh, keeping open directories open, and the recent
--- commits. Once loaded, the drawer stays on its root whatever the cwd
--- becomes.
---@return boolean loaded
function Drawer:load()
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

    return true
end

--- Replace the lines of `buf` with `lines` and their highlights, the
--- selection mark cleared.
---@param buf integer
---@param lines IterRenderLine[]
local function write(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render.text_lines(lines))
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, SELECTED_NS, 0, -1)
    render.apply(buf, lines)
end

--- Write the items into the buffer in the layout the pane's width allows,
--- with the header and key hint line around them, and the Recent commits
--- pinned under them.
function Drawer:render()
    local width = self:width()
    ---@type IterLayoutColumn[]
    local columns = vim.tbl_map(function(column)
        ---@type IterLayoutColumn
        return {
            id = column.id,
            title = column.title,
            items = column.items,
            cell = function(line, item, first, cell_width)
                return layout.file_cell(line, item, first, cell_width)
            end,
        }
    end, self:columns())

    self.layout = layout.mode(width, self.config.options.drawer.breakpoint)

    local built

    if #self:ordered() == 0 then
        built = layout.message('Working tree clean')
    elseif self.layout == 'columns' then
        built = layout.columns(columns, width)
    else
        built = layout.stacked(columns, width)
    end

    self.rows, self.cells = built.rows, built.cells

    write(self.buf, built.lines)

    self.float:reposition({
        min_lines = math.min(#built.lines, Drawer.MIN_LINES),
        strip = self:render_section(width),
        title = header_chunks(self),
        footer = self:footer(),
    })

    self:shown()
end

--- Write the Recent commits into their buffer, created on first use.
---@param width integer
---@return IterFloatStrip|false strip false without commits to show
function Drawer:render_section(width)
    local section = layout.commits(self.recent, width, os.time())

    self.ages = layout.commit_ages(self.recent)

    if #section.lines == 0 then
        return false
    end

    table.insert(section.lines, 1, render.line(''))

    local buf = self.section_buf

    if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = 'hide'
        vim.bo[buf].filetype = 'iter'
        self.section_buf = buf
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        render.text_lines(section.lines)
    )
    vim.bo[buf].modifiable = false
    render.apply(buf, section.lines)

    return { buf = buf, lines = #section.lines }
end

--- The key hint line.
---@return [string, string][]
function Drawer:footer()
    local hints = vim.tbl_map(function(hint)
        if hint[1] == 'mode' and self.preview.all_files then
            return { 'mode', 'one file' }
        elseif hint[1] == 'split' and self.view.layout == 'split' then
            return { 'unified', 'unified' }
        end

        return hint
    end, HINTS)

    -- The footer starts one cell in from the float's left edge.
    return layout.hints(
        keymap.list('drawer', self.keys, self.handlers),
        hints,
        self:width() - 1
    )
end

--- The old side's window of a split diff in the drawer's own pane, which
--- the drawer covers too.
---@return integer?
function Drawer:left()
    if self.view.win == self.pane and self.view.old ~= nil then
        return self.view.old.win
    end
end

--- Width of the drawer: its pane's, with the window left of it when it
--- covers that too.
---@return integer
function Drawer:width()
    local width = vim.api.nvim_win_get_width(self.pane)
    local left = self:left()

    if left ~= nil and util.is_valid_win(left) then
        width = width + vim.api.nvim_win_get_width(left) + 1
    end

    return width
end

--- Mark `buf` as the drawer's, shown in its float.
---@param buf integer
function Drawer:own(buf)
    uri.own(buf, {
        owns = function(win)
            return win == self.win
        end,
        reload = function()
            if not self:is_open() then
                return
            end

            local mark = self:mark()

            self:render()
            self:restore_selection(mark)
        end,
    })
end

--- Name the view after what it shows, `iter://status/<path>` or in
--- all-files mode `iter://status#all`.
function Drawer:shown()
    local file = self.view.files[1]

    if self.preview.all_files then
        self.view:set_name(uri.of('status') .. '#all')
    elseif file ~= nil then
        self.view:set_name(uri.of('status', file.path))
    end
end

--- The selected file.
---@return IterChange?
function Drawer:selected()
    local row = self.rows[self.lnum]

    return row and row[self.column]
end

--- The line nearest to `lnum` that holds an item of one of the columns
--- `ids`, looking in direction `dir` first.
---@param lnum integer
---@param ids string[]
---@param dir 1|-1
---@return integer? lnum
---@return string? id
function Drawer:find(lnum, ids, dir)
    local rows = self.rows

    for _, step in ipairs({ dir, -dir }) do
        local l = math.min(lnum, #rows)

        while l >= 1 and l <= #rows do
            for _, id in ipairs(ids) do
                if rows[l][id] ~= nil then
                    return l, id
                end
            end

            l = l + step
        end
    end

    return nil, nil
end

--- Line and column of the item at `path`, an absolute file path, looking in
--- column `first` before the others.
---@param path? string
---@param first? IterSide
---@return { lnum: integer, side: IterSide }?
function Drawer:find_path(path, first)
    if path == nil or path == '' then
        return nil
    end

    for _, side in ipairs(self:column_ids(first)) do
        for lnum, row in ipairs(self.rows) do
            local item = row[side]

            if
                item ~= nil
                and vim.fs.joinpath(self.changes.root, item.path) == path
            then
                return { lnum = lnum, side = side }
            end
        end
    end

    return nil
end

--- Select the item on `lnum` in `column`, mark its cell and follow it with
--- the preview.
---@param lnum integer
---@param column string
function Drawer:select(lnum, column)
    local cell = self.cells[lnum] and self.cells[lnum][column]

    if cell == nil then
        return
    end

    local switched = column ~= self.column

    self.lnum, self.column = lnum, column

    if switched and self.float ~= nil then
        self.float:reposition({ footer = self:footer() })
    end

    vim.api.nvim_buf_clear_namespace(self.buf, SELECTED_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(self.buf, SELECTED_NS, lnum - 1, cell.first, {
        end_col = cell.last,
        hl_group = 'IterDrawerSelected',
        priority = 100,
    })

    local win = self.win

    if win ~= nil and util.is_valid_win(win) then
        local cursor = vim.api.nvim_win_get_cursor(win)

        if cursor[1] ~= lnum or cursor[2] ~= cell.first then
            vim.api.nvim_win_set_cursor(win, { lnum, cell.first })
        end
    end

    local item = self:selected()

    if item ~= nil and key(item) ~= self.preview.previewed then
        self:schedule_preview()
    end
end

--- Select the item nearest to the cursor of `win`, the drawer's window,
--- among the columns it moves through: all of them stacked, else the
--- selected one.
---@param win integer
function Drawer:follow_cursor(win)
    if not util.is_valid_win(win) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local dir = lnum < self.lnum and -1 or 1
    local ids = self.layout == 'stacked' and self:column_ids()
        or { self.column }

    local target, side = self:find(lnum, ids, dir)

    if target ~= nil and side ~= nil then
        self:select(target, side)
    end
end

--- Select the item nearest to the selected line in column `column`.
---@param column string
function Drawer:switch(column)
    local lnum, side = self:find(self.lnum, { column }, 1)

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

--- Switch to the nearest column with items left (`dir` -1) or right (1) of
--- the selected one; at the first or last such column, stay.
---@param dir 1|-1
function Drawer:step_column(dir)
    local ids = self:column_ids()
    local index = dir

    for i, id in ipairs(ids) do
        if id == self.column then
            index = i + dir
        end
    end

    while ids[index] ~= nil do
        if #self:item_lines(ids[index]) > 0 then
            return self:switch(ids[index])
        end

        index = index + dir
    end
end

--- Select the marked item again when it is still there.
---@param mark IterDrawerMark
---@return boolean selected
function Drawer:recall_selection(mark)
    for _, lnum in ipairs(self:item_lines(mark.column)) do
        if self.rows[lnum][mark.column].path == mark.key then
            self:select(lnum, mark.column)
            return true
        end
    end

    return false
end

--- Lines that hold an item of `column`, top to bottom.
---@param column string
---@return integer[]
function Drawer:item_lines(column)
    local lines = {}

    for lnum, row in ipairs(self.rows) do
        if row[column] ~= nil then
            table.insert(lines, lnum)
        end
    end

    return lines
end

---@class IterDrawerMark selection to restore after a render
---@field column string
---@field key? string path of the file
---@field index integer position among the column's items

---@return IterDrawerMark
function Drawer:mark()
    local item = self:selected()
    local index = 1

    for i, lnum in ipairs(self:item_lines(self.column)) do
        if lnum <= self.lnum then
            index = i
        end
    end

    return {
        column = self.column,
        key = item and item.path,
        index = index,
    }
end

--- Select the marked item again, else the item now at its position in the
--- column, else the nearest item of the other column.
---@param target? IterDrawerMark|{ lnum: integer, side: string }
function Drawer:restore_selection(target)
    if target ~= nil and target.lnum ~= nil then
        return self:select(target.lnum, target.side)
    end

    local column = target and target.column or self.column
    local lines = self:item_lines(column)

    if
        target ~= nil
        and target.key ~= nil
        and self:recall_selection(target --[[@as IterDrawerMark]])
    then
        return
    end

    if #lines > 0 then
        local index = math.min(target and target.index or 1, #lines)
        return self:select(lines[index], column)
    end

    local lnum, side = self:find(self.lnum, self:column_ids(column), 1)

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

function Drawer:resized()
    if not self:is_open() then
        return
    end

    self.preview:resized()

    local mark = self:mark()
    self:render()
    self:restore_selection(mark)
    self.view:even_widths()
    self.view:rewrap()
end

--- Reload the status, keep the selection on its path, or select `target`
--- when it is still there, and show its diff afresh. A poll that finds the
--- files unchanged leaves the diff as it is and renders only when the
--- recent commits or their ages changed.
---@param reason? IterWatchReason nil after an action of the drawer
---@param target? { path: string, side: IterSide } absolute path, side first
function Drawer:refresh(reason, target)
    if not self:is_open() then
        return
    end

    local before, before_recent = self.changes, self.recent
    local mark = self:mark()
    if not self:load() then
        return
    end

    local same = vim.deep_equal(before, self.changes)

    if reason == 'poll' and same then
        if
            self.recent ~= before_recent
            or layout.commit_ages(self.recent) ~= self.ages
        then
            self:render()
            self:restore_selection(mark)
        end

        return
    end

    self:render()
    self:restore_selection(
        target and self:find_path(target.path, target.side) or mark
    )
    self:show_selection(true)

    if reason == nil or not same then
        util.emit('IterRefresh', {
            root = self.changes.root,
            paths = changes.paths(self.changes),
        })
    end
end

--- Reload after a git action and show the selection's new diff.
---@param ok boolean
---@param err? string
---@param fallback string
function Drawer:refresh_after(ok, err, fallback)
    if not ok then
        util.error(err, fallback)
    end

    self:refresh()
end

--- Preview the selection after `PREVIEW_DELAY_MS`, replacing a preview
--- scheduled before that still waits.
function Drawer:schedule_preview()
    if self.closed then
        return
    end

    self.preview_timer = self.preview_timer or assert(vim.uv.new_timer())
    self.preview_timer:stop()
    self.preview_timer:start(
        PREVIEW_DELAY_MS,
        0,
        vim.schedule_wrap(function()
            if not self.closed then
                self:show_selection(false)
            end
        end)
    )
end

--- Show the selected file's diff in the pane. Directories leave the pane
--- as it is; without a selection the pane gets its own buffer back.
---@param force boolean also when the view already shows the item
function Drawer:show_selection(force)
    local item = self:selected()

    if not self:is_open() then
        return
    end

    if item == nil then
        self.preview.previewed = nil
        self.view:hide()
        return
    end

    self.view:set_focus(nil)
    self.preview:show({ item }, force)
end

--- Show every file in one buffer (`on`), or the selected one alone. The
--- file under the cursor stays under it, near its row.
---@param on boolean
function Drawer:set_all_files(on)
    if on == self.preview.all_files then
        return
    end

    local item = self:selected()

    self.preview:set_all_files(on, item and { item } or nil)

    if self.float ~= nil then
        self.float:reposition({ footer = self:footer() })
    end
end

--- Select the file under the cursor of the all-files view in the drawer,
--- without showing it again.
function Drawer:follow_view()
    if not self.preview.all_files or not self:is_open() then
        return
    end

    local file = self.view:file()

    if file == nil then
        return
    end

    local k = key(file)

    local item = self:selected()

    if item ~= nil and key(item) == k then
        return
    end

    for lnum, row in ipairs(self.rows) do
        local candidate = row[file.side]

        if candidate ~= nil and key(candidate) == k then
            self.preview.previewed = k
            self:select(lnum, file.side)
            return
        end
    end
end

--- What the file actions work on.
---@return IterFileActionContext
function Drawer:action_context()
    return { changes = self.changes, config = self.config }
end

--- Refresh after `result`, an action's, and fire `User IterStage` for it.
---@param result? IterFileActionResult
function Drawer:after_action(result)
    if result == nil then
        return
    end

    self:refresh_after(result.ok, result.err, result.fallback)

    if result.action ~= nil then
        self:staged(result.ok, result.action, result.paths)
    end
end

function Drawer:stage()
    local item = self:selected()

    if item ~= nil then
        self:after_action(file_actions.stage(self:action_context(), { item }))
    end
end

function Drawer:unstage()
    local item = self:selected()

    if item ~= nil then
        self:after_action(file_actions.unstage(self:action_context(), { item }))
    end
end

--- Discard the unstaged changes of the selection after a confirm.
function Drawer:discard()
    local item = self:selected()

    if item ~= nil then
        self:after_action(file_actions.discard(self:action_context(), item))
    end
end

--- Fire `User IterStage` for `paths` when the `action` on them succeeded.
---@param ok boolean
---@param action 'stage'|'unstage'|'discard'
---@param paths string[]
function Drawer:staged(ok, action, paths)
    if ok then
        util.emit('IterStage', {
            root = self.changes.root,
            paths = paths,
            action = action,
        })
    end
end

--- Append the selected untracked path to the `.gitignore` at the root,
--- after a confirm.
function Drawer:ignore()
    local item = self:selected()

    if item ~= nil then
        self:after_action(file_actions.ignore(self:action_context(), item))
    end
end

--- Close the drawer and edit `rel`, a path of the repository, in the pane,
--- at `line` when given. A deleted file keeps the drawer open.
---@param rel string
---@param line? integer
function Drawer:edit(rel, line)
    local path = vim.fs.joinpath(self.changes.root, rel)

    if vim.uv.fs_stat(path) == nil then
        util.warn(rel .. ' is deleted')
        return
    end

    if not util.can_leave(self.view.prev_buf, path) then
        return
    end

    self:close()
    util.edit_at(path, line, rel)
end

--- Close the drawer and edit the selected file in the pane. A deleted file
--- keeps the drawer open.
function Drawer:open_file()
    local item = self:selected()

    if item == nil or item.dir then
        return
    end

    self:edit(item.path)
end

--- Close the drawer and open the review tab on the selected file.
function Drawer:open_review()
    local item = self:selected()
    local target

    if item ~= nil and not item.dir then
        target = { path = vim.fs.joinpath(self.changes.root, item.path) }
    end

    self:close()
    require('iter').review(target)
end

--- Select the file at `path`, relative to the root, and show its diff;
--- warn when it isn't in the changes.
---@param path string
function Drawer:reveal(path)
    local at = self:find_path(vim.fs.joinpath(self.changes.root, path))
    local item = at and self.rows[at.lnum][at.side]

    if item == nil or item.dir then
        util.warn(path .. ' is not in the changes')
        return
    end

    ---@cast at -nil
    self:select(at.lnum, at.side)
    self:show_selection(false)
end

--- Files in drawer order, directories left out.
---@return IterChange[]
function Drawer:files()
    return vim.tbl_filter(function(item)
        return not item.dir
    end, self:ordered())
end

--- Close the float and give the pane back its buffer and options.
function Drawer:close()
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

    self.float:close()
    self.preview:close()

    for _, buf in pairs({ self.buf, self.section_buf }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    if util.is_valid_win(self.pane) then
        vim.api.nvim_set_current_win(self.pane)
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

--- Focus the drawer again and reload its items.
function Drawer:focus()
    if util.is_valid_win(self.win) then
        vim.api.nvim_set_current_win(self.win)
    end

    self:refresh()
end

--- Open the help float with the drawer's keys, or close it.
function Drawer:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    self.help = help.open({
        view = 'drawer',
        keys = self.keys,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

return Drawer
