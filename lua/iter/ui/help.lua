local float = require('iter.ui.float')
local keymap = require('iter.keymap')
local util = require('iter.util')

local M = {}

---@class IterHelpOpts
---@field view IterView view whose keys are listed
---@field keys table<string, string[]> resolved keys of the view
---@field handlers table<string, fun()> the view's handlers
---@field close_keys table<string, string[]> resolved keys of the help view
---@field zindex integer

---@class IterHelp
---@field win integer
---@field buf integer
---@field group integer
local Help = {}
Help.__index = Help

--- One line per handled action of the view: its keys, then what it does.
---@param entries IterKeymapEntry[]
---@return string[]
local function help_lines(entries)
    local width = 0

    for _, entry in ipairs(entries) do
        width = math.max(
            width,
            vim.fn.strdisplaywidth(table.concat(entry.lhs, ' '))
        )
    end

    return vim.tbl_map(function(entry)
        local lhs = table.concat(entry.lhs, ' ')
        local pad = string.rep(' ', width - vim.fn.strdisplaywidth(lhs))

        return ' ' .. lhs .. pad .. '  ' .. entry.desc .. ' '
    end, entries)
end

--- The help float's config: `width` by `height` in the middle of the editor.
---@param width integer
---@param height integer
---@param zindex integer
---@return vim.api.keyset.win_config
local function centered(width, height, zindex)
    return {
        relative = 'editor',
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
        width = math.min(width, vim.o.columns),
        height = math.min(height, vim.o.lines),
        zindex = zindex,
    }
end

--- Open a centered, focused float listing the keys of `opts.view`. It
--- stays centered when the editor is resized.
---@param opts IterHelpOpts
---@return IterHelp
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.view', opts.view, 'string')
    vim.validate('opts.keys', opts.keys, 'table')
    vim.validate('opts.handlers', opts.handlers, 'table')
    vim.validate('opts.close_keys', opts.close_keys, 'table')
    vim.validate('opts.zindex', opts.zindex, 'number')

    local lines = help_lines(keymap.list(opts.view, opts.keys, opts.handlers))
    local width = 1

    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iterhelp'

    local height = math.max(1, #lines)
    local win = vim.api.nvim_open_win(
        buf,
        true,
        vim.tbl_extend('force', centered(width, height, opts.zindex), {
            style = 'minimal',
            border = 'rounded',
            title = ' Keys ',
            title_pos = 'center',
        })
    )

    float.follow_resize(win, function()
        return centered(width, height, opts.zindex)
    end)

    local self = setmetatable({ win = win, buf = buf }, Help)

    keymap.attach(buf, 'help', opts.close_keys, {
        close = function()
            self:close()
        end,
    })

    self.group =
        vim.api.nvim_create_augroup('iter.help.' .. buf, { clear = true })
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
function Help:is_open()
    return util.is_valid_win(self.win)
end

function Help:close()
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
end

return M
