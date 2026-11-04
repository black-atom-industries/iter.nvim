-- Adapted from diffbandit.nvim's lua/diffbandit/kitty/protocol.lua
-- (https://github.com/CoreyKaylor/diffbandit.nvim), Apache License 2.0, see
-- LICENSES/Apache-2.0-diffbandit.txt. Changed: restyled, reduced to direct
-- transmission, and the encoders return one string.

--- Escape sequences of the Kitty graphics protocol, as strings. Images show
--- through Unicode placeholders: cells holding U+10EEEE whose foreground is
--- the image id and whose diacritics are the image row and column, so Neovim
--- treats them as text and clips them under other windows.

local M = {}

-- kitty's gen/rowcolumn-diacritics.txt: entry i + 1 addresses row or column i.
local DIACRITICS = {
    0x0305,
    0x030D,
    0x030E,
    0x0310,
    0x0312,
    0x033D,
    0x033E,
    0x033F,
    0x0346,
    0x034A,
    0x034B,
    0x034C,
    0x0350,
    0x0351,
    0x0352,
    0x0357,
    0x035B,
    0x0363,
    0x0364,
    0x0365,
    0x0366,
    0x0367,
    0x0368,
    0x0369,
    0x036A,
    0x036B,
    0x036C,
    0x036D,
    0x036E,
    0x036F,
    0x0483,
    0x0484,
    0x0485,
    0x0486,
    0x0487,
    0x0592,
    0x0593,
    0x0594,
    0x0595,
    0x0597,
    0x0598,
    0x0599,
    0x059C,
    0x059D,
    0x059E,
    0x059F,
    0x05A0,
    0x05A1,
    0x05A8,
    0x05A9,
    0x05AB,
    0x05AC,
    0x05AF,
    0x05C4,
    0x0610,
    0x0611,
    0x0612,
    0x0613,
    0x0614,
    0x0615,
    0x0616,
    0x0617,
    0x0657,
    0x0658,
    0x0659,
    0x065A,
    0x065B,
    0x065D,
    0x065E,
    0x06D6,
    0x06D7,
    0x06D8,
    0x06D9,
    0x06DA,
    0x06DB,
    0x06DC,
    0x06DF,
    0x06E0,
    0x06E1,
    0x06E2,
    0x06E4,
    0x06E7,
    0x06E8,
    0x06EB,
    0x06EC,
    0x0730,
    0x0732,
    0x0733,
    0x0735,
    0x0736,
    0x073A,
    0x073D,
    0x073F,
    0x0740,
    0x0741,
    0x0743,
    0x0745,
    0x0747,
    0x0749,
    0x074A,
    0x07EB,
    0x07EC,
    0x07ED,
    0x07EE,
    0x07EF,
    0x07F0,
    0x07F1,
    0x07F3,
    0x0816,
    0x0817,
    0x0818,
    0x0819,
    0x081B,
    0x081C,
    0x081D,
    0x081E,
    0x081F,
    0x0820,
    0x0821,
    0x0822,
    0x0823,
    0x0825,
    0x0826,
    0x0827,
    0x0829,
    0x082A,
    0x082B,
    0x082C,
    0x082D,
    0x0951,
    0x0953,
    0x0954,
    0x0F82,
    0x0F83,
    0x0F86,
    0x0F87,
    0x135D,
    0x135E,
    0x135F,
    0x17DD,
    0x193A,
    0x1A17,
    0x1A75,
    0x1A76,
    0x1A77,
    0x1A78,
    0x1A79,
    0x1A7A,
    0x1A7B,
    0x1A7C,
    0x1B6B,
    0x1B6D,
    0x1B6E,
    0x1B6F,
    0x1B70,
    0x1B71,
    0x1B72,
    0x1B73,
    0x1CD0,
    0x1CD1,
    0x1CD2,
    0x1CDA,
    0x1CDB,
    0x1CE0,
    0x1DC0,
    0x1DC1,
    0x1DC3,
    0x1DC4,
    0x1DC5,
    0x1DC6,
    0x1DC7,
    0x1DC8,
    0x1DC9,
    0x1DCB,
    0x1DCC,
    0x1DD1,
    0x1DD2,
    0x1DD3,
    0x1DD4,
    0x1DD5,
    0x1DD6,
    0x1DD7,
    0x1DD8,
    0x1DD9,
    0x1DDA,
    0x1DDB,
    0x1DDC,
    0x1DDD,
    0x1DDE,
    0x1DDF,
    0x1DE0,
    0x1DE1,
    0x1DE2,
    0x1DE3,
    0x1DE4,
    0x1DE5,
    0x1DE6,
    0x1DFE,
    0x20D0,
    0x20D1,
    0x20D4,
    0x20D5,
    0x20D6,
    0x20D7,
    0x20DB,
    0x20DC,
    0x20E1,
    0x20E7,
    0x20E9,
    0x20F0,
    0x2CEF,
    0x2CF0,
    0x2CF1,
    0x2DE0,
    0x2DE1,
    0x2DE2,
    0x2DE3,
    0x2DE4,
    0x2DE5,
    0x2DE6,
    0x2DE7,
    0x2DE8,
    0x2DE9,
    0x2DEA,
    0x2DEB,
    0x2DEC,
    0x2DED,
    0x2DEE,
    0x2DEF,
    0x2DF0,
    0x2DF1,
    0x2DF2,
    0x2DF3,
    0x2DF4,
    0x2DF5,
    0x2DF6,
    0x2DF7,
    0x2DF8,
    0x2DF9,
    0x2DFA,
    0x2DFB,
    0x2DFC,
    0x2DFD,
    0x2DFE,
    0x2DFF,
    0xA66F,
    0xA67C,
    0xA67D,
    0xA6F0,
    0xA6F1,
    0xA8E0,
    0xA8E1,
    0xA8E2,
    0xA8E3,
    0xA8E4,
    0xA8E5,
    0xA8E6,
    0xA8E7,
    0xA8E8,
    0xA8E9,
    0xA8EA,
    0xA8EB,
    0xA8EC,
    0xA8ED,
    0xA8EE,
    0xA8EF,
    0xA8F0,
    0xA8F1,
    0xAAB0,
    0xAAB2,
    0xAAB3,
    0xAAB7,
    0xAAB8,
    0xAABE,
    0xAABF,
    0xAAC1,
    0xFE20,
    0xFE21,
    0xFE22,
    0xFE23,
    0xFE24,
    0xFE25,
    0xFE26,
    0x10A0F,
    0x10A38,
    0x1D185,
    0x1D186,
    0x1D187,
    0x1D188,
    0x1D189,
    0x1D1AA,
    0x1D1AB,
    0x1D1AC,
    0x1D1AD,
    0x1D242,
    0x1D243,
    0x1D244,
}

--- Most rows or columns a placeholder can address.
M.MAX_CELLS = #DIACRITICS

--- Primary device attributes: every terminal answers it, so a graphics reply
--- that hasn't come before its answer won't come.
M.DA1 = '\27[c'

local CHUNK = 4096

---@param control string
---@param payload string
---@return string
local function command(control, payload)
    return '\27_G' .. control .. ';' .. payload .. '\27\\'
end

---@param cp integer
---@return string
local function char(cp)
    return vim.fn.nr2char(cp, true)
end

--- The `rows` lines of `cols` placeholder cells that show an image whole.
---@param cols integer
---@param rows integer
---@return string[]
function M.placeholders(cols, rows)
    local cell = char(0x10EEEE)
    local columns = {}

    for col = 1, cols do
        columns[col] = char(DIACRITICS[col])
    end

    local lines = {}

    for row = 1, rows do
        local parts, mark = {}, char(DIACRITICS[row])

        for col = 1, cols do
            parts[col] = cell .. mark .. columns[col]
        end

        lines[row] = table.concat(parts)
    end

    return lines
end

---@class IterGraphicsImage
---@field id integer
---@field width integer pixels
---@field height integer pixels
---@field cols integer cells the placement spans
---@field rows integer
---@field data string RGBA bytes
---@field compressed? boolean `data` is zlib data

--- Send an image and make it the virtual placement its placeholders show.
--- It replaces the image of that id. The terminal answers only with an error.
---@param image IterGraphicsImage
---@return string
function M.transmit(image)
    local head = string.format(
        'a=T,U=1,f=32,%si=%d,s=%d,v=%d,c=%d,r=%d,q=1',
        image.compressed and 'o=z,' or '',
        image.id,
        image.width,
        image.height,
        image.cols,
        image.rows
    )
    local payload = vim.base64.encode(image.data)
    local parts = {}
    local first = true

    for pos = 1, math.max(#payload, 1), CHUNK do
        local more = pos + CHUNK <= #payload and 1 or 0
        local control = first and (head .. ',m=' .. more) or ('m=' .. more)

        parts[#parts + 1] = command(control, payload:sub(pos, pos + CHUNK - 1))
        first = false
    end

    return table.concat(parts)
end

--- Ask whether the terminal takes images: a 1x1 image it checks and drops.
---@param id integer
---@return string
function M.query(id)
    return command(string.format('i=%d,s=1,v=1,a=q,t=d,f=24', id), 'AAAA')
end

--- Delete an image and free its data.
---@param id integer
---@return string
function M.delete(id)
    return command(string.format('a=d,d=I,i=%d,q=2', id), '')
end

--- A graphics reply from `sequence`, with or without its framing.
---@param sequence any
---@return { id?: integer, ok: boolean, message: string }?
function M.parse_reply(sequence)
    if type(sequence) ~= 'string' then
        return nil
    end

    local keys, message = sequence:match('_G([^;\27]*);([^\27]*)')

    if keys == nil then
        return nil
    end

    return {
        id = tonumber(keys:match('i=(%d+)')),
        ok = message == 'OK',
        message = message,
    }
end

--- Whether `sequence` answers a primary device attributes request.
---@param sequence any
---@return boolean
function M.is_da1(sequence)
    return type(sequence) == 'string' and sequence:match('%[%?[%d;]*c') ~= nil
end

return M
