local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = H.R
local S = [[require('iter.ui.sidebar').of(require('iter').current_review.tab)]]

---@param prefix string
---@param from integer
---@param to integer
---@return string[]
local function numbered(prefix, from, to)
    local lines = {}

    for i = from, to do
        table.insert(lines, prefix .. i)
    end

    return lines
end

--- `a.txt` has a3 changed in the worktree; `e.txt` is committed and
--- unchanged.
---@return string
local function create_sidebar_repo()
    local path = helpers.create_repo({
        ['a.txt'] = numbered('a', 1, 12),
        ['e.txt'] = numbered('e', 1, 8),
    })

    local a = numbered('a', 1, 12)
    a[3] = 'a3 changed'
    helpers.write_file(vim.fs.joinpath(path, 'a.txt'), a)

    return path
end

---@param path string
---@param line integer
---@param text string
---@return table
local function anchor(path, line, text)
    return {
        path = path,
        side = 'new',
        start_line = line,
        end_line = line,
        lines = { text },
    }
end

local function seed()
    child.lua(
        [[
        local store = require('iter.store')
        for _, annotation in ipairs(...) do
            assert(store.put_annotation(vim.fn.getcwd(), annotation))
        end
    ]],
        {
            {
                {
                    scope = 'line',
                    body = 'Why this change?',
                    anchor = anchor('a.txt', 3, 'a3 changed'),
                },
                {
                    scope = 'line',
                    body = 'Unchanged but odd',
                    anchor = anchor('e.txt', 5, 'e5'),
                },
            },
        }
    )
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_sidebar_repo()
            helpers.start_child(child, repo, { lines = 30, columns = 200 })
            child.lua([[require('iter').setup()]])
            seed()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

---@param options string Lua table passed to setup()
local function setup(options)
    child.lua('require("iter").setup(' .. options .. ')')
end

local function open_review()
    H.open(child)
    helpers.wait_until(child, R .. [[.view:is_shown()]])
end

---@return integer?
local function sidebar_win()
    local win = child.lua_get('(' .. S .. ' or {}).win')

    return win ~= vim.NIL and win or nil
end

--- Enter the sidebar, move its cursor to the note with `body` and wait
--- until the diff pane focuses it.
---@param body string
local function goto_note(body)
    child.lua([[
        local body = ...
        local sidebar = ]] .. S .. [[
        vim.api.nvim_set_current_win(sidebar.win)
        for lnum, row in pairs(sidebar.rows) do
            if row.item ~= nil and row.item.annotation.body == body then
                vim.api.nvim_win_set_cursor(sidebar.win, { lnum, 0 })
                return
            end
        end
        error('no note ' .. body)
    ]], { body })
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local view = %s.view
                for _, mark in ipairs(view.marks) do
                    if mark.annotation.id == view.focus then
                        return mark.annotation.body == %q
                    end
                end
                return false
            end)()]],
            R,
            body
        )
    )
end

---@return string|vim.NIL
local function column_note()
    return child.lua_get([[(function()
        local d = ]] .. R .. [[.drawer
        if d.column ~= 'annotations' then return vim.NIL end
        local item = d:item()
        return item and item.annotation and item.annotation.body or vim.NIL
    end)()]])
end

T['wide'] = new_set()

T['wide']['from 160 tab columns the sidebar replaces the Annotations column'] = function()
    open_review()

    eq(sidebar_win() ~= nil, true)
    eq(child.lua_get('#' .. R .. '.drawer.extra'), 0)
    eq(child.lua_get(R .. '.drawer.float.side_win'), vim.NIL)
    eq(
        child.lua_get('vim.api.nvim_win_get_height(' .. S .. '.win)')
            > child.lua_get('vim.api.nvim_win_get_height(' .. R .. '.diff_win)'),
        true
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.drawer.win'))
end

T['wide']['the sidebar sits right, or left with annotate.side'] = function()
    open_review()

    local right =
        child.lua_get('vim.api.nvim_win_get_position(' .. S .. '.win)[2]')

    eq(right > 100, true)

    child.cmd('tabclose')
    setup([[{ annotate = { side = 'left' } }]])
    open_review()

    eq(child.lua_get('vim.api.nvim_win_get_position(' .. S .. '.win)[2]'), 0)
end

T['wide']['marks changed files and counts reviewed among them'] = function()
    open_review()

    local lines = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. S .. '.buf, 0, -1, false)'
    )

    eq(lines[2]:find('0 of 1', 1, true) ~= nil, true)
    eq(vim.startswith(lines[4], 'M a.txt'), true)
    eq(vim.startswith(lines[7], '  e.txt'), true)
end

T['wide']['moving in the sidebar previews the note in the diff'] = function()
    open_review()
    goto_note('Why this change?')

    eq(child.lua_get(R .. '.view.files[1].path'), 'a.txt')
    helpers.expect_screenshot(child, 'review-sidebar')
end

T['wide']['a note on a file without changes shows the file at HEAD'] = function()
    open_review()
    goto_note('Unchanged but odd')

    local file = child.lua_get(R .. '.view.files[1]')

    eq({ file.path, file.side }, { 'e.txt', 'commit' })
    helpers.expect_screenshot(child, 'review-sidebar-outside')
end

T['wide']['<CR> moves into the diff pane at the note'] = function()
    open_review()
    child.api.nvim_set_current_win(sidebar_win())
    goto_note('Why this change?')
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(child.api.nvim_get_current_line(), 'a3 changed')
end

T['wide']['l past the last column enters the sidebar and <C-j> comes back'] = function()
    open_review()

    local drawer = child.lua_get(R .. '.drawer.win')

    child.type_keys('l', 'l')
    eq(child.api.nvim_get_current_win(), sidebar_win())

    child.type_keys('<C-j>')
    eq(child.api.nvim_get_current_win(), drawer)
    eq(child.lua_get(R .. '.drawer:item().path'), 'a.txt')
end

T['wide']['q in the sidebar closes the review'] = function()
    open_review()
    child.api.nvim_set_current_win(sidebar_win())
    child.type_keys('q')

    eq(child.lua_get(R), vim.NIL)
end

T['wide']['the command focuses the sidebar and keeps it open'] = function()
    open_review()
    child.cmd('Iter annotate')

    eq(child.api.nvim_get_current_win(), sidebar_win())

    child.cmd('Iter annotate')

    eq(child.api.nvim_get_current_win(), sidebar_win())
end

T['resize'] = new_set()

T['resize']['crossing 160 swaps sidebar and column, keeping the note'] = function()
    open_review()
    goto_note('Unchanged but odd')

    child.o.columns = 120
    helpers.wait_until(child, R .. '.side_annotations == false')

    eq(sidebar_win(), nil)
    eq(column_note(), 'Unchanged but odd')

    child.type_keys('k')
    eq(column_note(), 'Why this change?')

    child.o.columns = 200
    helpers.wait_until(child, R .. '.side_annotations == true')
    helpers.wait_until(child, S .. ' ~= nil')

    eq(child.lua_get(R .. '.drawer.column') ~= 'annotations', true)
    eq(
        child.lua_get([[(function()
            local s = ]] .. S .. [[
            local row = s:row()
            return row and row.item and row.item.annotation.body or vim.NIL
        end)()]]),
        'Why this change?'
    )
end

T['resize']['below 160 l still reaches the Annotations column'] = function()
    child.o.columns = 120
    open_review()
    child.type_keys('l')

    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(sidebar_win(), nil)
end

T['resize']['closing the sidebar window brings the column back'] = function()
    open_review()
    child.lua('vim.api.nvim_win_close(' .. S .. '.win, true)')
    helpers.wait_until(child, R .. '.side_annotations == false')

    child.type_keys('l')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
end

T['config'] = new_set()

T['config']['annotate.review_breakpoint sets where the sidebar takes over'] = function()
    setup([[{ annotate = { review_breakpoint = 250 } }]])
    open_review()

    eq(sidebar_win(), nil)
    eq(child.lua_get('#' .. R .. '.drawer.extra'), 1)
end

return T
