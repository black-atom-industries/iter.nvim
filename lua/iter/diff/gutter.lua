--- The ribbons of one split view on screen: the chunks of its document, the
--- canvas over its gutter, and the image sent last, so an image that wouldn't
--- change isn't sent again.

local Canvas = require('iter.graphics.canvas')
local Surface = require('iter.graphics.surface')
local graphics = require('iter.graphics')
local ribbons = require('iter.diff.ribbons')

---@class IterDiffGutter
---@field win integer the new side's window
---@field canvas IterCanvas
---@field chunks IterRibbonChunk[]
---@field rows IterDocRow[] the new side
---@field active? IterRibbonChunk the chunk under the cursor
---@field key? string what the image sent last shows
local Gutter = {}
Gutter.__index = Gutter

-- Rows whose background runs through the gutter.
local BAND_HL = {
    header = 'IterDiffHeader',
    hunk = 'IterDiffHunk',
    gap = 'IterDiffGap',
}

---@param win integer
---@return IterDiffGutter
function Gutter.new(win)
    return setmetatable({
        win = win,
        canvas = Canvas.new({ anchor = win, col = -1, cols = ribbons.COLS }),
        chunks = {},
        rows = {},
    }, Gutter)
end

--- Show the chunks of `doc` from now on.
---@param doc IterDocument
function Gutter:set_document(doc)
    self.chunks = ribbons.chunks(doc)
    self.rows = doc.rows
    self.active = nil
    self.key = nil
end

--- Make the chunk at `lnum` the active one.
---@param lnum integer
---@return boolean changed
function Gutter:set_cursor(lnum)
    local chunk = ribbons.chunk_at(self.chunks, lnum)

    if chunk == self.active then
        return false
    end

    self.active = chunk

    return true
end

--- Whether `lnum` belongs to the chunk under the cursor.
---@param lnum integer
---@return boolean
function Gutter:is_active(lnum)
    local chunk = self.active

    return chunk ~= nil and lnum >= chunk.first and lnum <= chunk.last
end

---@param name string
---@param field 'bg'|'fg'|'sp'
---@return integer?
local function hl_color(name, field)
    return vim.api.nvim_get_hl(0, { name = name, link = false })[field]
end

---@return IterRibbonPalette
local function palette()
    ---@param name string
    ---@return integer[]
    local function band(name)
        return graphics.pixel(hl_color(name, 'bg') or 0x808080)
    end

    return {
        add = band('IterDiffAdd'),
        del = band('IterDiffDelete'),
        add_active = band('IterDiffAddCursor'),
        del_active = band('IterDiffDeleteCursor'),
    }
end

--- A function from a line to its screen row, also off screen: lines above the
--- top line end above row 0, and rows between lines hold their `virt_lines`.
---@param win integer
---@param top integer
---@return fun(lnum: integer): number
local function screen_rows(win, top)
    local topfill = vim.api.nvim_win_call(win, vim.fn.winsaveview).topfill or 0

    ---@param from integer
    ---@param to integer
    ---@return integer
    local function height(from, to)
        return vim.api.nvim_win_text_height(win, {
            start_row = from - 1,
            end_row = to - 1,
        }).all
    end

    return function(lnum)
        if lnum == top then
            return topfill
        elseif lnum > top then
            return topfill + height(top, lnum - 1)
        end

        return -height(lnum, top - 1)
    end
end

--- The rows in view that run through the gutter.
---@param first integer
---@param last integer
---@param top_of fun(lnum: integer): number
---@return IterRibbonBand[]
function Gutter:bands(first, last, top_of)
    local bands = {}

    for lnum = first, last do
        local kind = self.rows[lnum] and self.rows[lnum].kind

        if kind == 'blank' then
            local color = hl_color('IterDiffHeaderRule', 'fg')

            if color ~= nil then
                table.insert(bands, {
                    y = top_of(lnum),
                    color = graphics.pixel(color),
                    rule = true,
                })
            end
        elseif BAND_HL[kind] ~= nil then
            local color = hl_color(BAND_HL[kind], 'bg')

            if color ~= nil then
                table.insert(bands, {
                    y = top_of(lnum),
                    color = graphics.pixel(color),
                })
            end
        end
    end

    return bands
end

--- Open the canvas if it isn't, and send the image if it changed.
function Gutter:draw()
    local rows = self.canvas:place()
    local cell = graphics.cell_size()
    local first = vim.fn.line('w0', self.win)
    local last = vim.fn.line('w$', self.win)
    local top_of = screen_rows(self.win, first)
    local shapes =
        ribbons.shapes(self.chunks, rows, top_of, first, last, self.active)
    local bands = self:bands(first, last, top_of)
    local colors = palette()
    local key = vim.inspect({ rows, cell, shapes, bands, colors })

    if key == self.key then
        return
    end

    local surface = Surface.new(ribbons.COLS * cell.w, rows * cell.h)

    ribbons.paint(surface, shapes, bands, colors, cell.h)
    self.canvas:draw(surface)
    self.key = key
end

--- Close the canvas until the next `draw`.
function Gutter:hide()
    self.canvas:hide()
    self.key = nil
end

--- Close the canvas and free its image.
function Gutter:close()
    self.canvas:close()
end

return Gutter
