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

T['is_normal_win()'] = function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 5,
        height = 1,
    })

    eq(util.is_normal_win(win), true)
    eq(util.is_normal_win(float), false)
    eq(util.is_normal_win(nil), false)

    vim.api.nvim_win_close(float, true)
    vim.api.nvim_buf_delete(buf, { force = true })
end

T['stat_key()'] = function()
    local path = vim.fn.tempname()

    eq(util.stat_key(path), nil)

    vim.fn.writefile({ 'one' }, path)
    local before = util.stat_key(path)
    eq(type(before), 'string')
    eq(util.stat_key(path), before)

    local tmp = path .. '.tmp'
    vim.fn.writefile({ 'two' }, tmp)
    vim.uv.fs_rename(tmp, path)
    eq(util.stat_key(path) ~= before, true)

    vim.fn.delete(path)
end

T['can_leave()'] = function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname())
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'changed' })
    local hidden = vim.o.hidden

    local calls = capture(function()
        vim.o.hidden = true
        eq(util.can_leave(buf), true)
        vim.o.hidden = false
        eq(util.can_leave(buf), false)
        eq(util.can_leave(buf, vim.api.nvim_buf_get_name(buf)), true)
        eq(util.can_leave(nil), true)
    end)

    vim.o.hidden = hidden
    vim.api.nvim_buf_delete(buf, { force = true })

    eq(calls, {
        {
            message = '[iter] The pane has unsaved changes',
            level = vim.log.levels.WARN,
        },
    })
end

T['edit_at()'] = function()
    local path = vim.fn.resolve(vim.fn.tempname())
    vim.fn.writefile({ 'a', 'b', 'c' }, path)

    eq(util.edit_at(path, 2), true)
    eq(vim.fn.resolve(vim.api.nvim_buf_get_name(0)), path)
    eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })

    eq(util.edit_at(path, 99), true)
    eq(vim.api.nvim_win_get_cursor(0), { 3, 0 })

    vim.cmd('bwipeout!')
    vim.fn.delete(path)
end

return T
