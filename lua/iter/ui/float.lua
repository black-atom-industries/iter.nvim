local util = require('iter.util')

local M = {}

---@class IterFloatOpts
---@field pane integer window the float is anchored to
---@field buf integer
---@field zindex integer
---@field height number up to 1 a fraction of the pane's height, else lines
---@field enter? boolean focus the float

---@class IterFloat
---@field win integer
---@field pane integer
---@field opts IterFloatOpts
---@field group integer
local Float = {}
Float.__index = Float

--- Rows of the pane's text area, without its winbar.
---@param pane integer
---@return integer
local function text_height(pane)
    return vim.fn.getwininfo(pane)[1].height
end

---@param opts IterFloatOpts
---@return integer
local function resolve_height(opts)
    local pane_height = text_height(opts.pane)
    local height = opts.height

    if height <= 1 then
        height = math.floor(pane_height * height)
    end

    return math.max(1, math.min(math.floor(height), pane_height))
end

---@param opts IterFloatOpts
---@return table
local function win_config(opts)
    local height = resolve_height(opts)

    return {
        relative = 'win',
        win = opts.pane,
        anchor = 'SW',
        row = text_height(opts.pane),
        col = 0,
        width = vim.api.nvim_win_get_width(opts.pane),
        height = height,
        zindex = opts.zindex,
        style = 'minimal',
        focusable = true,
    }
end

--- Open a float over the bottom of `opts.pane`, as wide as the pane.
---@param opts IterFloatOpts
---@return IterFloat
function M.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.pane', opts.pane, 'number')
    vim.validate('opts.buf', opts.buf, 'number')
    vim.validate('opts.zindex', opts.zindex, 'number')
    vim.validate('opts.height', opts.height, 'number')

    local win =
        vim.api.nvim_open_win(opts.buf, opts.enter == true, win_config(opts))

    local self = setmetatable({
        win = win,
        pane = opts.pane,
        opts = vim.deepcopy(opts),
    }, Float)

    self.group =
        vim.api.nvim_create_augroup('iter.float.' .. win, { clear = true })

    vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
        group = self.group,
        callback = function()
            self:reposition()
        end,
    })
    -- A winbar appearing or going away resizes the text area without a
    -- WinResized.
    vim.api.nvim_create_autocmd('OptionSet', {
        group = self.group,
        pattern = 'winbar',
        callback = function()
            self:reposition()
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = { tostring(opts.pane), tostring(win) },
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })

    return self
end

---@return boolean
function Float:is_open()
    return util.is_valid_win(self.win)
end

--- Fit the float to its pane again, optionally with a new height.
---@param overrides? { height?: number }
function Float:reposition(overrides)
    if overrides ~= nil and overrides.height ~= nil then
        self.opts.height = overrides.height
    end

    if not self:is_open() then
        return
    end

    if not util.is_valid_win(self.pane) then
        self:close()
        return
    end

    vim.api.nvim_win_set_config(self.win, win_config(self.opts))
end

function Float:close()
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
end

return M
