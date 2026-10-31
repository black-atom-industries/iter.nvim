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

T['wide'] = new_set()

T['wide']['from 160 tab columns the annotations sit right of the diff'] = function()
    open_review()

    eq(sidebar_win() ~= nil, true)
    eq(
        child.lua_get('vim.api.nvim_win_get_height(' .. S .. '.win)')
            >= child.lua_get(
                'vim.api.nvim_win_get_height(' .. R .. '.diff_win)'
            ),
        true
    )
    eq(
        child.lua_get('vim.api.nvim_win_get_position(' .. S .. '.win)[2]')
            > child.lua_get(
                'vim.api.nvim_win_get_position(' .. R .. '.diff_win)[2]'
            ),
        true
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))
end

T['wide']['the annotations sit right whatever annotate.side says'] = function()
    setup([[{ annotate = { side = 'left' } }]])
    open_review()

    eq(
        child.lua_get('vim.api.nvim_win_get_position(' .. S .. '.win)[2]') > 100,
        true
    )
end

T['wide']['marks changed files; the progress sits in the tree'] = function()
    open_review()

    local lines = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. S .. '.buf, 0, -1, false)'
    )

    eq(vim.startswith(lines[3], 'M a.txt'), true)
    eq(vim.startswith(lines[6], '  e.txt'), true)
    eq(
        vim.trim(
            child.lua_get(
                'vim.api.nvim_buf_get_lines('
                    .. R
                    .. '.tree.buf, 2, 3, false)[1]'
            )
        ):find('0 of 1', 1, true) ~= nil,
        true
    )
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

T['wide']['<C-j> in the sidebar focuses the tree'] = function()
    open_review()
    child.api.nvim_set_current_win(sidebar_win())

    child.type_keys('<C-j>')
    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))
    eq(H.selected(child), 'a.txt')
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

--- The body of the note under the sidebar's cursor.
---@return string|vim.NIL
local function sidebar_note()
    return child.lua_get([[(function()
        local s = ]] .. S .. [[
        local row = s and s:row()
        return row and row.item and row.item.annotation.body or vim.NIL
    end)()]])
end

T['resize']['crossing 160 moves the sidebar below the tree and back, keeping the note'] = function()
    open_review()
    goto_note('Unchanged but odd')

    child.o.columns = 120
    helpers.wait_until(child, S .. ' ~= nil and ' .. S .. '.placement ~= nil')

    eq(sidebar_note(), 'Unchanged but odd')
    eq(child.lua_get('vim.api.nvim_win_get_position(' .. S .. '.win)[2]'), 0)
    eq(child.lua_get(R .. '.annotations_closed'), false)

    child.type_keys('k')
    child.o.columns = 200
    helpers.wait_until(child, S .. ' ~= nil and ' .. S .. '.placement == nil')

    eq(sidebar_note() ~= vim.NIL, true)
end

T['resize']['a sidebar the user closed stays closed across a resize'] = function()
    open_review()
    child.lua('vim.api.nvim_win_close(' .. S .. '.win, true)')
    helpers.wait_until(child, R .. '.annotations_closed')

    child.o.columns = 120
    child.lua('vim.wait(100)')
    eq(sidebar_win(), nil)

    child.lua([[require('iter').annotations()]])
    eq(child.api.nvim_get_current_win(), sidebar_win())
    eq(child.lua_get(S .. '.placement ~= nil'), true)
end

--- The widths of the tree and the annotations window, and whether the
--- split panes of the diff, when there are two, have half of theirs each.
---@return [integer, integer, boolean]
local function widths()
    return child.lua_get([[(function()
        local r = ]] .. R .. [[

        local old = r.view.old
        local new = vim.api.nvim_win_get_width(r.view.win)

        return {
            vim.api.nvim_win_get_width(r.panel.win),
            vim.api.nvim_win_get_width(]] .. S .. [[.win),
            old == nil
                or math.abs(vim.api.nvim_win_get_width(old.win) - new) <= 1,
        }
    end)()]])
end

--- Wait until the tree is `tree` cells wide and the annotations window
--- right of the diff 40, then check the split panes are even.
---@param tree integer
local function wait_widths(tree)
    helpers.wait_until(
        child,
        S
            .. ' ~= nil and '
            .. S
            .. '.placement == nil and vim.api.nvim_win_get_width('
            .. H.LIST_WIN
            .. ') == '
            .. tree
            .. ' and vim.api.nvim_win_get_width('
            .. S
            .. '.win) == 40'
    )
    eq(widths(), { tree, 40, true })
end

T['resize']['the tree and the annotations keep their widths beside the split diff'] = new_set(
    {
        parametrize = { { 'split' }, { 'auto' } },
    },
    {
        test = function(diff_layout)
            setup('{ diff = { layout = ' .. vim.inspect(diff_layout) .. ' } }')
            open_review()
            wait_widths(34)

            child.lua('vim.api.nvim_set_current_win(' .. H.LIST_WIN .. ')')
            child.cmd('vertical resize 50')
            wait_widths(50)

            child.o.columns = 180
            wait_widths(50)

            child.o.columns = 120
            helpers.wait_until(
                child,
                S .. ' ~= nil and ' .. S .. '.placement ~= nil'
            )
            child.o.columns = 200
            wait_widths(34)
        end,
    }
)

T['config'] = new_set()

T['config']['annotate.review_breakpoint sets where the sidebar moves right'] = function()
    setup([[{ annotate = { review_breakpoint = 250 } }]])
    open_review()

    eq(sidebar_win() ~= nil, true)
    eq(child.lua_get(S .. '.placement ~= nil'), true)
end

return T
