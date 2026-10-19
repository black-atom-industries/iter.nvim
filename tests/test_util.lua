local util = require('iter.util')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local T = new_set()

---@param fn fun()
---@return { message: string, level: integer }[]
local function capture(fn)
    local original = vim.notify
    local calls = {}

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message, level)
        table.insert(calls, { message = message, level = level })
    end
    local ok, err = pcall(fn)
    vim.notify = original

    assert(ok, err)

    return calls
end

T['is_valid_win()'] = function()
    local win = vim.api.nvim_get_current_win()

    eq(util.is_valid_win(win), true)
    eq(util.is_valid_win(nil), false)
    eq(util.is_valid_win(0), false)
    eq(util.is_valid_win(99999), false)
end

T['warn() and error() prefix the message'] = function()
    local calls = capture(function()
        util.warn('careful')
        util.error('boom', 'fallback')
    end)

    eq(calls, {
        { message = '[iter] careful', level = vim.log.levels.WARN },
        { message = '[iter] boom', level = vim.log.levels.ERROR },
    })
end

T['error() falls back when the message is empty'] = function()
    local calls = capture(function()
        util.error('', 'fallback')
        util.error(nil, 'fallback')
    end)

    eq(calls[1].message, '[iter] fallback')
    eq(calls[2].message, '[iter] fallback')
end

return T
