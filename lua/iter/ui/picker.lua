--- A list to pick one item from, as a page of the panel: a title, the
--- items under section titles, and two lines of key hints at the bottom.

local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local render = require('iter.ui.render')

local M = {}

---@alias IterPickerLabel string|[string, string?][]|fun(width: integer): [string, string?][] a label, its chunks of text and highlight group, or a function that fits them to `width` cells

---@class IterPickerItem
---@field label IterPickerLabel
---@field tag? string a word at the right edge, such as `parent`

---@class IterPickerPageOpts
---@field title string
---@field items IterPickerItem[] in order; the first takes the cursor
---@field sections? table<integer, string> a title line above the item at that index, after a blank line
---@field keys table<string, string[]> resolved keys of the picker view
---@field on_pick fun(index: integer)
---@field on_close fun() after the close key

---@class IterPickerPage: IterPanelPage
---@field buf integer
---@field opts IterPickerPageOpts
---@field handlers table<string, fun()>
---@field indexes table<integer, integer> buffer line → item index
---@field lnum integer the cursor line the page saw last
local Page = {}
Page.__index = Page

-- Cells left of an item: the gutter the panel draws `▸` over.
local GUTTER = '  '

--- The chunks of `item` in `width` cells, its tag at the right edge.
---@param item IterPickerItem
---@param width integer
---@return [string, string?][]
local function item_chunks(item, width)
    local tag = item.tag and (' ' .. item.tag .. ' ') or ''
    local room = width - #GUTTER - vim.fn.strdisplaywidth(tag)
    local label = item.label
    ---@type [string, string?][]
    local chunks

    if type(label) == 'function' then
        chunks = label(room)
    elseif type(label) == 'string' then
        chunks = { { label } }
    else
        chunks = vim.deepcopy(label)
    end

    table.insert(chunks, 1, { GUTTER })

    if tag ~= '' then
        local used = 0

        for _, chunk in ipairs(chunks) do
            used = used + vim.fn.strdisplaywidth(chunk[1])
        end

        table.insert(chunks, {
            string.rep(' ', math.max(1, width - used - #tag)),
        })
        table.insert(chunks, { tag, 'IterDrawerHint' })
    end

    return chunks
end

--- The page of `opts.items`, its keys mapped on its own buffer.
---@param opts IterPickerPageOpts
---@return IterPickerPage
function M.page(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.title', opts.title, 'string')
    vim.validate('opts.items', opts.items, 'table')
    vim.validate('opts.sections', opts.sections, 'table', true)
    vim.validate('opts.keys', opts.keys, 'table')
    vim.validate('opts.on_pick', opts.on_pick, 'function')
    vim.validate('opts.on_close', opts.on_close, 'function')

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iterpicker'

    local self = setmetatable({
        buf = buf,
        opts = opts,
        indexes = {},
        lnum = 1,
    }, Page)

    self.handlers = {
        pick = function()
            local index = self:index()

            if index ~= nil then
                opts.on_pick(index)
            end
        end,
        close = function()
            opts.on_close()
        end,
    }

    keymap.attach(buf, 'picker', opts.keys, self.handlers)

    return self
end

---@param width integer
---@param height integer
function Page:render(width, height)
    local opts = self.opts
    local lines = {
        render.chunks_line({ { ' ' .. opts.title, 'IterDrawerTitle' } }),
        render.chunks_line({
            { ' ' },
            { '/', 'IterDrawerKey' },
            { ' search', 'IterDrawerHint' },
        }),
    }

    self.indexes = {}

    for index, item in ipairs(opts.items) do
        local title = opts.sections and opts.sections[index]

        if title ~= nil or index == 1 then
            table.insert(lines, render.line(''))
        end

        if title ~= nil then
            table.insert(
                lines,
                render.chunks_line({ { ' ' .. title, 'IterDrawerTitle' } })
            )
        end

        table.insert(lines, render.chunks_line(item_chunks(item, width)))
        self.indexes[#lines] = index
    end

    local bound = keymap.list('picker', opts.keys, self.handlers)
    local pick = layout.hints(bound, { { 'pick', 'pick' } }, width - 1)

    if #pick > 0 then
        pick[#pick][1] = pick[#pick][1] .. '  '
    end

    vim.list_extend(
        pick,
        { { '/', 'IterDrawerKey' }, { ' search', 'IterDrawerHint' } }
    )

    local hints = {
        pick,
        layout.hints(bound, { { 'close', 'back to the tree' } }, width - 1),
    }

    layout.bottom_hints(lines, hints, height)

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, render.text_lines(lines))
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, lines)
end

--- Snap the cursor to the nearest item line, looking the way it moved.
---@param lnum integer
---@param prev integer
function Page:on_cursor(lnum, prev)
    local dir = lnum < prev and -1 or 1
    local last = vim.api.nvim_buf_line_count(self.buf)

    for _, step in ipairs({ dir, -dir }) do
        local l = lnum

        while l >= 1 and l <= last do
            if self.indexes[l] ~= nil then
                if l ~= lnum then
                    vim.api.nvim_win_set_cursor(0, { l, 0 })
                end

                self.lnum = l
                return
            end

            l = l + step
        end
    end

    self.lnum = lnum
end

--- The index of the item under the cursor.
---@return integer?
function Page:index()
    return self.indexes[self.lnum]
end

--- The line of item `index`.
---@param index integer
---@return integer?
function Page:line_of(index)
    for lnum, i in pairs(self.indexes) do
        if i == index then
            return lnum
        end
    end

    return nil
end

--- Wipe the page's buffer.
function Page:close()
    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end
end

return M
