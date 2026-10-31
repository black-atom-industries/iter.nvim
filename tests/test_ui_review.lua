local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

-- Window options the diff view borrows, set to values the view never uses,
-- so a changed one shows up.
local PANE_OPTS = {
    number = true,
    relativenumber = true,
    signcolumn = 'yes',
    foldcolumn = '1',
    foldenable = true,
    wrap = true,
    list = true,
    spell = true,
    statuscolumn = '%l ',
}

local R = H.R

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

--- `a.txt` has two unstaged hunks with gaps around them; `b.txt` has a
--- staged line after b2 and two unstaged lines at the top, so its index and
--- worktree line numbers differ; `c.txt` and `d/x.txt` are untracked.
---@return string
local function create_review_repo()
    local path = helpers.create_repo({
        ['a.txt'] = numbered('a', 1, 30),
        ['b.txt'] = numbered('b', 1, 10),
    })

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    helpers.write_file(vim.fs.joinpath(path, 'a.txt'), a)

    local b = numbered('b', 1, 10)
    table.insert(b, 3, 'staged')
    helpers.write_file(vim.fs.joinpath(path, 'b.txt'), b)
    helpers.git(path, { 'add', 'b.txt' })
    table.insert(b, 1, 'top2')
    table.insert(b, 1, 'top1')
    helpers.write_file(vim.fs.joinpath(path, 'b.txt'), b)

    helpers.write_file(vim.fs.joinpath(path, 'c.txt'), { 'c' })
    helpers.write_file(vim.fs.joinpath(path, 'd', 'x.txt'), { 'x' })

    return path
end

--- Keep the status a drawer in the child, whatever the default style.
local function pin_drawer()
    child.lua(
        [[require('iter').config = require('iter.config').resolve({ status = { style = 'drawer' } })]]
    )
end

local function stub_ui()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
    ]])
end

---@param options string Lua table passed to setup(), with the status kept a drawer
local function setup(options)
    child.lua(
        'require("iter").setup(vim.tbl_deep_extend("force", { status = { style = "drawer" } }, '
            .. options
            .. '))'
    )
end

--- Focus the diff pane and put its cursor on the first row whose text is
--- `text`.
---@param text string
local function cursor_on(text)
    child.lua(
        [[
        local text = ...
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum, row in ipairs(r.view.rows) do
            if row.text == text then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
        error('no row ' .. text)
    ]],
        { text }
    )
end

--- The tree's rows as the buffer shows them, without trailing blanks.
---@return string[]
local function tree_rows()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local lines = {}
        for lnum, _ in pairs(r.tree.items) do
            table.insert(lines, lnum)
        end
        table.sort(lines)
        return vim.tbl_map(function(lnum)
            local text = vim.api.nvim_buf_get_lines(r.tree.buf, lnum - 1, lnum, false)[1]
            return (text:gsub('%s+$', ''))
        end, lines)
    end)()]])
end

--- The paths git has staged.
---@return string[]
local function git_staged()
    return vim.split(
        vim.trim(helpers.git(repo, { 'diff', '--cached', '--name-only' })),
        '\n',
        { trimempty = true }
    )
end

---@return string kind and text of the diff pane's cursor row
local function cursor_row()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
        local row = r.view.rows[lnum]
        return row.kind .. ' ' .. row.text
    end)()]])
end

local function set_pane_opts()
    child.lua(
        [[
        _G.pane = vim.api.nvim_get_current_win()
        for name, value in pairs(...) do
            vim.api.nvim_set_option_value(name, value, { win = _G.pane })
        end
    ]],
        { PANE_OPTS }
    )
end

--- Local values of the borrowed options in `_G.pane` and their global values.
---@return table
local function pane_opts()
    return child.lua_get(
        [[(function(names)
            local values = { win = {}, global = {} }
            for name in pairs(names) do
                values.win[name] = vim.api.nvim_get_option_value(name, { scope = 'local', win = _G.pane })
                values.global[name] = vim.api.nvim_get_option_value(name, { scope = 'global' })
            end
            return values
        end)(...)]],
        { PANE_OPTS }
    )
end

-- Handles, autocmds, augroups and buffers that a closed review must not
-- leave behind.
local RESOURCES = [[(function()
    local counts = { fs_event = 0, timer = 0 }
    vim.uv.walk(function(handle)
        local kind = handle:get_type()
        if counts[kind] ~= nil and not handle:is_closing() then
            counts[kind] = counts[kind] + 1
        end
    end)
    local groups = 0
    for _, line in ipairs(vim.split(vim.fn.execute('augroup'), '%s+')) do
        if vim.startswith(line, 'iter.') then
            groups = groups + 1
        end
    end
    counts.groups = groups
    counts.autocmds = #vim.api.nvim_get_autocmds({})
    counts.bufs = #vim.api.nvim_list_bufs()
    counts.wins = #vim.api.nvim_list_wins()
    counts.tabs = #vim.api.nvim_list_tabpages()
    return counts
end)()]]

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_review_repo()
            helpers.start_child(child, repo)
            pin_drawer()
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['open'] = new_set()

T['open'][':Iter review opens the tab with the tree left of the diff'] = function()
    child.cmd('edit a.txt')
    H.open(child)
    H.wait_diff(child, 'unstaged a.txt')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
    eq(H.selected(child), 'a.txt')

    -- The tree at the left edge, the tab's full height, 34 cells wide; the
    -- diff right of it.
    local layout = child.lua_get([[(function()
        local r = require('iter').current_review
        return {
            tree = vim.fn.win_screenpos(r.panel.win),
            width = vim.api.nvim_win_get_width(r.panel.win),
            diff = vim.fn.win_screenpos(r.diff_win)[2],
            name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(r.panel.win)),
        }
    end)()]])
    -- Row 1 is the tab line.
    eq(layout.tree, { 2, 1 })
    eq(layout.width, 34)
    eq(layout.diff, 36)
    eq(layout.name, 'iter://review')
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'review-tab')
end

--- Text of screen row `row` after a redraw.
---@param row integer
---@return string
local function screen_row(row)
    return child.lua_get(
        [[(function(row)
            vim.cmd.redraw()
            local cells = {}
            for col = 1, vim.o.columns do
                table.insert(cells, vim.fn.screenstring(row, col))
            end
            return table.concat(cells)
        end)(...)]],
        { row }
    )
end

T['open']['the tab label and the statuslines read plainly'] = function()
    child.o.laststatus = 2
    child.o.showtabline = 2
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    -- The default tabline names the current window's buffer, shortened.
    eq(screen_row(1):find(' i//review ', 1, true) ~= nil, true)
    child.type_keys('<CR>')
    eq(screen_row(1):find(' i//r/a.txt ', 1, true) ~= nil, true)

    local diff = child.lua_get(R .. '.diff_win')
    local pos = child.fn.win_screenpos(diff)
    local diff_status = pos[1] + child.api.nvim_win_get_height(diff)
    eq(
        vim.startswith(
            vim.fn.strcharpart(screen_row(diff_status), pos[2] - 1),
            'iter://review/a.txt'
        ),
        true
    )
end

T['open']['opening twice gives one tab'] = function()
    H.open(child)
    H.open(child)

    eq(#child.api.nvim_list_tabpages(), 2)

    child.cmd('tabfirst')
    H.open(child)

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
end

T['open']['the tab opts out of the radar HUD'] = function()
    H.open(child)

    eq(child.lua_get('vim.t.radar_disabled'), true)

    child.cmd('tabfirst')

    eq(child.lua_get('vim.t.radar_disabled'), vim.NIL)
end

T['open']['r in the status drawer opens the review and closes the drawer'] = function()
    child.cmd('Iter')
    helpers.wait_until(child, [[require('iter').drawer ~= nil]])
    child.type_keys('r')
    helpers.wait_until(child, R .. ' ~= nil')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 2)

    child.cmd('tabfirst')
    child.cmd('Iter')
    helpers.wait_until(child, [[require('iter').drawer ~= nil]])
    child.type_keys('r')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
end

T['open']['r selects the file selected in the status drawer'] = function()
    child.cmd('Iter')
    helpers.wait_until(child, [[require('iter').drawer ~= nil]])
    child.lua([[
        local d = require('iter').drawer
        for lnum, row in ipairs(d.rows) do
            if row.staged ~= nil then
                d:select(lnum, 'staged')
            end
        end
    ]])
    child.type_keys('r')
    helpers.wait_until(child, R .. ' ~= nil')

    eq(H.selected(child), 'b.txt')
end

T['open'][':Iter status inside the review focuses its tree'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.cmd('Iter status')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
end

T['open'][':Iter completes review'] = function()
    eq(
        child.fn.getcompletion('Iter ', 'cmdline'),
        { 'annotate', 'commits', 'review', 'status' }
    )
    eq(child.fn.getcompletion('Iter re', 'cmdline'), { 'review' })
end

T['open']['outside a git repository warns and opens nothing'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.start_child(child, repo)
    pin_drawer()
    stub_ui()

    child.cmd('Iter review')

    eq(child.lua_get([[_G.notes]]), {
        { '[iter] Not inside a git repository', vim.log.levels.WARN },
    })
    eq(child.lua_get(R), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 1)
end

T['tree'] = new_set()

T['tree']['j moves and the diff follows; r is the mark'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('j')
    H.wait_diff(child, 'unstaged b.txt')

    eq(H.selected(child), 'b.txt')
    eq(
        child.lua_get([[vim.fn.maparg('r', 'n', false, true).desc]]),
        'Mark reviewed and go to the next file'
    )
    eq(child.lua_get([[vim.fn.maparg('q', 'n', false, true).desc]]), 'Close')
end

T['tree']['rows are directories first, then files, with staging icons'] = function()
    H.open(child)

    eq(tree_rows(), {
        '   ▾ d/',
        '     ○ ? x.txt',
        '   ○ M a.txt',
        '   ◐ M b.txt',
        '   ○ ? c.txt',
    })
    eq(H.selected(child), 'd/x.txt')
end

T['tree']['a partly staged file shows its Unstaged then its Staged section'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')

    eq(
        child.lua_get(
            [[vim.tbl_map(function(f) return f.side .. ' ' .. f.path end, ]]
                .. R
                .. [[.view.files)]]
        ),
        { 'unstaged b.txt', 'staged b.txt' }
    )
    eq(
        child.lua_get(R .. '.preview.previewed'),
        'unstaged\0b.txt\nstaged\0b.txt'
    )

    helpers.expect_screenshot(child, 'review-tree-partly')
end

T['tree']['<CR> moves into the diff pane'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('j', '<CR>')

    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.lua_get(R .. '.view.files[1].path'), 'b.txt')
end

T['tree']['h and l close and open a directory, <CR> toggles it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'd/x.txt')

    -- h on a file closes its directory and moves onto it.
    child.type_keys('h')
    eq(tree_rows()[1], '   ▸ d/')
    eq(#tree_rows(), 4)
    eq(H.selected(child), vim.NIL)
    eq(child.lua_get(R .. '.tree:node().path'), 'd/')

    child.type_keys('l')
    eq(tree_rows()[1], '   ▾ d/')
    eq(#tree_rows(), 5)

    child.type_keys('<CR>')
    eq(tree_rows()[1], '   ▸ d/')
    child.type_keys('<CR>')
    eq(tree_rows()[2], '     ○ ? x.txt')

    -- A closed directory stays closed across a refresh.
    child.type_keys('h')
    child.lua(R .. ':refresh()')
    eq(tree_rows()[1], '   ▸ d/')
end

T['tree']['h on a file closes its directory after a poll read the tree again'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'd/x.txt')
    child.lua(R .. [[:refresh('poll')]])
    H.focus_list(child)

    child.type_keys('h')

    eq(tree_rows()[1], '   ▸ d/')
    eq(child.lua_get(R .. '.tree:node().path'), 'd/')
end

T['tree']['s on a directory stages its files, u unstages them'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'd/x.txt')
    child.type_keys('h', 's')

    helpers.wait_until(child, [[(function()
            for _, item in ipairs(]] .. R .. [[.changes.staged) do
                if item.path == 'd/x.txt' then
                    return true
                end
            end
        end)()]])
    eq(git_staged(), { 'b.txt', 'd/x.txt' })

    -- Sticky: s again leaves them staged.
    child.type_keys('s')
    eq(git_staged(), { 'b.txt', 'd/x.txt' })

    child.type_keys('u')
    helpers.wait_until(child, [[#]] .. R .. [[.changes.staged == 1]])
    eq(git_staged(), { 'b.txt' })
end

T['tree']['d and I on a directory warn'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'd/x.txt')
    child.type_keys('h', 'd', 'I')

    eq(child.lua_get('_G.notes'), {
        { '[iter] Works on a file, not a directory', vim.log.levels.WARN },
        { '[iter] Works on a file, not a directory', vim.log.levels.WARN },
    })
end

T['tree']['I appends an untracked file to .gitignore'] = function()
    child.lua([[
        _G.confirms = {}
        vim.fn.confirm = function(msg)
            table.insert(_G.confirms, msg)
            return 1
        end
    ]])
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    H.select(child, 'unstaged', 'c.txt')
    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), { 'Append c.txt to .gitignore?' })
    eq(vim.fn.readfile(vim.fs.joinpath(repo, '.gitignore')), { '/c.txt' })
    eq(
        child.lua_get(
            'vim.tbl_map(function(item) return item.path end, '
                .. R
                .. '.changes.unstaged)'
        ),
        { '.gitignore', 'a.txt', 'b.txt', 'd/x.txt' }
    )
end

T['tree']['q closes the tab and returns to the tab it came from'] = function()
    child.cmd('tabnew')
    child.cmd('tabfirst')
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('q')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(child.lua_get(R), vim.NIL)
end

T['tree']['<C-d> and <C-u> scroll the diff, the tree keeps focus'] = function()
    local lines = {}
    for i = 1, 100 do
        lines[i] = 'line ' .. i
    end
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), lines)

    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    local topline = [[vim.fn.getwininfo(]] .. R .. [[.diff_win)[1].topline]]
    local drawer_focused = [[vim.api.nvim_get_current_win() == ]] .. H.LIST_WIN
    local before = child.lua_get(topline)

    child.type_keys('<C-d>')
    eq(child.lua_get(topline) > before, true)
    eq(child.lua_get(drawer_focused), true)

    child.type_keys('<C-u>')
    eq(child.lua_get(topline), before)
    eq(child.lua_get(drawer_focused), true)
end

T['diff'] = new_set()

T['diff']['<C-j> in the diff pane focuses the tree'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')

    child.type_keys('<C-j>')

    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
end

T['diff'][']c and [c jump between hunks'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.api.nvim_win_set_cursor(0, { 1, 0 })

    child.type_keys(']c')
    eq(cursor_row(), 'hunk @@ -1,6 +1,6 @@')
    child.type_keys(']c')
    eq(cursor_row(), 'hunk @@ -22,7 +22,7 @@ a21')
    child.type_keys(']c')
    eq(cursor_row(), 'hunk @@ -22,7 +22,7 @@ a21')
    child.type_keys('[c')
    eq(cursor_row(), 'hunk @@ -1,6 +1,6 @@')
end

T['diff'][']f and [f follow the tree order'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')

    local order = {}

    for _ = 1, 3 do
        child.type_keys(']f')
        table.insert(order, H.selected(child))
        eq(cursor_row():sub(1, 7), 'header ')
    end

    eq(order, { 'b.txt', 'c.txt', 'c.txt' })
    eq(child.lua_get(R .. '.view.files[1].path'), 'c.txt')
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)

    child.type_keys('[f')
    eq(H.selected(child), 'b.txt')
    eq(child.lua_get('#' .. R .. '.view.files'), 2)
end

T['diff']['[f into a closed directory opens it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'd/x.txt')
    child.type_keys('h')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(tree_rows()[1], '   ▸ d/')

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('[f')

    eq(H.selected(child), 'd/x.txt')
    eq(tree_rows()[1], '   ▾ d/')
    H.wait_diff(child, 'unstaged d/x.txt')
end

T['diff']['<CR> on a gap expands it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    local before = child.lua_get('#' .. R .. '.view.rows')
    child.type_keys('<CR>')
    child.lua([[
        local r = require('iter').current_review
        for lnum, row in ipairs(r.view.rows) do
            if row.kind == 'gap' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])
    child.type_keys('<CR>')

    eq(child.lua_get('#' .. R .. '.view.rows') > before, true)
end

T['diff']['<CR> on a code row keeps the review as it is'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    local tab = child.lua_get(R .. '.tab')
    local before = child.lua_get('#' .. R .. '.view.rows')
    cursor_on('a25 changed')

    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_tabpage(), tab)
    eq(child.lua_get(R .. ':is_open()'), true)
    eq(child.lua_get('#' .. R .. '.view.rows'), before)
    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
end

T['diff']['q closes the tab'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>', 'q')

    eq(#child.api.nvim_list_tabpages(), 1)
    eq(child.lua_get(R), vim.NIL)
end

---@return { line: integer, text: string, tab: integer, name: string }
local function goto_target()
    return child.lua_get([[{
        line = vim.api.nvim_win_get_cursor(0)[1],
        text = vim.api.nvim_get_current_line(),
        tab = vim.api.nvim_get_current_tabpage(),
        name = vim.fs.basename(vim.api.nvim_buf_get_name(0)),
    }]])
end

T['goto'] = new_set()

T['goto']['gf on an unstaged row opens the worktree line in the previous tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(goto_target(), { line = 4, text = 'b2', tab = origin, name = 'b.txt' })
    eq(#child.api.nvim_list_tabpages(), 2)
end

T['goto']['gf on a staged row maps through the unstaged diff'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    H.select(child, 'staged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')

    -- The Staged section's row of the line `staged`.
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        local section = r.view.document.sections[2]
        for lnum = section.first, #r.view.rows do
            if r.view.rows[lnum].text == 'staged' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])
    child.type_keys('gf')
    eq(
        goto_target(),
        { line = 5, text = 'staged', tab = origin, name = 'b.txt' }
    )

    child.cmd('tablast')
    child.lua([[
        local r = require('iter').current_review
        local section = r.view.document.sections[2]
        for lnum = section.first, #r.view.rows do
            if r.view.rows[lnum].text == 'b5' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])
    child.type_keys('gf')
    eq(goto_target(), { line = 8, text = 'b5', tab = origin, name = 'b.txt' })
end

T['goto']['gf on an unstaged del row lands on the line that replaced it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum, row in ipairs(r.view.rows) do
            if row.kind == 'del' and row.text == 'a25' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('gf')

    eq(goto_target().line, 25)
    eq(goto_target().text, 'a25 changed')
end

T['goto']['gf avoids a float in the previous tab'] = function()
    child.lua([[
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_open_win(buf, true, {
            relative = 'editor', row = 1, col = 1, width = 10, height = 2,
        })
    ]])
    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(child.api.nvim_win_get_config(0).relative, '')
    eq(goto_target().name, 'b.txt')
end

T['goto']['gf with nohidden and unsaved changes warns and stays'] = function()
    child.o.hidden = false
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    cursor_on('b2')
    child.lua('_G.notes = {}')
    child.type_keys('gf')

    eq(child.lua_get('_G.notes'), {
        { '[iter] The pane has unsaved changes', vim.log.levels.WARN },
    })
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.v.errmsg, '')
end

T['goto']['the view buffer is hermetic'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(
        child.lua_get([[vim.api.nvim_buf_get_name(]] .. R .. [[.view.buf)]]),
        'iter://review/a.txt'
    )
    eq(child.lua_get('vim.bo[' .. R .. '.view.buf].buftype'), 'nofile')
end

T['switch'] = new_set()

--- The review is open, its diff pane shows the view and its tree window
--- shows the tree.
local function expect_review_intact()
    child.lua('vim.wait(100)')
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. ' ~= nil and ' .. R .. ':is_open()'), true)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. R
                .. '.diff_win) == '
                .. R
                .. '.view.buf'
        ),
        true
    )
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. H.LIST_WIN
                .. ') == '
                .. R
                .. '.tree.buf'
        ),
        true
    )
end

T['switch']['<C-o> in the diff pane keeps the review'] = function()
    child.cmd('edit b.txt')
    child.cmd('edit a.txt')
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('<C-o>')

    expect_review_intact()
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.v.errmsg, '')
end

T['switch']['<C-o> in the tree keeps the review'] = function()
    child.cmd('edit b.txt')
    child.cmd('edit a.txt')
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<C-o>')

    expect_review_intact()
    eq(child.v.errmsg, '')
end

T['switch'][':e in the diff pane opens the file in the previous tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.cmd('edit +2 c.txt')
    child.lua('vim.wait(100)')

    eq(goto_target(), { line = 1, text = 'c', tab = origin, name = 'c.txt' })
    child.cmd('tablast')
    expect_review_intact()
    eq(child.lua_get(R .. '.view.files[1].path'), 'a.txt')
    eq(child.v.errmsg, '')

    -- Putting the view back leaves no jump to the file behind.
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    eq(
        child.lua_get([[vim.tbl_map(function(entry)
            return vim.fs.basename(vim.fn.bufname(entry.bufnr))
        end, vim.fn.getjumplist()[1])]]),
        {}
    )
    child.type_keys('<C-o>')
    child.lua('vim.wait(50)')
    eq(child.api.nvim_get_current_tabpage(), child.lua_get(R .. '.tab'))
    expect_review_intact()

    -- The pane stays the view's: closing the review gives nothing back to it.
    child.type_keys('q')
    eq(child.lua_get(R), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 1)
end

T['switch'][':e in the tree opens the file in the previous tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.cmd('edit +2 c.txt')
    child.lua('vim.wait(100)')

    eq(goto_target(), { line = 1, text = 'c', tab = origin, name = 'c.txt' })
    child.cmd('tablast')
    expect_review_intact()
    eq(child.lua_get(R .. '.view.files[1].path'), 'a.txt')
    eq(child.v.errmsg, '')
end

T['switch'][':enew in the diff pane puts the view back'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.cmd('enew')

    expect_review_intact()
    eq(child.v.errmsg, '')
end

T['refresh'] = new_set({
    hooks = {
        pre_case = function()
            setup([[{ refresh = { poll_ms = 100 } }]])
        end,
    },
})

T['refresh']['an external write re-renders the diff and keeps the cursor near its row'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a25 changed')
    child.lua('_G.generation = ' .. R .. '.view.generation')

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    table.insert(a, 10, 'inserted')
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

    helpers.wait_until(child, [[(function()
            for _, row in ipairs(]] .. R .. [[.view.rows) do
                if row.text == 'inserted' then
                    return true
                end
            end
        end)()]])

    eq(cursor_row(), 'add a25 changed')
    eq(child.lua_get(R .. '.view.generation > _G.generation'), true)
end

T['refresh']['a refresh in the background leaves other tabs as they are'] = function()
    child.cmd('vsplit')
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.cmd('tabfirst')

    local layout = [[{
        heights = vim.tbl_map(vim.api.nvim_win_get_height, vim.api.nvim_tabpage_list_wins(0)),
        cmdheight = vim.o.cmdheight,
    }]]
    local before = child.lua_get(layout)

    for i = 1, 6 do
        helpers.write_file(vim.fs.joinpath(repo, 'n' .. i .. '.txt'), { 'n' })
    end

    helpers.wait_until(child, '#' .. R .. ':paths() == 10')

    eq(child.lua_get(layout), before)
    eq(child.v.errmsg, '')
end

T['clean'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.start_child(child, repo)
            pin_drawer()
            stub_ui()
        end,
    },
})

T['clean']['a clean tree opens the tab with an empty diff pane'] = function()
    H.open(child)

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.diff_win), 0, -1, false)]]
        ),
        { '' }
    )
    eq(child.lua_get(R .. '.view:is_shown()'), false)
    eq(child.lua_get([[require('iter').statusline()]]), 'review')
end

T['statusline'] = new_set()

T['statusline']['names the file and its position inside the tab only'] = function()
    eq(child.lua_get([[require('iter').statusline()]]), '')

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · a.txt · 2/4'
    )

    H.select(child, 'staged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · b.txt · 3/4'
    )

    child.cmd('tabfirst')
    eq(child.lua_get([[require('iter').statusline()]]), 'main · 4')
end

T['close'] = new_set()

T['close']['the diff buffer keeps no <C-j> map once the review is closed'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    local view_buf = child.lua_get(R .. '.view.buf')
    eq(
        child.lua_get(
            string.format(
                [[vim.api.nvim_buf_call(%d, function() return vim.fn.maparg('<C-j>', 'n', false, true).desc end)]],
                view_buf
            )
        ),
        'Focus the drawer or the file tree'
    )

    child.lua('vim.cmd.tabclose()')
    helpers.wait_until(child, [[require('iter').current_review == nil]])

    eq(
        child.lua_get([[vim.fn.maparg('<C-j>', 'n', false, true).desc]]),
        vim.NIL
    )
    eq(child.api.nvim_buf_is_valid(view_buf), false)
end

T['close']['the previous tab keeps its window options'] = function()
    set_pane_opts()
    local before = pane_opts()

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys(']f')
    H.wait_diff(child, 'unstaged b.txt')
    child.type_keys('q')

    eq(pane_opts(), before)

    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(pane_opts().global, before.global)
    eq(child.lua_get('vim.wo[_G.pane].statuscolumn'), PANE_OPTS.statuscolumn)
end

T['close']['repeated open and close leaves nothing behind'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('q')
    child.lua('vim.wait(200)')

    local before = child.lua_get(RESOURCES)

    for _ = 1, 3 do
        H.open(child)
        H.select(child, 'unstaged', 'a.txt')
        H.wait_diff(child, 'unstaged a.txt')
        child.type_keys('<CR>', ']f')
        H.wait_diff(child, 'unstaged b.txt')
        child.type_keys('q')
        child.lua('vim.wait(200)')
        eq(child.lua_get(RESOURCES), before)
    end
end

--- Every way out of the tab clears the review and stops its watchers.
---@param leave fun()
local function expect_clean_exit(leave)
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('q')
    child.lua('vim.wait(200)')
    local before = child.lua_get(RESOURCES)

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    leave()
    child.lua('vim.wait(200)')

    eq(child.lua_get(R), vim.NIL)
    eq(child.lua_get(RESOURCES), before)
    eq(child.v.errmsg, '')
end

T['close'][':tabclose clears the review'] = function()
    expect_clean_exit(function()
        child.cmd('tabclose')
    end)
end

T['close'][':q in the diff pane closes the tab'] = function()
    expect_clean_exit(function()
        child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
        child.cmd('quit')
    end)
end

T['close'][':q in the tree closes the tab'] = function()
    expect_clean_exit(function()
        child.cmd('quit')
    end)
end

T['close'][':q in the annotations window closes only that window'] = function()
    child.o.columns = 200
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
    )
    child.cmd('quit')
    child.lua('vim.wait(100)')

    eq(child.lua_get(R .. ':is_open()'), true)
    eq(child.lua_get(R .. '.annotations_closed'), true)
    eq(child.v.errmsg, '')
end

T['close']['q in the annotations window closes the tab'] = function()
    expect_clean_exit(function()
        child.lua(
            [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
        )
        child.type_keys('q')
    end)
end

T['close']['q after :tabonly leaves one empty tab'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.cmd('tabonly')
    child.type_keys('q')

    eq(#child.api.nvim_list_tabpages(), 1)
    eq(child.lua_get(R), vim.NIL)
    eq(child.v.errmsg, '')
end

T['hunks'] = new_set()

---@param args string[]
---@return string
local function git_out(args)
    return helpers.git(repo, args)
end

---@param path string
---@param lines string[]
local function write_crlf(path, lines)
    local file = assert(io.open(path, 'wb'))
    file:write(table.concat(lines, '\r\n') .. '\r\n')
    file:close()
end

--- Wait until the diff pane's cursor sits on `expected` (kind and text).
---@param expected string
local function wait_cursor(expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
                local row = r.view.rows[lnum]
                return row ~= nil and row.kind .. ' ' .. row.text == %q
            end)()]],
            R,
            expected
        )
    )
end

T['hunks']['s stages the hunk under the cursor and keeps the other'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')

    local cached = git_out({ 'diff', '--cached', '--', 'a.txt' })
    eq(cached:find('+a3 changed', 1, true) ~= nil, true)
    eq(cached:find('a25 changed', 1, true), nil)

    local unstaged = git_out({ 'diff', '--', 'a.txt' })
    eq(unstaged:find('a3 changed', 1, true), nil)
    eq(unstaged:find('+a25 changed', 1, true) ~= nil, true)

    wait_cursor('hunk @@ -22,7 +22,7 @@ a21')
    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    eq(
        child.lua_get(
            'vim.tbl_map(function(item) return item.path end, '
                .. R
                .. '.changes.staged)'
        ),
        { 'a.txt', 'b.txt' }
    )
    eq(child.lua_get('_G.notes'), {})
end

T['hunks']['s on a hunk fires IterStage with the file'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua([[
        _G.stages = {}
        vim.api.nvim_create_autocmd('User', {
            pattern = 'IterStage',
            callback = function(args)
                table.insert(_G.stages, args.data)
            end,
        })
    ]])
    cursor_on('a3 changed')
    child.type_keys('s')

    eq(
        child.lua_get('_G.stages'),
        { { root = repo, paths = { 'a.txt' }, action = 'stage' } }
    )
end

T['hunks']['u unstages the hunk under the cursor and keeps the other'] = function()
    helpers.git(repo, { 'add', 'a.txt' })
    H.open(child)
    H.select(child, 'staged', 'a.txt')
    H.wait_diff(child, 'staged a.txt')
    cursor_on('a25 changed')
    child.type_keys('u')

    local cached = git_out({ 'diff', '--cached', '--', 'a.txt' })
    eq(cached:find('+a3 changed', 1, true) ~= nil, true)
    eq(cached:find('a25 changed', 1, true), nil)
    eq(
        git_out({ 'diff', '--', 'a.txt' }):find('+a25 changed', 1, true) ~= nil,
        true
    )

    wait_cursor('hunk @@ -1,6 +1,6 @@')
    eq(child.lua_get('_G.notes'), {})
end

T['hunks']['staging and unstaging the last hunk of a file keeps the file'] = function()
    local b_index = git_out({ 'diff', '--cached', '--', 'b.txt' })

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')
    wait_cursor('hunk @@ -22,7 +22,7 @@ a21')
    child.type_keys('s')

    eq(git_out({ 'diff', '--', 'a.txt' }), '')
    H.wait_diff(child, 'staged a.txt')
    eq(H.selected(child), 'a.txt')

    -- A second s stays on the file the pane shows.
    child.type_keys('s')
    eq(git_out({ 'diff', '--cached', '--', 'b.txt' }), b_index)
    eq(child.lua_get('_G.notes'), {
        { '[iter] The hunk is staged already', vim.log.levels.WARN },
    })
    child.lua('_G.notes = {}')

    cursor_on('a3 changed')
    child.type_keys('u')
    wait_cursor('hunk @@ -22,7 +22,7 @@ a21')
    child.type_keys('u')

    eq(git_out({ 'diff', '--cached', '--', 'a.txt' }), '')
    H.wait_diff(child, 'unstaged a.txt')
    eq(H.selected(child), 'a.txt')
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['hunks']['s on a staged row, u on an unstaged row and s off a hunk warn'] = function()
    helpers.git(repo, { 'add', 'a.txt' })
    local before = git_out({ 'diff', '--cached' })

    H.open(child)
    H.select(child, 'staged', 'a.txt')
    H.wait_diff(child, 'staged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')

    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    cursor_on('top1')
    child.type_keys('u')
    child.api.nvim_win_set_cursor(0, { 1, 0 })
    child.type_keys('s')

    eq(child.lua_get('_G.notes'), {
        { '[iter] The hunk is staged already', vim.log.levels.WARN },
        { '[iter] The hunk is not staged', vim.log.levels.WARN },
        { '[iter] No hunk under the cursor', vim.log.levels.WARN },
    })
    eq(git_out({ 'diff', '--cached' }), before)
end

T['hunks']['a hunk whose file changed after the render warns and changes nothing'] = function()
    setup([[{ refresh = { poll_ms = 60000 } }]])
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    a[28] = 'a28 written later'
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)
    child.type_keys('s')

    eq(git_out({ 'diff', '--cached', '--', 'a.txt' }), '')
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] a.txt changed since it was shown; nothing was applied',
            vim.log.levels.WARN,
        },
    })
    helpers.wait_until(child, [[(function()
            for _, row in ipairs(]] .. R .. [[.view.rows) do
                if row.text == 'a28 written later' then
                    return true
                end
            end
        end)()]])
end

T['hunks']['a hunk git apply refuses reports and changes nothing'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')
    local lock = vim.fs.joinpath(repo, '.git', 'index.lock')
    helpers.write_file(lock, {})
    child.type_keys('s')
    vim.fn.delete(lock)

    eq(git_out({ 'diff', '--cached', '--', 'a.txt' }), '')
    local notes = child.lua_get('_G.notes')
    eq(#notes, 1)
    eq(vim.startswith(notes[1][1], '[iter] Cannot stage the hunk: '), true)
    eq(notes[1][2], vim.log.levels.ERROR)
end

T['hunks']['s stages one hunk of a CRLF file byte for byte'] = function()
    local lines = numbered('e', 1, 30)
    local path = vim.fs.joinpath(repo, 'e.txt')
    write_crlf(path, lines)
    helpers.git(repo, { 'add', 'e.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'crlf' })

    local changed = vim.deepcopy(lines)
    changed[3], changed[25] = 'e3 changed', 'e25 changed'
    write_crlf(path, changed)

    H.open(child)
    H.select(child, 'unstaged', 'e.txt')
    H.wait_diff(child, 'unstaged e.txt')
    cursor_on('e3 changed')
    child.type_keys('s')

    local expected = vim.deepcopy(lines)
    expected[3] = 'e3 changed'
    local blob = vim.fn.tempname()
    write_crlf(blob, expected)

    eq(
        vim.trim(git_out({ 'rev-parse', ':e.txt' })),
        vim.trim(git_out({ 'hash-object', '--no-filters', blob }))
    )
    vim.fn.delete(blob)
    eq(child.lua_get('_G.notes'), {})
end

--- The added rows the diff pane shows.
---@return string[]
local function added_rows()
    return child.lua_get([[(function()
        local out = {}
        for _, row in ipairs(]] .. R .. [[.view.rows) do
            if row.kind == 'add' then
                table.insert(out, row.text)
            end
        end
        return out
    end)()]])
end

T['hunks']['visual s stages the selected lines and visual u unstages them'] = function()
    local a = numbered('a', 1, 30)
    table.insert(a, 11, 'n3')
    table.insert(a, 11, 'n2')
    table.insert(a, 11, 'n1')
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('n1')
    child.type_keys('V', 'j', 's')

    eq(child.fn.mode(), 'n')
    eq(
        vim.tbl_filter(function(line)
            return vim.startswith(line, '+n')
        end, vim.split(
            git_out({ 'diff', '--cached', '--', 'a.txt' }),
            '\n'
        )),
        { '+n1', '+n2' }
    )
    -- Unstaged section, then Staged.
    helpers.wait_until(child, R .. '.view.document.sections[2] ~= nil')
    eq(added_rows(), { 'n3', 'n1', 'n2' })

    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum = r.view.document.sections[2].first, #r.view.rows do
            if r.view.rows[lnum].text == 'n1' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])
    child.type_keys('V', 'u')

    eq(git_out({ 'show', ':a.txt' }):find('n1', 1, true), nil)
    eq(git_out({ 'show', ':a.txt' }):find('n2', 1, true) ~= nil, true)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local n = 0
                for _, row in ipairs(%s.view.rows) do
                    if row.kind == 'add' then
                        n = n + 1
                    end
                end
                return n == 3
            end)()]],
            R
        )
    )
    eq(added_rows(), { 'n1', 'n3', 'n2' })
    eq(vim.fn.readfile(vim.fs.joinpath(repo, 'a.txt')), a)
    eq(child.lua_get('_G.notes'), {})
end

T['hunks']['staging works with diff.args -U1 and --histogram'] = function()
    setup([[{ diff = { args = { '-U1', '--histogram' } } }]])
    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    table.insert(a, 11, 'n2')
    table.insert(a, 11, 'n1')
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')

    local cached = git_out({ 'diff', '--cached', '--', 'a.txt' })
    eq(cached:find('+a3 changed', 1, true) ~= nil, true)
    eq(cached:find('a25 changed', 1, true), nil)
    eq(cached:find('n1', 1, true), nil)

    helpers.wait_until(child, R .. [[.view.files[1].side == 'unstaged']])
    cursor_on('n1')
    child.type_keys('V', 's')

    local lines = vim.tbl_filter(function(line)
        return vim.startswith(line, '+n')
    end, vim.split(git_out({ 'diff', '--cached', '--', 'a.txt' }), '\n'))
    eq(lines, { '+n1' })
    eq(
        git_out({ 'diff', '--', 'a.txt' }):find('+a25 changed', 1, true) ~= nil,
        true
    )
    eq(child.lua_get('_G.notes'), {})
end

T['hunks']['visual s on a symlink warns and changes nothing'] = function()
    local link = vim.fs.joinpath(repo, 'l')
    vim.uv.fs_symlink('target-one', link)
    helpers.git(repo, { 'add', 'l' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'link' })
    vim.fn.delete(link)
    vim.uv.fs_symlink('target-two', link)
    local before = git_out({ 'ls-files', '--stage', 'l' })

    H.open(child)
    H.select(child, 'unstaged', 'l')
    H.wait_diff(child, 'unstaged l')
    cursor_on('target-two')
    child.type_keys('V', 's')

    eq(child.fn.mode(), 'n')
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] Lines of a symlink or submodule cannot be staged one by one',
            vim.log.levels.WARN,
        },
    })
    eq(git_out({ 'ls-files', '--stage', 'l' }), before)
    eq(git_out({ 'diff', '--cached', '--', 'l' }), '')
end

T['hunks']['visual s over context rows only warns once'] = function()
    local before = git_out({ 'diff', '--cached' })

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a4')
    child.type_keys('V', 'j', 's')

    eq(child.fn.mode(), 'n')
    eq(child.lua_get('_G.notes'), {
        { '[iter] No added or deleted lines selected', vim.log.levels.WARN },
    })
    eq(git_out({ 'diff', '--cached' }), before)
end

T['hunks']['? in the diff pane lists its keys'] = function()
    setup([[{ keys = { diff = { stage = 'S' } } }]])
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')

    local help = R .. '.help'

    for _, close in ipairs({ 'q', '?', '<Esc>' }) do
        child.type_keys('?')
        eq(
            child.lua_get(
                [[vim.tbl_map(function(line)
                    return (line:gsub('%s+$', ''))
                end, vim.api.nvim_buf_get_lines(]]
                    .. help
                    .. [[.buf, 0, -1, false))]]
            ),
            {
                ' ]c     Next hunk',
                ' [c     Previous hunk',
                ' ]a     Next annotation',
                ' [a     Previous annotation',
                ' ]f     Next file',
                ' [f     Previous file',
                ' S      Stage the hunk or the selected lines',
                ' u      Unstage the hunk or the selected lines',
                ' a      Annotate the line or range',
                ' A      Annotate the file',
                ' e      Edit the annotation',
                ' d      Delete the annotation',
                ' <CR>   Expand the collapsed file or hidden context',
                ' gf     Go to the line in the file',
                ' r      Mark reviewed and go to the next file',
                ' R      Remove the reviewed mark',
                ' =      Toggle one file or all files',
                ' |      Show the diff side by side',
                ' -      Show the diff unified',
                ' gw     Toggle wrapping long lines',
                ' y      Copy the annotation or file',
                ' Y      Copy all annotations',
                ' <C-j>  Focus the drawer or the file tree',
                ' q      Close',
                ' ?      Show the keys',
            }
        )
        eq(
            child.lua_get(
                'vim.api.nvim_win_get_config(' .. help .. '.win).zindex'
            ),
            50
        )

        child.type_keys(close)
        eq(child.lua_get(help .. ':is_open()'), false)
        eq(
            child.lua_get(
                'vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'
            ),
            true
        )
    end
end

T['reviewed'] = new_set({
    hooks = {
        pre_case = function()
            setup([[{ refresh = { poll_ms = 100 } }]])
            -- An 80-cell diff beside the tree.
            child.o.columns = 115
        end,
    },
})

--- The tree's row of `path` with its runs of blanks squeezed to one and
--- the staging icon left out: the letter, the name, then the marks.
---@param path string
---@return string?
local function row_of(path)
    return child.lua_get(
        [[(function(path)
            local r = require('iter').current_review
            for lnum, row in pairs(r.tree.items) do
                if row.node.path == path then
                    local text = vim.api.nvim_buf_get_lines(r.tree.buf, lnum - 1, lnum, false)[1]
                    for _, icon in ipairs({ '●', '◐', '○' }) do
                        text = text:gsub(icon, '')
                    end
                    text = vim.trim((text:gsub('%s+', ' ')))
                    return text
                end
            end
            return vim.NIL
        end)(...)]],
        { path }
    )
end

--- The tree's title and subtitle lines, trimmed.
---@return string[]
local function tree_header()
    return vim.tbl_map(
        vim.trim,
        child.lua_get(
            [[vim.api.nvim_buf_get_lines(]] .. R .. [[.tree.buf, 0, 2, false)]]
        )
    )
end

--- The reviewed progress line of the tree, trimmed.
---@return string
local function progress()
    return vim.trim(
        child.lua_get(
            [[vim.api.nvim_buf_get_lines(]]
                .. R
                .. [[.tree.buf, 2, 3, false)[1] ]]
        )
    )
end

--- The text of the diff header's right-aligned virtual text.
---@return string
local function diff_header()
    return child.lua_get([[(function()
        local view = require('iter').current_review.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff']
        local marks = vim.api.nvim_buf_get_extmarks(view.buf, ns, { 0, 0 }, { 0, -1 }, { details = true })
        for _, mark in ipairs(marks) do
            if mark[4].virt_text_pos == 'right_align' then
                local text = ''
                for _, chunk in ipairs(mark[4].virt_text) do
                    text = text .. chunk[1]
                end
                return text
            end
        end
        return ''
    end)()]])
end

--- Wait until the diff header shows `text`.
---@param text string
local function wait_diff_header(text)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local view = %s.view
                local ns = vim.api.nvim_get_namespaces()['iter.diff']
                for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, { 0, 0 }, { 0, -1 }, { details = true })) do
                    if mark[4].virt_text_pos == 'right_align' and mark[4].virt_text[1][1]:find(%q, 1, true) then
                        return true
                    end
                end
            end)()]],
            R,
            text
        )
    )
end

--- Select the row of `path` and press r in the tree.
---@param path string
local function view_file(path)
    H.select(child, 'unstaged', path)
    H.wait_diff(child, 'unstaged ' .. path)
    child.type_keys('r')
end

--- Wait until the review has `state` for `path`.
---@param path string
---@param state IterReviewedState
local function wait_state(path, state)
    helpers.wait_until(
        child,
        string.format([[%s.reviewed[%q] == %q]], R, path, state)
    )
end

--- Write the outside edit of `b.txt` that keeps its staged line.
local function edit_b_from_outside()
    local b = numbered('b', 1, 10)
    table.insert(b, 3, 'staged')
    table.insert(b, 1, 'top2')
    table.insert(b, 1, 'top1')
    table.insert(b, 'agent edit')
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
end

T['reviewed']['rows start unreviewed, the header counts files and shows progress'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(tree_rows(), {
        '   ▾ d/',
        '     ○ ? x.txt',
        '   ○ M a.txt',
        '   ◐ M b.txt',
        '   ○ ? c.txt',
    })
    eq(tree_header(), { 'Review HEAD main', 'Working changes · 4 files' })
    eq(
        progress(),
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 4'
    )
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
end

T['reviewed']['in a narrow pane the diff header keeps the path readable'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')

    -- The new window takes the width given; the diff pane keeps the rest.
    child.type_keys('<CR>')
    child.cmd('vsplit')
    child.cmd('vertical resize 30')
    helpers.wait_until(
        child,
        [[require('iter').current_review.view:text_width() < 40]]
    )
    eq(diff_header(), '+2 −2 · 0 annotations ')

    child.cmd('vertical resize 62')
    helpers.wait_until(
        child,
        [[require('iter').current_review.view:text_width() < 10]]
    )
    eq(diff_header(), '')
end

T['reviewed']['in the split layout at 70 columns the header fits beside the path'] = function()
    -- A 70-cell diff beside the tree.
    child.o.columns = 105
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.view.old ~= nil')

    local fit = child.lua_get([[(function()
        local view = ]] .. R .. [[.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff']
        local used = vim.fn.strdisplaywidth(
            'M ' .. vim.api.nvim_buf_get_lines(view.buf, 0, 1, true)[1]
                .. '  worktree'
        )
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, { 0, 0 }, { 0, -1 }, { details = true })) do
            if mark[4].virt_text_pos == 'right_align' then
                for _, chunk in ipairs(mark[4].virt_text) do
                    used = used + vim.fn.strdisplaywidth(chunk[1])
                end
            end
        end
        return used < view:text_width()
    end)()]])

    eq(fit, true)
end

T['reviewed']['the header has no ahead count'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    helpers.git(repo, { 'commit', '--quiet', '--allow-empty', '-m', 'ahead' })
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(tree_header(), { 'Review HEAD main', 'Working changes · 4 files' })
end

T['reviewed']['r in the tree marks the selected file, R unmarks it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(row_of('a.txt'), 'M a.txt ✓')
    eq(row_of('b.txt'), 'M b.txt')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
    eq(diff_header(), '✓ reviewed  +2 −2 · 0 annotations ')
    eq(child.lua_get('_G.notes'), {})

    child.type_keys('R')
    wait_state('a.txt', 'unreviewed')

    eq(H.selected(child), 'a.txt')

    eq(
        progress(),
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 4'
    )
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
end

T['reviewed']['r in the diff pane marks the shown file, R unmarks it'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(diff_header(), '✓ reviewed  +2 −2 · 0 annotations ')
    eq(row_of('a.txt'), 'M a.txt ✓')
    eq(row_of('b.txt'), 'M b.txt')

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('R')
    wait_state('a.txt', 'unreviewed')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
    eq(H.selected(child), 'a.txt')
end

T['reviewed']['v in the diff pane is visual mode and marks nothing'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('v')

    eq(child.api.nvim_get_mode().mode, 'v')
    child.type_keys('<Esc>')
    eq(child.lua_get(R .. ".reviewed['a.txt']"), 'unreviewed')
end

T['reviewed']['a partly staged file shows one mark'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')

    eq(row_of('a.txt'), 'M a.txt')
    eq(row_of('b.txt'), 'M b.txt ✓')
    eq(row_of('b.txt'), 'M b.txt ✓')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
end

T['reviewed']['staging keeps a file reviewed'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.changes.staged == 2')
    wait_state('a.txt', 'reviewed')

    eq(row_of('b.txt'), 'M b.txt')
    eq(row_of('a.txt'), 'M a.txt ✓')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
end

T['reviewed']['an edit from outside turns reviewed into changed'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    edit_b_from_outside()
    wait_state('b.txt', 'changed')

    eq(row_of('b.txt'), 'M b.txt ↻')
    eq(progress(), 'reviewed ▱▱▱▱▱▱▱▱▱ 0 of 4 · ↻ 1')

    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    wait_diff_header('↻ changed since reviewed')

    child.type_keys('r')
    wait_state('b.txt', 'reviewed')
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    wait_diff_header('✓ reviewed')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
end

T['reviewed']['an edit of the shown file updates the diff header'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    wait_diff_header('✓ reviewed')

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    a[30] = 'edited from outside'
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

    wait_state('a.txt', 'changed')
    wait_diff_header('↻ changed since reviewed')
end

T['reviewed']['a deleted file can be reviewed and comes back changed'] = function()
    vim.fn.delete(vim.fs.joinpath(repo, 'a.txt'))
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(row_of('a.txt'), 'D a.txt')
    eq(row_of('b.txt'), 'M b.txt')

    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    eq(
        child.lua_get(
            [[require('iter.store').load(vim.fn.getcwd()).reviewed['a.txt'].hash]]
        ),
        'deleted'
    )

    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'back' })
    wait_state('a.txt', 'changed')
end

T['reviewed']['each file of an untracked directory takes its own mark'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    H.select(child, 'unstaged', 'd/x.txt')
    H.wait_diff(child, 'unstaged d/x.txt')
    child.type_keys('r')
    wait_state('d/x.txt', 'reviewed')

    eq(row_of('c.txt'), '? c.txt')
    eq(row_of('d/x.txt'), '? x.txt ✓')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
end

T['reviewed']['reviewed marks survive a restart'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    child.stop()
    helpers.start_child(child, repo)
    pin_drawer()
    stub_ui()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(row_of('a.txt'), 'M a.txt ✓')
    eq(row_of('b.txt'), 'M b.txt')
    eq(
        progress(),
        'reviewed ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 4'
    )
end

T['reviewed']['the status drawer shows no reviewed marks and maps no reviewed key'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    child.type_keys('q')
    child.cmd('Iter')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.view:is_shown()]]
    )

    local state = child.lua_get([[(function()
        local d = require('iter').drawer
        local title = ''
        for _, chunk in ipairs(d.float.opts.title) do
            title = title .. chunk[1]
        end
        local reviewed_map = ''
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(d.buf, 'n')) do
            if (map.desc or ''):find('reviewed', 1, true) then
                reviewed_map = map.desc
            end
        end
        local text = table.concat(vim.api.nvim_buf_get_lines(d.buf, 0, -1, false), '\n')
        local ns = vim.api.nvim_get_namespaces()['iter.diff']
        local header = ''
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(d.view.buf, ns, 0, -1, { details = true })) do
            if mark[4].virt_text_pos == 'right_align' then
                header = mark[4].virt_text[1][1]
            end
        end
        return {
            title = title,
            reviewed_map = reviewed_map,
            marked = text:find('✓', 1, true) ~= nil or text:find('○', 1, true) ~= nil or text:find('↻', 1, true) ~= nil,
            header = header,
        }
    end)()]])

    eq((state.title:gsub('%s+', ' ')), 'HEAD main 4 changes ')
    eq(state.reviewed_map, '')
    eq(state.marked, false)
    eq(state.header, '+2 −2 ')
end

T['reviewed']['polls without a change hash nothing'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
    child.lua([[
        _G.hashes, _G.polls = 0, 0
        local git = require('iter.git')
        local run = git.run
        git.run = function(args, opts)
            if args[1] == 'hash-object' then
                _G.hashes = _G.hashes + 1
            end
            return run(args, opts)
        end
        local Review = require('iter.review')
        local refresh = Review.refresh
        Review.refresh = function(self, reason)
            if reason == 'poll' then
                _G.polls = _G.polls + 1
            end
            return refresh(self, reason)
        end
    ]])
    helpers.wait_until(child, '_G.polls >= 3')

    eq(child.lua_get('_G.hashes'), 0)
end

--- Top line of the diff pane and the window the cursor is in.
---@return { top: integer, focus: string }
local function placement()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local win = vim.api.nvim_get_current_win()
        return {
            top = vim.fn.getwininfo(r.diff_win)[1].topline,
            focus = win == r.diff_win and 'diff'
                or win == r.panel.win and 'tree'
                or 'other',
        }
    end)()]])
end

T['reviewed']['r in the diff marks the file and moves to the first change of the next'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')

    child.type_keys('r')
    H.wait_diff(child, 'unstaged b.txt')

    eq(H.selected(child), 'b.txt')
    eq(cursor_row(), 'add top1')
    eq(placement(), { top = 1, focus = 'diff' })
    eq(row_of('a.txt'), 'M a.txt ✓')
end

T['reviewed']['r in the tree moves the selection on and keeps the focus'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('r')
    H.wait_diff(child, 'unstaged b.txt')

    eq(H.selected(child), 'b.txt')
    eq(cursor_row(), 'add top1')
    eq(placement(), { top = 1, focus = 'tree' })
end

T['reviewed']['r skips files already reviewed'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(R .. ":mark_reviewed('b.txt')")

    child.type_keys('r')
    H.wait_diff(child, 'unstaged c.txt')

    eq(H.selected(child), 'c.txt')
    eq(cursor_row(), 'add c')
end

T['reviewed']['r on a reviewed file keeps the mark and moves on'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(R .. ":mark_reviewed('a.txt')")

    child.type_keys('r')
    H.wait_diff(child, 'unstaged b.txt')

    eq(H.selected(child), 'b.txt')
    eq(row_of('a.txt'), 'M a.txt ✓')
end

T['reviewed']['R on a file without a mark changes nothing'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.type_keys('R')

    eq(H.selected(child), 'a.txt')
    eq(row_of('a.txt'), 'M a.txt')
end

T['reviewed']['r on the last file marks it and stays'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    H.select(child, 'unstaged', 'c.txt')
    H.wait_diff(child, 'unstaged c.txt')

    child.type_keys('r')
    wait_state('c.txt', 'reviewed')

    eq(H.selected(child), 'c.txt')
    eq(row_of('c.txt'), '? c.txt ✓')
end

T['reviewed']['in all files, r collapses the file and puts the next header on top'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(R .. ':toggle_mode()')
    helpers.wait_until(child, R .. '.view.document.sections[2] ~= nil')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')

    child.type_keys('r')
    helpers.wait_until(
        child,
        R .. '.view.document.sections[2].collapsed == true'
    )

    -- d/x.txt, a.txt, then b.txt's Unstaged section.
    local header = child.lua_get(R .. '.view.document.sections[3].first')
    eq(H.selected(child), 'b.txt')
    eq(cursor_row(), 'add top1')
    eq(placement(), { top = header, focus = 'diff' })
    helpers.expect_screenshot(child, 'review-reviewed-advance')
end

T['reviewed']['screenshot of reviewed, changed and unreviewed rows'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    view_file('a.txt')
    wait_state('a.txt', 'reviewed')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')
    edit_b_from_outside()
    wait_state('b.txt', 'changed')
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    wait_diff_header('✓ reviewed')

    helpers.expect_screenshot(child, 'review-reviewed')
end

T['files'] = new_set()

--- The windows of the review's tab, each as its kind with its screen
--- position and size.
---@return table<string, { row: integer, col: integer, width: integer, height: integer }>
local function tab_layout()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local open = require('iter.ui.sidebar').of(r.tab)
        local out = {}
        for name, win in pairs({ tree = r.panel.win, diff = r.diff_win, notes = open and open.win }) do
            local pos = vim.fn.win_screenpos(win)
            out[name] = {
                row = pos[1],
                col = pos[2],
                width = vim.api.nvim_win_get_width(win),
                height = vim.api.nvim_win_get_height(win),
            }
        end
        return out
    end)()]])
end

T['files']['in a narrow tab the annotations sit below the tree'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    local layout = tab_layout()

    eq(layout.tree.col, 1)
    eq(layout.notes.col, 1)
    eq(layout.notes.width, 34)
    eq(layout.notes.row > layout.tree.row + layout.tree.height, true)
    eq(layout.diff.col, 36)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)

    -- <C-w>= keeps the annotations' height and the tree's width.
    child.cmd('wincmd =')
    eq(tab_layout(), layout)

    helpers.expect_screenshot(child, 'review-narrow')
end

T['files']['in a wide tab the annotations sit right of the diff'] = function()
    child.o.columns = 200
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    local layout = tab_layout()

    eq(layout.tree.col, 1)
    eq(layout.notes.col + layout.notes.width - 1, 200)
    eq(layout.notes.width, 40)
    eq(layout.diff.col, 36)

    helpers.expect_screenshot(child, 'review-wide')
end

T['files']['crossing the breakpoint moves the annotations and keeps the cursor'] = function()
    child.o.columns = 200
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua([[
        local store = require('iter.store')
        store.put_annotation(vim.fn.getcwd(), { scope = 'file', body = 'one', anchor = { path = 'a.txt', side = 'new' } })
        store.put_annotation(vim.fn.getcwd(), { scope = 'file', body = 'two', anchor = { path = 'b.txt', side = 'new' } })
    ]])
    child.lua(R .. ':refresh_annotations()')
    child.lua([[require('iter.ui.sidebar').refresh_all()]])
    child.lua([[
        local open = require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())
        for lnum, row in pairs(open.rows) do
            if row.item and row.item.annotation.body == 'two' then
                vim.api.nvim_win_set_cursor(open.win, { lnum, 0 })
            end
        end
    ]])

    local selected = [[(function()
        local open = require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())
        local row = open and open:row()
        return row and row.item and row.item.annotation.body or vim.NIL
    end)()]]

    child.o.columns = 80
    helpers.wait_until(
        child,
        [[(function()
        local open = require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())
        return open ~= nil and open.placement ~= nil
    end)()]]
    )
    eq(child.lua_get(selected), 'two')
    eq(child.lua_get(R .. '.annotations_closed'), false)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)

    child.o.columns = 200
    helpers.wait_until(
        child,
        [[(function()
        local open = require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())
        return open ~= nil and open.placement == nil
    end)()]]
    )
    eq(child.lua_get(selected), 'two')
end

T['files']['closed annotations stay closed until :Iter annotate'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    local open =
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())]]

    child.lua(open .. ':focus()')
    child.cmd('close')
    helpers.wait_until(child, R .. '.annotations_closed')

    child.o.columns = 200
    child.lua('vim.wait(100)')
    eq(child.lua_get(open), vim.NIL)

    child.cmd('Iter annotate')
    helpers.wait_until(child, open .. ' ~= nil')
    eq(child.lua_get(open .. '.win == vim.api.nvim_get_current_win()'), true)
    eq(child.lua_get(R .. '.annotations_closed'), false)
end

T['files']['<C-j> in the annotations focuses the tree'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
    )

    child.type_keys('<C-j>')

    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
end

T['files']['closing the tree window closes the review'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua('vim.api.nvim_win_close(' .. H.LIST_WIN .. ', true)')
    helpers.wait_until(child, R .. ' == nil')

    eq(#child.api.nvim_list_tabpages(), 1)
end

T['files']['u on a partly staged file unstages it and keeps its row'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')

    child.type_keys('u')
    helpers.wait_until(child, '#' .. R .. '.changes.staged == 0')

    eq(H.selected(child), 'b.txt')
    eq(row_of('b.txt'), 'M b.txt')
    eq(child.lua_get('_G.notes'), {})

    -- s stages the whole file, s again unstages it.
    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.changes.staged == 1')
    eq(tree_rows()[4], '   ● M b.txt')
    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.changes.staged == 0')
end

T['files']['u without commits makes the file untracked again'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.git(repo, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'm.txt'), { 'm' })
    helpers.git(repo, { 'add', 'm.txt' })
    helpers.start_child(child, repo)
    pin_drawer()
    stub_ui()
    H.open(child)
    H.wait_diff(child, 'staged m.txt')

    child.type_keys('u')
    helpers.wait_until(child, '#' .. R .. '.changes.staged == 0')

    eq(H.selected(child), 'm.txt')
    eq(helpers.git(repo, { 'status', '--porcelain=v1', '-z' }), '?? m.txt\0')
    eq(vim.fn.readfile(vim.fs.joinpath(repo, 'm.txt')), { 'm' })
    eq(child.lua_get('_G.notes'), {})
end

T['flow'] = new_set()

-- Everything the whole flow could leave behind. The augroups of setup()
-- and of the highlight groups live for the session.
local FLOW_STATE = [[(function()
    local handles = {}
    vim.uv.walk(function(handle)
        if not handle:is_closing() then
            local kind = handle:get_type()
            handles[kind] = (handles[kind] or 0) + 1
        end
    end)
    local groups = {}
    for _, name in ipairs(vim.split(vim.fn.execute('augroup'), '%s+')) do
        if
            vim.startswith(name, 'iter.')
            and name ~= 'iter.buffer_annotations'
            and name ~= 'iter.highlight'
        then
            table.insert(groups, name)
        end
    end
    local iter_bufs = vim.tbl_filter(function(buf)
        return vim.api.nvim_buf_get_name(buf):match('^iter://') ~= nil
    end, vim.api.nvim_list_bufs())
    local ctrl_t = vim.fn.maparg('<C-t>', 'n', false, true)
    return {
        handles = handles,
        groups = groups,
        iter_bufs = #iter_bufs,
        bufs = #vim.api.nvim_list_bufs(),
        wins = #vim.api.nvim_list_wins(),
        tabs = #vim.api.nvim_list_tabpages(),
        ctrl_t = ctrl_t.desc or ctrl_t.rhs or '',
    }
end)()]]

T['flow']['status, review, annotation, annotations window, yank and close leave nothing behind'] = function()
    child.lua([[
        require('iter').setup({ status = { style = 'drawer' } })
        vim.keymap.set('n', '<C-t>', '<Nop>', { desc = 'user ctrl-t' })
    ]])
    child.cmd('edit a.txt')
    child.lua('vim.wait(200)')
    local before = child.lua_get(FLOW_STATE)

    child.cmd('Iter')
    helpers.wait_until(child, [[require('iter').drawer ~= nil]])
    child.type_keys('r')
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.panel ~= nil')
    H.wait_diff(child, 'unstaged a.txt')
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)

    -- Annotate, hide the draft, show it again and save.
    child.type_keys('<CR>')
    cursor_on('a3 changed')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('flow note', '<C-t>')
    eq(child.lua_get([[require('iter.annotations.editor').is_shown()]]), false)
    child.type_keys('<C-t>')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('<C-s>')
    helpers.wait_until(
        child,
        [[not require('iter.annotations.editor').is_shown()]]
    )
    eq(
        child.lua_get(
            [[vim.tbl_map(function(c) return c.body end, require('iter.store').load(vim.fn.getcwd()).annotations)]]
        ),
        { 'flow note' }
    )

    -- Jump back to it through the annotations window, from another file.
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys(']f')
    H.wait_diff(child, 'unstaged b.txt')
    child.lua([[require('iter').annotations()]])
    child.lua([[
        local open = require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage())
        for lnum, row in pairs(open.rows) do
            if row.item then
                vim.api.nvim_win_set_cursor(open.win, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('<CR>')
    H.wait_diff(child, 'unstaged a.txt')
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a3 changed')

    -- Yank and clear.
    child.type_keys('y')
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 0]]
    )
    eq(child.fn.getreg('"'):find('flow note', 1, true) ~= nil, true)

    child.type_keys('q')
    child.lua('vim.wait(200)')

    eq(child.lua_get(R), vim.NIL)
    eq(child.lua_get(FLOW_STATE), before)
    eq(
        child.lua_get([[vim.fn.maparg('<C-t>', 'n', false, true).desc]]),
        'user ctrl-t'
    )
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'] = new_set()

--- `:edit` the URI `name`, escaped as a command line needs it.
---@param name string
local function edit_uri(name)
    child.cmd('edit ' .. vim.fn.fnameescape(name))
end

--- Wait until the review is open and focused in its tab.
local function wait_routed()
    helpers.wait_until(
        child,
        R
            .. [[ ~= nil and ]]
            .. R
            .. [[.panel ~= nil and vim.api.nvim_get_current_tabpage() == ]]
            .. R
            .. [[.tab]]
    )
end

--- Names of the buffers whose name starts with `iter://`, sorted.
---@return string[]
local function iter_names()
    return child.lua_get([[(function()
        local names = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(buf)
            if vim.startswith(name, 'iter://') then
                table.insert(names, name)
            end
        end
        table.sort(names)
        return names
    end)()]])
end

T['uri'][':edit iter://review opens the tab and wipes its own buffer'] = function()
    child.cmd('edit a.txt')
    local origin = child.api.nvim_get_current_tabpage()

    edit_uri('iter://review')
    wait_routed()
    H.wait_diff(child, 'unstaged a.txt')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(H.LIST_WIN .. ' == vim.api.nvim_get_current_win()'), true)
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(]]
                .. origin
                .. [[))))]]
        ),
        'a.txt'
    )
    eq(iter_names(), {
        'iter://annotate/2',
        'iter://review',
        'iter://review/a.txt',
    })
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'][':edit iter://review/<path>#L<n> puts the cursor on that line'] = function()
    edit_uri('iter://review/a.txt#L3')
    wait_routed()
    H.wait_diff(child, 'unstaged a.txt')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a3 changed')
    eq(child.lua_get(R .. '.view:row().new'), 3)

    -- Unstaged before Staged: b.txt's worktree line 5 is `staged`.
    edit_uri('iter://review/b.txt#L5')
    H.wait_diff(child, 'unstaged b.txt')
    eq(H.selected(child), 'b.txt')
    eq(cursor_row(), 'context staged')
    eq(child.lua_get(R .. '.view:row().new'), 5)
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get('_G.notes'), {})
end

T['uri']['a line in a collapsed file shows the file whole'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(R .. ":mark_reviewed('a.txt')")
    child.lua(R .. ':toggle_mode()')
    -- d/x.txt, then a.txt.
    helpers.wait_until(
        child,
        R .. '.view.document.sections[2].collapsed == true'
    )

    edit_uri('iter://review/a.txt#L25')
    helpers.wait_until(child, R .. '.view:row().new == 25')
    eq(cursor_row(), 'add a25 changed')
    eq(child.lua_get(R .. '.view.document.sections[2].collapsed'), vim.NIL)
end

T['uri'][':edit from another tab switches to the review'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.cmd('tabnew')
    child.cmd('edit c.txt')

    local other = child.api.nvim_get_current_tabpage()
    local bufs = #child.api.nvim_list_bufs()

    -- The tree's buffer has this name: the window gets c.txt back.
    edit_uri('iter://review')
    wait_routed()
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(]]
                .. other
                .. [[))))]]
        ),
        'c.txt'
    )

    -- So does the diff pane's.
    child.api.nvim_set_current_tabpage(other)
    edit_uri('iter://review/a.txt#L25')
    wait_routed()
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a25 changed')

    child.api.nvim_set_current_tabpage(other)
    edit_uri('iter://review/a.txt')
    wait_routed()
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(]]
                .. other
                .. [[))))]]
        ),
        'c.txt'
    )

    eq(#child.api.nvim_list_tabpages(), 3)
    eq(#child.api.nvim_list_bufs(), bufs)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'][':edit inside the review tab keeps its panes'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    -- From the diff pane.
    cursor_on('a3 changed')
    edit_uri('iter://review/b.txt#L1')
    H.wait_diff(child, 'unstaged b.txt')
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add top1')

    -- From the tree.
    H.focus_list(child)
    edit_uri('iter://review/a.txt#L25')
    H.wait_diff(child, 'unstaged a.txt')
    eq(cursor_row(), 'add a25 changed')
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. H.LIST_WIN
                .. [[) == ]]
                .. R
                .. [[.tree.buf]]
        ),
        true
    )
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.diff_win) == ]]
                .. R
                .. [[.view.buf]]
        ),
        true
    )
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'][':edit in an iter window draws it again'] = function()
    child.o.columns = 120
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    local drawer = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. R .. '.tree.buf, 0, -1, false)'
    )
    local diff = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. R .. '.view.buf, 0, -1, false)'
    )

    child.cmd('edit')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.tree.buf, 0, -1, false)'
        ),
        drawer
    )
    eq(H.selected(child), 'a.txt')

    cursor_on('a3 changed')
    child.cmd('edit')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.view.buf, 0, -1, false)'
        ),
        diff
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))

    local side =
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()).buf]]
    local annotations = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. side .. ', 0, -1, false)'
    )

    child.lua(
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
    )
    child.cmd('edit')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. side .. ', 0, -1, false)'
        ),
        annotations
    )

    -- The draft keeps its unsaved text.
    cursor_on('a3 changed')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('kept', '<Esc>')
    child.cmd('edit!')
    eq(child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)'), { 'kept' })
    eq(child.lua_get('vim.bo.modified'), true)

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.v.errmsg, '')
end

T['uri'][':edit iter://status opens the status drawer'] = function()
    child.cmd('edit a.txt')
    edit_uri('iter://status')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.win ~= nil]]
    )

    eq(
        child.lua_get([[vim.api.nvim_buf_get_name(require('iter').drawer.buf)]]),
        'iter://status'
    )
    helpers.wait_until(child, [[require('iter').drawer.view.files[1] ~= nil]])
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_name(require('iter').drawer.view.buf)]]
        ),
        'iter://status/a.txt'
    )
    eq(#child.api.nvim_list_tabpages(), 1)
    eq(
        child.lua_get([[vim.fs.basename(vim.api.nvim_buf_get_name(
            vim.api.nvim_win_get_buf(require('iter').drawer.pane)))]]),
        'a.txt'
    )
    eq(child.v.errmsg, '')
end

T['uri'][':edit from the status drawer windows'] = function()
    local function open_status()
        child.cmd('Iter')
        helpers.wait_until(
            child,
            [[require('iter').drawer ~= nil and require('iter').drawer.view.files[1] ~= nil]]
        )
        child.lua(
            [[vim.api.nvim_set_current_win(require('iter').drawer.view.win)]]
        )
    end

    local open =
        [[require('iter').drawer ~= nil and require('iter').drawer:is_open()]]

    child.cmd('edit a.txt')

    -- The drawer's buffer and a new one each take the diff pane, which
    -- closes the drawer; the address opens it again.
    open_status()
    edit_uri('iter://status')
    helpers.wait_until(child, open)
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(require('iter').drawer.pane)))]]
        ),
        'a.txt'
    )

    child.lua([[require('iter').drawer:close()]])
    open_status()
    edit_uri('iter://status/b.txt')
    helpers.wait_until(child, open)
    helpers.wait_until(
        child,
        [[require('iter').drawer.view.files[1] ~= nil and require('iter').drawer.view.files[1].path == 'b.txt']]
    )
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(require('iter').drawer.view.prev_buf))]]
        ),
        'a.txt'
    )

    -- From the drawer's float to the review.
    child.lua([[require('iter').drawer:focus()]])
    edit_uri('iter://review/a.txt#L3')
    wait_routed()
    helpers.wait_until(child, R .. '.view:row().new == 3')
    eq(cursor_row(), 'add a3 changed')
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.v.errmsg, '')
end

T['uri'][':edit from the annotations window routes'] = function()
    local focus_notes =
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.lua(focus_notes)

    child.type_keys(':e iter://review/a.txt\\#L3<CR>')
    helpers.wait_until(child, R .. '.view:row().new == 3')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a3 changed')
    eq(child.v.errmsg, '')

    child.lua(focus_notes)
    child.type_keys(':e iter://annotation<CR>')
    helpers.wait_until(child, '#_G.notes == 1')

    eq(child.lua_get('_G.notes[1][1]'), '[iter] No annotation draft to show')
    eq(child.v.errmsg, '')
end

T['uri']['#all and #annotations pick the view, all/ and annotations/ are files'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'all'), { 'x' })
    helpers.write_file(vim.fs.joinpath(repo, 'annotations'), { 'y' })
    child.o.columns = 120

    edit_uri('iter://review/all')
    wait_routed()
    H.wait_diff(child, 'unstaged all')
    edit_uri('iter://review/annotations')
    H.wait_diff(child, 'unstaged annotations')
    eq(child.lua_get(R .. '.preview.all_files'), false)

    edit_uri('iter://review#all')
    helpers.wait_until(child, R .. '.preview.all_files')
    edit_uri('iter://review#annotations')
    helpers.wait_until(
        child,
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()).win == vim.api.nvim_get_current_win()]]
    )
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri']['open_uri() routes without escaping'] = function()
    child.cmd('edit a.txt')
    child.lua([[require('iter').open_uri('iter://review/a.txt#L25')]])
    wait_routed()
    helpers.wait_until(child, R .. '.view:row().new == 25')
    eq(cursor_row(), 'add a25 changed')
    eq(child.lua_get('_G.notes'), {})
end

T['uri'][':edit from the split left pane'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.view.old ~= nil')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.view.old.win)')

    edit_uri('iter://review/b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    child.lua('vim.wait(100)')

    eq(
        child.fn.execute('messages'):find('Invalid buffer', 1, true) ~= nil,
        false
    )
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

--- Names of the listed buffers.
---@return string[]
local function listed()
    return child.lua_get([[vim.tbl_map(function(info)
        return info.name
    end, vim.fn.getbufinfo({ buflisted = 1 }))]])
end

T['uri'][':edit from the status drawer float'] = function()
    child.cmd('edit a.txt')
    child.cmd('Iter')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.view.files[1] ~= nil]]
    )

    local open =
        [[require('iter').drawer ~= nil and require('iter').drawer:is_open()]]

    edit_uri('iter://status/b.txt')
    helpers.wait_until(
        child,
        open
            .. [[ and require('iter').drawer.view.files[1] ~= nil and require('iter').drawer.view.files[1].path == 'b.txt']]
    )

    edit_uri('iter://status/nope.txt')
    helpers.wait_until(child, [[#_G.notes == 1]])
    helpers.wait_until(child, open)
    eq(child.lua_get('_G.notes'), {
        { '[iter] nope.txt is not in the changes', vim.log.levels.WARN },
    })

    edit_uri('iter://bogus')
    helpers.wait_until(child, [[#_G.notes == 2]])
    child.lua('vim.wait(100)')

    eq(
        child.fn.execute('messages'):find('Invalid buffer', 1, true) ~= nil,
        false
    )
    eq(child.lua_get(open), false)
    eq(vim.tbl_map(vim.fs.basename, listed()), { 'a.txt' })
    eq(child.v.errmsg, '')
end

T['uri']['iter buffers stay unlisted and out of :bnext'] = function()
    child.cmd('edit c.txt')
    child.cmd('edit a.txt')
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    child.cmd('edit')
    cursor_on('a3 changed')
    child.cmd('edit')
    child.cmd('tabedit iter://review')
    wait_routed()

    eq(vim.tbl_map(vim.fs.basename, listed()), { 'c.txt', 'a.txt' })

    child.cmd('tabfirst')
    for _ = 1, 4 do
        child.cmd('bnext')
        child.lua('vim.wait(50)')
        eq(
            child.lua_get(
                [[vim.startswith(vim.api.nvim_buf_get_name(0), 'iter://')]]
            ),
            false
        )
    end
    eq(child.v.errmsg, '')
end

T['uri']['stale buffers with iter names give way'] = function()
    -- E37 leaves an unloaded buffer of the name.
    child.o.hidden = false
    child.cmd('edit a.txt')
    child.lua([[vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'mod' })]])
    child.lua([[pcall(vim.cmd.edit, 'iter://review')]])
    child.cmd('edit!')
    H.open(child)
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.tree.buf)'),
        'iter://review'
    )

    -- A restored session leaves no buffer of iter's.
    cursor_on('a3 changed')
    local session = vim.fn.tempname()
    child.cmd('mksession! ' .. vim.fn.fnameescape(session))
    eq(
        table
            .concat(vim.fn.readfile(session), '\n')
            :find('iter://review/a.txt', 1, true) ~= nil,
        true
    )
    child.stop()
    helpers.start_child(child, repo)
    pin_drawer()
    stub_ui()
    child.cmd('source ' .. vim.fn.fnameescape(session))
    child.lua('vim.wait(100)')

    eq(
        vim.tbl_filter(function(name)
            return vim.startswith(name, 'iter://')
        end, listed()),
        {}
    )
    eq(
        child.lua_get([[#vim.tbl_filter(function(b)
            return vim.startswith(vim.api.nvim_buf_get_name(b), 'iter://')
        end, vim.api.nvim_list_bufs())]]),
        0
    )
    vim.fn.delete(session)
end

T['uri']['an open review of another repository stays as it is'] = function()
    local other = helpers.create_repo({ ['x.txt'] = { 'x' } })

    H.open(child)

    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    child.cmd('tabfirst')
    child.cmd('cd ' .. vim.fn.fnameescape(other))
    local tab = child.api.nvim_get_current_tabpage()

    edit_uri('iter://review/a.txt#L3')
    helpers.wait_until(child, '#_G.notes == 1')

    eq(child.api.nvim_get_current_tabpage(), tab)
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] The open review is of ' .. repo .. ', not of ' .. other,
            vim.log.levels.WARN,
        },
    })
    helpers.cleanup(other)
end

T['uri']['a path outside the changes opens the review and warns once'] = function()
    edit_uri('iter://review/a1.txt#L2')
    wait_routed()

    eq(child.lua_get('_G.notes'), {
        { '[iter] a1.txt is not in the changes', vim.log.levels.WARN },
    })
end

T['uri']['buffer names are stable and carry no numbers'] = function()
    child.o.columns = 120
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(iter_names(), {
        'iter://annotate/2',
        'iter://review',
        'iter://review/a.txt',
    })

    local bufs = #child.api.nvim_list_bufs()

    H.select(child, 'unstaged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    H.select(child, 'unstaged', 'c.txt')
    H.wait_diff(child, 'unstaged c.txt')
    eq(iter_names(), {
        'iter://annotate/2',
        'iter://review',
        'iter://review/c.txt',
    })

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('=')
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.view.buf)'),
        'iter://review#all'
    )
    child.type_keys('|')
    helpers.wait_until(child, R .. '.view.old ~= nil')
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.view.old.buf)'),
        'iter://review#all#old'
    )
    child.type_keys('-')
    eq(#child.api.nvim_list_bufs(), bufs)

    cursor_on('a3 changed')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_name(require('iter.annotations.editor').win() and vim.api.nvim_win_get_buf(require('iter.annotations.editor').win()))]]
        ),
        'iter://annotation'
    )
    eq(child.v.errmsg, '')
end

T['uri']['uri() names the diff cursor and opens there again'] = function()
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')
    eq(child.lua_get([[require('iter').uri()]]), vim.NIL)

    cursor_on('a3 changed')
    eq(child.lua_get([[require('iter').uri()]]), 'iter://review/a.txt#L3')

    -- A staged line carries its worktree line.
    H.select(child, 'staged', 'b.txt')
    H.wait_diff(child, 'unstaged b.txt')
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        local section = r.view.document.sections[2]
        for lnum = section.first, #r.view.rows do
            if r.view.rows[lnum].text == 'b2' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])

    local uri = child.lua_get([[require('iter').uri()]])

    eq(uri, 'iter://review/b.txt#L4')

    H.focus_list(child)
    edit_uri(uri)
    H.wait_diff(child, 'unstaged b.txt')
    eq(cursor_row(), 'context b2')

    -- A line in hidden context shows it.
    edit_uri('iter://review/b.txt#L9')
    helpers.wait_until(child, R .. '.view:row().new == 9')
    eq(cursor_row(), 'context b6')
end

T['uri']['the tab label reads iter review'] = function()
    child.o.columns = 120
    child.o.showtabline = 2
    child.o.tabline = [[%!v:lua.require'iter'.tabline()]]
    H.open(child)
    H.select(child, 'unstaged', 'a.txt')
    H.wait_diff(child, 'unstaged a.txt')

    eq(child.lua_get('vim.t.iter_label'), 'iter review')

    -- Three normal windows: the tree, the diff and the annotations.
    eq(screen_row(1):find(' 3 iter review ', 1, true) ~= nil, true)
    child.type_keys('<CR>')
    eq(screen_row(1):find(' 3 iter review ', 1, true) ~= nil, true)
    child.lua(
        [[require('iter.ui.sidebar').of(vim.api.nvim_get_current_tabpage()):focus()]]
    )
    eq(screen_row(1):find(' 3 iter review ', 1, true) ~= nil, true)

    helpers.expect_screenshot(child, 'review-tabline')

    -- The left pane of the split layout, where uri() names the new line a
    -- deleted line lands on.
    cursor_on('a3 changed')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.view.old ~= nil')
    child.lua([[
        local old = require('iter').current_review.view.old
        vim.api.nvim_set_current_win(old.win)
        vim.fn.search('^a3$')
    ]])
    eq(screen_row(1):find(' 4 iter review ', 1, true) ~= nil, true)
    eq(child.lua_get([[require('iter').uri()]]), 'iter://review/a.txt#L3')
end

return T
