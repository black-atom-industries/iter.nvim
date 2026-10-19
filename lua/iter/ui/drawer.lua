local changes = require('iter.changes')
local document = require('iter.diff.document')
local float = require('iter.ui.float')
local git = require('iter.git')
local help = require('iter.ui.help')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local model = require('iter.diff.model')
local render = require('iter.ui.render')
local util = require('iter.util')
local View = require('iter.diff.view')
local watch = require('iter.watch')

---@alias IterDrawerRow table<string, any> buffer line → item per column id: an IterChange in a file column, the extras' items in their columns

---@class IterDrawerColumnSpec: IterLayoutColumn a column the extras add after the file columns
---@field hints [string, string][] key hints while the column is selected: action and label

---@class IterDrawerExtras what a context such as the review tab adds to the drawer
---@field drawer_load fun(self, drawer: IterDrawer): boolean after a status read, before the first render with the view in place; true when what it shows changed
---@field drawer_decorator fun(self, drawer: IterDrawer): fun(item: IterChange): IterLayoutDecor per render, the decor of each file row
---@field drawer_columns fun(self, drawer: IterDrawer): IterDrawerColumnSpec[] per render, columns right of the file columns; their items carry a unique `key`
---@field drawer_preview fun(self, drawer: IterDrawer, item: any, force: boolean) shows an item of those columns in the view
---@field drawer_header fun(self, drawer: IterDrawer, summary: [string, string], room: integer): [string, string][] header chunks after the branch, in place of `summary`, in `room` cells
---@field drawer_rendered fun(self, drawer: IterDrawer, lines: integer) after the layout, before the buffer is written
---@field drawer_shown fun(self, drawer: IterDrawer) after the view showed the selection or the drawer rendered
---@field drawer_handlers fun(self, drawer: IterDrawer, handlers: table<string, fun()>) changes the drawer actions in place
---@field drawer_collapsed fun(self, drawer: IterDrawer, item: IterChange): boolean in all-files mode, whether the file shows its header row alone

---@class IterDrawerOpenOptions
---@field pane integer window the float is anchored to
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field side? IterSide side to look for `path` on first
---@field context? 'status'|'review'
---@field extras? IterDrawerExtras
---@field view_win? integer window the diff view borrows, the pane by default
---@field view_handlers? table<string, fun()> diff view actions
---@field height? number float height, `drawer.height` by default
---@field on_close? fun(drawer: IterDrawer)

---@class IterDrawer
---@field context 'status'|'review'
---@field extras? IterDrawerExtras
---@field keys_view IterView view whose keys the drawer maps
---@field keys table<string, string[]>
---@field pane integer
---@field win integer
---@field buf integer
---@field float IterFloat
---@field view IterDiffView diff of the selected file, shown in the pane
---@field watch? IterWatch refreshes the drawer on external changes
---@field help? IterHelp
---@field handlers table<string, fun()> drawer actions by name
---@field config IterConfig
---@field changes IterChanges
---@field recent? GitRecent the status drawer's recent commits, nil in the review or without a commit
---@field ages string the commit ages of the last render
---@field section_buf? integer buffer of the Recent commits, pinned under the files
---@field rows IterDrawerRow[]
---@field cells table<string, IterLayoutCell>[]
---@field side_buf? integer buffer of the extras' columns in a window of their own, in the review
---@field side_rows IterDrawerRow[] per line of `side_buf`, as `rows`
---@field side_cells table<string, IterLayoutCell>[]
---@field split boolean whether the extras' columns show in the side window
---@field extra IterDrawerColumnSpec[] the extras' columns of the last render
---@field column string id of the selected column
---@field lnum integer selected line
---@field layout IterLayoutMode
---@field recall table<string, IterDrawerMark> per stop, by its first column id, the selection it had when left
---@field previewed? string key of the item the view shows, or of the extras' item that showed it
---@field previewed_stat? string worktree stat of that item when it was read, of every file in all-files mode
---@field all_files boolean the view shows every file, in the review
---@field all_shown boolean the view's document is the all-files one
---@field diff_ids? table<string, string> per file key, the blob ids and worktree stat its shown diff was read with
---@field preview_tick integer bumped per scheduled preview; only the last one runs
---@field group integer
---@field closed boolean
---@field on_close? fun(drawer: IterDrawer)
local Drawer = {}
Drawer.__index = Drawer

-- Text lines the drawer keeps in a pane too short for `drawer.height`.
Drawer.MIN_LINES = 5

local SELECTED_NS = vim.api.nvim_create_namespace('iter.drawer.selected')
local PREVIEW_DELAY_MS = 50
-- Width share of the stacked file columns beside the extras' columns.
local FILES_WEIGHT = 3
-- Diff rows that stand for a line of the file.
local CODE_ROWS = { context = true, del = true, add = true }
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

---@param item IterChange|IterFileDiff
---@return string
local function key(item)
    return item.side .. '\0' .. item.path
end

--- The key of an item of any column: an extras' item carries its own.
---@param item any
---@return string
local function item_key(item)
    return item.key or key(item)
end

---@class IterDrawerColumn
---@field id IterSide
---@field title string
---@field items IterChange[]

--- The columns left to right, each listing the changes of its side.
---@return IterDrawerColumn[]
function Drawer:columns()
    local result = self.changes

    return {
        { id = 'unstaged', title = 'Unstaged', items = result.unstaged },
        { id = 'staged', title = 'Staged', items = result.staged },
    }
end

--- Column ids left to right, `first` moved to the front when given. With
--- `all`, the extras' columns follow the file columns.
---@param first? string
---@param all? boolean
---@return string[]
function Drawer:column_ids(first, all)
    local ids = first and { first } or {}
    local columns = self:columns()

    if all then
        vim.list_extend(columns, self.extra)
    end

    for _, column in ipairs(columns) do
        if column.id ~= first then
            table.insert(ids, column.id)
        end
    end

    return ids
end

--- Whether the file columns share one column, Unstaged above Staged: in
--- the review's columns layout.
---@return boolean
function Drawer:files_stacked()
    return self.context == 'review' and self.layout == 'columns'
end

--- The columns `h` and `l` step between, left to right, each a list of
--- column ids: the stacked file columns are one stop.
---@return string[][]
function Drawer:stops()
    local stops = {}

    if self:files_stacked() then
        table.insert(stops, self:column_ids())
    else
        for _, id in ipairs(self:column_ids()) do
            table.insert(stops, { id })
        end
    end

    for _, column in ipairs(self.extra) do
        table.insert(stops, { column.id })
    end

    return stops
end

--- The stop that holds column `id`, and its index.
---@param id string
---@return string[] ids
---@return integer index
function Drawer:stop_of(id)
    local stops = self:stops()

    for i, ids in ipairs(stops) do
        if vim.list_contains(ids, id) then
            return ids, i
        end
    end

    return { id }, 1
end

--- The extras' column `id`, nil for a file column.
---@param id string
---@return IterDrawerColumnSpec?
function Drawer:extra_column(id)
    for _, column in ipairs(self.extra) do
        if column.id == id then
            return column
        end
    end

    return nil
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

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

--- The status drawer's header in `width` cells: `HEAD <branch>  ↑n ↓m
--- <upstream>` and `summary` at the right edge, `↑`, `↓` and the upstream
--- only when there are. Too wide, it sheds from the right: the summary
--- shrinks to `total`, then goes, then the upstream, then the arrows;
--- `HEAD <branch>` always stays.
---@param drawer IterDrawer
---@param summary string
---@param total string
---@param width integer
---@return [string, string][]
local function status_header(drawer, summary, total, width)
    local recent = drawer.recent
    local head = {
        { 'HEAD ', 'IterDrawerHint' },
        {
            drawer.changes.branch == 'HEAD' and '(detached)'
                or drawer.changes.branch,
            'IterHead',
        },
    }
    local arrows, upstream = {}, {}

    if recent ~= nil and recent.upstream ~= nil then
        if recent.ahead > 0 then
            table.insert(arrows, { '  ↑' .. recent.ahead, 'IterUnpushed' })
        end

        if recent.behind > 0 then
            local gap = #arrows > 0 and ' ' or '  '
            table.insert(
                arrows,
                { gap .. '↓' .. recent.behind, 'IterBehind' }
            )
        end

        upstream = { { '  ' .. recent.upstream, 'IterDrawerHint' } }
    end

    local function build(parts, tail)
        local chunks = vim.deepcopy(head)

        for _, part in ipairs(parts) do
            vim.list_extend(chunks, part)
        end

        if tail ~= nil then
            tail = tail .. ' '
            local pad = width
                - chunks_width(chunks)
                - vim.fn.strdisplaywidth(tail)

            if pad < 2 then
                return nil
            end

            table.insert(chunks, { string.rep(' ', pad), 'IterDrawerHint' })
            table.insert(chunks, { tail, 'IterDrawerHint' })
        elseif chunks_width(chunks) > width then
            return nil
        end

        return chunks
    end

    return build({ arrows, upstream }, summary)
        or build({ arrows, upstream }, total)
        or build({ arrows, upstream })
        or build({ arrows })
        or head
end

--- The status drawer: `status_header`, with `<n> changes` at the right edge.
--- The review: `HEAD <branch> ↑<ahead>`, `↑` only when HEAD is ahead of its
--- upstream, and the extras' chunks. A file in more than one column counts
--- once. Stacked, the counts are per column, since a lower title may sit
--- below the visible lines.
---@param drawer IterDrawer
---@return [string, string][]
local function header_chunks(drawer)
    local result = drawer.changes
    local columns = drawer:columns()
    local count = #changes.paths(result)
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

    local width = vim.api.nvim_win_get_width(drawer.pane)

    if drawer.context == 'status' then
        return status_header(drawer, table.concat(parts, ' · '), total, width)
    end

    local chunks = {
        { 'HEAD ', 'IterDrawerHint' },
        {
            result.branch == 'HEAD' and '(detached)' or result.branch,
            'IterHead',
        },
    }

    if result.ahead ~= nil and result.ahead > 0 then
        table.insert(chunks, { ' ↑' .. result.ahead, 'IterUnpushed' })
    end

    local tail = { ' · ' .. table.concat(parts, ' · '), 'IterDrawerHint' }

    vim.list_extend(
        chunks,
        drawer.extras:drawer_header(drawer, tail, width - chunks_width(chunks))
    )

    return chunks
end

---@param opts IterDrawerOpenOptions
---@return IterDrawer?
function Drawer.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.side', opts.side, 'string', true)
    vim.validate('opts.context', opts.context, 'string', true)
    vim.validate('opts.extras', opts.extras, 'table', true)
    vim.validate('opts.view_win', opts.view_win, 'number', true)
    vim.validate('opts.view_handlers', opts.view_handlers, 'table', true)
    vim.validate('opts.height', opts.height, 'number', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local view_win = opts.view_win or opts.pane

    if not util.can_leave(vim.api.nvim_win_get_buf(view_win)) then
        return nil
    end

    highlight.setup()

    local context = opts.context or 'status'
    local review = context == 'review'
    local buf = vim.api.nvim_create_buf(false, true)
    -- The review keeps the buffer when another one takes the float, and puts
    -- it back.
    vim.bo[buf].bufhidden = review and 'hide' or 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    util.name_buf(buf, review and 'iter://review' or ('iter://drawer/' .. buf))

    local keys_view = context == 'review' and 'review_drawer' or 'drawer'

    local self = setmetatable({
        context = context,
        extras = opts.extras,
        keys_view = keys_view,
        keys = opts.config.keys[keys_view],
        pane = opts.pane,
        buf = buf,
        config = opts.config,
        rows = {},
        cells = {},
        side_rows = {},
        side_cells = {},
        split = false,
        extra = {},
        ages = '',
        column = 'unstaged',
        lnum = 1,
        layout = 'columns',
        recall = {},
        preview_tick = 0,
        all_files = false,
        all_shown = false,
        closed = false,
        on_close = opts.on_close,
    }, Drawer)

    if review then
        self.side_buf = vim.api.nvim_create_buf(false, true)
        vim.bo[self.side_buf].bufhidden = 'hide'
        vim.bo[self.side_buf].modifiable = false
        vim.bo[self.side_buf].filetype = 'iter'
        util.name_buf(self.side_buf, 'iter://review-annotations')
    end

    local view_handlers = vim.tbl_extend('force', opts.view_handlers or {}, {
        focus_drawer = function()
            if util.is_valid_win(self.win) then
                vim.api.nvim_set_current_win(self:selection_win())
            end
        end,
    })

    if not review then
        view_handlers.expand = function()
            self:open_row()
        end
    end

    -- The review's diff pane belongs to the view, so a buffer that takes its
    -- place only hides it, and the review puts it back.
    self.view = View.new({
        win = view_win,
        keys = opts.config.keys.diff,
        handlers = view_handlers,
        name = review and 'iter://review-diff' or nil,
        bufhidden = review and 'hide' or nil,
        on_cursor = function()
            self:follow_view()
        end,
        on_layout = function()
            if self.float ~= nil and not self.closed then
                self.float:reposition({ footer = self:footer() })
            end
        end,
    })

    if not self:load() then
        self.view:close()

        for _, b in pairs({ buf, self.side_buf }) do
            vim.api.nvim_buf_delete(b, { force = true })
        end

        return nil
    end

    self.handlers = self:make_handlers()
    self.float = float.open({
        pane = opts.pane,
        buf = buf,
        zindex = opts.config.options.drawer.zindex,
        height = opts.height or opts.config.options.drawer.height,
        enter = true,
        chrome = true,
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
    self:preview(true)
    self.watch = watch.start({
        root = self.changes.root,
        poll_ms = opts.config.options.refresh.poll_ms,
        on_change = function(reason)
            self:refresh(reason)
        end,
    })

    return self
end

--- Scroll the diff above the drawer by half a page, or by the count, and
--- leave the cursor and focus in the drawer.
---@param keys string `<C-d>` or `<C-u>`
function Drawer:scroll(keys)
    local win = self.view.win

    if not util.is_valid_win(win) then
        return
    end

    local count = vim.v.count > 0 and vim.v.count or ''
    local cmd = 'normal! ' .. count .. vim.keycode(keys)

    vim.api.nvim_win_call(win, function()
        vim.cmd(cmd)
    end)
    -- Scrollbind follows only the current window.
    self.view:sync(self.view)
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
        close = act('close'),
        help = act('toggle_help'),
        scroll_down = function()
            self:scroll('<C-d>')
        end,
        scroll_up = function()
            self:scroll('<C-u>')
        end,
        column_left = function()
            self:step_column(-1)
            self:take_focus()
        end,
        column_right = function()
            self:step_column(1)
            self:take_focus()
        end,
    }

    if self.extras ~= nil then
        self.extras:drawer_handlers(self, handlers)
    end

    return handlers
end

function Drawer:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.drawer.' .. self.buf,
        { clear = true }
    )

    for _, buf in ipairs({ self.buf, self.side_buf }) do
        vim.api.nvim_create_autocmd('CursorMoved', {
            group = self.group,
            buffer = buf,
            callback = function()
                self:follow_cursor(vim.api.nvim_get_current_win())
            end,
        })
        keymap.attach(buf, self.keys_view, self.keys, self.handlers)
    end

    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        callback = function(args)
            local win = tonumber(args.match)

            if win ~= nil and win == self.float.side_win then
                vim.schedule(function()
                    self:close()
                end)
            end
        end,
    })
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
end

---@return boolean
function Drawer:is_open()
    return not self.closed and util.is_valid_win(self.win)
end

--- Read the status afresh, keeping open directories open, then the extras.
--- Once loaded, the drawer stays on its root whatever the cwd becomes.
---@return boolean loaded
---@return boolean extras_changed
function Drawer:load()
    local status = self.context == 'status'
    local snapshot = git.status_snapshot(
        self.changes and self.changes.root or nil,
        { ahead = not status }
    )

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false, false
    end

    self.changes = changes.build(snapshot)
    require('iter.statusline').update(self.changes)

    if status then
        self.recent = git.recent(
            snapshot.root,
            self.config.options.drawer.commits,
            self.recent
        )
    end

    if self.extras == nil then
        return true, false
    end

    return true, self.extras:drawer_load(self)
end

--- The ages the Recent commits rows show now, joined.
---@param recent? GitRecent
---@return string
local function commit_ages(recent)
    if recent == nil then
        return ''
    end

    local now = os.time()

    return table.concat(
        vim.tbl_map(function(commit)
            return layout.age(now - commit.time)
        end, recent.commits),
        ' '
    )
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
    local width = vim.api.nvim_win_get_width(self.pane)
    local decorate = self.extras and self.extras:drawer_decorator(self)
    ---@type IterLayoutSlot[]
    local columns = vim.tbl_map(function(column)
        ---@type IterLayoutColumn
        return {
            id = column.id,
            title = column.title,
            items = column.items,
            cell = function(line, item, first, cell_width)
                return layout.file_cell(
                    line,
                    item,
                    first,
                    cell_width,
                    decorate and decorate(item)
                )
            end,
        }
    end, self:columns())

    self.extra = self.extras and self.extras:drawer_columns(self) or {}
    self.layout = layout.mode(width, self.config.options.drawer.breakpoint)

    if self:files_stacked() then
        columns = { { sections = columns, weight = FILES_WEIGHT } }
    end

    vim.list_extend(columns, self.extra)

    local built, side

    if #self:ordered() == 0 and #self.extra == 0 then
        built = layout.message('Working tree clean')
    elseif self:files_stacked() and self.side_buf ~= nil then
        side = layout.split(columns, width)
        built = side.left
    elseif self.layout == 'columns' then
        built = layout.columns(columns, width)
    else
        built = layout.stacked(columns, width)
    end

    self.rows, self.cells = built.rows, built.cells
    self.split = side ~= nil
    self.side_rows = side and side.right.rows or {}
    self.side_cells = side and side.right.cells or {}

    -- The side window closes below the breakpoint: the drawer keeps focus.
    if
        side == nil
        and self.float.side_win ~= nil
        and vim.api.nvim_get_current_win() == self.float.side_win
        and util.is_valid_win(self.win)
    then
        vim.api.nvim_set_current_win(self.win)
    end

    if self.extras ~= nil then
        self.extras:drawer_rendered(self, #built.lines)
    end

    write(self.buf, built.lines)

    if side ~= nil then
        write(self.side_buf, side.right.lines)
    end

    self.float:reposition({
        min_lines = math.min(#built.lines, Drawer.MIN_LINES),
        strip = self:render_section(width),
        side = side ~= nil and { buf = self.side_buf, col = side.col },
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

    self.ages = commit_ages(self.recent)

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

--- The key hint line of the selected column.
---@return [string, string][]
function Drawer:footer()
    local column = self:extra_column(self.column)
    local hints = column and column.hints
        or vim.tbl_map(function(hint)
            if hint[1] == 'mode' and self.all_files then
                return { 'mode', 'one file' }
            elseif hint[1] == 'split' and self.view.layout == 'split' then
                return { 'unified', 'unified' }
            end

            return hint
        end, HINTS)

    -- The footer starts one cell in from the float's left edge.
    return layout.hints(
        keymap.list(self.keys_view, self.keys, self.handlers),
        hints,
        vim.api.nvim_win_get_width(self.pane) - 1
    )
end

--- Let the extras follow what the view shows.
function Drawer:shown()
    if self.extras ~= nil then
        self.extras:drawer_shown(self)
    end
end

---@class IterDrawerGrid the lines of one drawer window
---@field rows IterDrawerRow[]
---@field cells table<string, IterLayoutCell>[]
---@field buf integer
---@field win? integer

--- The lines column `id` shows on: the side window's for an extras' column
--- while it is split off, else the drawer's.
---@param id string
---@return IterDrawerGrid
function Drawer:grid(id)
    if self.split and self:extra_column(id) ~= nil then
        return {
            rows = self.side_rows,
            cells = self.side_cells,
            buf = self.side_buf,
            win = self.float and self.float.side_win,
        }
    end

    return {
        rows = self.rows,
        cells = self.cells,
        buf = self.buf,
        win = self.win,
    }
end

--- The window of the selection: the side window while an extras' column
--- in it is selected, else the drawer's.
---@return integer
function Drawer:selection_win()
    local win = self:grid(self.column).win

    return util.is_valid_win(win) and win or self.win
end

--- Move the focus to the window of the selection when it is in the
--- drawer's other window.
function Drawer:take_focus()
    local current = vim.api.nvim_get_current_win()

    if current == self.win or current == self.float.side_win then
        vim.api.nvim_set_current_win(self:selection_win())
    end
end

--- The selected item of any column.
---@return any
function Drawer:item()
    local row = self:grid(self.column).rows[self.lnum]

    return row and row[self.column]
end

--- The selected file; nil when the selection is in an extras' column.
---@return IterChange?
function Drawer:selected()
    if self:extra_column(self.column) ~= nil then
        return nil
    end

    return self:item()
end

--- The line nearest to `lnum` that holds an item of one of the columns
--- `ids`, looking in direction `dir` first.
---@param lnum integer
---@param ids string[]
---@param dir 1|-1
---@return integer? lnum
---@return string? id
function Drawer:find(lnum, ids, dir)
    local order, by_rows = {}, {}

    for _, id in ipairs(ids) do
        local rows = self:grid(id).rows

        if by_rows[rows] == nil then
            by_rows[rows] = {}
            table.insert(order, rows)
        end

        table.insert(by_rows[rows], id)
    end

    for _, rows in ipairs(order) do
        for _, step in ipairs({ dir, -dir }) do
            local l = math.min(lnum, #rows)

            while l >= 1 and l <= #rows do
                for _, id in ipairs(by_rows[rows]) do
                    if rows[l][id] ~= nil then
                        return l, id
                    end
                end

                l = l + step
            end
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
    local grid = self:grid(column)
    local cell = grid.cells[lnum] and grid.cells[lnum][column]

    if cell == nil then
        return
    end

    local switched = column ~= self.column

    self.lnum, self.column = lnum, column

    if switched and self.float ~= nil then
        self.float:reposition({ footer = self:footer() })
    end

    for _, buf in ipairs({ self.buf, self.side_buf }) do
        vim.api.nvim_buf_clear_namespace(buf, SELECTED_NS, 0, -1)
    end

    vim.api.nvim_buf_set_extmark(grid.buf, SELECTED_NS, lnum - 1, cell.first, {
        end_col = cell.last,
        hl_group = 'IterDrawerSelected',
        priority = 100,
    })

    local win = grid.win

    if win ~= nil and util.is_valid_win(win) then
        local cursor = vim.api.nvim_win_get_cursor(win)

        if cursor[1] ~= lnum or cursor[2] ~= cell.first then
            vim.api.nvim_win_set_cursor(win, { lnum, cell.first })
        end
    end

    local item = self:item()

    if item ~= nil and item_key(item) ~= self.previewed then
        self:schedule_preview()
    end
end

--- Select the item nearest to the cursor of `win`, the drawer's window or
--- the side window, among the columns it moves through.
---@param win integer
function Drawer:follow_cursor(win)
    if not util.is_valid_win(win) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local dir = lnum < self.lnum and -1 or 1
    local ids

    if self.layout == 'stacked' then
        ids = self:column_ids(nil, true)
    elseif self.split then
        ids = win == self.float.side_win
                and vim.tbl_map(function(column)
                    return column.id
                end, self.extra)
            or self:column_ids()
    else
        ids = self:stop_of(self.column)
    end

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

--- Switch to the nearest stop with items left (`dir` -1) or right (1) of
--- the selected one; at the first or last such stop, stay. With the file
--- columns stacked, a stop selects again what it had when it was left.
---@param dir 1|-1
function Drawer:step_column(dir)
    local stops = self:stops()
    local current, index = self:stop_of(self.column)

    index = index + dir

    while stops[index] ~= nil do
        local ids = stops[index]

        for _, id in ipairs(ids) do
            if #self:item_lines(id) > 0 then
                if not self:files_stacked() then
                    return self:switch(id)
                end

                self.recall[current[1]] = self:mark()

                local recalled = self.recall[ids[1]]

                if recalled ~= nil and self:recall_selection(recalled) then
                    return
                end

                local lnum, side = self:find(self.lnum, ids, 1)

                if lnum ~= nil and side ~= nil then
                    self:select(lnum, side)
                end

                return
            end
        end

        index = index + dir
    end
end

--- Select the marked item again when it is still there.
---@param mark IterDrawerMark
---@return boolean selected
function Drawer:recall_selection(mark)
    local rows = self:grid(mark.column).rows

    for _, lnum in ipairs(self:item_lines(mark.column)) do
        local item = rows[lnum][mark.column]

        if (item.key or item.path) == mark.key then
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

    for lnum, row in ipairs(self:grid(column).rows) do
        if row[column] ~= nil then
            table.insert(lines, lnum)
        end
    end

    return lines
end

---@class IterDrawerMark selection to restore after a render
---@field column string
---@field key? string path of a file, `key` of an extras' item
---@field index integer position among the column's items

---@return IterDrawerMark
function Drawer:mark()
    local item = self:item()
    local index = 1

    for i, lnum in ipairs(self:item_lines(self.column)) do
        if lnum <= self.lnum then
            index = i
        end
    end

    return {
        column = self.column,
        key = item and (item.key or item.path),
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

    local lnum, side = self:find(self.lnum, self:stop_of(column), 1)

    if lnum == nil then
        lnum, side = self:find(self.lnum, self:column_ids(nil, true), 1)
    end

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

function Drawer:resized()
    if not self:is_open() then
        return
    end

    local mark = self:mark()
    self:render()
    self:restore_selection(mark)
    self:take_focus()
    self.view:even_widths()
    self.view:rewrap()
end

--- Reload the status, keep the selection on its path, or select `target`
--- when it is still there, and show its diff afresh. A poll that finds the
--- files unchanged leaves the diff as it is and renders only when the
--- extras, the recent commits or their ages changed.
---@param reason? IterWatchReason nil after an action of the drawer
---@param target? { path: string, side: IterSide } absolute path, side first
function Drawer:refresh(reason, target)
    if not self:is_open() then
        return
    end

    local before, before_recent = self.changes, self.recent
    local mark = self:mark()
    local loaded, extras_changed = self:load()

    if not loaded then
        return
    end

    local same = vim.deep_equal(before, self.changes)

    if reason == 'poll' and same then
        local item = self:selected()

        if
            extras_changed
            or self.recent ~= before_recent
            or commit_ages(self.recent) ~= self.ages
        then
            self:render()
            self:restore_selection(mark)
        end

        -- The review's diff also follows writes from outside Neovim, which
        -- leave the status as it was.
        if
            self.context == 'review'
            and item ~= nil
            and key(item) == self.previewed
            and self:stat(item) ~= self.previewed_stat
        then
            self:preview(true)
        end

        return
    end

    self:render()
    self:restore_selection(
        target and self:find_path(target.path, target.side) or mark
    )
    self:preview(true)

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

function Drawer:schedule_preview()
    self.preview_tick = self.preview_tick + 1
    local tick = self.preview_tick

    vim.defer_fn(function()
        if tick == self.preview_tick then
            self:preview(false)
        end
    end, PREVIEW_DELAY_MS)
end

--- Show the selected file's diff in the pane, or let the extras show an
--- item of their columns. Directories leave the pane as it is; without a
--- selection the pane gets its own buffer back.
---@param force boolean also when the view already shows the item
function Drawer:preview(force)
    local item = self:item()

    if not self:is_open() then
        return
    end

    if item ~= nil and self:extra_column(self.column) ~= nil then
        if force or item.key ~= self.previewed then
            self.extras:drawer_preview(self, item, force)
            self.previewed = item.key
        end

        return
    end

    if item == nil then
        self.previewed = nil
        self.view:hide()
        return
    end

    self.view:set_focus(nil)
    self:show(item, force)
end

--- Show the diff of `item`, a file of the changes, in the pane, whether it
--- is selected or not.
---@param item IterChange
---@param force boolean also when the view already shows the item
function Drawer:show(item, force)
    if item.dir then
        return
    end

    if not force and key(item) == self.previewed then
        return
    end

    if self.all_files then
        self:show_all(item, force)
        return
    end

    local stat = self:stat(item)
    local source, err = git.file_diff(self.changes.root, item)

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed_stat = stat
    self.all_shown = false
    self.view:set_new_follows(
        item.side == 'staged' and not self:has_unstaged(item.path)
    )

    -- The same diff again keeps the view as it is, expanded gaps included.
    local shown = #self.view.files == 1 and self.view.files[1] or nil

    if
        self.view:is_shown()
        and shown ~= nil
        and shown.side == item.side
        and shown.path == item.path
        and shown.code == item.code
        and vim.deep_equal(shown.raw, source.raw)
    then
        self.previewed = key(item)
        self:shown()
        return
    end

    self.previewed = key(item)
    self.view:show(model.build(item, source))
    self:shown()
end

--- The worktree stat of `item`, of every file in all-files mode, to tell a
--- write from outside.
---@param item IterChange
---@return string
function Drawer:stat(item)
    local items = self.all_files and self:files() or { item }

    return table.concat(
        vim.tbl_map(function(file)
            return util.stat_key(vim.fs.joinpath(self.changes.root, file.path))
                or ''
        end, items),
        '\0'
    )
end

--- Read the diff of every file and show them in drawer order, a file the
--- extras collapse as its header row alone. A file whose
--- blob ids and worktree stat are the ones read before keeps its rows
--- without a read, as does one whose diff text is the one shown, expanded
--- gaps included; when every file does, the view stays as it is.
function Drawer:load_all()
    local view = self.view
    local root = self.changes.root
    local files = self:files()
    local before = {}

    if self.all_shown then
        for _, section in ipairs(view.document.sections) do
            before[section.key] = section
        end
    end

    self.previewed_stat = self:stat(files[1])

    local ids = git.diff_ids(root) or {}
    local known = self.diff_ids or {}

    self.diff_ids = {}

    ---@type IterDocEntry[]
    local entries = {}
    local same = self.all_shown
        and view:is_shown()
        and #files == #view.document.sections

    for index, item in ipairs(files) do
        local k = key(item)
        local shown = before[k]
        local id = (ids[k] or '')
            .. '\0'
            .. (
                item.side == 'unstaged'
                    and util.stat_key(vim.fs.joinpath(root, item.path))
                or ''
            )
        ---@type IterFileDiff?
        local file = shown ~= nil
                and shown.file.code == item.code
                and known[k] == id
                and shown.file
            or nil

        if not file then
            local source, err = git.file_diff(root, item)

            if source == nil then
                util.error(err, 'Cannot read the diff of ' .. item.path)
            else
                file = shown ~= nil
                        and shown.file.code == item.code
                        and vim.deep_equal(shown.file.raw, source.raw)
                        and shown.file
                    or model.build(item, source)
            end
        end

        if file then
            local new_follows = item.side == 'staged'
                and not self:has_unstaged(item.path)
            local collapsed = self.extras ~= nil
                    and self.extras:drawer_collapsed(self, item)
                or nil
            local section = view.document.sections[#entries + 1]

            same = same
                and section ~= nil
                and section.file == file
                and section.new_follows == new_follows
                and section.collapsed == collapsed
            self.diff_ids[k] = id
            table.insert(entries, {
                file = file,
                new_follows = new_follows,
                collapsed = collapsed,
            })
        else
            same = false
        end
    end

    self.all_shown = true

    if #entries == 0 then
        view:hide()
    elseif not same then
        view:show_all(entries)
    end
end

--- In all-files mode: show every file, read again with `force` or when the
--- view shows something else, then put `item`'s header at the top of the
--- pane, unless a forced read finds the cursor in `item` already.
---@param item IterChange
---@param force boolean
function Drawer:show_all(item, force)
    local view = self.view

    if force or not self.all_shown then
        self:load_all()
    elseif not view:is_shown() and #view.document.sections > 0 then
        view:show_document(view.document)
    end

    self.previewed = key(item)

    local index = document.find(view.document, key(item))
    local _, _, at = view:at()

    if index ~= nil and (not force or at ~= index) then
        view:reveal(view.document.sections[index].first, 'top')
    end

    self:shown()
end

--- Show every file in one buffer (`on`), or the selected one alone. The
--- file under the cursor stays under it, near its row.
---@param on boolean
function Drawer:set_all_files(on)
    if on == self.all_files then
        return
    end

    local target = self:selected()
    local shown = self.view:is_shown() and self.view:file() or nil

    if (target == nil or target.dir) and shown ~= nil then
        target = nil

        for _, item in ipairs(self:files()) do
            if key(item) == key(shown) then
                target = item
            end
        end
    end

    self.all_files = on
    self.all_shown = false

    if self.float ~= nil then
        self.float:reposition({ footer = self:footer() })
    end

    if target ~= nil then
        self:show(target, true)
    elseif on then
        self:load_all()
        self:shown()
    end
end

--- Select the file under the cursor of the all-files view in the drawer,
--- without showing it again. With an extras' column selected, the file
--- columns remember it for when they are selected again.
function Drawer:follow_view()
    if not self.all_files or not self:is_open() then
        return
    end

    local file = self.view:file()

    if file == nil then
        return
    end

    local k = key(file)

    if self:extra_column(self.column) ~= nil then
        self.recall[self:stop_of(file.side)[1]] =
            { column = file.side, key = file.path, index = 1 }
        return
    end

    local item = self:selected()

    if item ~= nil and key(item) == k then
        return
    end

    for lnum, row in ipairs(self.rows) do
        local candidate = row[file.side]

        if candidate ~= nil and key(candidate) == k then
            self.previewed = k
            self:select(lnum, file.side)
            return
        end
    end
end

---@param path string
---@return boolean
function Drawer:has_unstaged(path)
    for _, item in ipairs(self.changes.unstaged) do
        if item.path == path then
            return true
        end
    end

    return false
end

--- The files an action on `item` touches. A nested repository is left out.
---@param item IterChange
---@return string[]
function Drawer:paths(item)
    if item.dir then
        util.warn('Skipped the nested repository ' .. item.path)
        return {}
    end

    return { item.path }
end

function Drawer:stage()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.side == 'staged' then
        return self:unstage()
    end

    local paths = self:paths(item)

    if #paths == 0 then
        return
    end

    local ok, err = git.stage(self.changes.root, paths)
    self:refresh_after(ok, err, 'Cannot stage ' .. item.path)
    self:staged(ok, 'stage', paths)
end

function Drawer:unstage()
    local item = self:selected()

    if item == nil then
        return
    end

    local target = item.side == 'staged' and item or nil

    if target == nil then
        for _, staged in ipairs(self.changes.staged) do
            if staged.path == item.path then
                target = staged
            end
        end
    end

    if target == nil then
        util.warn('Nothing to unstage')
        return
    end

    local paths = { target.path }

    if target.orig_path ~= nil then
        table.insert(paths, 1, target.orig_path)
    end

    local ok, err = git.unstage(self.changes.root, paths)
    self:refresh_after(ok, err, 'Cannot unstage ' .. item.path)
    self:staged(ok, 'unstage', paths)
end

--- Discard the unstaged changes of the selection after a confirm that names
--- every path: a tracked file goes back to its index version, untracked
--- files are deleted.
function Drawer:discard()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.side == 'staged' then
        util.warn('Unstage first')
        return
    end

    local untracked = item.code == '?'
    local paths = untracked and self:paths(item) or { item.path }

    if #paths == 0 then
        return
    end

    local message = (
        untracked and 'Delete untracked files:\n'
        or 'Discard unstaged changes in:\n'
    ) .. table.concat(paths, '\n')

    if
        self.config.options.confirm.discard
        and vim.fn.confirm(message, '&Discard\n&No', 2) ~= 1
    then
        return
    end

    local root = self.changes.root
    local ok, err

    if untracked then
        ok, err = git.delete_untracked(root, paths)
    else
        ok, err = git.discard(root, paths)
    end

    self:refresh_after(ok, err, 'Cannot discard ' .. item.path)
    self:staged(ok, 'discard', paths)
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
--- anchored to the root, after a confirm.
function Drawer:ignore()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.code ~= '?' then
        util.warn('Only untracked files can be ignored')
        return
    end

    if
        self.config.options.confirm.ignore
        and vim.fn.confirm(
                'Append ' .. item.path .. ' to .gitignore?',
                '&Yes\n&No',
                2
            )
            ~= 1
    then
        return
    end

    local ok, err = git.ignore(self.changes.root, item.path)
    self:refresh_after(ok, err, 'Cannot write .gitignore')
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

--- In the preview: on a code row, close the drawer and edit the file at the
--- row's worktree line; on a gap, expand it.
function Drawer:open_row()
    local view = self.view
    local section, index = view:at()
    local row = index and section and section.file.rows[index]

    if not row then
        return
    end

    ---@cast section IterDocSection
    ---@cast index integer

    if row.kind == 'gap' then
        view:expand()
    elseif CODE_ROWS[row.kind] then
        self:edit(section.file.path, self:worktree_line(section.file, index))
    end
end

--- The worktree line for model row `row` of `file`, a diff of this
--- drawer's changes. A staged line goes through the unstaged diff of the
--- same path, when there is one.
---@param file IterFileDiff
---@param row integer
---@return integer
function Drawer:worktree_line(file, row)
    local line = model.new_line(file, row)

    if file.side ~= 'staged' then
        return line
    end

    for _, item in ipairs(self.changes.unstaged) do
        if item.path == file.path and not item.dir and item.code ~= '?' then
            local source = git.file_diff(self.changes.root, item)

            if source == nil then
                return line
            end

            return model.old_line_to_new_line(model.build(item, source), line)
        end
    end

    return line
end

--- Show the selected file's diff and move into the diff view.
function Drawer:enter_view()
    local item = self:selected()

    if item == nil or item.dir then
        return
    end

    self:preview(false)

    if self.view:is_shown() then
        vim.api.nvim_set_current_win(self.view.win)
    end
end

--- Close the drawer and open the review tab on the selected file.
function Drawer:open_review()
    local item = self:selected()
    local target

    if item ~= nil and not item.dir then
        target = {
            path = vim.fs.joinpath(self.changes.root, item.path),
            side = item.side,
        }
    end

    self:close()
    require('iter').review(target)
end

--- Files in drawer order, directories left out.
---@return IterChange[]
function Drawer:files()
    return vim.tbl_filter(function(item)
        return not item.dir
    end, self:ordered())
end

--- Select the next (`dir` 1) or previous (-1) file in drawer order and show
--- its diff now, counting from the selected file, else the shown one. In
--- all-files mode the cursor moves to the next or previous file header and
--- the selection follows it. At the last or first file nothing changes.
---@param dir 1|-1
function Drawer:step_file(dir)
    if self.all_files and self.view:is_shown() then
        if self.view:jump_file(dir) then
            self:follow_view()
        end

        return
    end

    local items = self:ordered()
    local current = self:selected()
        or (self.view:is_shown() and self.view:file() or nil)
    local index = dir == 1 and 0 or #items + 1

    for i, item in ipairs(items) do
        if current ~= nil and key(item) == key(current) then
            index = i
        end
    end

    index = index + dir

    while items[index] ~= nil and items[index].dir do
        index = index + dir
    end

    local target = items[index]

    if target == nil then
        return
    end

    for lnum, row in ipairs(self.rows) do
        local item = row[target.side]

        if item ~= nil and key(item) == key(target) then
            self:select(lnum, target.side)
            self:preview(false)
            return
        end
    end
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

    if self.help ~= nil then
        self.help:close()
    end

    self.float:close()
    self.view:close()

    for _, buf in pairs({ self.buf, self.section_buf, self.side_buf }) do
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
        vim.api.nvim_set_current_win(self:selection_win())
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
        view = self.keys_view,
        keys = self.keys,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

return Drawer
