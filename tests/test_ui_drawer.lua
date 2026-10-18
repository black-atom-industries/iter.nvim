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
    ' Unstaged (4)                          │ Staged (1)',
    ' D deleted.txt                         │ M staged.txt',
    ' M modified.txt                        │',
    ' ? untracked.txt                       │',
    ' ? untracked_dir/                      │',
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
    local out = helpers.git(repo, { 'status', '--porcelain=v1', '-z' })

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
        ' Unstaged (4)',
        ' D deleted.txt',
        ' M modified.txt',
        ' ? untracked.txt',
        ' ? untracked_dir/',
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
    eq(child.fn.getcompletion('Iter ', 'cmdline'), { 'status' })
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
    eq(selected(), 'unstaged untracked_dir/')

    child.type_keys('k', 'k')
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
        local diffs = require('iter.git')
        local file_diff = diffs.file_diff
        _G.loads = {}
        diffs.file_diff = function(root, change)
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

    child.type_keys('j', 'j', 'j', 'j')
    eq(selected(), 'staged staged.txt')
    child.type_keys('k')
    eq(selected(), 'unstaged untracked_dir/')
end

T['keys']['a remapped key stages and the default key is unbound'] = function()
    child.lua(
        [[require('iter').setup({ keys = { drawer = { stage = 'S' } } })]]
    )
    open_drawer()

    eq(buf_map_desc('s'), '')
    eq(buf_map_desc('S'), 'Stage or unstage the file')
    eq(buf_map_desc('r'), '')

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

T['stage'] = new_set()

T['stage']['s stages a file and keeps the selection on the nearest row'] = function()
    open_drawer()
    select_item('unstaged', 'modified.txt')

    child.type_keys('s')

    eq(status()['modified.txt'], 'M ')
    eq(drawer_lines(), {
        ' Unstaged (3)                          │ Staged (2)',
        ' D deleted.txt                         │ M modified.txt',
        ' ? untracked.txt                       │ M staged.txt',
        ' ? untracked_dir/                      │',
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

T['stage']['s stages an untracked directory without its ignored file'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, '.git', 'info', 'exclude'),
        { '*.log' }
    )
    helpers.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'x.log'), { 'x' })
    open_drawer()
    select_item('unstaged', 'untracked_dir/')

    child.type_keys('s')

    local states = status()
    eq(states['untracked_dir/a.txt'], 'A ')
    eq(states['untracked_dir/b.txt'], 'A ')
    eq(states['untracked_dir/x.log'], nil)
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
        ' Unstaged (4)                          │ Staged (1)'
    )
end

T['discard']['an untracked directory leaves its ignored file'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, '.git', 'info', 'exclude'),
        { '*.log' }
    )
    helpers.write_file(vim.fs.joinpath(repo, 'untracked_dir', 'x.log'), { 'x' })
    open_drawer()
    select_item('unstaged', 'untracked_dir/')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {
        'Delete untracked files:\nuntracked_dir/a.txt\nuntracked_dir/b.txt',
    })
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'untracked_dir', 'a.txt')), 0)
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'untracked_dir', 'b.txt')), 0)
    eq(read('untracked_dir/x.log'), { 'x' })
    eq(status()['untracked_dir/'], nil)
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
    eq(status()['untracked_dir/'], '??')
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

T['expand'] = new_set()

T['expand']['<Tab> expands and collapses an untracked directory'] = function()
    open_drawer()
    select_item('unstaged', 'untracked_dir/')

    child.type_keys('<Tab>')
    eq(drawer_lines(), {
        ' Unstaged (4)                          │ Staged (1)',
        ' D deleted.txt                         │ M staged.txt',
        ' M modified.txt                        │',
        ' ? untracked.txt                       │',
        ' ? untracked_dir/                      │',
        '   ? a.txt                             │',
        '   ? b.txt                             │',
    })
    eq(selected(), 'unstaged untracked_dir/')

    child.type_keys('j')
    eq(selected(), 'unstaged untracked_dir/a.txt')
    wait_preview('unstaged untracked_dir/a.txt')

    child.type_keys('<Tab>')
    eq(drawer_lines(), FIXTURE_COLUMNS)
    eq(selected(), 'unstaged untracked_dir/')
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

--- Screen row (1-based) of the last text row of `win`.
---@param win string Lua expression for the window id
---@return integer
local function last_row(win)
    return child.lua_get(string.format(
        [[(function()
            local w = %s
            local info = vim.fn.getwininfo(w)[1]
            return info.winrow + info.winbar + info.height - 1
        end)()]],
        win
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
    eq(last_row(d .. '.win'), last_row(d .. '.pane'))
    eq(
        child.lua_get('vim.api.nvim_win_get_height(' .. d .. '.win)'),
        math.floor(
            child.lua_get('vim.api.nvim_win_get_height(' .. d .. '.pane)') * 0.3
        )
    )
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
    eq(vim.startswith(rows[first], ' Unstaged (4)'), true)
    eq(vim.startswith(rows[first + 1], ' D deleted.txt'), true)
    eq(rows[first + 1]:find('X', 1, true), nil)
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
    eq(last_row(d .. '.win'), last_row(d .. '.pane'))
    eq(vim.startswith(screen_lines()[first], ' Unstaged (4)'), true)
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
    eq(last_row(d .. '.win'), last_row(d .. '.pane'))
    eq(vim.startswith(screen_lines()[first], ' Unstaged (4)'), true)
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

T['odd paths']['show, preview and stage'] = function()
    open_drawer()
    wait_preview('unstaged sp ace/ü.txt')

    eq(drawer_lines(), {
        ' Unstaged (2)                          │ Staged (0)',
        ' M sp ace/ü.txt                        │',
        ' ? ne w/                               │',
    })
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_lines(require('iter').drawer.view.buf, 0, 1, false)]]
        ),
        { 'sp ace/ü.txt' }
    )

    child.type_keys('s')
    eq(status()['sp ace/ü.txt'], 'M ')

    select_item('unstaged', 'ne w/')
    child.type_keys('<Tab>', 'j')
    eq(selected(), 'unstaged ne w/ö ä.txt')
    wait_preview('unstaged ne w/ö ä.txt')
    child.lua('_G.answer = 1')
    child.type_keys('d')
    eq(
        child.lua_get('_G.confirms'),
        { 'Delete untracked files:\nne w/ö ä.txt' }
    )
    eq(vim.fn.filereadable(vim.fs.joinpath(repo, 'ne w', 'ö ä.txt')), 0)
end

return T
