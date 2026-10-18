local changes = require('iter.changes')
local float = require('iter.ui.float')
local git = require('iter.git')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local model = require('iter.diff.model')
local render = require('iter.ui.render')
local util = require('iter.util')
local View = require('iter.diff.view')

---@class IterDrawerRow buffer line → cells
---@field unstaged? IterChange
---@field staged? IterChange

---@class IterDrawerCell byte columns of one cell on its line
---@field first integer
---@field last integer

---@class IterDrawerOpenOptions
---@field pane integer window the float is anchored to
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field on_close? fun(drawer: IterDrawer)

---@class IterDrawer
---@field context 'status'
---@field pane integer
---@field win integer
---@field buf integer
---@field float IterFloat
---@field view IterDiffView diff of the selected file, shown in the pane
---@field config IterConfig
---@field changes IterChanges
---@field rows IterDrawerRow[]
---@field cells table<IterSide, IterDrawerCell>[]
---@field column IterSide selected column
---@field lnum integer selected line
---@field layout 'columns'|'stacked'
---@field expanded table<string, boolean> untracked directories shown open
---@field previewed? string key of the item the view shows
---@field preview_tick integer bumped per scheduled preview; only the last one runs
---@field group integer
---@field closed boolean
---@field on_close? fun(drawer: IterDrawer)
local Drawer = {}
Drawer.__index = Drawer

local SELECTED_NS = vim.api.nvim_create_namespace('iter.drawer.selected')
local PREVIEW_DELAY_MS = 50
local SEPARATOR = '│'
local SIDES = { 'unstaged', 'staged' }
local TITLES = { unstaged = 'Unstaged', staged = 'Staged' }

---@param item IterChange
---@return string
local function key(item)
    return item.side .. '\0' .. item.path
end

---@param item IterChange
---@return string
local function code_group(item)
    if item.code == '?' then
        return 'IterUntracked'
    elseif item.code == 'U' then
        return 'IterConflict'
    end

    return item.side == 'staged' and 'IterStage' or 'IterUnstage'
end

---@param text string
---@param width integer
---@return string
local function pad(text, width)
    return text .. string.rep(' ', width - vim.fn.strdisplaywidth(text))
end

---@class IterDrawerEntry
---@field item IterChange
---@field parent? IterChange expanded directory the item belongs to

--- Items of one side in display order, children after their directory.
---@param items IterChange[]
---@return IterDrawerEntry[]
local function flatten(items)
    local entries = {}

    for _, item in ipairs(items) do
        table.insert(entries, { item = item })

        if item.expanded then
            for _, child in ipairs(item.children or {}) do
                table.insert(entries, { item = child, parent = item })
            end
        end
    end

    return entries
end

--- One cell: code letter and path, the path cut from the left to fit.
---@param line IterRenderLine
---@param entry IterDrawerEntry
---@param first integer byte column the cell starts at
---@param width integer
---@return string
local function cell_text(line, entry, first, width)
    local item = entry.item
    local indent = entry.parent ~= nil and '   ' or ' '
    local name = entry.parent ~= nil and item.path:sub(#entry.parent.path + 1)
        or item.path
    local prefix = indent .. item.code .. ' '
    local text = prefix
        .. changes.truncate(name, width - vim.fn.strdisplaywidth(prefix))

    render.add_highlight(line, code_group(item), first + #indent)

    return pad(text, width)
end

---@param line IterRenderLine
---@param side IterSide
---@param count integer
---@param first integer
---@param width integer
---@return string
local function title_text(line, side, count, first, width)
    local text = string.format(' %s (%d)', TITLES[side], count)
    render.add_highlight(line, 'IterDrawerTitle', first, first + #text)

    return pad(text, width)
end

---@class IterDrawerLayout
---@field lines IterRenderLine[]
---@field rows IterDrawerRow[]
---@field cells table<IterSide, IterDrawerCell>[]

--- Unstaged and Staged side by side, each half of `width`.
---@param lists table<IterSide, IterDrawerEntry[]>
---@param counts table<IterSide, integer>
---@param width integer
---@return IterDrawerLayout
local function columns_layout(lists, counts, width)
    local widths = { unstaged = math.floor((width - 1) / 2) }
    widths.staged = width - 1 - widths.unstaged
    local result = { lines = {}, rows = {}, cells = {} }
    local height = math.max(#lists.unstaged, #lists.staged)

    for index = 0, height do
        local line = render.line('')
        local row, cells, parts = {}, {}, {}
        local first = 0

        for i, side in ipairs(SIDES) do
            local text
            local entry = lists[side][index]

            if index == 0 then
                text = title_text(line, side, counts[side], first, widths[side])
            elseif entry ~= nil then
                text = cell_text(line, entry, first, widths[side])
                row[side] = entry.item
                cells[side] = { first = first, last = first + #text }
            else
                text = string.rep(' ', widths[side])
            end

            table.insert(parts, text)
            first = first + #text

            if i == 1 then
                table.insert(parts, SEPARATOR)
                render.add_highlight(
                    line,
                    'WinSeparator',
                    first,
                    first + #SEPARATOR
                )
                first = first + #SEPARATOR
            end
        end

        line.text = table.concat(parts)
        table.insert(result.lines, line)
        table.insert(result.rows, row)
        table.insert(result.cells, cells)
    end

    return result
end

--- Unstaged above Staged, both the full `width`.
---@param lists table<IterSide, IterDrawerEntry[]>
---@param counts table<IterSide, integer>
---@param width integer
---@return IterDrawerLayout
local function stacked_layout(lists, counts, width)
    local result = { lines = {}, rows = {}, cells = {} }

    for i, side in ipairs(SIDES) do
        if i > 1 then
            table.insert(result.lines, render.line(''))
            table.insert(result.rows, {})
            table.insert(result.cells, {})
        end

        local title = render.line('')
        title.text = title_text(title, side, counts[side], 0, width)
        table.insert(result.lines, title)
        table.insert(result.rows, {})
        table.insert(result.cells, {})

        for _, entry in ipairs(lists[side]) do
            local line = render.line('')
            line.text = cell_text(line, entry, 0, width)
            table.insert(result.lines, line)
            table.insert(result.rows, { [side] = entry.item })
            table.insert(
                result.cells,
                { [side] = { first = 0, last = #line.text } }
            )
        end
    end

    return result
end

--- Open the drawer over the bottom of `opts.pane`, focused, with the diff of
--- the selected file in the pane.
--- With 'nohidden' a modified buffer can't leave its window (E37), so the
--- pane can neither show the preview nor switch to another file.
---@param buf? integer
---@param path? string file the window would switch to
---@return boolean
local function is_stuck(buf, path)
    return not vim.o.hidden
        and buf ~= nil
        and vim.api.nvim_buf_is_valid(buf)
        and vim.bo[buf].modified
        and vim.api.nvim_buf_get_name(buf) ~= path
end

---@param opts IterDrawerOpenOptions
---@return IterDrawer?
function Drawer.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    if is_stuck(vim.api.nvim_win_get_buf(opts.pane)) then
        util.warn('The pane has unsaved changes')
        return nil
    end

    highlight.setup()

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'

    local self = setmetatable({
        context = 'status',
        pane = opts.pane,
        buf = buf,
        config = opts.config,
        rows = {},
        cells = {},
        column = 'unstaged',
        lnum = 1,
        layout = 'columns',
        expanded = {},
        preview_tick = 0,
        closed = false,
        on_close = opts.on_close,
    }, Drawer)

    if not self:load() then
        vim.api.nvim_buf_delete(buf, { force = true })
        return nil
    end

    self.view = View.new({ win = opts.pane, keys = opts.config.keys.diff })
    self.float = float.open({
        pane = opts.pane,
        buf = buf,
        zindex = opts.config.options.drawer.zindex,
        height = opts.config.options.drawer.height,
        enter = true,
    })
    self.win = self.float.win
    vim.api.nvim_set_option_value(
        'wrap',
        false,
        { scope = 'local', win = self.win }
    )

    self:render()
    self:restore_selection(self:find_path(opts.path))
    self:attach()
    self:preview(true)

    return self
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

    local function act(method)
        return function()
            self[method](self)
        end
    end

    keymap.attach(self.buf, 'drawer', self.config.keys.drawer, {
        open = act('open_file'),
        stage = act('stage'),
        unstage = act('unstage'),
        discard = act('discard'),
        expand = act('toggle'),
        close = act('close'),
        column_left = function()
            self:switch('unstaged')
        end,
        column_right = function()
            self:switch('staged')
        end,
    })
end

---@return boolean
function Drawer:is_open()
    return not self.closed and util.is_valid_win(self.win)
end

--- Read the status afresh, keeping open directories open.
---@return boolean loaded
function Drawer:load()
    local snapshot = git.status_snapshot()

    if snapshot.error ~= nil then
        util.error(snapshot.error, 'Cannot read the git status')
        return false
    end

    self.changes = changes.build(snapshot)

    for _, item in ipairs(self.changes.unstaged) do
        if item.dir and self.expanded[item.path] then
            changes.expand(self.changes.root, item)
        end
    end

    return true
end

--- Write the items into the buffer in the layout the pane's width allows.
function Drawer:render()
    local width = vim.api.nvim_win_get_width(self.pane)
    local lists = {
        unstaged = flatten(self.changes.unstaged),
        staged = flatten(self.changes.staged),
    }
    local counts = {
        unstaged = #self.changes.unstaged,
        staged = #self.changes.staged,
    }

    self.layout = width >= self.config.options.drawer.breakpoint and 'columns'
        or 'stacked'

    local layout = self.layout == 'columns'
            and columns_layout(lists, counts, width)
        or stacked_layout(lists, counts, width)

    self.rows, self.cells = layout.rows, layout.cells

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(
        self.buf,
        0,
        -1,
        false,
        render.text_lines(layout.lines)
    )
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, layout.lines)
end

---@return IterChange?
function Drawer:selected()
    local row = self.rows[self.lnum]

    return row and row[self.column]
end

--- The line nearest to `lnum` that holds an item of one of `sides`, looking
--- in direction `dir` first.
---@param lnum integer
---@param sides IterSide[]
---@param dir 1|-1
---@return integer? lnum
---@return IterSide? side
function Drawer:find(lnum, sides, dir)
    for _, step in ipairs({ dir, -dir }) do
        local l = lnum

        while l >= 1 and l <= #self.rows do
            for _, side in ipairs(sides) do
                if self.rows[l][side] ~= nil then
                    return l, side
                end
            end

            l = l + step
        end
    end

    return nil, nil
end

--- Line and side of the item at `path`, an absolute file path.
---@param path? string
---@return { lnum: integer, side: IterSide }?
function Drawer:find_path(path)
    if path == nil or path == '' then
        return nil
    end

    for _, side in ipairs(SIDES) do
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
---@param column IterSide
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
    local sides = self.layout == 'stacked' and SIDES or { self.column }
    local target, side = self:find(lnum, sides, dir)

    if target ~= nil and side ~= nil then
        self:select(target, side)
    end
end

---@param column IterSide
function Drawer:switch(column)
    local lnum, side = self:find(self.lnum, { column }, 1)

    if lnum ~= nil and side ~= nil then
        self:select(lnum, side)
    end
end

--- Lines that hold an item of `column`, top to bottom.
---@param column IterSide
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
---@field column IterSide
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
---@param target? IterDrawerMark|{ lnum: integer, side: IterSide }
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

    local lnum, side = self:find(self.lnum, SIDES, 1)

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
end

--- Reload after a git action and show the selection's new diff.
---@param ok boolean
---@param err? string
---@param fallback string
function Drawer:refresh_after(ok, err, fallback)
    if not ok then
        util.error(err, fallback)
    end

    local mark = self:mark()

    if self:load() then
        self:render()
        self:restore_selection(mark)
        self:preview(true)
    end
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
--- it is.
---@param force boolean also when the view already shows the item
function Drawer:preview(force)
    local item = self:selected()

    if not self:is_open() or item == nil or item.dir then
        return
    end

    if not force and key(item) == self.previewed then
        return
    end

    local source, err = git.file_diff(self.changes.root, item)

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed = key(item)
    self.view:show(model.build(item, source))
end

--- The files an action on `item` touches. Nested repositories inside an
--- untracked directory are left out.
---@param item IterChange
---@return string[]
function Drawer:paths(item)
    local paths = {}

    for _, path in ipairs(changes.files(self.changes.root, item)) do
        if vim.endswith(path, '/') then
            util.warn('Skipped the nested repository ' .. path)
        else
            table.insert(paths, path)
        end
    end

    return paths
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

--- Expand or collapse the selected untracked directory, or the directory
--- the selected file belongs to.
function Drawer:toggle()
    local item = self:selected()

    if item == nil or item.side ~= 'unstaged' then
        return
    end

    ---@type IterChange?
    local dir = item

    if not item.dir then
        dir = nil

        for _, candidate in ipairs(self.changes.unstaged) do
            if
                candidate.expanded and vim.startswith(item.path, candidate.path)
            then
                dir = candidate
            end
        end
    end

    if dir == nil then
        return
    end

    if dir.expanded then
        changes.collapse(dir)
        self.expanded[dir.path] = nil
    else
        changes.expand(self.changes.root, dir)
        self.expanded[dir.path] = true
    end

    self:render()
    self:restore_selection({ column = 'unstaged', path = dir.path, index = 1 })
end

--- Close the drawer and edit the selected file in the pane. A deleted file
--- keeps the drawer open.
function Drawer:open_file()
    local item = self:selected()

    if item == nil then
        return
    end

    if item.dir then
        return self:toggle()
    end

    local path = vim.fs.joinpath(self.changes.root, item.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(item.path .. ' is deleted')
        return
    end

    if is_stuck(self.view.prev_buf, path) then
        util.warn('The pane has unsaved changes')
        return
    end

    self:close()

    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))

    if not ok then
        util.error(tostring(err), 'Cannot open ' .. item.path)
    end
end

--- Close the float and give the pane back its buffer and options.
function Drawer:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
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

    self:refresh_after(true, nil, '')
end

return Drawer
