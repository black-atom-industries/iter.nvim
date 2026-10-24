--- The annotation sidebar: a vertical split beside the text being read that
--- lists every annotation of the repository, grouped by file. One per
--- tabpage.

local editor = require('iter.annotations.editor')
local help = require('iter.ui.help')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local list = require('iter.annotations.list')
local render = require('iter.ui.render')
local store = require('iter.store')
local uri = require('iter.uri')
local watch = require('iter.watch')
local util = require('iter.util')

local M = {}

---@class IterSidebarRow what a sidebar line stands for
---@field path? string repository-relative path, nil in the review group
---@field group IterAnnotationGroup
---@field item? IterAnnotationItem nil on a group's header line

---@class IterSidebarLinesOpts
---@field width integer
---@field height? integer window rows; the hints sit on the last of them
---@field hints? [string, string][][] key and word pairs, one list per line

---@class IterSidebar
---@field tab integer
---@field win integer
---@field buf integer
---@field root string
---@field config IterConfig
---@field on_change fun() draws the annotations of the buffers, the review and every sidebar again after this one changed them
---@field signature? string identifies the stored annotations as last drawn
---@field watch? IterWatch
---@field rows table<integer, IterSidebarRow>
---@field order string[] files in the order the sidebar lists them
---@field handlers table<string, fun()>
---@field group integer
---@field help? IterHelp
local Sidebar = {}
Sidebar.__index = Sidebar

---@type table<integer, IterSidebar>
local sidebars = {}

-- Per hint line, the action and the word shown for it.
local HINTS = {
    { { 'jump', 'jump' }, { 'yank', 'yank' }, { 'yank_all', 'all' } },
    { { 'delete', 'delete' }, { 'edit', 'edit' }, { 'help', 'help' } },
}

--- The line an item stands for: `file` for a file note, `note` for a
--- review note, else the line or `first–last` it starts on, `line:col` for a
--- passage, with ` old` for deleted lines.
---@param item IterAnnotationItem
---@return string
local function location(item)
    local annotation = item.annotation
    local a = annotation.anchor

    if annotation.scope == 'review' then
        return 'note'
    end

    if annotation.scope == 'file' or a.start_line == nil then
        return 'file'
    end

    local first = item.start or a.start_line

    if a.quote ~= nil then
        return first .. ':' .. item.col
    end

    local last = first + (a.end_line or a.start_line) - a.start_line
    local loc = first == last and tostring(first) or (first .. '–' .. last)

    return loc .. (a.side == 'old' and ' old' or '')
end

---@param groups IterAnnotationGroup[]
---@return integer total
---@return integer outdated
local function counts(groups)
    local total, outdated = 0, 0

    for _, group in ipairs(groups) do
        for _, item in ipairs(group.items) do
            total = total + 1
            outdated = outdated + (item.outdated and 1 or 0)
        end
    end

    return total, outdated
end

--- `path`, or when it is wider than `width` its tail after `…`, which keeps
--- the file's name.
---@param path string
---@param width integer
---@return string
local function tail(path, width)
    if vim.fn.strdisplaywidth(path) <= width then
        return path
    end

    local kept = ''

    for i = vim.fn.strchars(path) - 1, 0, -1 do
        local next = vim.fn.strcharpart(path, i, 1) .. kept

        if vim.fn.strdisplaywidth(next) > width - 1 then
            break
        end

        kept = next
    end

    return '…' .. kept
end

---@param width integer
---@param group IterAnnotationGroup
---@return IterRenderLine
local function header(width, group)
    local count = tostring(#group.items)
    local room = width - #count - 1
    local name = layout.fit(tail(group.path or 'review', room), room)
    local line = render.line(name .. ' ' .. count)

    render.add_highlight(line, 'IterDrawerTitle', 0, #(name:gsub(' +$', '')))
    render.add_highlight(line, 'IterDrawerCount', #name + 1, #name + 1 + #count)

    return line
end

---@param opts IterSidebarLinesOpts
---@param item IterAnnotationItem
---@param label string
---@param label_width integer
---@return IterRenderLine
local function note_row(opts, item, label, label_width)
    local line = render.line('')
    local cell = layout.annotation_cell(line, {
        annotation = item.annotation,
        outdated = item.outdated,
        label = label,
    }, 1, opts.width - 1, label_width)

    line.text = ' ' .. cell

    return line
end

---@param hints [string, string][]
---@return IterRenderLine
local function hint_line(hints)
    local text = ''
    local spans = {}

    for _, hint in ipairs(hints) do
        if text ~= '' then
            text = text .. '  '
        end

        table.insert(spans, { 'IterDrawerKey', #text, #text + #hint[1] })
        text = text .. hint[1] .. ' '
        table.insert(spans, { 'IterDrawerHint', #text, #text + #hint[2] })
        text = text .. hint[2]
    end

    local line = render.line(text)

    for _, span in ipairs(spans) do
        render.add_highlight(line, span[1], span[2], span[3])
    end

    return line
end

--- The sidebar's lines for `groups`: the title with the counts, then per
--- group its header and one line per annotation, the key hints at the bottom
--- of `opts.height`. Also the row of each line that stands for a group or an
--- annotation.
---@param groups IterAnnotationGroup[]
---@param opts IterSidebarLinesOpts
---@return IterRenderLine[]
---@return table<integer, IterSidebarRow>
function M.lines(groups, opts)
    vim.validate('groups', groups, 'table')
    vim.validate('opts', opts, 'table')
    vim.validate('opts.width', opts.width, 'number')

    ---@type IterRenderLine[]
    local lines = {}
    ---@type table<integer, IterSidebarRow>
    local rows = {}
    local total, outdated = counts(groups)
    local title = string.format('Annotations (%d)', total)
    local note = outdated > 0 and string.format(' · %d outdated', outdated)
        or ''
    local first = render.line(title .. note)

    render.add_highlight(first, 'IterDrawerTitle', 0, #title)
    render.add_highlight(first, 'IterDrawerHint', #title, #title + #note)
    table.insert(lines, first)

    local labels = {}
    local label_width = 0

    for _, group in ipairs(groups) do
        for _, item in ipairs(group.items) do
            labels[item] = location(item)
            label_width =
                math.max(label_width, vim.fn.strdisplaywidth(labels[item]))
        end
    end

    if total == 0 then
        table.insert(lines, render.line(''))

        local none = render.line('No annotations')
        render.add_highlight(none, 'IterDrawerHint', 0, #none.text)
        table.insert(lines, none)
    end

    for _, group in ipairs(groups) do
        table.insert(lines, render.line(''))
        table.insert(lines, header(opts.width, group))
        rows[#lines] = { path = group.path, group = group }

        for _, item in ipairs(group.items) do
            table.insert(lines, note_row(opts, item, labels[item], label_width))
            rows[#lines] = { path = group.path, group = group, item = item }
        end
    end

    local hints = opts.hints or {}
    local gap = math.max(1, (opts.height or 0) - #lines - #hints)

    if #hints > 0 then
        for _ = 1, gap do
            table.insert(lines, render.line(''))
        end

        for _, hint in ipairs(hints) do
            table.insert(lines, hint_line(hint))
        end
    end

    return lines, rows
end

--- The hint lines for the keys of the annotate view; an action without a
--- key is left out.
---@param keys table<string, string[]>
---@return [string, string][][]
local function hints_of(keys)
    local out = {}

    for _, row in ipairs(HINTS) do
        local hints = {}

        for _, hint in ipairs(row) do
            local lhs = keys[hint[1]][1]

            if lhs ~= nil then
                table.insert(hints, { lhs, hint[2] })
            end
        end

        if #hints > 0 then
            table.insert(out, hints)
        end
    end

    return out
end

--- The ids and update times of `annotations`, to tell whether the store
--- changed even when the cache hands out a copy.
---@param annotations IterAnnotation[]
---@return string
local function signature(annotations)
    return table.concat(
        vim.tbl_map(function(annotation)
            return annotation.id .. ':' .. (annotation.updated_at or 0)
        end, annotations),
        ','
    )
end

---@return boolean
function Sidebar:is_open()
    return util.is_valid_win(self.win)
        and vim.api.nvim_win_get_buf(self.win) == self.buf
end

function Sidebar:focus()
    if self:is_open() then
        vim.api.nvim_set_current_win(self.win)
    end
end

--- Read the stored annotations and draw them. The cursor stays on the
--- annotation it was on, else on the same line.
function Sidebar:render()
    if not self:is_open() then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(self.win)[1]
    local row = self.rows[cursor]
    local id = row and row.item and row.item.annotation.id
    local annotations = store.cached(self.root).annotations
    self.signature = signature(annotations)

    local groups = list.groups(annotations, nil, list.reader(self.root))
    local lines, rows = M.lines(groups, {
        width = vim.api.nvim_win_get_width(self.win),
        height = vim.api.nvim_win_get_height(self.win),
        hints = hints_of(self.config.keys.annotate),
    })

    self.rows = rows
    self.order = {}

    for _, group in ipairs(groups) do
        if group.path ~= nil then
            table.insert(self.order, group.path)
        end
    end

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, render.text_lines(lines))
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, lines)

    local target = math.min(cursor, #lines)

    for lnum, other in pairs(rows) do
        if id ~= nil and other.item and other.item.annotation.id == id then
            target = lnum
        end
    end

    vim.api.nvim_win_set_cursor(self.win, { target, 0 })
end

--- The window a note opens in: the one the cursor came from, else the first
--- normal window of the tab, else with `create` a new one beside the
--- sidebar.
---@param create? boolean
---@return integer?
function Sidebar:pane(create)
    local previous = vim.fn.win_getid(vim.fn.winnr('#'))

    if
        previous ~= self.win
        and util.is_normal_win(previous)
        and vim.api.nvim_win_get_tabpage(previous) == self.tab
    then
        return previous
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(self.tab)) do
        if win ~= self.win and util.is_normal_win(win) then
            return win
        end
    end

    if not create then
        return nil
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'

    return vim.api.nvim_open_win(buf, false, {
        split = self.config.options.annotate.side == 'right' and 'left'
            or 'right',
        win = self.win,
    })
end

---@return IterSidebarRow?
function Sidebar:row()
    return self.rows[vim.api.nvim_win_get_cursor(self.win)[1]]
end

---@param path string
---@param line integer
---@param col? integer 0-based byte column
function Sidebar:open_file(path, line, col)
    local full = vim.fs.joinpath(self.root, path)

    if vim.uv.fs_stat(full) == nil then
        util.warn('Not in the worktree: ' .. path)
        return
    end

    local win = self:pane(true) --[[@as integer]]

    if not util.can_leave(vim.api.nvim_win_get_buf(win), full) then
        return
    end

    vim.api.nvim_set_current_win(win)
    util.edit_at(full, line, nil, col)
end

function Sidebar:jump()
    local row = self:row()

    if row == nil then
        return
    end

    local item = row.item

    if item ~= nil and item.annotation.scope == 'review' then
        self:edit()
        return
    end

    if row.path == nil then
        return
    end

    local line, col = 1, nil

    if item ~= nil and item.annotation.scope ~= 'file' then
        line = item.start or item.annotation.anchor.start_line or 1

        if item.start ~= nil then
            col = item.start_col
        end
    end

    self:open_file(row.path, line, col)
end

--- Copy the annotations with `ids`, all when nil, in the sidebar's file
--- order.
---@param ids? string[]
function Sidebar:yank(ids)
    require('iter.export').yank({
        root = self.root,
        config = self.config,
        order = self.order,
        ids = ids,
        on_clear = function()
            self.on_change()
        end,
    })
end

function Sidebar:edit()
    local row = self:row()

    if row == nil or row.item == nil then
        return
    end

    editor.open({
        root = self.root,
        annotation = row.item.annotation,
        config = self.config,
        pane = self:pane(false),
        on_save = function()
            self.on_change()
        end,
    })
end

function Sidebar:delete()
    local row = self:row()

    if row == nil or row.item == nil then
        return
    end

    if editor.delete(self.root, row.item.annotation) ~= nil then
        self.on_change()
    end
end

function Sidebar:toggle_help()
    if self.help ~= nil and self.help:is_open() then
        self.help:close()
        return
    end

    self.help = help.open({
        view = 'annotate',
        keys = self.config.keys.annotate,
        handlers = self.handlers,
        close_keys = self.config.keys.help,
        zindex = self.config.options.drawer.zindex + 10,
    })
end

function Sidebar:close()
    if self.help ~= nil then
        self.help:close()
    end

    if self:is_open() then
        pcall(vim.api.nvim_win_close, self.win, true)
    end
end

--- Drop the sidebar of the tab once its window is gone.
function Sidebar:forget()
    if self.watch ~= nil then
        self.watch:stop()
    end

    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if sidebars[self.tab] == self then
        sidebars[self.tab] = nil
    end
end

---@return string
local function current_root()
    local target =
        require('iter.annotations.marks').target(vim.api.nvim_get_current_buf())

    return target and target.root or require('iter.git').root()
end

---@param config IterConfig
---@param root string
---@param on_change fun()
---@return IterSidebar
local function create(config, root, on_change)
    local opts = config.options.annotate
    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    util.name_buf(
        buf,
        uri.of('annotate', tostring(vim.api.nvim_get_current_tabpage()))
    )

    if not util.is_normal_win(vim.api.nvim_get_current_win()) then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if util.is_normal_win(win) then
                vim.api.nvim_set_current_win(win)
                break
            end
        end
    end

    vim.cmd(
        string.format(
            '%s vertical %dsplit',
            opts.side == 'left' and 'topleft' or 'botright',
            opts.width
        )
    )

    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    local settings = {
        number = false,
        relativenumber = false,
        signcolumn = 'no',
        foldcolumn = '0',
        statuscolumn = '',
        wrap = false,
        list = false,
        cursorline = true,
        winfixwidth = true,
        winhighlight = 'Normal:IterSidebar,EndOfBuffer:IterSidebar,SignColumn:IterSidebar,FoldColumn:IterSidebar,CursorLine:IterDrawerSelected',
    }
    local before = {}

    for name, value in pairs(settings) do
        before[name] = vim.wo[win][name]
        vim.wo[win][name] = value
    end

    local self = setmetatable({
        tab = vim.api.nvim_get_current_tabpage(),
        win = win,
        buf = buf,
        root = root,
        config = config,
        on_change = on_change,
        rows = {},
        order = {},
    }, Sidebar)

    self.handlers = {
        jump = function()
            self:jump()
        end,
        yank = function()
            local row = self:row()

            if row == nil then
                return
            end

            self:yank(
                row.item and { row.item.annotation.id }
                    or vim.tbl_map(function(item)
                        return item.annotation.id
                    end, row.group.items)
            )
        end,
        yank_all = function()
            self:yank(nil)
        end,
        delete = function()
            self:delete()
        end,
        edit = function()
            self:edit()
        end,
        close = function()
            self:close()
        end,
        help = function()
            self:toggle_help()
        end,
    }

    uri.own(buf, {
        owns = function(other)
            return other == self.win
        end,
        reload = function()
            self:render()
        end,
    })
    keymap.attach(buf, 'annotate', config.keys.annotate, self.handlers)

    self.group =
        vim.api.nvim_create_augroup('iter.sidebar.' .. buf, { clear = true })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = tostring(win),
        once = true,
        callback = function()
            if self.help ~= nil then
                self.help:close()
            end

            self:forget()

            -- A copy of the window, such as `:split` makes, would outlive it.
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(buf) then
                    vim.api.nvim_buf_delete(buf, { force = true })
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd('BufWinLeave', {
        group = self.group,
        buffer = buf,
        callback = function()
            if vim.api.nvim_get_current_win() == self.win then
                for name, value in pairs(before) do
                    vim.wo[self.win][name] = value
                end
            end
        end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = self.group,
        buffer = buf,
        once = true,
        callback = function()
            if self.help ~= nil then
                self.help:close()
            end

            self:forget()
        end,
    })
    vim.api.nvim_create_autocmd('WinResized', {
        group = self.group,
        callback = function()
            if vim.tbl_contains(vim.v.event.windows, self.win) then
                self:render()
            end
        end,
    })

    self.watch = watch.start({
        root = root,
        poll_ms = config.options.refresh.poll_ms,
        on_change = function(reason)
            if
                reason == 'poll'
                and signature(store.cached(root).annotations)
                    == self.signature
            then
                return
            end

            self:render()
        end,
    })

    self:render()

    for lnum = 1, vim.api.nvim_buf_line_count(buf) do
        if self.rows[lnum] ~= nil and self.rows[lnum].item ~= nil then
            vim.api.nvim_win_set_cursor(win, { lnum, 0 })
            break
        end
    end

    return self
end

--- Open the sidebar beside the current window, or focus the one the tab
--- has.
---@param config IterConfig
---@param on_change fun()
local function open(config, on_change)
    local tab = vim.api.nvim_get_current_tabpage()
    local existing = sidebars[tab]

    if existing ~= nil and existing:is_open() then
        existing:focus()
        return
    end

    local root = current_root()

    if root == '' then
        util.warn('Not inside a git repository')
        return
    end

    sidebars[tab] = create(config, root, on_change)
end

--- Draw every open sidebar again, in every tab.
function M.refresh_all()
    for _, sidebar in pairs(sidebars) do
        sidebar:render()
    end
end

--- Open the sidebar, focus it when it is open elsewhere in the tab, close it
--- when the cursor is in it.
---@param config IterConfig
---@param on_change fun()
function M.toggle(config, on_change)
    local current = sidebars[vim.api.nvim_get_current_tabpage()]

    if
        current ~= nil
        and current:is_open()
        and vim.api.nvim_get_current_win() == current.win
    then
        current:close()
        return
    end

    open(config, on_change)
end

return M
