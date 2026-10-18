local util = require('iter.util')

local M = {}

---@class IterFloatOpts
---@field pane integer window the float is anchored to
---@field buf integer
---@field zindex integer
---@field height number up to 1 a fraction of the pane's height, else lines
---@field enter? boolean focus the float
---@field chrome? boolean a header row above and a hint row below the text
---@field title? [string, string][] header chunks, with `chrome`
---@field footer? [string, string][] hint chunks, with `chrome`
---@field fit? integer text lines to grow to, up to half the pane

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

-- Top and bottom edges only: one row each for the title and the footer.
local CHROME_BORDER = { '', ' ', '', '', '', ' ', '', '' }

--- Text rows of the float. `opts.height` and the half-pane cap for `fit`
--- count the chrome rows too.
---@param opts IterFloatOpts
---@return integer
local function resolve_height(opts)
    local pane_height = text_height(opts.pane)
    local chrome = opts.chrome and 2 or 0
    local height = opts.height

    if height <= 1 then
        height = math.floor(pane_height * height)
    end

    if opts.fit ~= nil then
        local fitted = math.min(opts.fit + chrome, math.floor(pane_height / 2))
        height = math.max(height, fitted)
    end

    height = math.min(math.floor(height), pane_height) - chrome

    return math.max(1, height)
end

---@param opts IterFloatOpts
---@return table
local function win_config(opts)
    local height = resolve_height(opts)

    local config = {
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

    if opts.chrome then
        config.border = CHROME_BORDER
        config.title = opts.title or ''
        config.title_pos = 'left'
        config.footer = opts.footer or ''
        config.footer_pos = 'left'
    end

    return config
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

---@class IterFloatOverrides
---@field height? number
---@field title? [string, string][]
---@field footer? [string, string][]
---@field fit? integer

--- Fit the float to its pane again, optionally with new options.
---@param overrides? IterFloatOverrides
function Float:reposition(overrides)
    self.opts = vim.tbl_extend('force', self.opts, overrides or {})

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
