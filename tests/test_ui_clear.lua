local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'one', 'two' } })
            helpers.start_child(child, repo)
            child.lua([[
                _G.notes = {}
                vim.notify = function(msg, level)
                    table.insert(_G.notes, { msg, level })
                end
                _G.confirms = {}
                _G.confirm_answer = 1
                vim.fn.confirm = function(msg, choices)
                    _G.choices = choices
                    table.insert(_G.confirms, msg)
                    return _G.confirm_answer
                end
            ]])
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

local function seed()
    child.lua([[
        local store = require('iter.store')
        local root = vim.fn.getcwd()
        assert(store.put_annotation(root, {
            scope = 'review',
            body = 'Overall fine',
            anchor = { side = 'new' },
        }))
        assert(store.put_annotation(root, {
            scope = 'line',
            body = 'Why this?',
            anchor = {
                path = 'a.txt', side = 'new', start_line = 2, end_line = 2,
                lines = { 'two' },
            },
        }))
    ]])
end

---@return integer
local function stored_count()
    return child.lua_get(
        [[#require('iter.store').load(vim.fn.getcwd()).annotations]]
    )
end

---@return string[]
local function notes()
    return vim.tbl_map(function(note)
        return note[1]
    end, child.lua_get('_G.notes'))
end

---@return integer
local function buffer_marks()
    return child.lua_get([[#vim.api.nvim_buf_get_extmarks(
        0,
        vim.api.nvim_create_namespace('iter.buffer.annotations'),
        0, -1, {}
    )]])
end

T['clear removes every annotation after the confirm'] = function()
    seed()
    child.lua([[require('iter').clear()]])
    eq(child.lua_get('_G.confirms'), { 'Clear all 2 annotations?' })
    eq(stored_count(), 0)
end

T['clear keeps the annotations when the confirm is declined'] = function()
    seed()
    child.lua('_G.confirm_answer = 2')
    child.lua([[require('iter').clear()]])
    eq(stored_count(), 2)
end

T['clear confirms with x and declines with n'] = function()
    seed()
    child.lua([[require('iter').clear()]])
    eq(child.lua_get('_G.choices'), 'Clear &x\n&No')
end

T['clear names a single annotation'] = function()
    child.lua([[assert(require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'review', body = 'Only', anchor = { side = 'new' },
    }))]])
    child.lua([[require('iter').clear()]])
    eq(child.lua_get('_G.confirms'), { 'Clear 1 annotation?' })
    eq(stored_count(), 0)
end

T['clear warns when there is nothing to clear'] = function()
    child.lua([[require('iter').clear()]])
    eq(notes(), { '[iter] No annotations to clear' })
    eq(child.lua_get('_G.confirms'), {})
end

T['clear warns outside a repository'] = function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    child.cmd('cd ' .. vim.fn.fnameescape(dir))
    child.lua([[require('iter').clear()]])
    eq(notes(), { '[iter] Not inside a git repository' })
end

T['clear removes the marks from the buffer shown'] = function()
    seed()
    child.lua([[require('iter').setup()]])
    child.cmd('edit a.txt')
    helpers.wait_until(
        child,
        [[#vim.api.nvim_buf_get_extmarks(0,
            vim.api.nvim_create_namespace('iter.buffer.annotations'),
            0, -1, {}) > 0]]
    )
    child.lua([[require('iter').clear()]])
    eq(buffer_marks(), 0)
    helpers.expect_screenshot(child, 'clear_buffer')
end

return T
