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
        git.file_diff = function(root, change)
            table.insert(_G.loads, change.path)
            return file_diff(root, change)
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
    eq(last_row(d .. '.win', 2), last_row(d .. '.pane'))
    -- 0.3 of the 29-row pane, minus the 2 chrome rows.
    eq(child.lua_get('vim.api.nvim_win_get_height(' .. d .. '.win)'), 6)
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
    eq(last_row(d .. '.win', 2), last_row(d .. '.pane'))
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
    eq(last_row(d .. '.win', 2), last_row(d .. '.pane'))
    eq(vim.startswith(screen_lines()[first + 1], ' Unstaged (5)'), true)
end

--- Text of the drawer float's header (title) and key hint line (footer).
---@return { header: string, hint: string }
local function chrome()
    return child.lua_get([[(function()
        local config = vim.api.nvim_win_get_config(require('iter').drawer.win)
        local function text(chunks)
            return table.concat(vim.tbl_map(function(chunk)
                return chunk[1]
            end, chunks or {}))
        end
        return { header = text(config.title), hint = text(config.footer) }
    end)()]])
end

local HINT = 's stage  u unstage  d discard  <CR> open  r review  ? help'

---@param options string Lua table passed to setup()
local function setup(options)
    child.lua('require("iter").setup(' .. options .. ')')
end

T['header'] = new_set()

T['header']['shows the branch, the changes and the key hint'] = function()
    open_drawer()

    eq(chrome(), { header = 'HEAD main · 6 changes', hint = HINT })
end

T['header']['shows the commits ahead of the upstream'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'ahead' })
    open_drawer()

    eq(chrome().header, 'HEAD main ↑1 · 5 changes')
end

T['header']['names a detached HEAD'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    open_drawer()

    eq(chrome().header, 'HEAD (detached) · 6 changes')
end

T['header']['the hint follows remapped keys'] = function()
    setup([[{ keys = { drawer = { stage = 'S', discard = false } } }]])
    open_drawer()

    eq(chrome().hint, 'S stage  u unstage  <CR> open  r review  ? help')
end

T['header']['stacked, the header, hint and the selected section stay on screen'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 60')
    open_drawer()
    select_item('staged', 'staged.txt')
    child.cmd('redraw')

    local screen = table.concat(screen_lines(), '\n')

    for _, text in ipairs({
        'HEAD main · 5 unstaged · 1 staged',
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
    eq(
        vim.startswith(
            screen_lines()[first],
            ' HEAD main · 20 unstaged · 1 staged'
        ),
        true
    )
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
    eq(
        chrome().header,
        'HEAD feat/a-rather-long-branch-name ↑1 · 5 unstaged · 0 staged'
    )

    -- Neovim cuts a title wider than the float from the left with `<`.
    local info =
        child.lua_get('vim.fn.getwininfo(require("iter").drawer.win)[1]')
    eq(info.width, 30)
    local row = child.get_screenshot().text[info.winrow]
    eq(
        table.concat(row, '', info.wincol, info.wincol + info.width - 1),
        ' <me ↑1 · 5 unstaged · 0 stage'
    )
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
    eq(chrome(), { header = 'HEAD main · 0 changes', hint = HINT })
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
    eq(chrome().header, 'HEAD feat · 2 changes')

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
    local count = [[(function()
        local counts = { fs_event = 0, timer = 0 }
        vim.uv.walk(function(handle)
            local kind = handle:get_type()
            if counts[kind] ~= nil and not handle:is_closing() then
                counts[kind] = counts[kind] + 1
            end
        end)
        return counts
    end)()]]
    local before = child.lua_get(count)
    local opened

    for _ = 1, 3 do
        open_drawer()
        wait_preview('unstaged deleted.txt')

        local now = child.lua_get(count)
        eq(now.fs_event > before.fs_event, true)
        opened = opened or now
        eq(now, opened)

        child.type_keys('q')
        child.lua('vim.wait(300)')
        eq(child.lua_get(count), before)
    end
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
