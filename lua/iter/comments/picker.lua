--- The comment picker: every stored comment grouped by file in a float,
--- filtered by what is typed in a prompt float above it.

local anchor = require('iter.comments.anchor')
local highlight = require('iter.highlight')
local keymap = require('iter.keymap')
local store = require('iter.store')
local util = require('iter.util')

---@class IterPickerItem
---@field comment IterComment
---@field index integer position in the store
---@field loc string
---@field outdated boolean
---@field text string first line of the body
---@field haystack string lowercase text the filter looks in
---@field lnum? integer line in the results buffer
---@field first? boolean first item of its group

---@class IterPickerGroup
---@field title string
---@field path? string nil for the review group
---@field items IterPickerItem[]

---@class IterPickerOpenOptions
---@field root string
---@field config IterConfig
---@field order? string[] file paths in the order the groups follow
---@field jump fun(comment: IterComment)
---@field edit fun(comment: IterComment)
---@field on_change? fun() after a comment is deleted

---@class IterPicker
---@field opts IterPickerOpenOptions
---@field groups IterPickerGroup[]
---@field shown IterPickerGroup[]
---@field flat IterPickerItem[]
---@field sel? integer
---@field results_buf integer
---@field results_win integer
---@field prompt_buf integer
---@field prompt_win integer
---@field prev_win integer
---@field group integer
---@field closed boolean
local Picker = {}
Picker.__index = Picker

local M = {}

local NS = vim.api.nvim_create_namespace('iter.picker')
local SELECTED_NS = vim.api.nvim_create_namespace('iter.picker.selected')
local GROUP = 'iter.picker'
local MAX_WIDTH = 90
local MAX_HEIGHT = 16

---@type IterPicker?
local current = nil

--- Lines of `path`: the loaded buffer's when there is one, else the file's.
---@param root string
---@param path string
---@return string[]?
function M.file_lines(root, path)
    local full = vim.fs.joinpath(root, path)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)

        if
            vim.api.nvim_buf_is_loaded(buf)
            and name ~= ''
            and vim.bo[buf].buftype == ''
            and vim.fs.normalize(vim.fn.resolve(name)) == full
        then
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
    end

    local ok, lines = pcall(vim.fn.readfile, full)

    return ok and lines or nil
end

--- The line of `lines` that `comment` stands for: where its text is now,
--- else its stored end line kept inside the file.
---@param comment IterComment
---@param lines? string[]
---@return integer
function M.line_of(comment, lines)
    local a = comment.anchor

    if a.start_line == nil then
        return 1
    end

    local start = anchor.resolve(a, lines)

    if start ~= nil then
        return start
    end

    local stored = a.end_line or a.start_line --[[@as integer]]

    return math.max(1, math.min(stored, lines and #lines or 1))
end

---@param comment IterComment
---@return boolean
local function follows_worktree(comment)
    return (comment.scope == 'line' or comment.scope == 'range')
        and comment.anchor.side == 'new'
        and comment.anchor.lines ~= nil
        and #comment.anchor.lines > 0
end

---@param comment IterComment
---@return string
local function location(comment)
    local a = comment.anchor

    if comment.scope == 'review' then
        return ''
    elseif comment.scope == 'file' then
        return 'file'
    end

    local loc = a.start_line == a.end_line and ('L' .. a.start_line)
        or string.format('L%d-%d', a.start_line, a.end_line)

    return a.side == 'old' and loc .. ' old' or loc
end

--- Comments in groups: the files of `order` first, in that order, then the
--- other files by name, the review last. In a group the file comment comes
--- first, then the comments by line.
---@param comments IterComment[]
---@param order? string[]
---@param lines_of fun(path: string): string[]?
---@return IterPickerGroup[]
function M.groups(comments, order, lines_of)
    local rank = {}

    for i, path in ipairs(order or {}) do
        rank[path] = rank[path] or i
    end

    ---@type table<string, IterPickerGroup>
    local by_key = {}
    ---@type IterPickerGroup[]
    local groups = {}

    for index, comment in ipairs(comments) do
        local path = comment.scope ~= 'review' and comment.anchor.path or nil
        local key = path or ''
        local group = by_key[key]

        if group == nil then
            group = { title = path or 'Review', path = path, items = {} }
            by_key[key] = group
            table.insert(groups, group)
        end

        local outdated = comment.outdated == true

        if follows_worktree(comment) then
            outdated = anchor.resolve(
                comment.anchor,
                lines_of(path --[[@as string]])
            ) == nil
        end

        local loc = location(comment)
        local text = vim.split(comment.body, '\n')[1]:gsub('\t', ' ')

        if comment.body:find('\n', 1, true) then
            text = text .. ' …'
        end

        table.insert(group.items, {
            comment = comment,
            index = index,
            loc = loc,
            outdated = outdated,
            text = text,
            haystack = vim.fn.tolower(table.concat({
                group.title,
                loc,
                comment.body,
                outdated and 'outdated' or '',
            }, ' ')),
        })
    end

    for _, group in ipairs(groups) do
        table.sort(group.items, function(a, b)
            local sa = a.comment.anchor.start_line or 0
            local sb = b.comment.anchor.start_line or 0

            if a.comment.scope == 'file' then
                sa = 0
            end

            if b.comment.scope == 'file' then
                sb = 0
            end

            if sa ~= sb then
                return sa < sb
            end

            return a.index < b.index
        end)
    end

    table.sort(groups, function(a, b)
        if (a.path == nil) ~= (b.path == nil) then
            return a.path ~= nil
        end

        local ra, rb = rank[a.path or ''], rank[b.path or '']

        if ra ~= rb and (ra ~= nil or rb ~= nil) then
            return ra ~= nil and (rb == nil or ra < rb)
        end

        return a.title < b.title
    end)

    return groups
end

--- The groups with the items that contain every word of `query`.
---@param groups IterPickerGroup[]
---@param query string
---@return IterPickerGroup[]
function M.filter(groups, query)
    local words = vim.split(vim.fn.tolower(query), '%s+', { trimempty = true })
    local result = {}

    for _, group in ipairs(groups) do
        local items = vim.tbl_filter(function(item)
            for _, word in ipairs(words) do
                if not item.haystack:find(word, 1, true) then
                    return false
                end
            end

            return true
        end, group.items)

        if #items > 0 then
            table.insert(
                result,
                { title = group.title, path = group.path, items = items }
            )
        end
    end

    return result
end

---@param keys table<string, string[]>
---@return string
local function footer_of(keys)
    local parts = {}
    local next_lhs, prev_lhs = (keys.next or {})[1], (keys.prev or {})[1]

    if next_lhs ~= nil and prev_lhs ~= nil then
        table.insert(parts, next_lhs .. '/' .. prev_lhs .. ' move')
    end

    for _, action in ipairs({ 'jump', 'edit', 'delete', 'close' }) do
        local lhs = (keys[action] or {})[1]

        if lhs ~= nil then
            table.insert(parts, lhs .. ' ' .. action)
        end
    end

    return ' ' .. table.concat(parts, ' · ') .. ' '
end

---@param zindex integer
---@param footer string
---@return table prompt
---@return table results
local function layout(zindex, footer)
    local width = math.max(20, math.min(MAX_WIDTH, vim.o.columns - 6))
    local height = math.max(3, math.min(MAX_HEIGHT, vim.o.lines - 10))
    local top = math.max(0, math.floor((vim.o.lines - height - 5) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))

    return {
        relative = 'editor',
        row = top,
        col = col,
        width = width,
        height = 1,
        zindex = zindex,
        style = 'minimal',
        border = 'rounded',
        title = ' Comments ',
        title_pos = 'left',
    }, {
        relative = 'editor',
        row = top + 3,
        col = col,
        width = width,
        height = height,
        zindex = zindex,
        style = 'minimal',
        border = 'rounded',
        footer = footer,
        footer_pos = 'left',
        focusable = false,
    }
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

--- Write the shown groups into the results buffer.
function Picker:render()
    local lines, flat, marks = {}, {}, {}
    local width = 0

    for _, group in ipairs(self.shown) do
        for _, item in ipairs(group.items) do
            width = math.max(width, vim.fn.strdisplaywidth(item.loc))
        end
    end

    for _, group in ipairs(self.shown) do
        table.insert(lines, group.title)
        table.insert(marks, { #lines, 0, nil, 'IterDrawerTitle' })

        for position, item in ipairs(group.items) do
            local loc = item.loc
                .. string.rep(' ', width - vim.fn.strdisplaywidth(item.loc))
            local label = item.outdated and 'outdated · ' or ''
            local line = '  ' .. loc .. '  ' .. label .. item.text

            table.insert(lines, line)
            table.insert(flat, item)
            item.lnum = #lines
            item.first = position == 1

            table.insert(marks, { #lines, 2, 2 + #item.loc, 'IterDrawerKey' })

            if item.outdated then
                table.insert(
                    marks,
                    { #lines, 2 + #loc + 2, #line, 'IterDiffCommentOutdated' }
                )
            end
        end
    end

    if #flat == 0 then
        lines = { '  No matching comments' }
        marks = { { 1, 0, nil, 'IterDrawerHint' } }
    end

    self.flat = flat
    set_lines(self.results_buf, lines)
    vim.api.nvim_buf_clear_namespace(self.results_buf, NS, 0, -1)

    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(
            self.results_buf,
            NS,
            mark[1] - 1,
            mark[2],
            {
                end_col = mark[3] or #lines[mark[1]],
                hl_group = mark[4],
            }
        )
    end
end

--- Select item `index` of the shown list, wrapping at both ends.
---@param index? integer
function Picker:select(index)
    vim.api.nvim_buf_clear_namespace(self.results_buf, SELECTED_NS, 0, -1)

    if #self.flat == 0 then
        self.sel = nil
        return
    end

    self.sel = (((index or 1) - 1) % #self.flat) + 1

    local item = self.flat[self.sel]

    vim.api.nvim_buf_set_extmark(
        self.results_buf,
        SELECTED_NS,
        item.lnum - 1,
        0,
        { line_hl_group = 'IterDrawerSelected', priority = 100 }
    )

    -- A window that isn't current doesn't scroll to its cursor by itself.
    local lnum = item.lnum
    local want = item.first and lnum - 1 or lnum

    vim.api.nvim_win_call(self.results_win, function()
        vim.api.nvim_win_set_cursor(0, { lnum, 0 })

        local height = vim.api.nvim_win_get_height(0)
        local top = vim.fn.line('w0')

        if want < top then
            vim.fn.winrestview({ topline = want })
        elseif lnum >= top + height then
            vim.fn.winrestview({ topline = lnum - height + 1 })
        end
    end)
end

---@return string
function Picker:query()
    return table.concat(
        vim.api.nvim_buf_get_lines(self.prompt_buf, 0, -1, false),
        ' '
    )
end

--- Apply the prompt's text, keeping the selected comment selected when it
--- is still listed.
function Picker:refilter()
    local keep = self.sel ~= nil and self.flat[self.sel].comment.id or nil

    self.shown = M.filter(self.groups, self:query())
    self:render()

    local index = 1

    for i, item in ipairs(self.flat) do
        if item.comment.id == keep then
            index = i
        end
    end

    self:select(index)
end

---@return IterComment?
function Picker:selected()
    return self.sel ~= nil and self.flat[self.sel].comment or nil
end

---@param restore? boolean give the focus back to the window the picker came from
function Picker:close(restore)
    if self.closed then
        return
    end

    local own = vim.api.nvim_get_current_win()
    restore = restore or own == self.prompt_win or own == self.results_win

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    vim.cmd.stopinsert()

    for _, win in ipairs({ self.prompt_win, self.results_win }) do
        if util.is_valid_win(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    if current == self then
        current = nil
    end

    if restore and util.is_valid_win(self.prev_win) then
        vim.api.nvim_set_current_win(self.prev_win)
    end
end

--- Read the store again and list it. Closes when nothing is left.
function Picker:reload()
    local data, err = store.load(self.opts.root)

    if data == nil then
        util.error(err, 'Cannot read the comments')
        self:close(true)
        return
    end

    if #data.comments == 0 then
        self:close(true)
        return
    end

    local cache = {}

    self.groups = M.groups(data.comments, self.opts.order, function(path)
        if cache[path] == nil then
            cache[path] = M.file_lines(self.opts.root, path) or false
        end

        return cache[path] or nil
    end)
    self:refilter()
end

function Picker:jump()
    local comment = self:selected()

    if comment == nil then
        return
    end

    self:close(true)
    self.opts.jump(comment)
end

function Picker:edit()
    local comment = self:selected()

    if comment == nil then
        return
    end

    self:close(true)
    vim.schedule(function()
        self.opts.edit(comment)
    end)
end

function Picker:delete()
    local comment = self:selected()

    if comment == nil then
        return
    end

    local first = vim.split(comment.body, '\n')[1]

    if
        vim.fn.confirm('Delete the comment?\n' .. first, '&Delete\n&No', 2) ~= 1
    then
        return
    end

    local _, err = store.remove_comments(self.opts.root, { comment.id })

    if err ~= nil then
        util.warn('Cannot delete the comment: ' .. err)
        return
    end

    local sel = self.sel
    self:reload()

    if not self.closed then
        self:select(math.min(sel or 1, #self.flat))
    end

    if self.opts.on_change ~= nil then
        self.opts.on_change()
    end
end

--- Open the picker over the comments stored for `opts.root`.
---@param opts IterPickerOpenOptions
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.root', opts.root, 'string')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.order', opts.order, 'table', true)
    vim.validate('opts.jump', opts.jump, 'function')
    vim.validate('opts.edit', opts.edit, 'function')
    vim.validate('opts.on_change', opts.on_change, 'function', true)

    local data, err = store.load(opts.root)

    if data == nil then
        util.error(err, 'Cannot read the comments')
        return
    end

    if #data.comments == 0 then
        util.warn('No comments')
        return
    end

    if current ~= nil then
        current:close()
    end

    highlight.setup()

    local keys = opts.config.keys.picker
    local zindex = opts.config.options.drawer.zindex + 10
    local footer = footer_of(keys)
    local prompt_config, results_config = layout(zindex, footer)

    local prev_win = vim.api.nvim_get_current_win()
    local results_buf = vim.api.nvim_create_buf(false, true)
    local prompt_buf = vim.api.nvim_create_buf(false, true)

    for _, buf in ipairs({ results_buf, prompt_buf }) do
        vim.bo[buf].bufhidden = 'wipe'
        vim.bo[buf].filetype = 'iterpicker'
    end

    vim.bo[results_buf].modifiable = false

    local results_win =
        vim.api.nvim_open_win(results_buf, false, results_config)
    local prompt_win = vim.api.nvim_open_win(prompt_buf, true, prompt_config)

    vim.wo[results_win].wrap = false

    local self = setmetatable({
        opts = opts,
        groups = {},
        shown = {},
        flat = {},
        results_buf = results_buf,
        results_win = results_win,
        prompt_buf = prompt_buf,
        prompt_win = prompt_win,
        prev_win = prev_win,
        group = vim.api.nvim_create_augroup(GROUP, { clear = true }),
        closed = false,
    }, Picker)

    current = self

    keymap.attach(prompt_buf, 'picker', keys, {
        next = function()
            self:select((self.sel or 0) + 1)
        end,
        prev = function()
            self:select((self.sel or 2) - 1)
        end,
        jump = function()
            self:jump()
        end,
        edit = function()
            self:edit()
        end,
        delete = function()
            self:delete()
        end,
        close = function()
            self:close(true)
        end,
    })

    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = self.group,
        buffer = prompt_buf,
        callback = function()
            self:refilter()
        end,
    })
    vim.api.nvim_create_autocmd('VimResized', {
        group = self.group,
        callback = function()
            local prompt, results = layout(zindex, footer)
            vim.api.nvim_win_set_config(self.prompt_win, prompt)
            vim.api.nvim_win_set_config(self.results_win, results)
        end,
    })
    vim.api.nvim_create_autocmd('WinLeave', {
        group = self.group,
        buffer = prompt_buf,
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })

    self:reload()
    vim.cmd.startinsert()
end

---@return boolean
function M.is_open()
    return current ~= nil and not current.closed
end

--- The results window, nil while closed.
---@return integer?
function M.win()
    return M.is_open() and current.results_win or nil
end

--- The prompt window, nil while closed.
---@return integer?
function M.prompt_win()
    return M.is_open() and current.prompt_win or nil
end

--- The selected comment, nil while closed or when nothing is listed.
---@return IterComment?
function M.selected()
    return M.is_open() and current:selected() or nil
end

return M
