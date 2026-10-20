local helpers = dofile('tests/helpers.lua')

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

local R = [[require('iter').current_review]]

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

local function stub_ui()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
    ]])
end

---@param options string Lua table passed to setup()
local function setup(options)
    child.lua('require("iter").setup(' .. options .. ')')
end

--- Wait until the review's diff pane shows `expected` (`side path`).
---@param expected string
local function wait_diff(expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                local f = r and r.drawer.view.files[1]
                return f ~= nil and f.side .. ' ' .. f.path == %q
                    and r.drawer.view:is_shown()
            end)()]],
            R,
            expected
        )
    )
end

--- Run `:Iter review` (or `command`) and wait for the review drawer.
---@param command? string
local function open_review(command)
    child.cmd(command or 'Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.win ~= nil]]
    )
end

---@return string?
local function selected()
    return child.lua_get([[(function()
        local item = ]] .. R .. [[.drawer:selected()
        return item and (item.side .. ' ' .. item.path) or vim.NIL
    end)()]])
end

--- Select the `side` item with `path` in the review drawer.
---@param side string
---@param path string
local function select_item(side, path)
    child.lua(
        [[
        local side, path = ...
        local d = require('iter').current_review.drawer
        for lnum, row in ipairs(d.rows) do
            if row[side] ~= nil and row[side].path == path then
                vim.api.nvim_win_set_cursor(d.win, { lnum, 0 })
                d:select(lnum, side)
                return
            end
        end
        error('no row for ' .. side .. ' ' .. path)
    ]],
        { side, path }
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
        for lnum, row in ipairs(r.drawer.view.rows) do
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

---@return string kind and text of the diff pane's cursor row
local function cursor_row()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
        local row = r.drawer.view.rows[lnum]
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
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['open'] = new_set()

T['open'][':Iter review opens the tab with the diff above the drawer'] = function()
    child.cmd('edit a.txt')
    open_review()
    wait_diff('unstaged a.txt')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(
        child.lua_get(R .. '.drawer.win == vim.api.nvim_get_current_win()'),
        true
    )
    eq(selected(), 'unstaged a.txt')

    local config =
        child.lua_get('vim.api.nvim_win_get_config(' .. R .. '.drawer.win)')
    eq(config.relative, 'win')
    eq(config.win, child.lua_get(R .. '.spacer_win'))
    eq(config.anchor, 'SW')
    eq(config.zindex, 40)

    -- The float covers the whole spacer split: its rows plus the two chrome
    -- rows are the spacer's rows.
    eq(
        config.height + 2,
        child.lua_get('vim.api.nvim_win_get_height(' .. R .. '.spacer_win)')
    )
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
    open_review()
    wait_diff('unstaged a.txt')

    -- The default tabline names the current window's buffer, shortened.
    eq(screen_row(1):find(' i//review ', 1, true) ~= nil, true)
    child.type_keys('<CR>')
    eq(screen_row(1):find(' i//r/a.txt ', 1, true) ~= nil, true)

    local spacer = child.lua_get(R .. '.spacer_win')
    local status_row = child.fn.win_screenpos(spacer)[1]
        + child.api.nvim_win_get_height(spacer)
    eq(vim.trim(screen_row(status_row)), '')

    local diff = child.lua_get(R .. '.diff_win')
    local diff_status = child.fn.win_screenpos(diff)[1]
        + child.api.nvim_win_get_height(diff)
    eq(vim.startswith(screen_row(diff_status), 'iter://review/a.txt'), true)
end

T['open']['opening twice gives one tab'] = function()
    open_review()
    open_review()

    eq(#child.api.nvim_list_tabpages(), 2)

    child.cmd('tabfirst')
    open_review()

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(
        child.lua_get(R .. '.drawer.win == vim.api.nvim_get_current_win()'),
        true
    )
end

T['open']['the tab opts out of the radar HUD'] = function()
    open_review()

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

    eq(selected(), 'staged b.txt')
end

T['open'][':Iter status inside the review focuses its drawer'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.cmd('Iter status')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(
        child.lua_get(R .. '.drawer.win == vim.api.nvim_get_current_win()'),
        true
    )
end

T['open'][':Iter completes review'] = function()
    eq(child.fn.getcompletion('Iter ', 'cmdline'), { 'review', 'status' })
    eq(child.fn.getcompletion('Iter re', 'cmdline'), { 'review' })
end

T['open']['outside a git repository warns and opens nothing'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.start_child(child, repo)
    stub_ui()

    child.cmd('Iter review')

    eq(child.lua_get([[_G.notes]]), {
        { '[iter] Not inside a git repository', vim.log.levels.WARN },
    })
    eq(child.lua_get(R), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 1)
end

T['drawer'] = new_set()

T['drawer']['j moves and the diff follows; r is the mark'] = function()
    open_review()
    wait_diff('unstaged a.txt')

    child.type_keys('j')
    wait_diff('unstaged b.txt')

    eq(selected(), 'unstaged b.txt')
    eq(
        child.lua_get([[vim.fn.maparg('r', 'n', false, true).desc]]),
        'Toggle reviewed'
    )
    eq(child.lua_get([[vim.fn.maparg('q', 'n', false, true).desc]]), 'Close')
end

T['drawer']['<CR> moves into the diff pane'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('j', '<CR>')

    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.lua_get(R .. '.drawer.view.files[1].path'), 'b.txt')
end

T['drawer']['s stages one file of an untracked directory'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    select_item('unstaged', 'd/x.txt')
    child.type_keys('s')

    helpers.wait_until(child, [[(function()
            for _, item in ipairs(]] .. R .. [[.drawer.changes.staged) do
                if item.path == 'd/x.txt' then
                    return true
                end
            end
        end)()]])
end

T['drawer']['I appends an untracked file to .gitignore'] = function()
    child.lua([[
        _G.confirms = {}
        vim.fn.confirm = function(msg)
            table.insert(_G.confirms, msg)
            return 1
        end
    ]])
    open_review()
    wait_diff('unstaged a.txt')
    select_item('unstaged', 'c.txt')
    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), { 'Append c.txt to .gitignore?' })
    eq(vim.fn.readfile(vim.fs.joinpath(repo, '.gitignore')), { '/c.txt' })
    eq(
        child.lua_get(
            'vim.tbl_map(function(item) return item.path end, '
                .. R
                .. '.drawer.changes.unstaged)'
        ),
        { '.gitignore', 'a.txt', 'b.txt', 'd/x.txt' }
    )
end

T['drawer']['q closes the tab and returns to the tab it came from'] = function()
    child.cmd('tabnew')
    child.cmd('tabfirst')
    local origin = child.api.nvim_get_current_tabpage()
    open_review()
    wait_diff('unstaged a.txt')

    child.type_keys('q')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(child.lua_get(R), vim.NIL)
end

T['drawer']['<C-d> and <C-u> scroll the diff, the drawer keeps focus'] = function()
    local lines = {}
    for i = 1, 100 do
        lines[i] = 'line ' .. i
    end
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), lines)

    open_review()
    select_item('unstaged', 'a.txt')
    wait_diff('unstaged a.txt')

    local topline = [[vim.fn.getwininfo(]] .. R .. [[.diff_win)[1].topline]]
    local drawer_focused = [[vim.api.nvim_get_current_win() == ]]
        .. R
        .. [[.drawer.win]]
    local before = child.lua_get(topline)

    child.type_keys('<C-d>')
    eq(child.lua_get(topline) > before, true)
    eq(child.lua_get(drawer_focused), true)

    child.type_keys('<C-u>')
    eq(child.lua_get(topline), before)
    eq(child.lua_get(drawer_focused), true)
end

T['diff'] = new_set()

T['diff']['<C-j> in the diff pane focuses the drawer, not the spacer'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')

    child.type_keys('<C-j>')

    eq(
        child.lua_get(
            R .. '.drawer:selection_win() == vim.api.nvim_get_current_win()'
        ),
        true
    )
    eq(
        child.lua_get(R .. '.spacer_win == vim.api.nvim_get_current_win()'),
        false
    )
end

T['diff'][']c and [c jump between hunks'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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

T['diff'][']f and [f follow the drawer order'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')

    local order = {}

    for _ = 1, 5 do
        child.type_keys(']f')
        table.insert(order, selected())
        eq(cursor_row():sub(1, 7), 'header ')
    end

    eq(order, {
        'unstaged b.txt',
        'unstaged c.txt',
        'unstaged d/x.txt',
        'staged b.txt',
        'staged b.txt',
    })
    eq(child.lua_get(R .. '.drawer.view.files[1].side'), 'staged')
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)

    child.type_keys('[f')
    eq(selected(), 'unstaged d/x.txt')
    eq(child.lua_get(R .. '.drawer.view.files[1].path'), 'd/x.txt')
end

T['diff']['<CR> on a gap expands it'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    local before = child.lua_get('#' .. R .. '.drawer.view.rows')
    child.type_keys('<CR>')
    child.lua([[
        local r = require('iter').current_review
        for lnum, row in ipairs(r.drawer.view.rows) do
            if row.kind == 'gap' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
    ]])
    child.type_keys('<CR>')

    eq(child.lua_get('#' .. R .. '.drawer.view.rows') > before, true)
end

T['diff']['<CR> on a code row keeps the review as it is'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    local tab = child.lua_get(R .. '.tab')
    local before = child.lua_get('#' .. R .. '.drawer.view.rows')
    cursor_on('a25 changed')

    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_tabpage(), tab)
    eq(child.lua_get(R .. '.drawer:is_open()'), true)
    eq(child.lua_get('#' .. R .. '.drawer.view.rows'), before)
    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
end

T['diff']['q closes the tab'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>', 'q')

    eq(#child.api.nvim_list_tabpages(), 1)
    eq(child.lua_get(R), vim.NIL)
end

T['diff']['the cursor at the last row stays visible above the drawer'] = function()
    child.lua([[
        local lines = {}
        for i = 1, 200 do lines[i] = 'line ' .. i end
        vim.fn.writefile(lines, 'long.txt')
    ]])
    open_review()
    select_item('unstaged', 'long.txt')
    wait_diff('unstaged long.txt')
    child.type_keys('<CR>', 'G')

    local last = child.lua_get('#' .. R .. '.drawer.view.rows')
    eq(child.api.nvim_win_get_cursor(0)[1], last)

    local pos = child.lua_get([[(function()
        local r = require('iter').current_review
        local screen = vim.fn.screenpos(r.diff_win, ]] .. last .. [[, 1)
        local float = vim.fn.win_screenpos(r.drawer.win)
        local spacer = vim.fn.win_screenpos(r.spacer_win)
        return { row = screen.row, float = float[1], spacer = spacer[1] }
    end)()]])

    eq(pos.row > 0, true)
    eq(pos.row < pos.spacer, true)
    eq(pos.row < pos.float, true)
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
    open_review()
    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(goto_target(), { line = 4, text = 'b2', tab = origin, name = 'b.txt' })
    eq(#child.api.nvim_list_tabpages(), 2)
end

T['goto']['gf on a staged row maps through the unstaged diff'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    open_review()
    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')

    cursor_on('staged')
    child.type_keys('gf')
    eq(
        goto_target(),
        { line = 5, text = 'staged', tab = origin, name = 'b.txt' }
    )

    child.cmd('tablast')
    cursor_on('b5')
    child.type_keys('gf')
    eq(goto_target(), { line = 8, text = 'b5', tab = origin, name = 'b.txt' })
end

T['goto']['gf on an unstaged del row lands on the line that replaced it'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum, row in ipairs(r.drawer.view.rows) do
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
    open_review()
    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(child.api.nvim_win_get_config(0).relative, '')
    eq(goto_target().name, 'b.txt')
end

T['goto']['gf with nohidden and unsaved changes warns and stays'] = function()
    child.o.hidden = false
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
    open_review()
    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    cursor_on('b2')
    child.lua('_G.notes = {}')
    child.type_keys('gf')

    eq(child.lua_get('_G.notes'), {
        { '[iter] The pane has unsaved changes', vim.log.levels.WARN },
    })
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.v.errmsg, '')
end

T['goto']['the spacer and the view buffer are hermetic'] = function()
    child.lua([[
        vim.o.foldenable = true
        vim.o.colorcolumn = '10'
        vim.o.cursorcolumn = true
    ]])
    open_review()
    wait_diff('unstaged a.txt')

    eq(
        child.lua_get([[(function()
            local w = vim.wo[require('iter').current_review.spacer_win]
            return { w.colorcolumn, w.cursorcolumn, w.foldenable }
        end)()]]),
        { '', false, false }
    )
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_name(]] .. R .. [[.drawer.view.buf)]]
        ),
        'iter://review/a.txt'
    )
    eq(child.lua_get('vim.bo[' .. R .. '.drawer.view.buf].buftype'), 'nofile')
end

T['switch'] = new_set()

--- The review is open, its diff pane shows the view and its drawer float
--- shows the drawer buffer.
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
                .. '.drawer.view.buf'
        ),
        true
    )
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. R
                .. '.drawer.win) == '
                .. R
                .. '.drawer.buf'
        ),
        true
    )
end

T['switch']['<C-o> in the diff pane keeps the review'] = function()
    child.cmd('edit b.txt')
    child.cmd('edit a.txt')
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('<C-o>')

    expect_review_intact()
    eq(child.lua_get(R .. '.diff_win == vim.api.nvim_get_current_win()'), true)
    eq(child.v.errmsg, '')
end

T['switch']['<C-o> in the drawer keeps the review'] = function()
    child.cmd('edit b.txt')
    child.cmd('edit a.txt')
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<C-o>')

    expect_review_intact()
    eq(child.v.errmsg, '')
end

T['switch'][':e in the diff pane opens the file in the previous tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')
    child.cmd('edit +2 c.txt')
    child.lua('vim.wait(100)')

    eq(goto_target(), { line = 1, text = 'c', tab = origin, name = 'c.txt' })
    child.cmd('tablast')
    expect_review_intact()
    eq(child.lua_get(R .. '.drawer.view.files[1].path'), 'a.txt')
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

T['switch'][':e in the drawer opens the file in the previous tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    open_review()
    wait_diff('unstaged a.txt')
    child.cmd('edit +2 c.txt')
    child.lua('vim.wait(100)')

    eq(goto_target(), { line = 1, text = 'c', tab = origin, name = 'c.txt' })
    child.cmd('tablast')
    expect_review_intact()
    eq(child.lua_get(R .. '.drawer.view.files[1].path'), 'a.txt')
    eq(child.v.errmsg, '')
end

T['switch'][':enew in the diff pane puts the view back'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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
    open_review()
    wait_diff('unstaged a.txt')
    cursor_on('a25 changed')
    child.lua('_G.generation = ' .. R .. '.drawer.view.generation')

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    a[25] = 'a25 changed'
    table.insert(a, 10, 'inserted')
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

    helpers.wait_until(child, [[(function()
            for _, row in ipairs(]] .. R .. [[.drawer.view.rows) do
                if row.text == 'inserted' then
                    return true
                end
            end
        end)()]])

    eq(cursor_row(), 'add a25 changed')
    eq(child.lua_get(R .. '.drawer.view.generation > _G.generation'), true)
end

T['refresh']['a refresh in the background refits the spacer only'] = function()
    child.cmd('vsplit')
    open_review()
    wait_diff('unstaged a.txt')
    child.cmd('tabfirst')

    local layout = [[{
        heights = vim.tbl_map(vim.api.nvim_win_get_height, vim.api.nvim_tabpage_list_wins(0)),
        cmdheight = vim.o.cmdheight,
    }]]
    local before = child.lua_get(layout)

    for i = 1, 6 do
        helpers.write_file(vim.fs.joinpath(repo, 'n' .. i .. '.txt'), { 'n' })
    end

    helpers.wait_until(child, '#' .. R .. '.drawer.rows == 14')

    eq(child.lua_get(layout), before)

    child.cmd('tabnext')

    local fit = child.lua_get([[(function()
        local r = require('iter').current_review
        local spacer = vim.api.nvim_win_get_height(r.spacer_win)
        local total = spacer + vim.api.nvim_win_get_height(r.diff_win)
        local diff_row = vim.fn.win_screenpos(r.diff_win)[1]
        return {
            spacer = spacer,
            expected = math.max(3, math.floor(total * 0.3), math.min(math.min(#r.drawer.rows, 5) + 2, math.floor(total / 2))),
            float = vim.api.nvim_win_get_config(r.drawer.win).height + 2,
            spacer_row = vim.fn.win_screenpos(r.spacer_win)[1],
            below_diff = diff_row + vim.api.nvim_win_get_height(r.diff_win) + 1,
        }
    end)()]])

    eq(fit.spacer, fit.expected)
    eq(fit.float, fit.spacer)
    eq(fit.spacer_row, fit.below_diff)
    eq(child.v.errmsg, '')
end

T['clean'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.start_child(child, repo)
            stub_ui()
        end,
    },
})

T['clean']['a clean tree opens the tab with an empty diff pane'] = function()
    open_review()

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.diff_win), 0, -1, false)]]
        ),
        { '' }
    )
    eq(child.lua_get(R .. '.drawer.view:is_shown()'), false)
    eq(child.lua_get([[require('iter').statusline()]]), 'review')
end

T['statusline'] = new_set()

T['statusline']['names the file and its position inside the tab only'] = function()
    eq(child.lua_get([[require('iter').statusline()]]), '')

    open_review()
    wait_diff('unstaged a.txt')
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · a.txt · 1/5'
    )

    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · b.txt · 5/5'
    )

    child.cmd('tabfirst')
    eq(child.lua_get([[require('iter').statusline()]]), 'main · 4')
end

T['close'] = new_set()

T['close']['the diff buffer keeps no <C-j> map once the review is closed'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    local view_buf = child.lua_get(R .. '.drawer.view.buf')
    eq(
        child.lua_get(
            string.format(
                [[vim.api.nvim_buf_call(%d, function() return vim.fn.maparg('<C-j>', 'n', false, true).desc end)]],
                view_buf
            )
        ),
        'Focus the drawer'
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

    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys(']f')
    wait_diff('unstaged b.txt')
    child.type_keys('q')

    eq(pane_opts(), before)

    open_review()
    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    cursor_on('b2')
    child.type_keys('gf')

    eq(pane_opts().global, before.global)
    eq(child.lua_get('vim.wo[_G.pane].statuscolumn'), PANE_OPTS.statuscolumn)
end

T['close']['repeated open and close leaves nothing behind'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('q')
    child.lua('vim.wait(200)')

    local before = child.lua_get(RESOURCES)

    for _ = 1, 3 do
        open_review()
        wait_diff('unstaged a.txt')
        child.type_keys('<CR>', ']f')
        wait_diff('unstaged b.txt')
        child.type_keys('q')
        child.lua('vim.wait(200)')
        eq(child.lua_get(RESOURCES), before)
    end
end

--- Every way out of the tab clears the review and stops its watchers.
---@param leave fun()
local function expect_clean_exit(leave)
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('q')
    child.lua('vim.wait(200)')
    local before = child.lua_get(RESOURCES)

    open_review()
    wait_diff('unstaged a.txt')
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

T['close'][':q in the drawer closes the tab'] = function()
    expect_clean_exit(function()
        child.cmd('quit')
    end)
end

T['close'][':q in the Annotations window closes the tab'] = function()
    expect_clean_exit(function()
        child.type_keys('l')
        child.cmd('quit')
    end)
end

T['close']['closing the spacer pane closes the tab'] = function()
    expect_clean_exit(function()
        child.type_keys('l')
        child.lua('vim.api.nvim_win_close(' .. R .. '.spacer_win, true)')
    end)
end

T['close']['q in the Annotations window closes the tab'] = function()
    expect_clean_exit(function()
        child.type_keys('l', 'q')
    end)
end

T['close']['q after :tabonly leaves one empty tab'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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
                local row = r.drawer.view.rows[lnum]
                return row ~= nil and row.kind .. ' ' .. row.text == %q
            end)()]],
            R,
            expected
        )
    )
end

T['hunks']['s stages the hunk under the cursor and keeps the other'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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
                .. '.drawer.changes.staged)'
        ),
        { 'a.txt', 'b.txt' }
    )
    eq(child.lua_get('_G.notes'), {})
end

T['hunks']['s on a hunk fires IterStage with the file'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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
    open_review()
    select_item('staged', 'a.txt')
    wait_diff('staged a.txt')
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

    open_review()
    wait_diff('unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')
    wait_cursor('hunk @@ -22,7 +22,7 @@ a21')
    child.type_keys('s')

    eq(git_out({ 'diff', '--', 'a.txt' }), '')
    wait_diff('staged a.txt')
    eq(selected(), 'staged a.txt')

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
    wait_diff('unstaged a.txt')
    eq(selected(), 'unstaged a.txt')
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['hunks']['s on a staged row, u on an unstaged row and s off a hunk warn'] = function()
    helpers.git(repo, { 'add', 'a.txt' })
    local before = git_out({ 'diff', '--cached' })

    open_review()
    select_item('staged', 'a.txt')
    wait_diff('staged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')

    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
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
    open_review()
    wait_diff('unstaged a.txt')
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
            for _, row in ipairs(]] .. R .. [[.drawer.view.rows) do
                if row.text == 'a28 written later' then
                    return true
                end
            end
        end)()]])
end

T['hunks']['a hunk git apply refuses reports and changes nothing'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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

    open_review()
    select_item('unstaged', 'e.txt')
    wait_diff('unstaged e.txt')
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
        for _, row in ipairs(]] .. R .. [[.drawer.view.rows) do
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

    open_review()
    wait_diff('unstaged a.txt')
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
    eq(added_rows(), { 'n3' })

    select_item('staged', 'a.txt')
    wait_diff('staged a.txt')
    eq(added_rows(), { 'n1', 'n2' })

    cursor_on('n1')
    child.type_keys('V', 'u')

    eq(git_out({ 'show', ':a.txt' }):find('n1', 1, true), nil)
    eq(git_out({ 'show', ':a.txt' }):find('n2', 1, true) ~= nil, true)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local n = 0
                for _, row in ipairs(%s.drawer.view.rows) do
                    if row.kind == 'add' then
                        n = n + 1
                    end
                end
                return n == 1
            end)()]],
            R
        )
    )
    eq(added_rows(), { 'n2' })
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

    open_review()
    wait_diff('unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('s')

    local cached = git_out({ 'diff', '--cached', '--', 'a.txt' })
    eq(cached:find('+a3 changed', 1, true) ~= nil, true)
    eq(cached:find('a25 changed', 1, true), nil)
    eq(cached:find('n1', 1, true), nil)

    helpers.wait_until(child, R .. [[.drawer.view.files[1].side == 'unstaged']])
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

    open_review()
    select_item('unstaged', 'l')
    wait_diff('unstaged l')
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

    open_review()
    wait_diff('unstaged a.txt')
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
    open_review()
    wait_diff('unstaged a.txt')
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
                ' x      Delete the annotation',
                ' <CR>   Expand the collapsed file or hidden context',
                ' gf     Go to the line in the file',
                ' r      Toggle reviewed',
                ' m      Toggle one file or all files',
                ' |      Show the diff side by side',
                ' -      Show the diff unified',
                ' y      Copy the review',
                ' <C-j>  Focus the drawer',
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
        end,
    },
})

--- The drawer's file column, one trimmed cell per line.
---@return string[]
local function drawer_rows()
    local lines = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]] .. R .. [[.drawer.buf, 0, -1, false)]]
    )

    return vim.tbl_map(function(line)
        return vim.trim(vim.split(line, '│')[1])
    end, lines)
end

--- The drawer header with its runs of blanks squeezed to one.
---@return string
local function drawer_header()
    local text = child.lua_get([[(function()
        local text = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(]] .. R .. [[.drawer.win).title) do
            text = text .. chunk[1]
        end
        return text
    end)()]])

    return vim.trim((text:gsub('%s+', ' ')))
end

--- The reviewed progress row of the Annotations column, trimmed.
---@return string
local function progress()
    local line = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.side_buf, 1, 2, false)[1] ]]
    )

    return vim.trim(line)
end

--- The text of the diff header's right-aligned virtual text.
---@return string
local function diff_header()
    return child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
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
                local view = %s.drawer.view
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

--- Select the unstaged row of `path` and press r in the drawer.
---@param path string
local function view_file(path)
    select_item('unstaged', path)
    wait_diff('unstaged ' .. path)
    child.type_keys('r')
end

--- Wait until the drawer has `state` for `path`.
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

T['reviewed']['rows start unreviewed, the header counts files, the column shows progress'] = function()
    open_review()
    wait_diff('unstaged a.txt')

    eq(drawer_rows(), {
        'Unstaged (4)',
        'M ○ a.txt',
        'M ○ b.txt',
        '? ○ c.txt',
        '? ○ d/x.txt',
        '',
        'Staged (1)',
        'M ○ b.txt',
    })
    eq(drawer_header(), 'HEAD main 4 files')
    eq(progress(), 'reviewed □□□□□□□□ 0 of 4')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
end

T['reviewed']['in a narrow pane the diff header keeps the path readable'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')

    -- The new window takes the width given; the diff pane keeps the rest.
    child.type_keys('<CR>')
    child.cmd('vsplit')
    child.cmd('vertical resize 30')
    helpers.wait_until(
        child,
        [[require('iter').current_review.drawer.view:text_width() < 40]]
    )
    eq(diff_header(), '+2 −2 · 0 annotations ')

    child.cmd('vertical resize 62')
    helpers.wait_until(
        child,
        [[require('iter').current_review.drawer.view:text_width() < 10]]
    )
    eq(diff_header(), '')
end

T['reviewed']['in the split layout at 70 columns the header fits beside the path'] = function()
    child.o.columns = 70
    open_review()
    wait_diff('unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.drawer.view.old ~= nil')

    local fit = child.lua_get([[(function()
        local view = ]] .. R .. [[.drawer.view
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
    open_review()
    wait_diff('unstaged a.txt')

    eq(drawer_header(), 'HEAD main 4 files')
end

T['reviewed']['r in the drawer toggles the selected file'] = function()
    open_review()
    wait_diff('unstaged a.txt')

    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    eq(drawer_rows()[2], 'M ✓ a.txt')
    eq(drawer_rows()[8], 'M ○ b.txt')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
    eq(diff_header(), '✓ reviewed  +2 −2 · 0 annotations ')
    eq(child.lua_get('_G.notes'), {})

    child.type_keys('r')
    wait_state('a.txt', 'unreviewed')

    eq(progress(), 'reviewed □□□□□□□□ 0 of 4')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
end

T['reviewed']['r in the diff pane toggles the shown file'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    eq(diff_header(), '✓ reviewed  +2 −2 · 0 annotations ')
    eq(drawer_rows()[2], 'M ✓ a.txt')
    eq(drawer_rows()[8], 'M ○ b.txt')

    child.type_keys('r')
    wait_state('a.txt', 'unreviewed')
    eq(diff_header(), '○ not reviewed  +2 −2 · 0 annotations ')
end

T['reviewed']['v in the diff pane is visual mode and marks nothing'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('<CR>')
    child.type_keys('v')

    eq(child.api.nvim_get_mode().mode, 'v')
    child.type_keys('<Esc>')
    eq(child.lua_get(R .. ".reviewed['a.txt']"), 'unreviewed')
end

T['reviewed']['a file on both sides shows the mark on both rows'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')

    eq(drawer_rows()[2], 'M ○ a.txt')
    eq(drawer_rows()[8], 'M ✓ b.txt')
    eq(drawer_rows()[3], 'M ✓ b.txt')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
end

T['reviewed']['staging keeps a file reviewed'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.staged == 2')
    wait_state('a.txt', 'reviewed')

    eq(drawer_rows()[2], 'M ○ b.txt')
    eq(drawer_rows()[7], 'M ✓ a.txt')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
end

T['reviewed']['an edit from outside turns reviewed into changed'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')
    select_item('unstaged', 'a.txt')
    wait_diff('unstaged a.txt')

    edit_b_from_outside()
    wait_state('b.txt', 'changed')

    eq(drawer_rows()[3], 'M ↻ b.txt')
    eq(progress(), '□□□□□□□□ 0 of 4 · ↻ 1')

    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    wait_diff_header('↻ changed since reviewed')

    child.type_keys('r')
    wait_state('b.txt', 'reviewed')
    wait_diff_header('✓ reviewed')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
end

T['reviewed']['an edit of the shown file updates the diff header'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')
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
    open_review()
    wait_diff('unstaged a.txt')
    eq(drawer_rows()[2], 'D ○ a.txt')
    eq(drawer_rows()[8], 'M ○ b.txt')

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
    open_review()
    wait_diff('unstaged a.txt')
    select_item('unstaged', 'd/x.txt')
    wait_diff('unstaged d/x.txt')
    child.type_keys('r')
    wait_state('d/x.txt', 'reviewed')

    eq(drawer_rows()[4], '? ○ c.txt')
    eq(drawer_rows()[5], '? ✓ d/x.txt')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
end

T['reviewed']['reviewed marks survive a restart'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('r')
    wait_state('a.txt', 'reviewed')

    child.stop()
    helpers.start_child(child, repo)
    stub_ui()
    open_review()
    wait_diff('unstaged a.txt')

    eq(drawer_rows()[2], 'M ✓ a.txt')
    eq(drawer_rows()[8], 'M ○ b.txt')
    eq(progress(), 'reviewed ■■□□□□□□ 1 of 4')
end

T['reviewed']['the status drawer shows no reviewed marks and maps no reviewed key'] = function()
    open_review()
    wait_diff('unstaged a.txt')
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
        for _, chunk in ipairs(vim.api.nvim_win_get_config(d.win).title) do
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
    open_review()
    wait_diff('unstaged a.txt')
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
        local Drawer = require('iter.ui.drawer')
        local refresh = Drawer.refresh
        Drawer.refresh = function(self, reason)
            if reason == 'poll' then
                _G.polls = _G.polls + 1
            end
            return refresh(self, reason)
        end
    ]])
    helpers.wait_until(child, '_G.polls >= 3')

    eq(child.lua_get('_G.hashes'), 0)
end

T['reviewed']['screenshot of reviewed, changed and unreviewed rows'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    view_file('a.txt')
    wait_state('a.txt', 'reviewed')
    view_file('b.txt')
    wait_state('b.txt', 'reviewed')
    edit_b_from_outside()
    wait_state('b.txt', 'changed')
    select_item('unstaged', 'a.txt')
    wait_diff('unstaged a.txt')
    wait_diff_header('✓ reviewed')

    helpers.expect_screenshot(child, 'review-reviewed')
end

T['files'] = new_set()

T['files']['Unstaged and Staged share the left column, Annotations the right'] = function()
    open_review()
    wait_diff('unstaged a.txt')

    local first = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.side_buf, 0, 1, false)[1] ]]
    )

    eq(child.lua_get(R .. '.drawer.layout'), 'columns')
    eq(vim.trim(first), 'Annotations (0)')
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.drawer.float.side_win) == ]]
                .. R
                .. [[.drawer.side_buf]]
        ),
        true
    )
    eq(drawer_rows()[7], 'Staged (1)')
end

T['files']['j crosses from the last Unstaged row into Staged, k goes back'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    select_item('unstaged', 'd/x.txt')
    wait_diff('unstaged d/x.txt')

    child.type_keys('j')
    wait_diff('staged b.txt')
    eq(selected(), 'staged b.txt')

    child.type_keys('j')
    eq(selected(), 'staged b.txt')

    child.type_keys('k')
    wait_diff('unstaged d/x.txt')
    eq(selected(), 'unstaged d/x.txt')
end

T['files']['h and l switch columns and select again what was left'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')

    child.type_keys('l')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')

    child.type_keys('h')
    eq(selected(), 'staged b.txt')

    child.type_keys('h')
    eq(selected(), 'staged b.txt')
end

T['files']['u in the Staged section unstages and keeps a file selected'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')

    child.type_keys('u')
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.staged == 0')

    eq(drawer_rows()[7], 'Staged (0)')
    eq(child.lua_get(R .. '.drawer.column'), 'unstaged')
    eq(child.lua_get('_G.notes'), {})

    select_item('unstaged', 'a.txt')
    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.staged == 1')
    select_item('staged', 'a.txt')
    child.type_keys('s')
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.staged == 0')
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
    stub_ui()
    open_review()
    wait_diff('staged m.txt')

    child.type_keys('u')
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.staged == 0')

    eq(selected(), 'unstaged m.txt')
    eq(helpers.git(repo, { 'status', '--porcelain=v1', '-z' }), '?? m.txt\0')
    eq(vim.fn.readfile(vim.fs.joinpath(repo, 'm.txt')), { 'm' })
    eq(child.lua_get('_G.notes'), {})
end

T['files']['below the breakpoint Unstaged, Staged and Annotations stack'] = function()
    child.o.columns = 60
    open_review()
    wait_diff('unstaged a.txt')

    local titles = child.lua_get(
        [[vim.tbl_filter(function(line)
        return line:find('%(%d+%)') ~= nil
    end, vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.buf, 0, -1, false)))]]
    )

    eq(child.lua_get(R .. '.drawer.layout'), 'stacked')
    eq(titles, { 'Unstaged (4)', 'Staged (1)', 'Annotations (0)' })
end

T['files']['l and h move the focus between the windows and back'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    select_item('unstaged', 'c.txt')
    wait_diff('unstaged c.txt')

    local focus = [[(function()
        local d = ]] .. R .. [[.drawer
        local win = vim.api.nvim_get_current_win()
        return win == d.win and 'files'
            or win == d.float.side_win and 'annotations'
            or 'other'
    end)()]]

    child.type_keys('l')
    eq(child.lua_get(focus), 'annotations')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')

    child.type_keys('h')
    eq(child.lua_get(focus), 'files')
    eq(selected(), 'unstaged c.txt')

    child.type_keys('l', 'h')
    eq(child.lua_get(focus), 'files')
    eq(selected(), 'unstaged c.txt')
end

T['files']['entering either window selects there and a resize keeps the focus'] = function()
    open_review()
    wait_diff('unstaged a.txt')

    local state = [[(function()
        local d = ]] .. R .. [[.drawer
        local win = vim.api.nvim_get_current_win()
        return (win == d.win and 'files'
            or win == d.float.side_win and 'annotations'
            or 'other') .. ' ' .. d.column
    end)()]]

    child.type_keys(
        '<Cmd>lua vim.api.nvim_set_current_win('
            .. R
            .. '.drawer.float.side_win)<CR>'
    )
    eq(child.lua_get(state), 'annotations annotations')

    child.type_keys(
        '<Cmd>lua vim.api.nvim_set_current_win(' .. R .. '.drawer.win)<CR>'
    )
    eq(child.lua_get(state), 'files unstaged')

    child.type_keys('<C-w>w', '<C-w>w')
    eq(child.lua_get(state), 'files unstaged')

    child.o.columns = 81
    helpers.wait_until(
        child,
        [[vim.api.nvim_win_get_width(]] .. R .. [[.drawer.pane) == 81]]
    )
    child.lua('vim.wait(50)')
    eq(child.lua_get(state), 'files unstaged')
end

T['files']['crossing the breakpoint opens and closes the Annotations window'] = function()
    child.o.columns = 120
    open_review()
    wait_diff('unstaged a.txt')
    child.type_keys('l')

    local state = [[(function()
        local d = ]] .. R .. [[.drawer
        local side = d.float.side_win
        return {
            layout = d.layout,
            side = side ~= nil and vim.api.nvim_win_is_valid(side),
            focus = vim.api.nvim_get_current_win() == d.win and 'files'
                or vim.api.nvim_get_current_win() == side and 'annotations'
                or 'other',
            column = d.column,
            wins = #vim.api.nvim_tabpage_list_wins(0),
        }
    end)()]]

    eq(child.lua_get(state), {
        layout = 'columns',
        side = true,
        focus = 'annotations',
        column = 'annotations',
        wins = 4,
    })

    child.o.columns = 60
    helpers.wait_until(child, R .. [[.drawer.layout == 'stacked']])
    eq(child.lua_get(state), {
        layout = 'stacked',
        side = false,
        focus = 'files',
        column = 'annotations',
        wins = 3,
    })

    child.o.columns = 120
    helpers.wait_until(child, R .. [[.drawer.layout == 'columns']])
    eq(child.lua_get(state), {
        layout = 'columns',
        side = true,
        focus = 'annotations',
        column = 'annotations',
        wins = 4,
    })
    eq(child.v.errmsg, '')
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

T['flow']['status, review, annotation, annotations column, yank and close leave nothing behind'] = function()
    child.lua([[
        require('iter').setup()
        vim.keymap.set('n', '<C-t>', '<Nop>', { desc = 'user ctrl-t' })
    ]])
    child.cmd('edit a.txt')
    child.lua('vim.wait(200)')
    local before = child.lua_get(FLOW_STATE)

    child.cmd('Iter')
    helpers.wait_until(child, [[require('iter').drawer ~= nil]])
    child.type_keys('r')
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.drawer.win ~= nil')
    wait_diff('unstaged a.txt')
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

    -- Jump back to it through the Annotations column, from another file.
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys(']f')
    wait_diff('unstaged b.txt')
    child.lua([[require('iter').annotations()]])
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    child.type_keys('<CR>')
    wait_diff('unstaged a.txt')
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
            .. [[.drawer.win ~= nil and vim.api.nvim_get_current_tabpage() == ]]
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
    wait_diff('unstaged a.txt')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(
        child.lua_get(R .. '.drawer.win == vim.api.nvim_get_current_win()'),
        true
    )
    eq(
        child.lua_get(
            [[vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(]]
                .. origin
                .. [[))))]]
        ),
        'a.txt'
    )
    eq(iter_names(), {
        'iter://review',
        'iter://review#annotations',
        'iter://review/a.txt',
    })
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'][':edit iter://review/<path>#L<n> puts the cursor on that line'] = function()
    edit_uri('iter://review/a.txt#L3')
    wait_routed()
    wait_diff('unstaged a.txt')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a3 changed')
    eq(child.lua_get(R .. '.drawer.view:row().new'), 3)

    -- Unstaged before Staged: b.txt's worktree line 5 is `staged`.
    edit_uri('iter://review/b.txt#L5')
    wait_diff('unstaged b.txt')
    eq(selected(), 'unstaged b.txt')
    eq(cursor_row(), 'context staged')
    eq(child.lua_get(R .. '.drawer.view:row().new'), 5)
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get('_G.notes'), {})
end

T['uri']['a line in a collapsed file shows the file whole'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.lua(R .. ":toggle_reviewed('a.txt')")
    child.lua(R .. ':toggle_mode()')
    helpers.wait_until(
        child,
        R .. '.drawer.view.document.sections[1].collapsed == true'
    )

    edit_uri('iter://review/a.txt#L25')
    helpers.wait_until(child, R .. '.drawer.view:row().new == 25')
    eq(cursor_row(), 'add a25 changed')
    eq(
        child.lua_get(R .. '.drawer.view.document.sections[1].collapsed'),
        vim.NIL
    )
end

T['uri'][':edit from another tab switches to the review'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    child.cmd('tabnew')
    child.cmd('edit c.txt')

    local other = child.api.nvim_get_current_tabpage()
    local bufs = #child.api.nvim_list_bufs()

    -- The drawer's buffer has this name: the window gets c.txt back.
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
    open_review()
    wait_diff('unstaged a.txt')

    -- From the diff pane.
    cursor_on('a3 changed')
    edit_uri('iter://review/b.txt#L1')
    wait_diff('unstaged b.txt')
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add top1')

    -- From the drawer.
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    edit_uri('iter://review/a.txt#L25')
    wait_diff('unstaged a.txt')
    eq(cursor_row(), 'add a25 changed')
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.drawer.win) == ]]
                .. R
                .. [[.drawer.buf]]
        ),
        true
    )
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.diff_win) == ]]
                .. R
                .. [[.drawer.view.buf]]
        ),
        true
    )
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri'][':edit in an iter window draws it again'] = function()
    child.o.columns = 120
    open_review()
    wait_diff('unstaged a.txt')

    local drawer = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. R .. '.drawer.buf, 0, -1, false)'
    )
    local diff = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. R .. '.drawer.view.buf, 0, -1, false)'
    )

    child.cmd('edit')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.drawer.buf, 0, -1, false)'
        ),
        drawer
    )
    eq(selected(), 'unstaged a.txt')

    cursor_on('a3 changed')
    child.cmd('edit')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines('
                .. R
                .. '.drawer.view.buf, 0, -1, false)'
        ),
        diff
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))

    local side = R .. '.drawer.side_buf'
    local annotations = child.lua_get(
        'vim.api.nvim_buf_get_lines(' .. side .. ', 0, -1, false)'
    )

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    child.type_keys('l')
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
    helpers.wait_until(child, R .. '.drawer.view:row().new == 3')
    eq(cursor_row(), 'add a3 changed')
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.v.errmsg, '')
end

T['uri'][':edit from the Annotations window routes from the diff pane'] = function()
    child.o.columns = 120
    open_review()
    wait_diff('unstaged a.txt')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.float.side_win)')

    child.type_keys(':e iter://review/a.txt\\#L3<CR>')
    helpers.wait_until(child, R .. '.drawer.view:row().new == 3')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(cursor_row(), 'add a3 changed')
    eq(child.v.errmsg, '')

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.float.side_win)')
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
    wait_diff('unstaged all')
    edit_uri('iter://review/annotations')
    wait_diff('unstaged annotations')
    eq(child.lua_get(R .. '.drawer.all_files'), false)

    edit_uri('iter://review#all')
    helpers.wait_until(child, R .. '.drawer.all_files')
    edit_uri('iter://review#annotations')
    helpers.wait_until(child, R .. [[.drawer.column == 'annotations']])
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['uri']['open_uri() routes without escaping'] = function()
    child.cmd('edit a.txt')
    child.lua([[require('iter').open_uri('iter://review/a.txt#L25')]])
    wait_routed()
    helpers.wait_until(child, R .. '.drawer.view:row().new == 25')
    eq(cursor_row(), 'add a25 changed')
    eq(child.lua_get('_G.notes'), {})
end

T['uri'][':edit from the split left pane'] = function()
    open_review()
    wait_diff('unstaged a.txt')
    cursor_on('a3 changed')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.drawer.view.old ~= nil')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.view.old.win)')

    edit_uri('iter://review/b.txt')
    wait_diff('unstaged b.txt')
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
    open_review()
    wait_diff('unstaged a.txt')

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
    open_review()
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.drawer.buf)'),
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

    open_review()
    wait_diff('unstaged a.txt')
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
    open_review()
    wait_diff('unstaged a.txt')
    eq(iter_names(), {
        'iter://review',
        'iter://review#annotations',
        'iter://review/a.txt',
    })

    local bufs = #child.api.nvim_list_bufs()

    select_item('unstaged', 'b.txt')
    wait_diff('unstaged b.txt')
    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')
    eq(iter_names(), {
        'iter://review',
        'iter://review#annotations',
        'iter://review/b.txt',
    })

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('m')
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.drawer.view.buf)'),
        'iter://review#all'
    )
    child.type_keys('|')
    helpers.wait_until(child, R .. '.drawer.view.old ~= nil')
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_name(' .. R .. '.drawer.view.old.buf)'
        ),
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
    open_review()
    wait_diff('unstaged a.txt')
    eq(child.lua_get([[require('iter').uri()]]), vim.NIL)

    cursor_on('a3 changed')
    eq(child.lua_get([[require('iter').uri()]]), 'iter://review/a.txt#L3')

    -- A staged line carries its worktree line.
    select_item('staged', 'b.txt')
    wait_diff('staged b.txt')
    cursor_on('b2')

    local uri = child.lua_get([[require('iter').uri()]])

    eq(uri, 'iter://review/b.txt#L4')

    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    edit_uri(uri)
    wait_diff('unstaged b.txt')
    eq(cursor_row(), 'context b2')

    -- A line in hidden context shows it.
    edit_uri('iter://review/b.txt#L9')
    helpers.wait_until(child, R .. '.drawer.view:row().new == 9')
    eq(cursor_row(), 'context b6')
end

T['uri']['the tab label reads iter review'] = function()
    child.o.columns = 120
    child.o.showtabline = 2
    child.o.tabline = [[%!v:lua.require'iter'.tabline()]]
    open_review()
    wait_diff('unstaged a.txt')

    eq(child.lua_get('vim.t.iter_label'), 'iter review')

    -- Two normal windows: the diff pane and the spacer.
    eq(screen_row(1):find(' 2 iter review ', 1, true) ~= nil, true)
    child.type_keys('<CR>')
    eq(screen_row(1):find(' 2 iter review ', 1, true) ~= nil, true)
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    child.type_keys('l')
    eq(
        child.api.nvim_get_current_win(),
        child.lua_get(R .. '.drawer.float.side_win')
    )
    eq(screen_row(1):find(' 2 iter review ', 1, true) ~= nil, true)

    helpers.expect_screenshot(child, 'review-tabline')

    -- The left pane of the split layout, where uri() names the new line a
    -- deleted line lands on.
    cursor_on('a3 changed')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.drawer.view.old ~= nil')
    child.lua([[
        local old = require('iter').current_review.drawer.view.old
        vim.api.nvim_set_current_win(old.win)
        vim.fn.search('^a3$')
    ]])
    eq(screen_row(1):find(' 3 iter review ', 1, true) ~= nil, true)
    eq(child.lua_get([[require('iter').uri()]]), 'iter://review/a.txt#L3')
end

return T
