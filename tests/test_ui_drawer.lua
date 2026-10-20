local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

-- Window options the diff view borrows, set to values the view never uses,
-- so a missing restore shows up.
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

local FIXTURE_COLUMNS = {
    ' Unstaged (5)                          │ Staged (1)',
    ' D deleted.txt                         │ M staged.txt',
    ' M modified.txt                        │',
    ' ? untracked.txt                       │',
    ' ? untracked_dir/a.txt                 │',
    ' ? untracked_dir/b.txt                 │',
}

local FIXTURE_SECTION = {
    '',
    ' Recent commits',
    ' 021b9c0  initial                                                            2h',
}

--- Run `:Iter` (or `command`) in the child and wait for the drawer and its
--- first preview.
---@param command? string
local function open_drawer(command)
    child.cmd(command or 'Iter')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.win ~= nil]]
    )
end

---@return string[] drawer lines without trailing blanks
local function drawer_lines()
    return child.lua_get(
        [[vim.tbl_map(function(line)
        return (line:gsub('%s+$', ''))
    end, vim.api.nvim_buf_get_lines(require('iter').drawer.buf, 0, -1, false))]]
    )
end

--- Lines of the pinned Recent commits without trailing blanks, empty
--- without its window.
---@return string[]
local function section_lines()
    return child.lua_get([[(function()
        local d = require('iter').drawer
        local win = d.float.strip_win
        if win == nil or not vim.api.nvim_win_is_valid(win) then
            return {}
        end
        return vim.tbl_map(function(line)
            return (line:gsub('%s+$', ''))
        end, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
    end)()]])
end

--- `side path` of the selected item, or nil.
---@return string?
local function selected()
    return child.lua_get([[(function()
        local item = require('iter').drawer:selected()
        return item and (item.side .. ' ' .. item.path) or vim.NIL
    end)()]])
end

--- Wait until the pane shows the diff of `expected` (`side path`).
---@param expected string
local function wait_preview(expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local d = require('iter').drawer
                local f = d and d.view.files[1]
                return f ~= nil and f.side .. ' ' .. f.path == %q
                    and vim.api.nvim_win_get_buf(d.pane) == d.view.buf
            end)()]],
            expected
        )
    )
end

--- Select the `side` item with `path` the way h/l and j/k would.
---@param side string
---@param path string
local function select_item(side, path)
    child.lua(
        [[
        local side, path = ...
        local d = require('iter').drawer
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

--- Set the borrowed options on the current window like `:set` does, and
--- remember the window as `_G.pane`.
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

---@return table<string, any>
local function pane_opts()
    return child.lua_get(
        [[(function(names)
            local values = {}
            for name in pairs(names) do
                values[name] = vim.api.nvim_get_option_value(name, { scope = 'local', win = _G.pane })
            end
            return values
        end)(...)]],
        { PANE_OPTS }
    )
end

local function stub_ui()
    child.lua([[
        -- The fixture commits are dated 2026-01-01T00:00:00Z; now is 2h later.
        local time = os.time
        os.time = function(date)
            return date and time(date) or _G.now or 1767232800
        end
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
        _G.confirms = {}
        _G.answer = 2
        vim.fn.confirm = function(msg)
            table.insert(_G.confirms, msg)
            return _G.answer
        end
    ]])
end

---@param path string
---@return string[]
local function read(path)
    return vim.fn.readfile(vim.fs.joinpath(repo, path))
end

---@return table<string, string> porcelain XY per path
local function status()
    local states = {}
    local out = helpers.git(
        repo,
        { 'status', '--porcelain=v1', '-z', '--untracked-files=all' }
    )

    for _, record in ipairs(vim.split(out, '\0', { plain = true })) do
        if record ~= '' then
            states[record:sub(4)] = record:sub(1, 2)
        end
    end

    return states
end

---@param lhs string
---@return string
local function buf_map_desc(lhs)
    return child.lua_get(
        [[vim.fn.maparg(..., 'n', false, true).desc or '']],
        { lhs }
    )
end

---@return string[]
local function screen_lines()
    return vim.tbl_map(function(cells)
        return table.concat(cells)
    end, child.get_screenshot().text)
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_fixture_repo()
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

T['open'][':Iter shows the columns side by side at 80 columns'] = function()
    open_drawer()
    wait_preview('unstaged deleted.txt')

    local d = 'require("iter").drawer'
    eq(child.lua_get(d .. '.layout'), 'columns')
    eq(child.lua_get('vim.api.nvim_get_current_win() == ' .. d .. '.win'), true)
    eq(child.bo.filetype, 'iter')
    eq(drawer_lines(), FIXTURE_COLUMNS)
    eq(section_lines(), FIXTURE_SECTION)
    eq(selected(), 'unstaged deleted.txt')

    local config = child.lua_get('vim.api.nvim_win_get_config(' .. d .. '.win)')
    eq(config.relative, 'win')
    eq(config.win, child.lua_get(d .. '.pane'))
    eq(config.anchor, 'SW')
    eq(config.zindex, 40)
    eq(config.width, 80)
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'drawer-80-columns')
end

T['open']['drawer windows take the Normal background, not the float one'] = function()
    child.lua([[
        vim.api.nvim_set_hl(0, 'Normal', { bg = 0x101010, fg = 0xcccccc })
        vim.api.nvim_set_hl(0, 'NormalFloat', { bg = 0x303030, fg = 0xcccccc })
    ]])
    child.lua([[require('iter.highlight').apply()]])
    -- Read before the drawer opens: a focused window's winhighlight remaps the lookup.
    local bgs = child.lua_get([[{
        vim.api.nvim_get_hl(0, { name = 'IterDrawer', link = false }).bg,
        vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg,
        vim.api.nvim_get_hl(0, { name = 'NormalFloat', link = false }).bg,
    }]])
    eq(bgs[2], 0x101010)
    eq(bgs[1], bgs[2])
    eq(bgs[1] ~= bgs[3], true)

    open_drawer()

    local d = 'require("iter").drawer'
    local wins = child.lua_get(
        '{ ' .. d .. '.win, ' .. d .. '.float.strip_win or vim.NIL }'
    )
    eq(type(wins[2]), 'number')

    for _, win in ipairs(wins) do
        local winhl = child.lua_get('vim.wo[' .. win .. '].winhighlight')
        eq(winhl:find('NormalFloat:IterDrawer', 1, true) ~= nil, true)
        eq(winhl:find('FloatBorder:IterDrawer', 1, true) ~= nil, true)
        eq(winhl:find('FloatTitle:IterDrawer', 1, true) ~= nil, true)
        eq(winhl:find('FloatFooter:IterDrawer', 1, true) ~= nil, true)
    end

    helpers.expect_screenshot(child, 'drawer-normal-background')
end

T['open'][':Iter status opens the drawer'] = function()
    open_drawer('Iter status')

    eq(drawer_lines(), FIXTURE_COLUMNS)
end

T['open']['stacks the columns in a 60-column split'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()
    wait_preview('unstaged deleted.txt')

    eq(child.lua_get('require("iter").drawer.layout'), 'stacked')
    eq(drawer_lines(), {
        ' Unstaged (5)',
        ' D deleted.txt',
        ' M modified.txt',
        ' ? untracked.txt',
        ' ? untracked_dir/a.txt',
        ' ? untracked_dir/b.txt',
        '',
        ' Staged (1)',
        ' M staged.txt',
    })
    eq(section_lines(), {
        '',
        ' Recent commits',
        ' 021b9c0  initial                                        2h',
    })
    eq(
        child.lua_get('vim.api.nvim_win_get_width(require("iter").drawer.win)'),
        60
    )

    helpers.expect_screenshot(child, 'drawer-60-column-split')
end

T['open']['selects the file of the current buffer'] = function()
    child.cmd('edit staged.txt')
    open_drawer()

    eq(selected(), 'staged staged.txt')
    wait_preview('staged staged.txt')
end

T['open'][':Iter with an unknown subcommand errors'] = function()
    local result = child.lua_get([[{ pcall(vim.cmd, 'Iter foo') }]])

    eq(result[1], false)
    eq(result[2]:find('Unknown subcommand: foo', 1, true) ~= nil, true)
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
end

T['open'][':Iter completes the subcommands'] = function()
    eq(child.fn.getcompletion('Iter ', 'cmdline'), { 'review', 'status' })
    eq(child.fn.getcompletion('Iter st', 'cmdline'), { 'status' })
    eq(child.fn.getcompletion('Iter x', 'cmdline'), {})
end

T['open']['outside a git repository warns and opens nothing'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.start_child(child, repo)
    stub_ui()

    child.cmd('Iter')

    eq(child.lua_get([[_G.notes]]), {
        { '[iter] Not inside a git repository', vim.log.levels.WARN },
    })
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
end

T['keys'] = new_set()

T['keys']['j and k move and the preview follows'] = function()
    open_drawer()
    wait_preview('unstaged deleted.txt')

    child.type_keys('j')
    eq(selected(), 'unstaged modified.txt')
    wait_preview('unstaged modified.txt')
    eq(child.lua_get('_G.notes'), {})

    child.type_keys('j', 'j', 'j', 'j')
    eq(selected(), 'unstaged untracked_dir/b.txt')

    child.type_keys('k', 'k', 'k')
    eq(selected(), 'unstaged modified.txt')
    wait_preview('unstaged modified.txt')

    child.type_keys('k', 'k', 'k', 'k')
    eq(selected(), 'unstaged deleted.txt')
    wait_preview('unstaged deleted.txt')
end

T['keys']['the preview loads once after quick moves'] = function()
    open_drawer()
    wait_preview('unstaged deleted.txt')
    child.lua([[
        local git = require('iter.git')
        local file_diff = git.file_diff
        _G.loads = {}
        git.file_diff = function(root, change, args)
            table.insert(_G.loads, change.path)
            return file_diff(root, change, args)
        end
    ]])

    child.type_keys('j', 'j')
    wait_preview('unstaged untracked.txt')

    eq(child.lua_get('_G.loads'), { 'untracked.txt' })
end

T['keys']['h and l switch the column'] = function()
    open_drawer()
    child.type_keys('j', 'j')

    child.type_keys('l')
    eq(selected(), 'staged staged.txt')
    wait_preview('staged staged.txt')

    child.type_keys('j')
    eq(selected(), 'staged staged.txt')

    child.type_keys('h')
    eq(selected(), 'unstaged deleted.txt')
end

T['keys']['j crosses from Unstaged to Staged when stacked'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()

    child.type_keys('j', 'j', 'j', 'j', 'j')
    eq(selected(), 'staged staged.txt')
    child.type_keys('k')
    eq(selected(), 'unstaged untracked_dir/b.txt')
end

T['keys']['a remapped key stages and the default key is unbound'] = function()
    child.lua(
        [[require('iter').setup({ keys = { drawer = { stage = 'S' } } })]]
    )
    open_drawer()

    eq(buf_map_desc('s'), '')
    eq(buf_map_desc('S'), 'Stage or unstage the file')
    eq(buf_map_desc('r'), 'Open the review tab')

    select_item('unstaged', 'modified.txt')
    child.type_keys('S')

    eq(status()['modified.txt'], 'M ')
end

T['keys']['a key disabled with false is not mapped'] = function()
    child.lua(
        [[require('iter').setup({ keys = { drawer = { discard = false } } })]]
    )
    open_drawer()

    eq(buf_map_desc('d'), '')
    eq(buf_map_desc('u'), 'Unstage the file')
end

T['keys']['<C-d> and <C-u> scroll the preview, the drawer keeps focus'] = function()
    local lines = {}
    for i = 1, 100 do
        lines[i] = 'line ' .. i
    end
    helpers.write_file(vim.fs.joinpath(repo, 'modified.txt'), lines)

    open_drawer()
    select_item('unstaged', 'modified.txt')
    wait_preview('unstaged modified.txt')

    local topline =
        [[vim.fn.getwininfo(require('iter').drawer.pane)[1].topline]]
    local drawer_focused =
        [[vim.api.nvim_get_current_win() == require('iter').drawer.win]]
    local before = child.lua_get(topline)

    child.type_keys('<C-d>')
    local down = child.lua_get(topline)
    eq(down > before, true)
    eq(child.lua_get(drawer_focused), true)

    child.type_keys('<C-u>')
    eq(child.lua_get(topline), before)
    eq(child.lua_get(drawer_focused), true)
end

T['keys']['<C-j> in the preview focuses the drawer; the map leaves with it'] = function()
    child.cmd('edit modified.txt')
    local buf = child.api.nvim_get_current_buf()
    open_drawer()
    wait_preview('unstaged modified.txt')

    local view_buf = child.lua_get([[require('iter').drawer.view.buf]])
    child.lua([[vim.api.nvim_set_current_win(require('iter').drawer.pane)]])
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == require('iter').drawer.pane]]
        ),
        true
    )

    child.type_keys('<C-j>')
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == require('iter').drawer.win]]
        ),
        true
    )

    child.type_keys('q')
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(
        child.lua_get([[vim.fn.maparg('<C-j>', 'n', false, true).desc]]),
        vim.NIL
    )
    eq(child.api.nvim_buf_is_valid(view_buf), false)
end

T['stage'] = new_set()

T['stage']['s stages a file and keeps the selection on the nearest row'] = function()
    open_drawer()
    select_item('unstaged', 'modified.txt')

    child.type_keys('s')

    eq(status()['modified.txt'], 'M ')
    eq(drawer_lines(), {
        ' Unstaged (4)                          │ Staged (2)',
        ' D deleted.txt                         │ M modified.txt',
        ' ? untracked.txt                       │ M staged.txt',
        ' ? untracked_dir/a.txt                 │',
        ' ? untracked_dir/b.txt                 │',
    })
    eq(selected(), 'unstaged untracked.txt')
    wait_preview('unstaged untracked.txt')
end

T['stage']['u and s in Staged unstage a file'] = function()
    open_drawer()
    select_item('staged', 'staged.txt')

    child.type_keys('u')
    eq(status()['staged.txt'], ' M')
    eq(selected(), 'unstaged deleted.txt')

    select_item('unstaged', 'deleted.txt')
    child.type_keys('s')
    select_item('staged', 'deleted.txt')
    child.type_keys('s')
    eq(status()['deleted.txt'], ' D')
end

T['stage']['u without commits makes the file untracked again'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.git(repo, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'm.txt'), { 'm' })
    helpers.git(repo, { 'add', 'm.txt' })
    helpers.start_child(child, repo)
    stub_ui()
    open_drawer()
    select_item('staged', 'm.txt')

    child.type_keys('u')

    eq(status(), { ['m.txt'] = '??' })
    eq(read('m.txt'), { 'm' })
    eq(child.lua_get('_G.notes'), {})
end

T['stage']['u unstages a staged rename on both paths'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'rename_me.txt'),
        { 'one', 'two', 'three', 'four', 'five' }
    )
    helpers.git(repo, { 'add', 'rename_me.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'add rename_me' })
    helpers.git(repo, { 'mv', 'rename_me.txt', 'renamed.txt' })
    open_drawer()
    eq(
        child.lua_get([[(function()
            for _, item in ipairs(require('iter').drawer.changes.staged) do
                if item.path == 'renamed.txt' then
                    return { item.code, item.orig_path }
                end
            end
        end)()]]),
        { 'R', 'rename_me.txt' }
    )
    select_item('staged', 'renamed.txt')

    child.type_keys('u')

    local states = status()
    eq(states['rename_me.txt'], ' D')
    eq(states['renamed.txt'], '??')
    eq(child.lua_get('_G.notes'), {})
end

T['stage']['u on an Unstaged row unstages its staged part'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'staged.txt'),
        { 'alpha', 'gamma' }
    )
    open_drawer()
    select_item('unstaged', 'staged.txt')

    child.type_keys('u')
    eq(status()['staged.txt'], ' M')

    select_item('unstaged', 'modified.txt')
    child.type_keys('u')
    eq(child.lua_get('_G.notes'), {
        { '[iter] Nothing to unstage', vim.log.levels.WARN },
    })
end

T['stage']['s stages one untracked file of a new directory'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, '.git', 'info', 'exclude'),
        { '*.log' }
    )
    helpers.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'x.log'), { 'x' })
    open_drawer()
    select_item('unstaged', 'untracked_dir/a.txt')

    child.type_keys('s')

    local states = status()
    eq(states['untracked_dir/a.txt'], 'A ')
    eq(states['untracked_dir/b.txt'], '??')
    eq(states['untracked_dir/x.log'], nil)
end

T['stage']['s and d skip a nested repository with a warning'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'nested', 'a.txt'), { 'a' })
    helpers.git(vim.fs.joinpath(repo, 'nested'), { 'init', '--quiet' })
    open_drawer()
    select_item('unstaged', 'nested/')
    child.lua('_G.answer = 1')

    child.type_keys('s')

    eq(child.lua_get('_G.notes'), {
        {
            '[iter] Skipped the nested repository nested/',
            vim.log.levels.WARN,
        },
    })

    child.lua('_G.notes = {}')
    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {})
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] Skipped the nested repository nested/',
            vim.log.levels.WARN,
        },
    })
    eq(status()['nested/'], '??')
end

T['discard'] = new_set()

T['discard']['a declined confirm changes nothing'] = function()
    open_drawer()
    select_item('unstaged', 'modified.txt')

    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {
        'Discard unstaged changes in:\nmodified.txt',
    })
    eq(read('modified.txt'), { 'one', 'two changed', 'three' })
    eq(status()['modified.txt'], ' M')
end

T['discard']['keeps the staged part of a file'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'staged.txt'),
        { 'alpha', 'gamma' }
    )
    open_drawer()
    select_item('unstaged', 'staged.txt')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(read('staged.txt'), { 'alpha', 'beta' })
    eq(status()['staged.txt'], 'M ')
    eq(helpers.git(repo, { 'show', ':staged.txt' }), 'alpha\nbeta\n')
    eq(
        drawer_lines()[1],
        ' Unstaged (5)                          │ Staged (1)'
    )
end

T['discard']['an untracked file leaves an ignored file in its directory'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, '.git', 'info', 'exclude'),
        { '*.log' }
    )
    helpers.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'x.log'), { 'x' })
    open_drawer()
    select_item('unstaged', 'untracked_dir/a.txt')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {
        'Delete untracked files:\nuntracked_dir/a.txt',
    })
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'untracked_dir', 'a.txt')), 0)
    eq(read('untracked_dir/b.txt'), { 'b' })
    eq(read('untracked_dir/x.log'), { 'x' })
    eq(status()['untracked_dir/a.txt'], nil)
    eq(status()['untracked_dir/b.txt'], '??')
end

T['discard']['deletes a single untracked file'] = function()
    open_drawer()
    select_item('unstaged', 'untracked.txt')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {
        'Delete untracked files:\nuntracked.txt',
    })
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'untracked.txt')), 0)
    eq(status()['untracked.txt'], nil)
    eq(status()['untracked_dir/b.txt'], '??')
end

T['discard']['d in Staged warns and changes nothing'] = function()
    open_drawer()
    select_item('staged', 'staged.txt')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(child.lua_get('_G.notes'), {
        { '[iter] Unstage first', vim.log.levels.WARN },
    })
    eq(child.lua_get('_G.confirms'), {})
    eq(status()['staged.txt'], 'M ')
end

T['close'] = new_set()

T['close']['<CR> opens the file in the pane and restores it'] = function()
    set_pane_opts()
    open_drawer()
    select_item('unstaged', 'modified.txt')
    wait_preview('unstaged modified.txt')

    child.type_keys('<CR>')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.pane'), true)
    eq(
        child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'),
        'modified.txt'
    )
    eq(pane_opts(), PANE_OPTS)
    eq(#child.api.nvim_list_wins(), 1)
end

T['close'][':Iter with nohidden and unsaved changes opens nothing'] = function()
    child.o.hidden = false
    child.cmd('edit modified.txt')
    child.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved' })
    local buf = child.api.nvim_get_current_buf()

    child.cmd('Iter')

    eq(child.lua_get('_G.notes'), {
        { '[iter] The pane has unsaved changes', vim.log.levels.WARN },
    })
    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.v.errmsg, '')
end

T['close']['<CR> keeps the drawer when the pane has unsaved changes'] = function()
    child.cmd('edit modified.txt')
    local buf = child.api.nvim_get_current_buf()
    open_drawer()
    select_item('staged', 'staged.txt')
    wait_preview('staged staged.txt')
    child.o.hidden = false
    child.api.nvim_buf_set_lines(buf, 0, 1, false, { 'unsaved' })

    child.type_keys('<CR>')

    eq(child.lua_get('_G.notes'), {
        { '[iter] The pane has unsaved changes', vim.log.levels.WARN },
    })
    eq(child.lua_get([[require('iter').drawer ~= nil]]), true)
    eq(child.api.nvim_buf_get_lines(buf, 0, 1, false), { 'unsaved' })
    eq(child.v.errmsg, '')

    child.type_keys('q')
    eq(child.api.nvim_get_current_buf(), buf)
end

T['close']['<CR> on a deleted file keeps the drawer and the preview'] = function()
    open_drawer()
    select_item('unstaged', 'deleted.txt')
    wait_preview('unstaged deleted.txt')

    child.type_keys('<CR>')

    eq(child.lua_get([[require('iter').drawer ~= nil]]), true)
    eq(selected(), 'unstaged deleted.txt')
    wait_preview('unstaged deleted.txt')
    eq(child.lua_get('_G.notes'), {
        { '[iter] deleted.txt is deleted', vim.log.levels.WARN },
    })
end

T['close']['q closes and restores the pane'] = function()
    child.cmd('edit modified.txt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()
    open_drawer()
    wait_preview('unstaged modified.txt')

    child.type_keys('q')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(pane_opts(), PANE_OPTS)
end

T['close']['wiping the preview buffer closes the drawer'] = function()
    set_pane_opts()
    open_drawer()
    wait_preview('unstaged deleted.txt')

    child.lua([[
        vim.api.nvim_win_call(require('iter').drawer.pane, function()
            vim.cmd.bwipeout()
        end)
    ]])
    helpers.wait_until(child, [[require('iter').drawer == nil]])

    eq(#child.api.nvim_list_wins(), 1)
    eq(pane_opts(), PANE_OPTS)
end

T['close']['wiping the pane buffer before q still restores it'] = function()
    child.cmd('edit modified.txt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()
    open_drawer()
    wait_preview('unstaged modified.txt')

    child.lua('vim.cmd.bwipeout(...)', { buf })
    eq(child.lua_get([[require('iter').drawer ~= nil]]), true)
    child.type_keys('q')

    eq(child.lua_get([[require('iter').drawer]]), vim.NIL)
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.pane'), true)
    eq(pane_opts(), PANE_OPTS)
end

T['close'][':close in the drawer restores the pane'] = function()
    set_pane_opts()
    open_drawer()
    wait_preview('unstaged deleted.txt')

    child.cmd('close')
    helpers.wait_until(child, [[require('iter').drawer == nil]])

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.lua_get('vim.api.nvim_get_current_win() == _G.pane'), true)
    eq(pane_opts(), PANE_OPTS)
end

T['float'] = new_set()

--- Screen row (1-based) of the last text row of `win`, or of its bottom
--- border with `border` rows around the text. A bordered float's `winrow`
--- is its top border.
---@param win string Lua expression for the window id
---@param border? integer
---@return integer
local function last_row(win, border)
    return child.lua_get(string.format(
        [[(function()
            local w = %s
            local info = vim.fn.getwininfo(w)[1]
            return info.winrow + info.winbar + info.height - 1 + %d
        end)()]],
        win,
        border or 0
    ))
end

T['float']['keeps its place after pane resizes'] = function()
    open_drawer()
    local d = 'require("iter").drawer'

    child.o.lines = 30
    child.o.columns = 60
    child.cmd('redraw')
    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_width(' .. d .. '.win) == 60'
    )

    eq(child.lua_get(d .. '.layout'), 'stacked')
    eq(last_row(d .. '.float.strip_win', 1), last_row(d .. '.pane'))
    -- The height share minus the chrome and the Recent commits leaves fewer
    -- rows than the minimum of file lines, so the minimum holds.
    eq(child.lua_get('vim.api.nvim_win_get_height(' .. d .. '.win)'), 5)
    eq(selected(), 'unstaged deleted.txt')

    child.o.columns = 80
    child.cmd('redraw')
    helpers.wait_until(child, d .. '.layout == "columns"')
    eq(drawer_lines(), FIXTURE_COLUMNS)
end

T['float']['sits above a float at zindex 20'] = function()
    open_drawer()
    -- Opened after the drawer, so only the zindex can keep it below.
    child.lua([[
        local low = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(low, 0, -1, false, vim.fn['repeat']({ ('X'):rep(80) }, 30))
        vim.api.nvim_open_win(low, false, {
            relative = 'editor', row = 0, col = 0,
            width = 80, height = 22, zindex = 20,
        })
    ]])
    child.cmd('redraw')

    local rows = screen_lines()
    local first = child.lua_get(
        [[vim.fn.getwininfo(require('iter').drawer.win)[1].winrow]]
    )
    eq(vim.startswith(rows[first], ' HEAD main'), true)
    eq(vim.startswith(rows[first + 1], ' Unstaged (5)'), true)
    eq(vim.startswith(rows[first + 2], ' D deleted.txt'), true)
    eq(rows[first + 2]:find('X', 1, true), nil)
    eq(rows[first - 1]:find('XXXX', 1, true) ~= nil, true)
end

T['float']['ends on the last pane row below a winbar'] = function()
    child.cmd('split')
    open_drawer()
    local d = 'require("iter").drawer'
    child.lua('vim.wo[' .. d .. '.pane].winbar = "PANE WINBAR"')
    child.cmd('redraw')
    local first = child.lua_get('vim.fn.getwininfo(' .. d .. '.win)[1].winrow')

    eq(last_row(d .. '.pane') < child.o.lines - 2, true)
    eq(last_row(d .. '.float.strip_win', 1), last_row(d .. '.pane'))
    eq(vim.startswith(screen_lines()[first + 1], ' Unstaged (5)'), true)
    eq(screen_lines()[1]:find('PANE WINBAR', 1, true) ~= nil, true)
    eq(child.lua_get('vim.wo[' .. d .. '.win].winbar'), '')
end

T['float']['shows no global winbar of its own'] = function()
    child.o.winbar = 'GLOBAL WINBAR'
    child.cmd('split')
    open_drawer()
    child.cmd('redraw')
    local d = 'require("iter").drawer'
    local first = child.lua_get('vim.fn.getwininfo(' .. d .. '.win)[1].winrow')

    eq(last_row(d .. '.pane') < child.o.lines - 2, true)
    eq(last_row(d .. '.float.strip_win', 1), last_row(d .. '.pane'))
    eq(vim.startswith(screen_lines()[first + 1], ' Unstaged (5)'), true)
end

--- Text of the drawer float's header (title) and key hint line (footer).
--- The header's padding is cut to two spaces and its end trimmed.
---@return { header: string, hint: string }
local function chrome()
    local result = child.lua_get([[(function()
        local config = vim.api.nvim_win_get_config(require('iter').drawer.win)
        local function text(chunks)
            return table.concat(vim.tbl_map(function(chunk)
                return chunk[1]
            end, chunks or {}))
        end
        local strip = require('iter').drawer.float.strip_win
        local footer = strip and vim.api.nvim_win_get_config(strip).footer
            or config.footer
        return { header = text(config.title), hint = text(footer) }
    end)()]])

    result.header = result.header:gsub('%s%s%s+', '  '):gsub('%s+$', '')

    return result
end

local HINT =
    's stage  u unstage  d discard  I ignore  <CR> open  r review  ? help'

---@param options string Lua table passed to setup()
local function setup(options)
    child.lua('require("iter").setup(' .. options .. ')')
end

T['header'] = new_set()

T['header']['shows the branch, the changes and the key hint'] = function()
    open_drawer()

    eq(chrome(), { header = 'HEAD main  6 changes', hint = HINT })
end

T['header']['shows the commits ahead of the upstream'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'ahead' })
    open_drawer()

    eq(chrome().header, 'HEAD main  ↑1  base  5 changes')
end

T['header']['names a detached HEAD'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    open_drawer()

    eq(chrome().header, 'HEAD (detached)  6 changes')
end

T['header']['the hint follows remapped keys'] = function()
    setup([[{ keys = { drawer = { stage = 'S', discard = false } } }]])
    open_drawer()

    eq(
        chrome().hint,
        'S stage  u unstage  I ignore  <CR> open  r review  ? help'
    )
end

T['header']['stacked, the header, hint and the selected section stay on screen'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()
    select_item('staged', 'staged.txt')
    child.cmd('redraw')

    local screen = table.concat(screen_lines(), '\n')

    for _, text in ipairs({
        '5 unstaged · 1 staged',
        ' Staged (1)',
        ' M staged.txt',
        '? help',
    }) do
        eq({ text, screen:find(text, 1, true) ~= nil }, { text, true })
    end
end

T['header']['stacked with a long list, the header counts both sides'] = function()
    for i = 1, 15 do
        helpers.write_file(
            vim.fs.joinpath(repo, string.format('many_%02d.txt', i)),
            { 'x' }
        )
    end
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()
    child.cmd('redraw')

    local first = child.lua_get(
        [[vim.fn.getwininfo(require('iter').drawer.win)[1].winrow]]
    )
    eq(vim.startswith(screen_lines()[first], ' HEAD main  '), true)
    eq(vim.endswith(chrome().header, '20 unstaged · 1 staged'), true)
end

T['header']['a narrow drawer with a long branch opens cleanly'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(
        repo,
        { 'checkout', '--quiet', '-b', 'feat/a-rather-long-branch-name' }
    )
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'ahead' })
    child.cmd('vsplit')
    child.cmd('vertical resize 30')
    open_drawer()
    child.cmd('redraw')

    eq(child.v.errmsg, '')
    eq(child.lua_get('_G.notes'), {})
    eq(vim.endswith(chrome().hint, '? help'), true)
    eq(
        child.lua_get(
            'vim.fn.strdisplaywidth(' .. vim.inspect(chrome().hint) .. ')'
        ) <= 30,
        true
    )
    eq(chrome().header, 'HEAD feat/a-rather-long-branch-name')

    -- Neovim cuts a title wider than the float from the left with `<`.
    local info =
        child.lua_get('vim.fn.getwininfo(require("iter").drawer.win)[1]')
    eq(info.width, 30)
    local row = child.get_screenshot().text[info.winrow]
    eq(
        table.concat(row, '', info.wincol, info.wincol + info.width - 1),
        ' <eat/a-rather-long-branch-nam'
    )
end

T['header']['stacked at 60 columns keeps HEAD and the branch whole'] = function()
    local remote = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(remote, 'p')
    helpers.git(remote, { 'init', '--quiet', '--bare' })
    helpers.git(repo, { 'checkout', '--quiet', '-b', 'feat/renovation' })
    helpers.git(repo, { 'remote', 'add', 'origin', remote })
    helpers.git(repo, { 'push', '--quiet', '-u', 'origin', 'feat/renovation' })

    -- Commits made without touching the index: one only on the remote, one
    -- only on the branch.
    local function commit(message)
        return vim.trim(
            helpers.git(
                repo,
                { 'commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', message }
            )
        )
    end
    helpers.git(repo, {
        'push',
        '--quiet',
        'origin',
        commit('theirs') .. ':refs/heads/feat/renovation',
    })
    helpers.git(repo, { 'fetch', '--quiet' })
    helpers.git(repo, { 'update-ref', 'HEAD', commit('mine') })

    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()
    child.cmd('redraw')

    eq(child.lua_get('require("iter").drawer.layout'), 'stacked')
    eq(
        chrome().header,
        'HEAD feat/renovation  ↑1 ↓1  origin/feat/renovation'
    )

    local info =
        child.lua_get('vim.fn.getwininfo(require("iter").drawer.win)[1]')
    local row = child.get_screenshot().text[info.winrow]
    eq(
        vim.startswith(
            table.concat(row, '', info.wincol, info.wincol + info.width - 1),
            ' HEAD feat/renovation  ↑1 ↓1  origin/feat/renovation'
        ),
        true
    )

    helpers.cleanup(remote)
end

T['help'] = new_set()

--- Lines of the open help float, or nil.
---@return string[]?
local function help_lines()
    return child.lua_get([[(function()
        local help = require('iter').drawer.help
        if help == nil or not help:is_open() then
            return vim.NIL
        end
        return vim.tbl_map(function(line)
            return (line:gsub('%s+$', ''))
        end, vim.api.nvim_buf_get_lines(help.buf, 0, -1, false))
    end)()]])
end

T['help']['? lists the current keys and closes on q, ? and <Esc>'] = function()
    setup(
        [[{ keys = { drawer = { stage = { 'S', 'gs' }, discard = false } } }]]
    )
    open_drawer()

    for _, close in ipairs({ 'q', '?', '<Esc>' }) do
        child.type_keys('?')
        eq(help_lines(), {
            ' <CR>   Open the file and close the drawer',
            ' S gs   Stage or unstage the file',
            ' u      Unstage the file',
            ' I      Add the untracked file to .gitignore',
            ' r      Open the review tab',
            ' q      Close',
            ' ?      Show the keys',
            ' <C-d>  Scroll the diff down',
            ' <C-u>  Scroll the diff up',
            ' h      Select the column to the left',
            ' l      Select the column to the right',
        })
        eq(
            child.lua_get(
                [[vim.api.nvim_win_get_config(require('iter').drawer.help.win).zindex]]
            ),
            50
        )

        if close == 'q' then
            helpers.expect_screenshot(child, 'drawer-help')
        end

        child.type_keys(close)
        eq(help_lines(), vim.NIL)
        eq(child.lua_get('require("iter").drawer:is_open()'), true)
        eq(
            child.lua_get(
                'vim.api.nvim_get_current_win() == require("iter").drawer.win'
            ),
            true
        )
    end
end

T['help']['stays centered when the editor is resized'] = function()
    open_drawer()
    child.type_keys('?')

    local config = [[(function()
        local c = vim.api.nvim_win_get_config(require('iter').drawer.help.win)
        return { c.row, c.col, c.width, c.height }
    end)()]]
    local before = child.lua_get(config)

    child.o.columns = child.o.columns - 20
    child.o.lines = child.o.lines - 6
    child.lua('vim.wait(20)')

    local after = child.lua_get(config)
    eq({ after[3], after[4] }, { before[3], before[4] })
    eq(after[1], math.max(0, math.floor((child.o.lines - after[4]) / 2) - 1))
    eq(after[2], math.max(0, math.floor((child.o.columns - after[3]) / 2) - 1))
    eq(after[2] < before[2], true)
end

T['help']['closes with the drawer'] = function()
    open_drawer()
    child.type_keys('?')
    local help_win = child.lua_get('require("iter").drawer.help.win')

    child.lua('require("iter").drawer:close()')

    eq(child.api.nvim_win_is_valid(help_win), false)
end

T['preview'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)

            local a, b, c = {}, {}, {}
            for i = 1, 30 do
                table.insert(a, 'a' .. i)
            end
            for i = 1, 6 do
                table.insert(b, 'b' .. i)
                table.insert(c, 'c' .. i)
            end
            repo = helpers.create_repo({
                ['a.txt'] = a,
                ['b.txt'] = b,
                ['c.txt'] = c,
            })

            -- a.txt: an added line near the top, a25 replaced, a gap between.
            table.insert(a, 3, 'a2 new')
            a[26] = 'a25 changed'
            helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), a)

            -- b.txt: `staged` staged after b4, then an unstaged line on top.
            table.insert(b, 5, 'staged')
            helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
            helpers.git(repo, { 'add', 'b.txt' })
            table.insert(b, 1, 'unstaged')
            helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)

            -- c.txt: a staged change only.
            c[3] = 'c3 staged'
            helpers.write_file(vim.fs.joinpath(repo, 'c.txt'), c)
            helpers.git(repo, { 'add', 'c.txt' })

            helpers.start_child(child, repo)
            stub_ui()
            set_pane_opts()
        end,
    },
})

--- Show the diff of `side path`, focus the preview and put the cursor on the
--- first row of `kind`, with `text` when given.
---@param side string
---@param path string
---@param kind string
---@param text? string
local function preview_cursor(side, path, kind, text)
    open_drawer()
    select_item(side, path)
    wait_preview(side .. ' ' .. path)
    child.lua(
        [[
        local kind, text = ...
        local view = require('iter').drawer.view
        vim.api.nvim_set_current_win(view.win)
        for lnum, row in ipairs(view.rows) do
            if row.kind == kind and (text == vim.NIL or row.text == text) then
                vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
                return
            end
        end
        error('no ' .. kind .. ' row ' .. tostring(text))
    ]],
        { kind, text == nil and vim.NIL or text }
    )
end

--- Where `<CR>` landed: drawer state, window, file, line and its text.
---@return table
local function landing()
    return child.lua_get([[{
        drawer = require('iter').drawer ~= nil,
        pane = vim.api.nvim_get_current_win() == _G.pane,
        name = vim.fs.basename(vim.api.nvim_buf_get_name(0)),
        line = vim.api.nvim_win_get_cursor(0)[1],
        text = vim.api.nvim_get_current_line(),
    }]])
end

T['preview']['<CR> on an added row opens its line and closes the drawer'] = function()
    preview_cursor('unstaged', 'a.txt', 'add', 'a2 new')
    child.type_keys('<CR>')

    eq(landing(), {
        drawer = false,
        pane = true,
        name = 'a.txt',
        line = 3,
        text = 'a2 new',
    })
    eq(pane_opts(), PANE_OPTS)
    eq(#child.api.nvim_list_wins(), 1)
end

T['preview']['<CR> on the file the pane shows, modified, only moves the cursor'] = function()
    child.cmd('edit a.txt')
    child.lua([[vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'unsaved' })]])
    preview_cursor('unstaged', 'a.txt', 'add', 'a2 new')
    child.type_keys('<CR>')

    eq(landing(), {
        drawer = false,
        pane = true,
        name = 'a.txt',
        line = 3,
        text = 'a2 new',
    })
    eq(child.bo.modified, true)
    eq(child.api.nvim_buf_get_lines(0, -2, -1, false), { 'unsaved' })
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['preview']['<CR> on a context row opens its line'] = function()
    preview_cursor('unstaged', 'a.txt', 'context', 'a5')
    child.type_keys('<CR>')

    eq(
        landing(),
        { drawer = false, pane = true, name = 'a.txt', line = 6, text = 'a5' }
    )
    eq(pane_opts(), PANE_OPTS)
end

T['preview']['<CR> on a deleted row opens the line that replaced it'] = function()
    preview_cursor('unstaged', 'a.txt', 'del', 'a25')
    child.type_keys('<CR>')

    eq(landing(), {
        drawer = false,
        pane = true,
        name = 'a.txt',
        line = 26,
        text = 'a25 changed',
    })
end

T['preview']['<CR> on a staged-only row opens its line'] = function()
    preview_cursor('staged', 'c.txt', 'add', 'c3 staged')
    child.type_keys('<CR>')

    eq(landing(), {
        drawer = false,
        pane = true,
        name = 'c.txt',
        line = 3,
        text = 'c3 staged',
    })
end

T['preview']['<CR> on a staged row maps through the unstaged diff'] = function()
    preview_cursor('staged', 'b.txt', 'add', 'staged')
    child.type_keys('<CR>')

    eq(landing(), {
        drawer = false,
        pane = true,
        name = 'b.txt',
        line = 6,
        text = 'staged',
    })
end

T['preview']['<CR> on a gap expands it and keeps the drawer'] = function()
    preview_cursor('unstaged', 'a.txt', 'gap')
    local before = child.lua_get([[#require('iter').drawer.view.rows]])

    child.type_keys('<CR>')

    eq(child.lua_get([[require('iter').drawer ~= nil]]), true)
    eq(child.lua_get([[#require('iter').drawer.view.rows]]) > before, true)
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == require('iter').drawer.view.win]]
        ),
        true
    )
end

T['preview']['<CR> on a hunk row does nothing'] = function()
    preview_cursor('unstaged', 'a.txt', 'hunk')
    local before = child.lua_get([[#require('iter').drawer.view.rows]])

    child.type_keys('<CR>')

    eq(child.lua_get([[require('iter').drawer ~= nil]]), true)
    eq(child.lua_get([[#require('iter').drawer.view.rows]]), before)
    eq(child.lua_get('_G.notes'), {})
end

---@type string?
local remote

--- Commit `message` in `repo` with the committer date `date`, staged
--- changes included.
---@param message string
---@param date string
local function commit_at(message, date)
    local pinned = vim.env.GIT_COMMITTER_DATE
    vim.env.GIT_COMMITTER_DATE = date
    helpers.git(repo, { 'commit', '--quiet', '--allow-empty', '-m', message })
    vim.env.GIT_COMMITTER_DATE = pinned
end

--- Lines of the pinned Recent commits with every short sha as `sha`.
---@return string[]
local function commit_lines()
    return vim.tbl_map(function(line)
        return (line:gsub('%f[%w]%x%x%x%x%x%x%x+%f[%W]', 'sha'))
    end, section_lines())
end

T['commits'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)

            local pinned = vim.env.GIT_COMMITTER_DATE
            vim.env.GIT_COMMITTER_DATE = '2025-12-31T00:00:00Z'
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            vim.env.GIT_COMMITTER_DATE = pinned

            remote = helpers.create_remote(repo)
            helpers.push_from_clone(remote, 'theirs')
            helpers.git(repo, { 'fetch', '--quiet' })
            commit_at(
                'refactor(drawer): split ui/drawer.lua',
                '2026-01-01T00:00:00Z'
            )
            commit_at(
                'docs: move scope into CONVENTIONS',
                '2026-01-01T01:00:00Z'
            )
            helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a', 'b' })
            helpers.start_child(child, repo, { lines = 30, columns = 100 })
            stub_ui()
        end,
        post_case = function()
            helpers.cleanup(remote)
            remote = nil
        end,
    },
})

local RECENT = {
    '',
    ' Recent commits · ↑2 unpushed · ↓1 behind',
    ' ↑ sha  docs: move scope into CONVENTIONS'
        .. string.rep(' ', 52)
        .. '1h',
    ' ↑ sha  refactor(drawer): split ui/drawer.lua'
        .. string.rep(' ', 48)
        .. '2h',
    '   sha  initial' .. string.rep(' ', 78) .. '1d',
}

--- The drawer's windows: float, section strip, and whether the strip sits
--- right under the float and ends on the pane's last row.
---@return { strip: boolean, focusable: boolean?, stacked: boolean?, height: integer }
local function strip_state()
    child.cmd('redraw')

    return child.lua_get([[(function()
        local d = require('iter').drawer
        local strip = d.float.strip_win
        local valid = strip ~= nil and vim.api.nvim_win_is_valid(strip)
        local main = vim.fn.getwininfo(d.win)[1]
        local result = { strip = valid, height = main.height }
        if valid then
            local info = vim.fn.getwininfo(strip)[1]
            local pane = vim.fn.getwininfo(d.pane)[1]
            result.focusable = vim.api.nvim_win_get_config(strip).focusable
            -- A float's winrow is its top border: the float has a title
            -- row, the strip only a footer row.
            result.stacked = main.winrow + 1 + main.height == info.winrow
                and info.winrow + info.height
                    == pane.winrow + pane.winbar + pane.height - 1
        end
        return result
    end)()]])
end

T['commits']['the header shows ahead, behind and the upstream'] = function()
    open_drawer()

    eq(chrome().header, 'HEAD main  ↑2 ↓1  origin/main  1 change')

    local title = child.lua_get([[(function()
        local config = vim.api.nvim_win_get_config(require('iter').drawer.win)
        local text = ''
        for _, chunk in ipairs(config.title) do
            text = text .. chunk[1]
        end
        return text
    end)()]])
    eq(vim.fn.strdisplaywidth(title), 100)
    eq(vim.endswith(title, ' 1 change '), true)
end

T['commits']['pins the recent commits under the files'] = function()
    open_drawer()

    eq(commit_lines(), RECENT)
    eq(#drawer_lines(), 2)
    -- The file area is what the height share leaves after the chrome and
    -- the section, here enough for both file lines.
    eq(
        strip_state(),
        { strip = true, focusable = false, stacked = true, height = 2 }
    )
    eq(chrome().hint, HINT)

    helpers.expect_screenshot(child, 'drawer-recent-commits')
end

T['commits']['stay visible above a long file list'] = function()
    for i = 1, 30 do
        helpers.write_file(
            vim.fs.joinpath(repo, string.format('many_%02d.txt', i)),
            { 'x' }
        )
    end
    open_drawer()
    child.type_keys('G')
    child.cmd('redraw')

    eq(selected(), 'unstaged many_30.txt')
    eq(commit_lines(), RECENT)
    eq(strip_state().stacked, true)

    -- The share leaves fewer rows than the minimum of file lines, so the
    -- minimum holds and the rest of the list scrolls.
    eq(strip_state().height, 5)

    helpers.expect_screenshot(child, 'drawer-recent-commits-long')
end

T['commits']['the section never takes focus'] = function()
    open_drawer()
    local drawer_win = child.lua_get('require("iter").drawer.win')

    child.type_keys('G', 'j', 'j')
    eq(selected(), 'unstaged a.txt')
    eq(child.lua_get('vim.api.nvim_get_current_win()'), drawer_win)

    child.cmd('wincmd w')
    child.cmd('wincmd w')
    eq(
        child.lua_get(
            'vim.api.nvim_get_current_win() ~= require("iter").drawer.float.strip_win'
        ),
        true
    )
end

T['commits']['closing the drawer closes the section on every path'] = function()
    --- Floats and buffers once the drawer reports itself closed.
    local function after_close()
        helpers.wait_until(
            child,
            [[_G.opened.closed and require('iter').drawer == nil]]
        )
        child.lua('vim.wait(50)')

        return child.lua_get([[(function()
            local floats = 0
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(win).relative ~= '' then
                    floats = floats + 1
                end
            end
            return { floats = floats, bufs = #vim.api.nvim_list_bufs() }
        end)()]])
    end

    open_drawer()
    child.lua('_G.opened = require("iter").drawer')
    child.type_keys('q')
    local baseline = after_close()
    eq(baseline.floats, 0)

    -- Each path gets a window of its own (a split, or a tab of the same
    -- buffer) that the path may close.
    for _, path in ipairs({
        { 'split', 'q' },
        { 'split', ':quit' },
        { 'split', 'close the pane' },
        { 'tab split', ':tabclose' },
    }) do
        child.cmd(path[1])
        open_drawer()
        child.lua('_G.opened = require("iter").drawer')
        eq({ path[2], strip_state().strip }, { path[2], true })
        local section_buf = child.lua_get('require("iter").drawer.section_buf')

        if path[2] == 'q' then
            child.type_keys('q')
        elseif path[2] == ':quit' then
            child.cmd('quit')
        elseif path[2] == ':tabclose' then
            child.cmd('tabclose')
        else
            child.lua(
                'vim.api.nvim_win_close(require("iter").drawer.pane, true)'
            )
        end

        eq({ path[2], after_close() }, { path[2], baseline })
        eq(
            { path[2], child.api.nvim_buf_is_valid(section_buf) },
            { path[2], false }
        )
    end
end

T['commits'][':Iter on an open drawer focuses it and keeps the section'] = function()
    open_drawer()
    local d = 'require("iter").drawer'
    child.lua('vim.api.nvim_set_current_win(' .. d .. '.pane)')

    child.cmd('Iter')

    eq(child.lua_get('vim.api.nvim_get_current_win() == ' .. d .. '.win'), true)
    eq(child.lua_get(d .. '.closed'), false)
    eq(strip_state().strip, true)
end

T['commits']['drawer.commits = 0 opens no section window'] = function()
    child.lua('require("iter").setup({ drawer = { commits = 0 } })')
    open_drawer()

    eq(#drawer_lines(), 2)
    eq(strip_state().strip, false)
    eq(chrome().header, 'HEAD main  ↑2 ↓1  origin/main  1 change')
    eq(chrome().hint, HINT)
end

T['commits']['stacked, the section stays pinned at the bottom'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()

    eq(child.lua_get('require("iter").drawer.layout'), 'stacked')
    eq(drawer_lines(), { ' Unstaged (1)', ' M a.txt', '', ' Staged (0)' })
    eq(commit_lines()[2], ' Recent commits · ↑2 unpushed · ↓1 behind')
    eq(#commit_lines(), 5)
    eq(vim.endswith(commit_lines()[5], ' 1d'), true)
    eq(strip_state().stacked, true)

    child.lua('vim.api.nvim_win_set_width(require("iter").drawer.pane, 40)')
    helpers.wait_until(
        child,
        [[vim.api.nvim_win_get_width(require('iter').drawer.float.strip_win) == 40]]
    )
    eq(strip_state().stacked, true)
    eq(vim.fn.strdisplaywidth(commit_lines()[3]) <= 40, true)
end

T['commits']['follows VimResized'] = function()
    open_drawer()

    child.o.lines = 40
    child.o.columns = 70
    helpers.wait_until(
        child,
        [[vim.api.nvim_win_get_width(require('iter').drawer.float.strip_win) == 70]]
    )
    eq(strip_state().stacked, true)
end

T['commits']['a new commit shows on the next poll'] = function()
    child.lua('require("iter").setup({ refresh = { poll_ms = 50 } })')
    open_drawer()

    helpers.git(repo, { 'commit', '--quiet', '-am', 'feat: polled' })
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_get_lines(require('iter').drawer.section_buf, 1, 2, false)[1]
            == ' Recent commits · ↑3 unpushed · ↓1 behind']]
    )
    eq(drawer_lines(), { ' Working tree clean' })
end

T['commits']['an age rolling over renders without diff or log'] = function()
    open_drawer()
    wait_preview('unstaged a.txt')
    child.lua([[
        local system = vim.system
        _G.calls = {}
        vim.system = function(cmd, ...)
            table.insert(_G.calls, cmd[3])
            return system(cmd, ...)
        end
        _G.now = 1767232800 + 3600
        require('iter').drawer:refresh('poll')
        vim.system = system
    ]])

    eq(child.lua_get('_G.calls'), { 'branch', 'status', 'rev-parse' })
    eq(
        vim.tbl_map(function(line)
            return line:sub(-2)
        end, vim.list_slice(commit_lines(), 3, 5)),
        { '2h', '3h', '1d' }
    )
end

T['commits']['a detached HEAD lists commits without markers'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    open_drawer()

    eq(chrome().header, 'HEAD (detached)  1 change')
    eq(vim.list_slice(commit_lines(), 1, 3), {
        '',
        ' Recent commits',
        ' sha  docs: move scope into CONVENTIONS'
            .. string.rep(' ', 54)
            .. '1h',
    })
end

T['commits']['an unborn HEAD has no section'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.git(repo, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a' })
    helpers.start_child(child, repo)
    stub_ui()
    open_drawer()

    eq(#drawer_lines(), 2)
    eq(strip_state().strip, false)
    eq(chrome().header, 'HEAD main  1 change')
end

T['clean'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.start_child(child, repo)
            stub_ui()
            set_pane_opts()
        end,
    },
})

T['clean']['a clean tree says Working tree clean'] = function()
    open_drawer()

    eq(drawer_lines(), { ' Working tree clean' })
    eq(section_lines(), {
        '',
        ' Recent commits',
        ' 1a6d49e  initial                                                            2h',
    })
    eq(chrome(), { header = 'HEAD main  0 changes', hint = HINT })
    eq(selected(), vim.NIL)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf(_G.pane) == require("iter").drawer.view.buf'
        ),
        false
    )

    child.type_keys('s', 'u', 'd', '<CR>', 'j', 'l')
    eq(child.v.errmsg, '')
    eq(child.lua_get('_G.notes'), {})

    helpers.expect_screenshot(child, 'drawer-clean')

    child.type_keys('q')
    eq(pane_opts(), PANE_OPTS)
end

T['clean']['turning clean keeps the drawer and gives the pane back'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a', 'b' })
    open_drawer()
    wait_preview('unstaged a.txt')

    helpers.git(repo, { 'commit', '--quiet', '-am', 'clean again' })
    helpers.wait_until(
        child,
        [[require('iter').drawer.rows[1] ~= nil
            and vim.api.nvim_buf_get_lines(require('iter').drawer.buf, 0, 1, false)[1]
                == ' Working tree clean']]
    )

    eq(child.lua_get('require("iter").drawer:is_open()'), true)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf(_G.pane) == require("iter").drawer.view.buf'
        ),
        false
    )
    eq(pane_opts(), PANE_OPTS)
    eq(child.v.errmsg, '')

    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a', 'b', 'c' })
    helpers.git(repo, { 'add', 'a.txt' })
    wait_preview('staged a.txt')
end

T['refresh'] = new_set({
    hooks = {
        pre_case = function()
            setup([[{ refresh = { poll_ms = 600000 } }]])
        end,
    },
})

--- True in the child once the drawer lists `path` on `side`.
---@param side string
---@param path string
---@return string Lua expression
local function lists(side, path)
    return string.format(
        [[(function()
            for _, row in ipairs(require('iter').drawer.rows) do
                if row[%q] ~= nil and row[%q].path == %q then
                    return true
                end
            end
            return false
        end)()]],
        side,
        side,
        path
    )
end

T['refresh']['two external git add in a linked worktree'] = function()
    local worktree = vim.fs.joinpath(repo, '..', vim.fs.basename(repo) .. '-wt')
    helpers.git(repo, { 'worktree', 'add', '--quiet', '-b', 'feat', worktree })
    worktree = vim.fn.resolve(worktree)
    helpers.write_file(vim.fs.joinpath(worktree, 'one.txt'), { 'one' })
    helpers.write_file(vim.fs.joinpath(worktree, 'two.txt'), { 'two' })
    child.cmd('cd ' .. vim.fn.fnameescape(worktree))
    open_drawer()
    eq(chrome().header, 'HEAD feat  2 changes')

    helpers.git(worktree, { 'add', 'one.txt' })
    helpers.wait_until(child, lists('staged', 'one.txt'))

    helpers.git(worktree, { 'add', 'two.txt' })
    helpers.wait_until(child, lists('staged', 'two.txt'))

    child.lua('require("iter").drawer:close()')
    helpers.cleanup(worktree)
end

T['refresh']['keeps the selection on its path'] = function()
    open_drawer()
    select_item('unstaged', 'untracked.txt')

    helpers.git(repo, { 'add', 'modified.txt' })
    helpers.wait_until(child, lists('staged', 'modified.txt'))

    eq(selected(), 'unstaged untracked.txt')
    wait_preview('unstaged untracked.txt')
end

T['refresh']['FocusGained picks up a worktree change'] = function()
    open_drawer()

    helpers.write_file(vim.fs.joinpath(repo, 'staged.txt'), { 'edited' })
    child.cmd('doautocmd FocusGained')
    helpers.wait_until(child, lists('unstaged', 'staged.txt'))
end

T['refresh']['the poll picks up a new file'] = function()
    setup([[{ refresh = { poll_ms = 50 } }]])
    open_drawer()

    helpers.write_file(vim.fs.joinpath(repo, 'polled.txt'), { 'new' })
    helpers.wait_until(child, lists('unstaged', 'polled.txt'))
end

T['refresh']['an idle drawer does not refresh itself'] = function()
    open_drawer()
    wait_preview('unstaged deleted.txt')
    child.lua([[
        local git = require('iter.git')
        local snapshot = git.status_snapshot
        _G.snapshots = 0
        git.status_snapshot = function(...)
            _G.snapshots = _G.snapshots + 1
            return snapshot(...)
        end
    ]])

    child.lua('vim.wait(500)')

    eq(child.lua_get('_G.snapshots'), 0)
end

T['refresh']['stays on its repository after :cd'] = function()
    open_drawer()
    local elsewhere = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(elsewhere, 'p')
    child.cmd('cd ' .. vim.fn.fnameescape(elsewhere))

    child.cmd('doautocmd FocusGained')
    helpers.git(repo, { 'add', 'modified.txt' })
    helpers.wait_until(child, lists('staged', 'modified.txt'))

    eq(child.lua_get('require("iter").drawer.changes.root'), repo)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
    helpers.cleanup(elsewhere)
end

T['refresh']['an unchanged diff keeps the preview as it is'] = function()
    open_drawer()
    select_item('unstaged', 'modified.txt')
    wait_preview('unstaged modified.txt')
    child.lua([[
        local view = require('iter').drawer.view
        local show = view.show
        _G.shows = 0
        view.show = function(...)
            _G.shows = _G.shows + 1
            return show(...)
        end
    ]])

    helpers.git(repo, { 'add', 'untracked.txt' })
    helpers.wait_until(child, lists('staged', 'untracked.txt'))

    eq(selected(), 'unstaged modified.txt')
    eq(child.lua_get('_G.shows'), 0)
end

T['refresh']['closing stops the watchers and timers'] = function()
    child.lua([[_G.handle_counts = function()
        local counts = { fs_event = 0, timer = 0 }
        vim.uv.walk(function(handle)
            local kind = handle:get_type()
            if counts[kind] ~= nil and not handle:is_closing() then
                counts[kind] = counts[kind] + 1
            end
        end)
        return counts
    end]])

    --- The handle counts once they equal `expected`, or after two seconds
    --- of waiting for that.
    ---@param expected? table
    ---@return table
    local function counts(expected)
        return child.lua(
            [[
            local expected = ...
            vim.wait(2000, function()
                return expected == vim.NIL
                    or vim.deep_equal(_G.handle_counts(), expected)
            end, 20)
            return _G.handle_counts()
        ]],
            { expected or vim.NIL }
        )
    end

    local before = counts()
    local opened

    for _ = 1, 3 do
        open_drawer()
        wait_preview('unstaged deleted.txt')

        local now = counts(opened)
        eq(now.fs_event > before.fs_event, true)
        opened = opened or now
        eq(now, opened)

        child.type_keys('q')
        eq(counts(before), before)
    end
end

--- Whether a drawer line shows `text`.
---@param text string
---@return boolean
local function shows(text)
    for _, line in ipairs(drawer_lines()) do
        if line:find(text, 1, true) ~= nil then
            return true
        end
    end

    return false
end

T['rename'] = new_set()

T['rename']['a staged rename reads old → new in one row'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'ui', 'diff', 'parser.lua'),
        { 'one', 'two', 'three', 'four', 'five' }
    )
    helpers.git(repo, { 'add', 'ui' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'add parser' })
    vim.fn.mkdir(vim.fs.joinpath(repo, 'diff'), 'p')
    helpers.git(repo, { 'mv', 'ui/diff/parser.lua', 'diff/parser.lua' })
    open_drawer()

    eq(shows('R ui/diff/parser.lua → diff/parser.lua'), true)

    select_item('staged', 'diff/parser.lua')
    wait_preview('staged diff/parser.lua')
    helpers.expect_screenshot(child, 'drawer-rename')
end

T['statusline'] = new_set()

T['statusline']['follows new files after the drawer closed'] = function()
    child.lua([[require('iter').setup()]])
    open_drawer()
    child.type_keys('q')
    eq(child.lua_get([[require('iter').statusline()]]), 'main · 6')

    helpers.write_file(vim.fs.joinpath(repo, 'one.txt'), { '1' })
    helpers.write_file(vim.fs.joinpath(repo, 'two.txt'), { '2' })
    child.api.nvim_exec_autocmds('FocusGained', {})

    helpers.wait_until(child, [[require('iter').statusline() == 'main · 8']])
end

T['ignore'] = new_set()

T['ignore']['I on an untracked file appends it to .gitignore'] = function()
    open_drawer()
    select_item('unstaged', 'untracked.txt')
    child.lua('_G.answer = 1')

    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), { 'Append untracked.txt to .gitignore?' })
    eq(read('.gitignore'), { '/untracked.txt' })
    eq(status()['untracked.txt'], nil)
    eq(shows('? untracked.txt'), false)
    eq(shows('? .gitignore'), true)
    eq(child.lua_get('_G.notes'), {})
end

T['ignore']['I declined leaves everything as it was'] = function()
    open_drawer()
    select_item('unstaged', 'untracked.txt')

    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), { 'Append untracked.txt to .gitignore?' })
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, '.gitignore')), 0)
    eq(status()['untracked.txt'], '??')
    eq(shows('? untracked.txt'), true)
end

T['ignore']['I on a tracked file warns and asks nothing'] = function()
    open_drawer()
    select_item('unstaged', 'modified.txt')

    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), {})
    eq(child.lua_get('_G.notes'), {
        { '[iter] Only untracked files can be ignored', vim.log.levels.WARN },
    })
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, '.gitignore')), 0)
end

T['ignore']['confirm.ignore = false appends without asking'] = function()
    setup([[{ confirm = { ignore = false } }]])
    open_drawer()
    select_item('unstaged', 'untracked_dir/a.txt')

    child.type_keys('I')

    eq(child.lua_get('_G.confirms'), {})
    eq(read('.gitignore'), { '/untracked_dir/a.txt' })
    eq(status()['untracked_dir/a.txt'], nil)
    eq(status()['untracked_dir/b.txt'], '??')
end

T['events'] = new_set()

local function spy_events()
    child.lua([[
        _G.events = {}
        vim.api.nvim_create_autocmd('User', {
            pattern = { 'IterRefresh', 'IterStage' },
            callback = function(args)
                table.insert(_G.events, { args.match, args.data })
            end,
        })
    ]])
end

T['events']['s fires IterRefresh, then IterStage, with root and paths'] = function()
    open_drawer()
    spy_events()
    select_item('unstaged', 'modified.txt')

    child.type_keys('s')

    eq(child.lua_get('_G.events'), {
        {
            'IterRefresh',
            {
                root = repo,
                paths = {
                    'deleted.txt',
                    'untracked.txt',
                    'untracked_dir/a.txt',
                    'untracked_dir/b.txt',
                    'modified.txt',
                    'staged.txt',
                },
            },
        },
        {
            'IterStage',
            { root = repo, paths = { 'modified.txt' }, action = 'stage' },
        },
    })
end

T['events']['u and d fire IterStage with their action'] = function()
    open_drawer()
    spy_events()
    select_item('staged', 'staged.txt')
    child.type_keys('u')
    select_item('unstaged', 'modified.txt')
    child.lua('_G.answer = 1')
    child.type_keys('d')

    local stages = vim.tbl_filter(function(event)
        return event[1] == 'IterStage'
    end, child.lua_get('_G.events'))

    eq(stages, {
        {
            'IterStage',
            { root = repo, paths = { 'staged.txt' }, action = 'unstage' },
        },
        {
            'IterStage',
            { root = repo, paths = { 'modified.txt' }, action = 'discard' },
        },
    })
end

T['events']['a declined discard and a poll without changes fire nothing'] = function()
    open_drawer()
    spy_events()
    select_item('unstaged', 'modified.txt')

    child.type_keys('d')
    child.lua([[require('iter').drawer:refresh('poll')]])

    eq(child.lua_get('_G.events'), {})
end

T['odd paths'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = helpers.create_odd_paths_repo()
            helpers.start_child(child, repo)
            stub_ui()
        end,
    },
})

T['odd paths']['show, preview, stage and discard'] = function()
    open_drawer()
    wait_preview('unstaged ne w/ö ä.txt')

    eq(drawer_lines(), {
        ' Unstaged (2)                          │ Staged (0)',
        ' ? ne w/ö ä.txt                        │',
        ' M sp ace/ü.txt                        │',
    })

    select_item('unstaged', 'sp ace/ü.txt')
    child.type_keys('s')
    eq(status()['sp ace/ü.txt'], 'M ')

    select_item('unstaged', 'ne w/ö ä.txt')
    child.lua('_G.answer = 1')
    child.type_keys('d')
    eq(
        child.lua_get('_G.confirms'),
        { 'Delete untracked files:\nne w/ö ä.txt' }
    )
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'ne w', 'ö ä.txt')), 0)
end

return T
