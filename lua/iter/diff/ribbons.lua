-- The curve follows diffbandit.nvim's lua/diffbandit/kitty/raster.lua
-- (https://github.com/CoreyKaylor/diffbandit.nvim), Apache License 2.0, see
-- LICENSES/Apache-2.0-diffbandit.txt. Changed: rewritten for iter's chunks,
-- colours and gutter.

--- The bands between the two sides of the split layout, see
--- tests/visual_contract.md. A chunk is a run of lines with a change on either
--- side. The functions here are pure, from the document and the rows it takes
--- on screen to shapes and pixels; `iter.diff.view` shows them.

local M = {}

--- Cells of the gutter: the separator, which the float covers, and `EXTRA`
--- blank cells at the left of the new side's rail.
M.COLS = 5
M.EXTRA = M.COLS - 1

-- Thickness of a thin line, as a share of a row.
local LINE = 1 / 18

-- Curve control points, as shares of the gutter's width.
local CONTROL_1, CONTROL_2 = 0.3, 0.7

-- Samples per pixel column, for smooth edges.
local SAMPLES = 4

---@class IterRibbonChunk
---@field first integer first line
---@field last integer last line
---@field old_first? integer first line with old text
---@field old_last? integer
---@field new_first? integer first line with new text
---@field new_last? integer

---@param rows IterDocRow[]
---@param old_rows IterDocRow[]
---@param lnum integer
---@return boolean
local function changed(rows, old_rows, lnum)
    return rows[lnum].kind == 'add' or old_rows[lnum].kind == 'del'
end

--- The chunks of a split document, in line order.
---@param doc IterDocument
---@return IterRibbonChunk[]
function M.chunks(doc)
    local chunks = {}
    local rows, old_rows = doc.rows, doc.old_rows or {}
    local current

    for lnum = 1, #rows do
        if changed(rows, old_rows, lnum) then
            if current == nil then
                current = { first = lnum, last = lnum }
                table.insert(chunks, current)
            end

            current.last = lnum

            if old_rows[lnum].kind == 'del' then
                current.old_first = current.old_first or lnum
                current.old_last = lnum
            end

            if rows[lnum].kind == 'add' then
                current.new_first = current.new_first or lnum
                current.new_last = lnum
            end
        else
            current = nil
        end
    end

    return chunks
end

--- The chunk with `lnum`, nil on a line outside them.
---@param chunks IterRibbonChunk[]
---@param lnum integer
---@return IterRibbonChunk?
function M.chunk_at(chunks, lnum)
    local low, high = 1, #chunks

    while low <= high do
        local middle = math.floor((low + high) / 2)
        local chunk = chunks[middle]

        if lnum < chunk.first then
            high = middle - 1
        elseif lnum > chunk.last then
            low = middle + 1
        else
            return chunk
        end
    end

    return nil
end

---@class IterRibbonShape
---@field kind 'add'|'del'|'change'
---@field active boolean the chunk under the cursor
---@field lt number top on the left, in screen rows
---@field lb number bottom on the left
---@field rt number top on the right
---@field rb number bottom on the right
---@field left_empty boolean
---@field right_empty boolean

--- The shapes of `chunks` that show in `rows` screen rows.
---@param chunks IterRibbonChunk[]
---@param rows integer
---@param top_of fun(lnum: integer): number screen row of a line, also off screen
---@param first integer first line in view
---@param last integer last line in view
---@param active? IterRibbonChunk
---@return IterRibbonShape[]
function M.shapes(chunks, rows, top_of, first, last, active)
    local shapes = {}

    for _, chunk in ipairs(chunks) do
        if chunk.last >= first - 1 and chunk.first <= last + 1 then
            -- The side without text is a point at the bottom of the line
            -- above, past any annotation there.
            local origin = top_of(chunk.first - 1) + 1
            local has_old = chunk.old_first ~= nil
            local has_new = chunk.new_first ~= nil
            local shape = {
                kind = not has_old and 'add'
                    or not has_new and 'del'
                    or 'change',
                active = chunk == active,
                lt = has_old and top_of(chunk.old_first) or origin,
                lb = has_old and top_of(chunk.old_last) + 1 or origin,
                rt = has_new and top_of(chunk.new_first) or origin,
                rb = has_new and top_of(chunk.new_last) + 1 or origin,
                left_empty = not has_old,
                right_empty = not has_new,
            }

            if
                math.max(shape.lb, shape.rb) > 0
                and math.min(shape.lt, shape.rt) < rows
            then
                table.insert(shapes, shape)
            end
        end
    end

    return shapes
end

--- Progress of a curve at each sample: 0 at the left of the gutter, 1 at the
--- right, the height of a cubic bezier whose control points sit at the start's
--- and the end's height.
---@param width integer pixels
---@return number[] 0-based, `SAMPLES` per pixel
local function curve(width)
    local progress = {}

    for sample = 0, width * SAMPLES - 1 do
        local x = (sample + 0.5) / (width * SAMPLES)
        local low, high = 0, 1

        for _ = 1, 24 do
            local t = (low + high) / 2
            local u = 1 - t
            local at = 3 * CONTROL_1 * u * u * t
                + 3 * CONTROL_2 * u * t * t
                + t * t * t

            if at < x then
                low = t
            else
                high = t
            end
        end

        local t = (low + high) / 2

        progress[sample] = 3 * t * t - 2 * t * t * t
    end

    return progress
end

---@type table<integer, number[]>
local curves = {}

---@class IterRibbonPalette
---@field add integer[] band of added lines
---@field del integer[] band of deleted lines
---@field add_active integer[] band of added lines in the chunk under the cursor
---@field del_active integer[] band of deleted lines in the chunk under the cursor

---@param a integer[]
---@param b integer[]
---@param share number
---@return integer[]
local function mix(a, b, share)
    return {
        a[1] + (b[1] - a[1]) * share,
        a[2] + (b[2] - a[2]) * share,
        a[3] + (b[3] - a[3]) * share,
    }
end

--- Draw the fill of `shape`.
---@param surface IterSurface
---@param shape IterRibbonShape
---@param palette IterRibbonPalette
---@param progress number[]
---@param row integer pixels per row
local function fill(surface, shape, palette, progress, row)
    local width = surface.width
    local thickness = math.max(1, LINE * row)
    local add = shape.active and palette.add_active or palette.add
    local del = shape.active and palette.del_active or palette.del

    ---@param top number
    ---@param bottom number
    ---@param empty boolean
    ---@return number, number
    local function extent(top, bottom, empty)
        return top * row, empty and top * row + thickness or bottom * row
    end

    local lt, lb = extent(shape.lt, shape.lb, shape.left_empty)
    local rt, rb = extent(shape.rt, shape.rb, shape.right_empty)

    for x = 0, width - 1 do
        local color = shape.kind == 'add' and add
            or shape.kind == 'del' and del
            or mix(del, add, (x + 0.5) / width)
        local spans = {}

        for k = 0, SAMPLES - 1 do
            local s = progress[x * SAMPLES + k]

            spans[k + 1] = { lt + (rt - lt) * s, lb + (rb - lb) * s }
        end

        surface:column(x, spans, color)
    end
end

---@class IterRibbonBand
---@field y integer screen row
---@field color integer[] fills the row
---@field rule? boolean a thin line through the row's middle instead

--- Draw the rows that run through the gutter, then `shapes`.
---@param surface IterSurface
---@param shapes IterRibbonShape[]
---@param bands IterRibbonBand[]
---@param palette IterRibbonPalette
---@param row integer pixels per row
function M.paint(surface, shapes, bands, palette, row)
    local width = surface.width

    curves[width] = curves[width] or curve(width)

    local progress = curves[width]

    for _, band in ipairs(bands) do
        if band.rule then
            local thickness = math.max(1, math.floor(LINE * row))

            surface:rect(
                0,
                band.y * row + math.floor((row - thickness) / 2),
                width,
                thickness,
                band.color
            )
        else
            surface:rect(0, band.y * row, width, row, band.color)
        end
    end

    for _, shape in ipairs(shapes) do
        fill(surface, shape, palette, progress, row)
    end
end

return M
