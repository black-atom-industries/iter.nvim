-- The blending follows diffbandit.nvim's lua/diffbandit/kitty/raster.lua
-- (https://github.com/CoreyKaylor/diffbandit.nvim), Apache License 2.0, see
-- LICENSES/Apache-2.0-diffbandit.txt. Changed: rewritten for iter, and a column
-- sums the coverage of its samples before it blends.

--- A rectangle of RGBA pixels to draw on, in memory. It knows nothing of the
--- terminal: `canvas` shows its bytes.

---@class IterSurface
---@field width integer
---@field height integer
---@field pixels ffi.cdata*
local Surface = {}
Surface.__index = Surface

---@param width integer
---@param height integer
---@return IterSurface
function Surface.new(width, height)
    return setmetatable({
        width = width,
        height = height,
        pixels = require('ffi').new('uint8_t[?]', width * height * 4),
    }, Surface)
end

--- Lay `rgb` over the pixel at `coverage` (0 to 1). Outside the surface it
--- draws nothing.
---@param x integer
---@param y integer
---@param rgb integer[]
---@param coverage number
function Surface:blend(x, y, rgb, coverage)
    if
        coverage <= 0
        or x < 0
        or y < 0
        or x >= self.width
        or y >= self.height
    then
        return
    end

    local pixels = self.pixels
    local i = (y * self.width + x) * 4

    if coverage >= 1 then
        pixels[i], pixels[i + 1], pixels[i + 2] = rgb[1], rgb[2], rgb[3]
        pixels[i + 3] = 255

        return
    end

    local below = pixels[i + 3] / 255 * (1 - coverage)
    local alpha = coverage + below

    for channel = 0, 2 do
        pixels[i + channel] = (
            rgb[channel + 1] * coverage + pixels[i + channel] * below
        )
                / alpha
            + 0.5
    end

    pixels[i + 3] = alpha * 255 + 0.5
end

--- Fill whole pixels from `x`, `y`, `width` by `height`.
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param rgb integer[]
function Surface:rect(x, y, width, height, rgb)
    for row = y, y + height - 1 do
        for col = x, x + width - 1 do
            self:blend(col, row, rgb, 1)
        end
    end
end

--- Draw column `x` over `spans`, equal samples of the column, each from its
--- `[1]` to its `[2]` in fractions of a pixel. A pixel is as covered as the
--- samples together cover it.
---@param x integer
---@param spans number[][]
---@param rgb integer[]
function Surface:column(x, spans, rgb)
    local top, bottom = math.huge, -math.huge

    for _, span in ipairs(spans) do
        top = math.min(top, span[1])
        bottom = math.max(bottom, span[2])
    end

    local first = math.max(0, math.floor(top))
    local last = math.min(self.height - 1, math.ceil(bottom) - 1)

    for y = first, last do
        local covered = 0

        for _, span in ipairs(spans) do
            covered = covered
                + math.max(0, math.min(span[2], y + 1) - math.max(span[1], y))
        end

        self:blend(x, y, rgb, covered / #spans)
    end
end

--- The pixel at `x`, `y` as `{ r, g, b, a }`.
---@param x integer
---@param y integer
---@return integer[]
function Surface:pixel(x, y)
    local i = (y * self.width + x) * 4
    local pixels = self.pixels

    return { pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] }
end

--- The pixels as RGBA bytes.
---@return string
function Surface:bytes()
    return require('ffi').string(self.pixels, self.width * self.height * 4)
end

return Surface
