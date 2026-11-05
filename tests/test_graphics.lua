local helpers = dofile('tests/helpers.lua')
local protocol = require('iter.graphics.protocol')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = new_set()

T['protocol'] = new_set()

T['protocol']['placeholders() address each cell by row and column'] = function()
    local lines = protocol.placeholders(2, 2)
    local cell = vim.fn.nr2char(0x10EEEE, true)

    eq(#lines, 2)
    eq(
        lines[1],
        cell
            .. vim.fn.nr2char(0x0305, true)
            .. vim.fn.nr2char(0x0305, true)
            .. cell
            .. vim.fn.nr2char(0x0305, true)
            .. vim.fn.nr2char(0x030D, true)
    )
    eq(vim.fn.strdisplaywidth(lines[2]), 2)
end

T['protocol']['transmit() places a virtual image in one command'] = function()
    local out = protocol.transmit({
        id = 7,
        width = 2,
        height = 1,
        cols = 5,
        rows = 9,
        data = 'abcd',
    })

    eq(
        out,
        '\27_Ga=T,U=1,f=32,i=7,s=2,v=1,c=5,r=9,q=1,m=0;'
            .. vim.base64.encode('abcd')
            .. '\27\\'
    )
end

T['protocol']['transmit() splits a long payload into chunks'] = function()
    local out = protocol.transmit({
        id = 7,
        width = 1,
        height = 1,
        cols = 1,
        rows = 1,
        data = string.rep('x', 9000),
        compressed = true,
    })
    local _, commands = out:gsub('\27_G', '')

    eq(commands, 3)
    eq(out:find('o=z', 1, true) ~= nil, true)
    eq(out:find('m=1;', 1, true) ~= nil, true)
    eq(out:find('\27_Gm=0;', 1, true) ~= nil, true)
end

T['protocol']['delete() frees the image'] = function()
    eq(protocol.delete(7), '\27_Ga=d,d=I,i=7,q=2;\27\\')
end

T['protocol']['parse_reply() reads replies, framed or not'] = function()
    eq(
        protocol.parse_reply('\27_Gi=31;OK\27\\'),
        { id = 31, ok = true, message = 'OK' }
    )
    eq(
        protocol.parse_reply('_Gi=31;ENOENT:gone'),
        { id = 31, ok = false, message = 'ENOENT:gone' }
    )
    eq(protocol.parse_reply('\27[?62;22c'), vim.NIL and nil)
end

T['protocol']['is_da1() tells device attributes'] = function()
    eq(protocol.is_da1('\27[?62;22c'), true)
    eq(protocol.is_da1('\27]11;rgb:2424/1717/1010'), false)
end

--- A child with a terminal UI and true colour as far as iter can tell, its
--- writes to the terminal in `_G.sent`.
local function fake_terminal()
    child.lua([[
        _G.sent = {}
        vim.o.termguicolors = true
        vim.api.nvim_ui_send = function(bytes)
            table.insert(_G.sent, bytes)
        end
        local list = vim.api.nvim_list_uis
        vim.api.nvim_list_uis = function()
            return { { stdout_tty = true } }
        end
    ]])
end

---@param sequence string
local function respond(sequence)
    child.lua(
        [[vim.api.nvim_exec_autocmds('TermResponse', {
            data = { sequence = ... },
        })]],
        { sequence }
    )
end

local OK = '\27_Gi=' .. 0x1A0000 .. ';OK\27\\'
local DA1 = '\27[?62;22c'

T['probe()'] = new_set({
    hooks = {
        pre_case = function()
            child.restart({ '-u', helpers.minimal_init })
        end,
        post_case = function()
            child.stop()
        end,
    },
})

T['probe()']['without a terminal UI asks nothing'] = function()
    child.lua([[
        _G.sent = {}
        vim.api.nvim_ui_send = function(b) table.insert(_G.sent, b) end
        require('iter.graphics').probe()
    ]])

    eq(child.lua_get('#_G.sent'), 0)
    eq(child.lua_get([[require('iter.graphics').on()]]), false)
end

T['probe()']['in tmux stays off'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = '/tmp/tmux,1,0'
        require('iter.graphics').probe()
    ]])

    eq(child.lua_get('#_G.sent'), 0)
    eq(child.lua_get([[require('iter.graphics').on()]]), false)
end

T['probe()']['without true colour stays off'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        vim.o.termguicolors = false
        require('iter.graphics').probe()
    ]])

    eq(child.lua_get('#_G.sent'), 0)
end

T['probe()']['an OK before the sentinel turns images on'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        _G.changes = 0
        require('iter.graphics').subscribe(function()
            _G.changes = _G.changes + 1
        end)
        require('iter.graphics').probe()
    ]])

    eq(child.lua_get([[_G.sent[1]:find('a=q', 1, true) ~= nil]]), true)
    eq(child.lua_get([[_G.sent[1]:sub(-3)]]), '\27[c')

    respond(OK)
    respond(DA1)
    helpers.wait_until(child, [[require('iter.graphics').on()]])
    eq(child.lua_get('_G.changes'), 1)
end

T['probe()']['the sentinel alone leaves images off'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        _G.changes = 0
        require('iter.graphics').subscribe(function()
            _G.changes = _G.changes + 1
        end)
        require('iter.graphics').probe()
    ]])

    respond(DA1)
    helpers.wait_until(child, [[_G.changes == 1]])
    eq(child.lua_get([[require('iter.graphics').on()]]), false)
end

T['probe()']['a late OK within the grace still counts'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        require('iter.graphics').probe()
    ]])

    respond(DA1)
    respond(OK)
    helpers.wait_until(child, [[require('iter.graphics').on()]])
end

T['probe()']['a rejected image turns images off for good'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        _G.notes = {}
        vim.notify = function(msg) table.insert(_G.notes, msg) end
        require('iter.graphics').probe()
    ]])
    respond(OK)
    respond(DA1)
    helpers.wait_until(child, [[require('iter.graphics').on()]])

    respond('\27_Gi=' .. (0x1A0000 + 1) .. ';ENOMEM:no room\27\\')
    helpers.wait_until(child, [[not require('iter.graphics').on()]])
    eq(child.lua_get('#_G.notes'), 1)

    child.lua([[vim.api.nvim_exec_autocmds('UIEnter', {})]])
    eq(child.lua_get([[require('iter.graphics').on()]]), false)
end

T['probe()']['a UI that cannot be asked turns images off'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        _G.changes = 0
        require('iter.graphics').probe()
    ]])
    respond(OK)
    respond(DA1)
    helpers.wait_until(child, [[require('iter.graphics').on()]])

    child.lua([[
        require('iter.graphics').subscribe(function()
            _G.changes = _G.changes + 1
        end)
        vim.api.nvim_list_uis = function()
            return {}
        end
        vim.api.nvim_exec_autocmds('UIEnter', {})
    ]])

    eq(child.lua_get([[require('iter.graphics').on()]]), false)
    eq(child.lua_get('_G.changes'), 1)
end

T['probe()']['without LuaJIT the diff view loads and images stay off'] = function()
    fake_terminal()
    child.lua([[
        vim.env.TMUX = nil
        package.loaded.ffi = nil
        package.preload.ffi = function()
            error('no LuaJIT')
        end
        require('iter.diff.view')
        require('iter.graphics').probe()
    ]])

    eq(child.lua_get('#_G.sent'), 0)
    eq(child.lua_get([[require('iter.graphics').on()]]), false)
end

T['pixel()'] = new_set()

T['pixel()']['keeps sRGB outside Ghostty on macOS'] = function()
    local saved = vim.env.GHOSTTY_RESOURCES_DIR

    vim.env.GHOSTTY_RESOURCES_DIR = nil
    eq(require('iter.graphics').pixel(0x102030), { 0x10, 0x20, 0x30 })
    vim.env.GHOSTTY_RESOURCES_DIR = saved
end

T['canvas'] = new_set()

T['canvas']['close() frees the id once, new() takes it again'] = function()
    local Canvas = require('iter.graphics.canvas')

    ---@return IterCanvas
    local function new()
        return Canvas.new({
            anchor = vim.api.nvim_get_current_win(),
            col = 0,
            cols = 1,
        })
    end

    local first = new()
    local id = first.id

    first:close()
    first:close()

    local second, third = new(), new()

    eq(second.id, id)
    eq(third.id ~= id, true)

    second:close()
    third:close()
end

return T
