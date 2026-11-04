-- The probe and the Display P3 conversion follow diffbandit.nvim's
-- lua/diffbandit/kitty/detect.lua and color.lua
-- (https://github.com/CoreyKaylor/diffbandit.nvim), Apache License 2.0, see
-- LICENSES/Apache-2.0-diffbandit.txt. Changed: rewritten for iter, without
-- temp-file transmission or configuration.

--- Whether the terminal shows images, asked once per UI: a graphics query
--- followed by a device attributes request, never a terminal's name. A
--- graphics OK before the attributes answer means yes. `subscribe` hears every
--- change of the answer, the late one included: a terminal rejecting an image
--- after that turns images off for the session.

local protocol = require('iter.graphics.protocol')
local util = require('iter.util')

local M = {}

local QUERY_ID = 0x1A0000

--- Image ids start here, so a reply can be told as iter's.
M.FIRST_ID = QUERY_ID + 1

-- How long a stray attributes answer waits for the graphics reply, since
-- Neovim sends the same request at startup.
local GRACE_MS = 60
local TIMEOUT_MS = 300

-- Without a measurement, the size of a HiDPI cell: terminals scale it down
-- cleanly.
local FALLBACK_CELL = { w = 20, h = 40 }

---@type 'unknown'|'probing'|'on'|'off'
local status = 'unknown'
local rejected = false
local listeners = {}
local group
local probe_timer

---@return boolean
local function has_terminal_ui()
    for _, ui in ipairs(vim.api.nvim_list_uis()) do
        if ui.stdout_tty then
            return true
        end
    end

    return false
end

local function notify()
    for _, listener in ipairs(listeners) do
        listener()
    end
end

---@param new 'on'|'off'
local function settle(new)
    if probe_timer ~= nil then
        probe_timer:stop()
        probe_timer:close()
        probe_timer = nil
    end

    local changed = status ~= new

    status = new

    if changed then
        notify()
    end
end

--- Turn images off after the terminal refused one.
---@param message string
local function reject(message)
    rejected = true

    if status == 'on' then
        util.warn('the terminal rejected a ribbon image: ' .. message)
    end

    settle('off')
end

local answered = false

---@param sequence any
local function on_response(sequence)
    local reply = protocol.parse_reply(sequence)

    if reply ~= nil then
        if reply.id == QUERY_ID then
            answered = answered or reply.ok
        elseif reply.id ~= nil and reply.id >= M.FIRST_ID and not reply.ok then
            vim.schedule(function()
                reject(reply.message)
            end)
        end
    elseif status == 'probing' and protocol.is_da1(sequence) then
        if answered then
            vim.schedule(function()
                settle('on')
            end)
        else
            vim.defer_fn(function()
                if status == 'probing' then
                    settle(answered and 'on' or 'off')
                end
            end, GRACE_MS)
        end
    end
end

--- Ask the terminal, unless the answer is known. A session in tmux, without a
--- terminal UI or without true colour, which the image id needs, stays off.
function M.probe()
    if group == nil then
        group = vim.api.nvim_create_augroup('iter.graphics', { clear = true })
        vim.api.nvim_create_autocmd('TermResponse', {
            group = group,
            callback = function(args)
                on_response(args.data and args.data.sequence)
            end,
        })
        vim.api.nvim_create_autocmd('UIEnter', {
            group = group,
            callback = function()
                if not rejected and status ~= 'probing' then
                    local was_on = status == 'on'

                    status = 'unknown'
                    M.probe()

                    -- This UI can't be asked, so what was on is off now.
                    if was_on and status == 'unknown' then
                        notify()
                    end
                end
            end,
        })
    end

    if status ~= 'unknown' or rejected then
        return
    end

    if
        not has_terminal_ui()
        or not vim.o.termguicolors
        or (vim.env.TMUX or '') ~= ''
        or not pcall(require, 'ffi')
    then
        return
    end

    status = 'probing'
    answered = false
    probe_timer = vim.uv.new_timer()
    probe_timer:start(
        TIMEOUT_MS,
        0,
        vim.schedule_wrap(function()
            if status == 'probing' then
                settle(answered and 'on' or 'off')
            end
        end)
    )
    M.send(protocol.query(QUERY_ID) .. protocol.DA1)
end

--- Whether images show.
---@return boolean
function M.on()
    return status == 'on'
end

--- Call `listener` whenever `on()` changes.
---@param listener fun()
function M.subscribe(listener)
    table.insert(listeners, listener)
end

--- Write `bytes` to the terminal.
---@param bytes string
function M.send(bytes)
    vim.api.nvim_ui_send(bytes)
end

local function define_winsize()
    local ffi = require('ffi')

    pcall(
        ffi.cdef,
        [[
        struct iter_winsize {
            unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel;
        };
        int ioctl(int fd, unsigned long request, ...);
        int isatty(int fd);
    ]]
    )

    return ffi
end

--- The size of a terminal cell in pixels, read anew each time, since a font
--- size change or a terminal still starting up changes it. A placeholder
--- image keeps its aspect ratio inside its cells, so a wrong cell shape moves
--- what it shows.
---@return { w: integer, h: integer }
function M.cell_size()
    local ffi = define_winsize()
    local request = ffi.os == 'OSX' and 0x40087468 or 0x5413

    -- The embedded server inherits the terminal on its standard descriptors.
    for fd = 0, 2 do
        if ffi.C.isatty(fd) == 1 then
            ---@type any
            local size = ffi.new('struct iter_winsize')

            if
                ffi.C.ioctl(fd, request, size) == 0
                and size.ws_col > 0
                and size.ws_row > 0
                and size.ws_xpixel > 0
                and size.ws_ypixel > 0
            then
                return {
                    w = math.floor(size.ws_xpixel / size.ws_col),
                    h = math.floor(size.ws_ypixel / size.ws_row),
                }
            end
        end
    end

    return FALLBACK_CELL
end

-- Linear sRGB to linear Display P3, both D65.
local SRGB_TO_P3 = {
    { 0.8224621, 0.1775380, 0.0000000 },
    { 0.0331941, 0.9668058, 0.0000000 },
    { 0.0170827, 0.0723974, 0.9105199 },
}

---@param value integer
---@return number
local function linear(value)
    value = value / 255

    return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
end

---@param value number
---@return integer
local function gamma(value)
    value = math.max(0, math.min(1, value))
    value = value <= 0.0031308 and value * 12.92
        or 1.055 * value ^ (1 / 2.4) - 0.055

    return math.floor(value * 255 + 0.5)
end

---@return boolean
local function images_are_p3()
    return (vim.env.GHOSTTY_RESOURCES_DIR or '') ~= ''
        and vim.fn.has('mac') == 1
        and (vim.env.SSH_CONNECTION or '') == ''
end

--- `color` (0xRRGGBB in sRGB) as the image pixel that looks like it next to a
--- cell of that colour. Ghostty on macOS shows image pixels as Display P3 and
--- converts text colours from sRGB.
---@param color integer
---@return integer[] rgb
function M.pixel(color)
    local rgb = {
        math.floor(color / 0x10000) % 256,
        math.floor(color / 0x100) % 256,
        color % 256,
    }

    if not images_are_p3() then
        return rgb
    end

    local lin = { linear(rgb[1]), linear(rgb[2]), linear(rgb[3]) }
    local out = {}

    for i, row in ipairs(SRGB_TO_P3) do
        out[i] = gamma(row[1] * lin[1] + row[2] * lin[2] + row[3] * lin[3])
    end

    return out
end

return M
