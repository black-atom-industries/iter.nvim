local float = require('iter.ui.float')
local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')

local M = {}

---@class IterPickerOpts
---@field over IterFloat the float whose footprint the picker covers
---@field title string
---@field items string[] the labels, in order; the first is selected
---@field sections? table<integer, string> a title shown above the item at that index, never selected
---@field keys table<string, string[]> resolved keys of the picker view
---@field on_pick fun(index: integer) after the picker closed
---@field on_close? fun() after a key closed the picker, before `on_pick`

---@class IterPicker
---@field float IterFloat
---@field buf integer
---@field group integer
local Picker = {}
Picker.__index = Picker

local SECTIONS_NS = vim.api.nvim_create_namespace('iter.picker.sections')

local HINTS = { { 'pick', 'pick' }, { 'close', 'back' } }

--- Open a focused list over `opts.over`, with its chrome, its height and
--- above its side window.
---@param opts IterPickerOpts
---@return IterPicker
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.over', opts.over, 'table')
    vim.validate('opts.title', opts.title, 'string')
    vim.validate('opts.items', opts.items, 'table')
    vim.validate('opts.sections', opts.sections, 'table', true)
    vim.validate('opts.keys', opts.keys, 'table')
    vim.validate('opts.on_pick', opts.on_pick, 'function')
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local buf = vim.api.nvim_create_buf(false, true)
    -- One column in, as the drawer's rows start.
    vim.api.nvim_buf_set_lines(
        buf,
        0,
        -1,
        false,
        vim.tbl_map(function(label)
            return ' ' .. label
        end, opts.items)
    )
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iterpicker'

    for index, title in pairs(opts.sections or {}) do
        vim.api.nvim_buf_set_extmark(buf, SECTIONS_NS, index - 1, 0, {
            virt_lines = { { { '' } }, { { ' ' .. title, 'IterDrawerTitle' } } },
            virt_lines_above = true,
        })
    end

    local self = setmetatable({ buf = buf }, Picker)

    local function leave()
        self:close()

        if opts.on_close ~= nil then
            opts.on_close()
        end
    end

    local handlers = {
        pick = function()
            local index = vim.api.nvim_win_get_cursor(0)[1]

            leave()
            opts.on_pick(index)
        end,
        close = leave,
    }
    local over = opts.over.opts

    self.float = float.open({
        pane = over.pane,
        left = over.left,
        buf = buf,
        zindex = over.zindex + 5,
        height = over.height,
        min_lines = over.min_lines,
        enter = true,
        chrome = true,
        rule = over.rule,
        title = { { opts.title, 'IterDrawerTitle' } },
        footer = layout.hints(
            keymap.list('picker', opts.keys, handlers),
            HINTS,
            vim.api.nvim_win_get_width(opts.over.win) - 1
        ),
    })

    local win = self.float.win

    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winhighlight = vim.wo[win].winhighlight
        .. ',CursorLine:IterDrawerSelected'

    keymap.attach(buf, 'picker', opts.keys, handlers)

    self.group =
        vim.api.nvim_create_augroup('iter.picker.' .. buf, { clear = true })
    vim.api.nvim_create_autocmd('WinLeave', {
        group = self.group,
        buffer = buf,
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })

    return self
end

---@return boolean
function Picker:is_open()
    return self.float:is_open()
end

function Picker:close()
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if not self:is_open() then
        return
    end

    self.float:close()
end

return M
