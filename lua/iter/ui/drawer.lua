local changes = require('iter.changes')
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

---@alias IterDrawerRow table<string, IterChange> buffer line → item per column id

---@class IterDrawerExtras what a context such as the review tab adds to the drawer
---@field drawer_load fun(self, drawer: IterDrawer): boolean after a status read, before the first render with the view in place; true when what it shows changed
---@field drawer_decorator fun(self, drawer: IterDrawer): fun(item: IterChange): IterLayoutDecor per render, the decor of each file row
---@field drawer_header fun(self, drawer: IterDrawer, summary: [string, string]): [string, string][] header chunks after the branch, in place of `summary`
---@field drawer_rendered fun(self, drawer: IterDrawer, lines: integer) after the layout, before the buffer is written
---@field drawer_shown fun(self, drawer: IterDrawer) after the view showed the selection or the drawer rendered
---@field drawer_handlers fun(self, drawer: IterDrawer, handlers: table<string, fun()>) changes the drawer actions in place

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
---@field rows IterDrawerRow[]
---@field cells table<string, IterLayoutCell>[]
---@field column string id of the selected column
---@field lnum integer selected line
---@field layout IterLayoutMode
---@field previewed? string key of the item the view shows
---@field previewed_stat? string worktree stat of that item when it was read
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
-- The columns, left to right, each listing the changes of its side.
---@type { id: IterSide, title: string }[]
local COLUMNS = {
    { id = 'unstaged', title = 'Unstaged' },
    { id = 'staged', title = 'Staged' },
}
-- Diff rows that stand for a line of the file.
local CODE_ROWS = { context = true, del = true, add = true }
-- Actions the key hint line shows, in order, with their short labels.
local HINTS = {
    { 'stage', 'stage' },
    { 'unstage', 'unstage' },
    { 'discard', 'discard' },
    { 'open', 'open' },
    { 'review', 'review' },
    { 'help', 'help' },
}

---@param item IterChange
---@return string
local function key(item)
    return item.side .. '\0' .. item.path
end

--- Column ids left to right, `first` moved to the front when given.
---@param first? string
---@return string[]
local function column_ids(first)
    local ids = first and { first } or {}

    for _, column in ipairs(COLUMNS) do
        if column.id ~= first then
            table.insert(ids, column.id)
        end
    end

    return ids
end

--- Every item in drawer order: column by column, left to right.
---@param result IterChanges
---@return IterChange[]
local function ordered(result)
    local items = {}

    for _, column in ipairs(COLUMNS) do
        vim.list_extend(items, result[column.id])
    end

    return items
end

--- `HEAD <branch> ↑<ahead> · <n> changes`; `↑` only when HEAD is ahead of
--- its upstream. A file in more than one column counts once. Stacked, the
--- counts are per column, since a lower title may sit below the visible
--- lines. `extras` replaces the summary after the branch.
---@param drawer IterDrawer
---@return [string, string][]
local function header_chunks(drawer)
    local result = drawer.changes
    local paths = {}
    local count = 0

    for _, item in ipairs(ordered(result)) do
        if not paths[item.path] then
            paths[item.path] = true
            count = count + 1
        end
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

    local summary =
        string.format(' · %d %s', count, count == 1 and 'change' or 'changes')

    if drawer.layout == 'stacked' and count > 0 then
        summary = ''

        for _, column in ipairs(COLUMNS) do
            summary = summary
                .. string.format(
                    ' · %d %s',
                    #result[column.id],
                    column.title:lower()
                )
        end
    end

    local tail = { summary, 'IterDrawerHint' }

    if drawer.extras ~= nil then
        vim.list_extend(chunks, drawer.extras:drawer_header(drawer, tail))
    else
        table.insert(chunks, tail)
    end

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
    vim.bo[buf].bufhidden = 'wipe'
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
        column = COLUMNS[1].id,
        lnum = 1,
        layout = 'columns',
        preview_tick = 0,
        closed = false,
        on_close = opts.on_close,
    }, Drawer)

    local view_handlers = opts.view_handlers

    if not review then
        view_handlers = vim.tbl_extend('force', view_handlers or {}, {
            expand = function()
                self:open_row()
            end,
        })
    end

    -- The review's diff pane belongs to the view, so a buffer that takes its
    -- place only hides it, and the review puts it back.
    self.view = View.new({
        win = view_win,
        keys = opts.config.keys.diff,
        handlers = view_handlers,
        name = review and 'iter://review-diff' or nil,
        bufhidden = review and 'hide' or nil,
    })

    if not self:load() then
        self.view:close()
        vim.api.nvim_buf_delete(buf, { force = true })
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
        end,
        column_right = function()
            self:step_column(1)
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

    vim.api.nvim_create_autocmd('CursorMoved', {
        group = self.group,
        buffer = self.buf,
        callback = function()
            self:follow_cursor()
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

    keymap.attach(self.buf, self.keys_view, self.keys, self.handlers)
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
    local snapshot =
        git.status_snapshot(self.changes and self.changes.root or nil)

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false, false
    end

    self.changes = changes.build(snapshot)

    if self.extras == nil then
        return true, false
    end

    return true, self.extras:drawer_load(self)
end

--- Write the items into the buffer in the layout the pane's width allows,
--- with the header and key hint line around them.
function Drawer:render()
    local width = vim.api.nvim_win_get_width(self.pane)
    local decorate = self.extras and self.extras:drawer_decorator(self)
    local columns = vim.tbl_map(function(column)
        ---@type IterLayoutColumn
        return {
            id = column.id,
            title = column.title,
            items = self.changes[column.id],
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
    end, COLUMNS)

    self.layout = layout.mode(width, self.config.options.drawer.breakpoint)

    local built

    if #ordered(self.changes) == 0 then
        built = layout.message('Working tree clean')
    elseif self.layout == 'columns' then
        built = layout.columns(columns, width)
    else
        built = layout.stacked(columns, width)
    end

    self.rows, self.cells = built.rows, built.cells

    if self.extras ~= nil then
        self.extras:drawer_rendered(self, #built.lines)
    end

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        self.buf,
        0,
        -1,
        false,
        render.text_lines(built.lines)
    )
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, SELECTED_NS, 0, -1)
    render.apply(self.buf, built.lines)

    self.float:reposition({
        min_lines = math.min(#built.lines, Drawer.MIN_LINES),
        title = header_chunks(self),
        footer = layout.hints(
            keymap.list(self.keys_view, self.keys, self.handlers),
            HINTS,
            width
        ),
    })

    self:shown()
end

--- Let the extras follow what the view shows.
function Drawer:shown()
    if self.extras ~= nil then
        self.extras:drawer_shown(self)
    end
end

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
    for _, step in ipairs({ dir, -dir }) do
        local l = lnum

        while l >= 1 and l <= #self.rows do
            for _, id in ipairs(ids) do
                if self.rows[l][id] ~= nil then
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

    for _, side in ipairs(column_ids(first)) do
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

    self.lnum, self.column = lnum, column

    vim.api.nvim_buf_clear_namespace(self.buf, SELECTED_NS, 0, -1)
    vim.api.nvim_buf_set_extmark(self.buf, SELECTED_NS, lnum - 1, cell.first, {
        end_col = cell.last,
        hl_group = 'IterDrawerSelected',
        priority = 100,
    })

    if util.is_valid_win(self.win) then
        local cursor = vim.api.nvim_win_get_cursor(self.win)

        if cursor[1] ~= lnum or cursor[2] ~= cell.first then
            vim.api.nvim_win_set_cursor(self.win, { lnum, cell.first })
        end
    end

    local item = self:selected()

    if item ~= nil and key(item) ~= self.previewed then
        self:schedule_preview()
    end
end

function Drawer:follow_cursor()
    if not util.is_valid_win(self.win) then
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    local dir = lnum < self.lnum and -1 or 1
    local ids = self.layout == 'stacked' and column_ids() or { self.column }
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

--- Switch to the column left (`dir` -1) or right (1) of the selected one;
--- at the first or last column, to that column.
---@param dir 1|-1
function Drawer:step_column(dir)
    local index = 1

    for i, column in ipairs(COLUMNS) do
        if column.id == self.column then
            index = i
        end
    end

    index = math.max(1, math.min(index + dir, #COLUMNS))
    self:switch(COLUMNS[index].id)
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
---@field path? string
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

    return { column = self.column, path = item and item.path, index = index }
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

    if target ~= nil and target.path ~= nil then
        for _, lnum in ipairs(lines) do
            if self.rows[lnum][column].path == target.path then
                return self:select(lnum, column)
            end
        end
    end

    if #lines > 0 then
        local index = math.min(target and target.index or 1, #lines)
        return self:select(lines[index], column)
    end

    local lnum, side = self:find(self.lnum, column_ids(), 1)

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
    self.view:rewrap()
end

--- Reload the status, keep the selection on its path, or select `target`
--- when it is still there, and show its diff afresh. A poll that finds
--- nothing changed leaves everything as it is.
---@param reason? IterWatchReason nil after an action of the drawer
---@param target? { path: string, side: IterSide } absolute path, side first
function Drawer:refresh(reason, target)
    if not self:is_open() then
        return
    end

    local before = self.changes
    local mark = self:mark()
    local loaded, extras_changed = self:load()

    if not loaded then
        return
    end

    if reason == 'poll' and vim.deep_equal(before, self.changes) then
        local item = self:selected()

        if extras_changed then
            self:render()
            self:restore_selection(mark)
        end

        -- The review's diff also follows writes from outside Neovim, which
        -- leave the status as it was.
        if
            self.context == 'review'
            and item ~= nil
            and key(item) == self.previewed
            and util.stat_key(vim.fs.joinpath(self.changes.root, item.path))
                ~= self.previewed_stat
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

--- Show the selected file's diff in the pane. Directories leave the pane as
--- it is; without a selection the pane gets its own buffer back.
---@param force boolean also when the view already shows the item
function Drawer:preview(force)
    local item = self:selected()

    if not self:is_open() then
        return
    end

    if item == nil then
        self.previewed = nil
        self.view:hide()
        return
    end

    if item.dir then
        return
    end

    if not force and key(item) == self.previewed then
        return
    end

    local stat = util.stat_key(vim.fs.joinpath(self.changes.root, item.path))
    local source, err = git.file_diff(self.changes.root, item)

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed_stat = stat
    self.view:set_new_follows(
        item.side == 'staged' and not self:has_unstaged(item.path)
    )

    -- The same diff again keeps the view as it is, expanded gaps included.
    local shown = self.view.files[1]

    if
        key(item) == self.previewed
        and self.view:is_shown()
        and shown ~= nil
        and shown.code == item.code
        and vim.deep_equal(shown.raw, source.raw)
    then
        self:shown()
        return
    end

    self.previewed = key(item)
    self.view:show(model.build(item, source))
    self:shown()
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
        util.warn('Nothing to stage')
        return
    end

    local ok, err = git.stage(self.changes.root, paths)
    self:refresh_after(ok, err, 'Cannot stage ' .. item.path)
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
        util.warn('Nothing to discard')
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
    local row = view:row()
    local file = view.files[1]

    if row == nil or file == nil then
        return
    end

    if row.kind == 'gap' then
        view:expand()
    elseif CODE_ROWS[row.kind] then
        local lnum = vim.api.nvim_win_get_cursor(view.win)[1]

        self:edit(file.path, self:worktree_line(file, lnum))
    end
end

--- The worktree line for row `lnum` of `file`, a diff of this drawer's
--- changes. A staged line goes through the unstaged diff of the same path,
--- when there is one.
---@param file IterFileDiff
---@param lnum integer
---@return integer
function Drawer:worktree_line(file, lnum)
    local line = model.new_line(file, lnum)

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
    end, ordered(self.changes))
end

--- Select the next (`dir` 1) or previous (-1) file in drawer order and show
--- its diff now. At the last or first file nothing changes.
---@param dir 1|-1
function Drawer:step_file(dir)
    local items = ordered(self.changes)
    local current = self:selected()
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
        view = self.keys_view,
        keys = self.keys,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

return Drawer
