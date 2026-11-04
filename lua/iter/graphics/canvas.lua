-- The compression follows diffbandit.nvim's lua/diffbandit/kitty/zlib.lua
-- (https://github.com/CoreyKaylor/diffbandit.nvim), Apache License 2.0, see
-- LICENSES/Apache-2.0-diffbandit.txt. Changed: restyled, and zlib loads on first
-- use.

--- An image over cells of a window: a non-focusable float holding placeholder
--- text that never changes, and the image behind it, sent anew by `draw`. Other
--- floats cover it as they cover text, so it stays under all of them.

local graphics = require('iter.graphics')
local protocol = require('iter.graphics.protocol')
local util = require('iter.util')

-- Below every other float, whose default is 50.
local ZINDEX = 1

---@type any
local zlib

---@param data string
---@return string? compressed nil when it can't be compressed
local function compress(data)
    local ffi = require('ffi')

    if zlib == nil then
        pcall(
            ffi.cdef,
            [[
            unsigned long compressBound(unsigned long source_length);
            int compress2(uint8_t *dest, unsigned long *dest_length,
                          const uint8_t *source, unsigned long source_length,
                          int level);
        ]]
        )

        local loaded, library = pcall(ffi.load, 'z')

        zlib = loaded and library or false
    end

    if not zlib then
        return nil
    end

    local length = ffi.new('unsigned long[1]', zlib.compressBound(#data))
    local out = ffi.new('uint8_t[?]', tonumber(length[0]))

    if zlib.compress2(out, length, data, #data, 1) ~= 0 then
        return nil
    end

    return ffi.string(out, tonumber(length[0]))
end

---@class IterCanvas
---@field id integer image id, which placeholders show as their foreground
---@field anchor integer window the float moves with
---@field col integer column of the float in the anchor; -1 covers the separator left of it
---@field cols integer
---@field group string highlight group of the placeholder cells
---@field win? integer the float
---@field buf? integer
---@field rows integer rows the float and its placeholders have
---@field on_anchor_closed integer
local Canvas = {}
Canvas.__index = Canvas

local next_id = graphics.FIRST_ID

---@param opts { anchor: integer, col: integer, cols: integer }
---@return IterCanvas
function Canvas.new(opts)
    vim.validate('opts.anchor', opts.anchor, 'number')
    vim.validate('opts.col', opts.col, 'number')
    vim.validate('opts.cols', opts.cols, 'number')

    local id = next_id

    next_id = next_id + 1

    local self = setmetatable({
        id = id,
        anchor = opts.anchor,
        col = opts.col,
        cols = opts.cols,
        group = 'IterCanvas' .. id,
        rows = 0,
    }, Canvas)

    -- A window closed from outside takes its float along.
    self.on_anchor_closed = vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(opts.anchor),
        once = true,
        callback = vim.schedule_wrap(function()
            self:close()
        end),
    })

    return self
end

--- The placeholder cells' colours: the foreground names the image, and
--- transparent pixels show the background.
function Canvas:apply_highlight()
    local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
    local current = vim.api.nvim_get_hl(0, { name = self.group })

    if current.fg ~= self.id or current.bg ~= bg then
        vim.api.nvim_set_hl(0, self.group, { fg = self.id, bg = bg })
    end
end

--- Open the float if it isn't, and give it the anchor's height.
---@return integer rows
function Canvas:place()
    self:apply_highlight()

    local rows =
        math.min(vim.api.nvim_win_get_height(self.anchor), protocol.MAX_CELLS)

    if self.buf == nil or not vim.api.nvim_buf_is_valid(self.buf) then
        self.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[self.buf].bufhidden = 'hide'
        self.rows = 0
    end

    if rows ~= self.rows then
        vim.bo[self.buf].modifiable = true
        vim.api.nvim_buf_set_lines(
            self.buf,
            0,
            -1,
            false,
            protocol.placeholders(self.cols, rows)
        )
        vim.bo[self.buf].modifiable = false
    end

    local config = {
        relative = 'win',
        win = self.anchor,
        row = 0,
        col = self.col,
        width = self.cols,
        height = rows,
    }

    if util.is_valid_win(self.win) then
        if rows ~= self.rows then
            vim.api.nvim_win_set_config(self.win, config)
        end
    else
        self.win = vim.api.nvim_open_win(
            self.buf,
            false,
            vim.tbl_extend('force', config, {
                focusable = false,
                mouse = false,
                style = 'minimal',
                border = 'none',
                zindex = ZINDEX,
                noautocmd = true,
            })
        )

        local win = self.win

        -- A new window takes these from the current one, and a bound float
        -- scrolls its placeholders away.
        vim.wo[win].scrollbind = false
        vim.wo[win].cursorbind = false
        vim.wo[win].winfixwidth = false
        vim.wo[win].wrap = false
        vim.wo[win].winblend = 0
        vim.wo[win].statuscolumn = ''
        vim.wo[win].winhighlight = string.format(
            'Normal:%s,NormalNC:%s,NormalFloat:%s,EndOfBuffer:%s',
            self.group,
            self.group,
            self.group,
            self.group
        )
    end

    self.rows = rows

    return rows
end

--- Show `surface`, whose size is a whole number of cells of the float.
---@param surface IterSurface
function Canvas:draw(surface)
    local bytes = surface:bytes()
    local compressed = compress(bytes)

    graphics.send(protocol.transmit({
        id = self.id,
        width = surface.width,
        height = surface.height,
        cols = self.cols,
        rows = self.rows,
        data = compressed or bytes,
        compressed = compressed ~= nil,
    }))
end

--- Close the float and free the image. `place` opens it again.
function Canvas:hide()
    if util.is_valid_win(self.win) then
        vim.api.nvim_win_close(self.win, true)
    end

    self.win = nil

    if self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end

    self.buf = nil
    self.rows = 0
end

--- Close the float for good.
function Canvas:close()
    self:hide()
    pcall(vim.api.nvim_del_autocmd, self.on_anchor_closed)

    if graphics.on() then
        graphics.send(protocol.delete(self.id))
    end
end

return Canvas
