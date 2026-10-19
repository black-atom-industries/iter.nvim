local util = require('iter.util')

local M = {}

-- Floats take the editor's background, not the colorscheme's float one.
local WINHIGHLIGHT = table.concat({
    'NormalFloat:IterDrawer',
    'FloatBorder:IterDrawer',
    'FloatTitle:IterDrawer',
    'FloatFooter:IterDrawer',
}, ',')

---@param win integer
local function paint(win)
    vim.api.nvim_set_option_value(
        'winhighlight',
        WINHIGHLIGHT,
        { scope = 'local', win = win }
    )
end

---@class IterFloatOpts
---@field pane integer window the float is anchored to
---@field buf integer
---@field zindex integer
---@field height number up to 1 a fraction of the pane's height, else lines
---@field enter? boolean focus the float
---@field chrome? boolean a header row above and a hint row below the text
---@field title? [string, string][] header chunks, with `chrome`
---@field footer? [string, string][] hint chunks, with `chrome`
---@field min_lines? integer text lines kept when `height` gives fewer
---@field strip? IterFloatStrip|false a window pinned under the text, with `chrome`
---@field side? IterFloatSide|false a window over the right of the text rows

---@class IterFloatStrip rows pinned at the bottom of the float's footprint, between its text and the footer; never focused
---@field buf integer
---@field lines integer

---@class IterFloatSide a focusable window over the float's text rows, from `col` to the right edge, above the float
---@field buf integer
---@field col integer display column of the text area it starts at

---@class IterFloat
---@field win integer
---@field strip_win? integer the strip's window while `opts.strip` has lines
---@field side_win? integer the side window while `opts.side` is set
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
-- With a strip the title row stays on the float and the footer row moves
-- under the strip.
local TITLE_BORDER = { '', ' ', '', '', '', '', '', '' }
local FOOTER_BORDER = { '', '', '', '', '', ' ', '', '' }

---@param opts IterFloatOpts
---@return IterFloatStrip?
local function strip_of(opts)
    local strip = opts.strip

    if not opts.chrome or not strip or strip.lines <= 0 then
        return nil
    end

    return strip
end

--- Text rows of the float. `opts.height` counts the chrome rows and the
--- strip too, so the footprint stays the same with and without a strip.
---@param opts IterFloatOpts
---@return integer
local function resolve_height(opts)
    local pane_height = text_height(opts.pane)
    local strip = strip_of(opts)
    local reserved = (opts.chrome and 2 or 0) + (strip and strip.lines or 0)
    local height = opts.height

    if height <= 1 then
        height = math.floor(pane_height * height)
    end

    if opts.min_lines ~= nil then
        height = math.max(height, opts.min_lines + reserved)
    end

    height = math.min(math.floor(height), pane_height) - reserved

    return math.max(1, height)
end

--- The float's window config, and the strip's when there is one.
---@param opts IterFloatOpts
---@return table config
---@return table? strip_config
local function win_config(opts)
    local height = resolve_height(opts)
    local strip = strip_of(opts)
    local bottom = text_height(opts.pane)
    local width = vim.api.nvim_win_get_width(opts.pane)

    local config = {
        relative = 'win',
        win = opts.pane,
        anchor = 'SW',
        row = strip and (bottom - strip.lines - 1) or bottom,
        col = 0,
        width = width,
        height = height,
        zindex = opts.zindex,
        style = 'minimal',
        focusable = true,
    }

    if not opts.chrome then
        return config
    end

    config.title = opts.title or ''
    config.title_pos = 'left'

    if strip == nil then
        config.border = CHROME_BORDER
        config.footer = opts.footer or ''
        config.footer_pos = 'left'

        return config
    end

    config.border = TITLE_BORDER

    return config,
        {
            relative = 'win',
            win = opts.pane,
            anchor = 'SW',
            row = bottom,
            col = 0,
            width = width,
            height = strip.lines,
            zindex = opts.zindex,
            style = 'minimal',
            focusable = false,
            border = FOOTER_BORDER,
            footer = opts.footer or '',
            footer_pos = 'left',
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

    local config, strip_config = win_config(opts)
    local win = vim.api.nvim_open_win(opts.buf, opts.enter == true, config)
    paint(win)

    local self = setmetatable({
        win = win,
        pane = opts.pane,
        opts = vim.deepcopy(opts),
    }, Float)

    self:place_strip(strip_config)
    self:place_side()

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

--- Give `win` the config `fit()` returns again whenever the editor or a
--- window is resized, until `win` closes. For floats that `M.open` doesn't
--- lay out.
---@param win integer
---@param fit fun(): vim.api.keyset.win_config
function M.follow_resize(win, fit)
    local group = vim.api.nvim_create_augroup(
        'iter.float.resize.' .. win,
        { clear = true }
    )

    vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
        group = group,
        callback = function()
            if util.is_valid_win(win) then
                vim.api.nvim_win_set_config(win, fit())
            end
        end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
        group = group,
        pattern = tostring(win),
        once = true,
        callback = function()
            pcall(vim.api.nvim_del_augroup_by_id, group)
        end,
    })
end

---@return boolean
function Float:is_open()
    return util.is_valid_win(self.win)
end

---@class IterFloatOverrides
---@field height? number
---@field title? [string, string][]
---@field footer? [string, string][]
---@field min_lines? integer
---@field strip? IterFloatStrip|false
---@field side? IterFloatSide|false

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

    local config, strip_config = win_config(self.opts)

    -- The footer moves between the float and the strip: drop it from the
    -- window losing its bottom edge first.
    if strip_config ~= nil then
        config.footer = nil
        vim.api.nvim_win_set_config(self.win, {
            relative = config.relative,
            win = config.win,
            row = config.row,
            col = config.col,
            footer = '',
        })
    end

    vim.api.nvim_win_set_config(self.win, config)
    self:place_strip(strip_config)
    self:place_side()
end

--- Open, move or close the side window to match `opts.side`.
function Float:place_side()
    local side = self.opts.side
    local win = self.side_win or -1
    local open = util.is_valid_win(win)

    if not side or not self:is_open() then
        -- Cleared first, so a WinClosed handler sees the close as the
        -- float's own.
        self.side_win = nil

        if open then
            vim.api.nvim_win_close(win, true)
        end

        return
    end

    local width = vim.api.nvim_win_get_width(self.win)
    local config = {
        relative = 'win',
        win = self.win,
        row = 0,
        col = side.col,
        width = math.max(1, width - side.col),
        height = vim.api.nvim_win_get_height(self.win),
        zindex = self.opts.zindex + 1,
        style = 'minimal',
        focusable = true,
    }

    if open and vim.api.nvim_win_get_buf(win) == side.buf then
        vim.api.nvim_win_set_config(win, config)
        return
    end

    self.side_win = nil

    if open then
        vim.api.nvim_win_close(win, true)
    end

    self.side_win = vim.api.nvim_open_win(side.buf, false, config)
    paint(self.side_win)
    -- A new window copies the jumplist of the one it opens from.
    vim.api.nvim_win_call(self.side_win, function()
        vim.cmd.clearjumps()
    end)

    for name, value in pairs({ wrap = false, winfixbuf = true }) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = self.side_win }
        )
    end
end

--- Open, move or close the strip's window to match `config`.
---@param config? table
function Float:place_strip(config)
    local open = self.strip_win ~= nil and util.is_valid_win(self.strip_win)

    if config == nil then
        if open then
            vim.api.nvim_win_close(self.strip_win, true)
        end

        self.strip_win = nil
        return
    end

    local strip = strip_of(self.opts)

    if strip == nil then
        return
    end

    local buf = strip.buf

    if open and vim.api.nvim_win_get_buf(self.strip_win) == buf then
        vim.api.nvim_win_set_config(self.strip_win, config)
        return
    end

    if open then
        vim.api.nvim_win_close(self.strip_win, true)
    end

    self.strip_win = vim.api.nvim_open_win(buf, false, config)
    paint(self.strip_win)
    vim.api.nvim_set_option_value(
        'wrap',
        false,
        { scope = 'local', win = self.strip_win }
    )
end

function Float:close()
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self:place_strip(nil)
    self.opts.side = false
    self:place_side()

    if self:is_open() then
        vim.api.nvim_win_close(self.win, true)
    end
end

return M
