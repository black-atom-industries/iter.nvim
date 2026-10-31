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

--- A repository with one change of each staging state: `a.txt` unstaged,
--- `b.txt` partly staged, `dir/c.txt` staged, `dir/sub/d.txt` unstaged and
--- `new.txt` untracked.
---@return string
local function create_repo()
    local lines = {}

    for i = 1, 60 do
        lines[i] = 'line ' .. i
    end

    local dir = helpers.create_repo({
        ['a.txt'] = { 'one', 'two', 'three' },
        ['b.txt'] = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '10' },
        ['dir/c.txt'] = { 'c' },
        ['dir/sub/d.txt'] = { 'd' },
        ['long.txt'] = lines,
    })

    helpers.write_file(
        vim.fs.joinpath(dir, 'a.txt'),
        { 'one', 'two changed', 'three' }
    )
    helpers.write_file(
        vim.fs.joinpath(dir, 'b.txt'),
        { 'staged', '2', '3', '4', '5', '6', '7', '8', '9', '10' }
    )
    helpers.git(dir, { 'add', 'b.txt' })
    helpers.write_file(
        vim.fs.joinpath(dir, 'b.txt'),
        { 'staged', '2', '3', '4', '5', '6', '7', '8', '9', 'unstaged' }
    )
    helpers.write_file(vim.fs.joinpath(dir, 'dir/c.txt'), { 'c', 'added' })
    helpers.git(dir, { 'add', 'dir/c.txt' })
    helpers.write_file(vim.fs.joinpath(dir, 'dir/sub/d.txt'), { 'd changed' })
    helpers.write_file(vim.fs.joinpath(dir, 'new.txt'), { 'new' })

    return dir
end

--- Resolve the config in the child with `options`.
---@param options string Lua table source
local function configure(options)
    child.lua(
        [[require('iter').config = require('iter.config').resolve(...)]],
        {
            child.lua_get(options),
        }
    )
end

local S = 'require("iter").drawer'

--- Run `:Iter` (or `command`) and wait for the sidebar.
---@param command? string
local function open_status(command)
    child.cmd(command or 'Iter')
    helpers.wait_until(
        child,
        S .. ' ~= nil and ' .. S .. '.panel ~= nil and ' .. S .. ':is_open()'
    )
end

---@return string[] the panel's lines without trailing blanks
local function panel_lines()
    return child.lua_get(
        [[vim.tbl_map(function(line)
        return (line:gsub('%s+$', ''))
    end, vim.api.nvim_buf_get_lines(require('iter').drawer.tree.buf, 0, -1, false))]]
    )
end

---@return string? path of the row under the cursor
local function cursor_path()
    return child.lua_get([[(function()
        local node = require('iter').drawer.tree:node()
        return node and node.path or vim.NIL
    end)()]])
end

--- Move the panel's cursor to the row of `path`, as `j`/`k` would.
---@param path string
local function move_to(path)
    child.lua(
        [[
        local s = require('iter').drawer
        local lnum = s.tree:line_of(...)
        assert(lnum, 'no row for ' .. ...)
        s.panel:set_cursor(lnum)
    ]],
        { path }
    )
end

--- Wait until the pane shows the diff of `expected`, `side path` per
--- section.
---@param expected string[]
local function wait_preview(expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local s = require('iter').drawer
                if s == nil or not s:is_open() then return false end
                local shown = vim.tbl_map(function(f)
                    return f.side .. ' ' .. f.path
                end, s.view.files)
                return vim.deep_equal(shown, %s)
                    and vim.api.nvim_win_get_buf(s.pane) == s.view.buf
            end)()]],
            vim.inspect(expected)
        )
    )
end

local function stub_ui()
    child.lua([[
        -- The fixture commits are dated 2026-01-01T00:00:00Z; now is 2h later.
        local time = os.time
        os.time = function(date)
            return date and time(date) or 1767232800
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

--- Set the borrowed options on the current window, and remember it as
--- `_G.pane`.
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

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_repo()
            helpers.start_child(child, repo)
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

local ROWS = {
    ' HEAD main',
    ' 5 files · 1 staged · 1 partly',
    '',
    '   ▾ dir/',
    '     ▾ sub/',
    '       ○ M d.txt            +1 −1',
    '     ● M c.txt                 +1',
    '   ○ M a.txt                +1 −1',
    '   ◐ M b.txt                +2 −2',
    '   ○ ? new.txt',
}

T['open'] = new_set()

T['open'][':Iter opens the sidebar at the left edge and the diff in the window'] = function()
    child.cmd('edit long.txt')
    local pane = child.api.nvim_get_current_win()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })

    local panel = child.lua_get(S .. '.panel.win')

    eq(child.api.nvim_get_current_win(), panel)
    eq(child.api.nvim_win_get_width(panel), 34)
    eq(child.fn.win_screenpos(panel), { 1, 1 })
    eq(child.lua_get(S .. '.pane'), pane)
    eq(
        child.api.nvim_buf_get_name(child.lua_get(S .. '.tree.buf')),
        'iter://status'
    )
    eq(
        child.api.nvim_buf_get_name(child.api.nvim_win_get_buf(pane)),
        'iter://status/dir/sub/d.txt'
    )
    eq(cursor_path(), 'dir/sub/d.txt')

    local lines = panel_lines()

    eq(vim.list_slice(lines, 1, #ROWS), ROWS)
    eq(vim.list_slice(lines, #lines - 1), {
        ' s stage  u unstage  d discard',
        ' <CR> open  r review  ? help',
    })
    helpers.expect_screenshot(child, 'status-sidebar')
end

T['open']['the cursor starts on the file of the current buffer'] = function()
    child.cmd('edit a.txt')

    open_status()
    wait_preview({ 'unstaged a.txt' })

    eq(cursor_path(), 'a.txt')
end

T['open']['the cursor, the marker and the diff move together'] = function()
    child.cmd('edit a.txt')

    open_status()
    wait_preview({ 'unstaged a.txt' })
    child.type_keys('j', 'j')
    wait_preview({ 'unstaged new.txt' })

    local state = child.lua_get([[(function()
        local s = require('iter').drawer
        local ns = vim.api.nvim_create_namespace('iter.panel.cursor')
        local marks = vim.api.nvim_buf_get_extmarks(s.tree.buf, ns, 0, -1, {})
        return {
            cursor = vim.api.nvim_win_get_cursor(s.panel.win)[1],
            marks = vim.tbl_map(function(mark)
                return mark[2] + 1
            end, marks),
            lnum = s.tree:line_of('new.txt'),
            pane = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(s.pane)),
        }
    end)()]])

    eq(state.cursor, state.lnum)
    eq(state.marks, { state.lnum })
    eq(state.pane, 'iter://status/new.txt')
end

T['open']['a partly staged file shows its unstaged and its staged section'] = function()
    open_status()
    move_to('b.txt')
    wait_preview({ 'unstaged b.txt', 'staged b.txt' })

    helpers.expect_screenshot(child, 'status-sidebar-partly')
end

T['open']['a clean tree leaves the window as it is'] = function()
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'all' })
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()

    eq(vim.list_slice(panel_lines(), 1, 4), {
        ' HEAD main',
        ' no changes',
        '',
        ' Working tree clean',
    })
    eq(child.api.nvim_win_get_buf(child.lua_get(S .. '.pane')), buf)
    helpers.expect_screenshot(child, 'status-sidebar-clean')
end

T['open']['closing on a clean tree keeps the cursor in the window'] = function()
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'all' })
    child.cmd('edit long.txt')

    open_status()
    child.cmd('wincmd l')
    child.cmd('normal! 30G')
    child.cmd('Iter')

    eq(child.lua_get(S), vim.NIL)
    eq(child.api.nvim_win_get_cursor(0)[1], 30)
end

T['open']['on a clean tree a poll leaves the window to the user'] = function()
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'all' })
    configure('{ refresh = { poll_ms = 50 } }')
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    child.cmd('wincmd l')
    helpers.write_file(vim.fs.joinpath(repo, 'polled.txt'), { 'new' })
    helpers.wait_until(child, S .. ':file_at("polled.txt") ~= nil')

    eq(child.api.nvim_get_current_buf(), buf)
end

T['open']['setup() without options opens the sidebar'] = function()
    child.lua([[require('iter').setup()]])

    open_status()

    local panel = child.lua_get(S .. '.panel.win')

    eq(child.lua_get(S .. '.float'), vim.NIL)
    eq(child.api.nvim_win_get_config(panel).relative, '')
    eq(child.fn.win_screenpos(panel), { 1, 1 })
    eq(
        child.api.nvim_buf_get_name(child.lua_get(S .. '.tree.buf')),
        'iter://status'
    )
end

T['open']['the drawer style still opens the float'] = function()
    configure('{ status = { style = "drawer" } }')

    child.cmd('Iter')
    helpers.wait_until(child, S .. ' ~= nil and ' .. S .. '.float ~= nil')

    eq(child.lua_get(S .. '.panel'), vim.NIL)
end

T['stage'] = new_set()

T['stage']['s stages the rest of a partly staged file, u unstages all of it'] = function()
    open_status()
    move_to('b.txt')

    child.type_keys('s')
    eq(status()['b.txt'], 'M ')
    eq(cursor_path(), 'b.txt')

    child.type_keys('u')
    eq(status()['b.txt'], ' M')
end

T['stage']['s and u act on every file below a directory'] = function()
    open_status()
    move_to('dir/')

    child.type_keys('s')
    eq(status()['dir/c.txt'], 'M ')
    eq(status()['dir/sub/d.txt'], 'M ')

    child.type_keys('u')
    eq(status()['dir/c.txt'], ' M')
    eq(status()['dir/sub/d.txt'], ' M')
end

T['stage']['d discards after a confirm, and warns on a directory'] = function()
    open_status()
    move_to('a.txt')
    child.lua('_G.answer = 1')

    child.type_keys('d')

    eq(#child.lua_get('_G.confirms'), 1)
    eq(status()['a.txt'], nil)

    move_to('dir/')
    child.type_keys('d')

    eq(child.lua_get('_G.notes'), {
        { '[iter] Works on a file, not a directory', vim.log.levels.WARN },
    })
end

T['stage']['s fires IterRefresh, then IterStage'] = function()
    open_status()
    child.lua([[
        _G.events = {}
        vim.api.nvim_create_autocmd('User', {
            pattern = { 'IterRefresh', 'IterStage' },
            callback = function(args)
                table.insert(_G.events, { args.match, args.data.paths })
            end,
        })
    ]])
    move_to('a.txt')

    child.type_keys('s')

    eq(child.lua_get('_G.events'), {
        {
            'IterRefresh',
            { 'b.txt', 'dir/sub/d.txt', 'new.txt', 'a.txt', 'dir/c.txt' },
        },
        { 'IterStage', { 'a.txt' } },
    })
end

T['tree'] = new_set()

T['tree']['<CR> on a directory closes and opens it'] = function()
    open_status()
    move_to('dir/')

    child.type_keys('<CR>')
    eq(vim.list_slice(panel_lines(), 4, 6), {
        '   ▸ dir/',
        '   ○ M a.txt                +1 −1',
        '   ◐ M b.txt                +2 −2',
    })
    eq(cursor_path(), 'dir/')

    child.type_keys('<CR>')
    eq(vim.list_slice(panel_lines(), 1, #ROWS), ROWS)
end

T['tree']['h closes the directory of a file, l opens it'] = function()
    open_status()
    move_to('dir/sub/d.txt')

    child.type_keys('h')
    eq(panel_lines()[5], '     ▸ sub/')
    eq(cursor_path(), 'dir/sub/')

    child.type_keys('l')
    eq(vim.list_slice(panel_lines(), 1, #ROWS), ROWS)
end

T['tree']['? lists the keys with collapse and expand'] = function()
    open_status()

    child.type_keys('?')

    local lines = child.lua_get(
        [[vim.tbl_map(function(line)
        return (line:gsub('%s+$', ''))
    end, vim.api.nvim_buf_get_lines(require('iter').drawer.help.buf, 0, -1, false))]]
    )

    eq(lines, {
        ' <CR>   Open the file and close the status',
        ' s      Stage or unstage the file',
        ' u      Unstage the file',
        ' d      Discard changes in the file',
        ' I      Add the untracked file to .gitignore',
        ' r      Open the review tab',
        ' =      Toggle one file or all files',
        ' |      Show the diff side by side',
        ' -      Show the diff unified',
        ' gw     Toggle wrapping long lines',
        ' q      Close',
        ' ?      Show the keys',
        ' <C-d>  Scroll the diff down',
        ' <C-u>  Scroll the diff up',
        " h      Close the directory, or the file's directory",
        ' l      Open the directory',
    })
    helpers.expect_screenshot(child, 'status-sidebar-help')
end

T['diff'] = new_set()

--- Focus the diff with the cursor on its first line.
local function focus_diff()
    child.api.nvim_set_current_win(child.lua_get(S .. '.pane'))
    child.api.nvim_win_set_cursor(0, { 1, 0 })
end

T['diff'][']c and [c move between the hunks'] = function()
    open_status()
    move_to('b.txt')
    wait_preview({ 'unstaged b.txt', 'staged b.txt' })
    focus_diff()

    local function hunk()
        return child.lua_get([[(function()
            local s = require('iter').drawer
            local section, index = s.view:at()
            local row = section.file.rows[index]
            return { section.file.side, row.kind, row.hunk }
        end)()]])
    end

    child.type_keys(']c')
    eq(hunk(), { 'unstaged', 'hunk', 1 })
    child.type_keys(']c')
    eq(hunk(), { 'staged', 'hunk', 1 })
    child.type_keys('[c')
    eq(hunk(), { 'unstaged', 'hunk', 1 })
end

T['diff']['s stages the hunk under the cursor, u unstages it'] = function()
    open_status()
    move_to('b.txt')
    wait_preview({ 'unstaged b.txt', 'staged b.txt' })
    focus_diff()

    child.type_keys(']c', 's')
    wait_preview({ 'staged b.txt' })

    eq(status()['b.txt'], 'M ')
    eq(
        helpers.git(repo, { 'diff', '--cached', '--name-only' }),
        'b.txt\ndir/c.txt\n'
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(S .. '.pane'))

    child.api.nvim_win_set_cursor(0, { 1, 0 })
    child.type_keys(']c', 'u')
    wait_preview({ 'unstaged b.txt', 'staged b.txt' })

    eq(status()['b.txt'], 'MM')
end

T['diff']['q closes the sidebar'] = function()
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    focus_diff()
    child.type_keys('q')

    eq(child.lua_get(S), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
end

T['diff']['? lists the keys of the diff'] = function()
    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    focus_diff()
    child.type_keys('?')

    local lines = child.lua_get(
        [[vim.tbl_map(function(line)
        return (line:gsub('%s+$', ''))
    end, vim.api.nvim_buf_get_lines(require('iter').drawer.help.buf, 0, -1, false))]]
    )

    eq(lines, {
        ' ]c     Next hunk',
        ' [c     Previous hunk',
        ' s      Stage the hunk or the selected lines',
        ' u      Unstage the hunk or the selected lines',
        ' <CR>   Expand the collapsed file or hidden context',
        ' gf     Go to the line in the file',
        ' =      Toggle one file or all files',
        ' |      Show the diff side by side',
        ' -      Show the diff unified',
        ' gw     Toggle wrapping long lines',
        ' <C-j>  Focus the drawer or the file tree',
        ' q      Close',
        ' ?      Show the keys',
    })
    helpers.expect_screenshot(child, 'status-sidebar-diff-help')
end

T['close'] = new_set()

T['close']['q gives the window back its buffer, options and view'] = function()
    child.cmd('edit long.txt')
    child.cmd('normal! 30Gzt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()
    local view = child.fn.winsaveview()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })

    child.type_keys('q')

    eq(child.lua_get(S), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_win(), child.lua_get('_G.pane'))
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.fn.winsaveview().topline, view.topline)
    eq(child.fn.winsaveview().lnum, view.lnum)
    eq(pane_opts(), PANE_OPTS)
    eq(child.api.nvim_win_get_width(0), 80)
end

T['close']['the split keeps its width'] = function()
    child.cmd('vsplit')
    child.cmd('vertical resize 30')
    local layout = child.fn.winrestcmd()

    open_status()
    child.type_keys('q')

    eq(child.fn.winrestcmd(), layout)
end

T['close']['<CR> on a file edits it in the window and closes'] = function()
    set_pane_opts()
    open_status()
    move_to('a.txt')

    child.type_keys('<CR>')

    eq(child.lua_get(S), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
    eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'), 'a.txt')
    eq(pane_opts(), PANE_OPTS)
end

T['close']['<CR> on an added line of the diff edits the file there'] = function()
    open_status()
    move_to('a.txt')
    wait_preview({ 'unstaged a.txt' })
    child.lua([[
        local s = require('iter').drawer
        vim.api.nvim_set_current_win(s.pane)
        for lnum = 1, vim.api.nvim_buf_line_count(s.view.buf) do
            local _, index = s.view:at(lnum)
            local row = index and s.view.files[1].rows[index]
            if row and row.kind == 'add' then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
                return
            end
        end
    ]])

    child.type_keys('<CR>')

    eq(child.lua_get(S), vim.NIL)
    eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'), 'a.txt')
    eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T['close'][':Iter closes an open sidebar'] = function()
    open_status()

    child.cmd('Iter')

    eq(child.lua_get(S), vim.NIL)
    eq(#child.api.nvim_list_wins(), 1)
end

T['close']['closing the window closes the sidebar'] = function()
    child.cmd('vsplit')
    open_status()

    child.cmd(
        'call win_execute(' .. child.lua_get(S .. '.pane') .. ', "close")'
    )
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
end

T['close']['closing the sidebar gives the window back'] = function()
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.cmd('close')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
end

T['close'][':Iter in another tab moves the sidebar there'] = function()
    open_status()
    local first = child.api.nvim_get_current_tabpage()

    child.cmd('tabnew')
    local second = child.api.nvim_get_current_tabpage()
    open_status()

    eq(child.api.nvim_get_current_tabpage(), second)
    eq(child.lua_get(S .. '.tab'), second)
    eq(#child.api.nvim_tabpage_list_wins(first), 1)
    eq(#child.api.nvim_tabpage_list_wins(second), 2)
end

T['close'][':Iter in the commits tab opens the sidebar in its origin tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    child.cmd('Iter commits')
    helpers.wait_until(child, 'require("iter").current_commits ~= nil')
    local commits = child.api.nvim_get_current_tabpage()

    open_status()

    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(child.lua_get(S .. '.tab'), origin)
    eq(child.api.nvim_tabpage_is_valid(commits), true)
end

T['close'][':tabclose of its tab closes the sidebar'] = function()
    local first = child.api.nvim_get_current_tabpage()

    child.cmd('tabnew')
    open_status()
    child.cmd('tabclose')
    helpers.wait_until(child, S .. ' == nil')

    eq(child.api.nvim_get_current_tabpage(), first)
    eq(#child.api.nvim_tabpage_list_wins(first), 1)
    eq(child.lua_get('_G.notes'), {})
    eq(child.v.errmsg, '')
end

T['close'][':Iter in the commits tab focuses the sidebar open in its origin tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    child.cmd('Iter commits')
    helpers.wait_until(child, 'require("iter").current_commits ~= nil')
    local commits = child.api.nvim_get_current_tabpage()
    child.api.nvim_set_current_tabpage(origin)
    open_status()
    child.api.nvim_set_current_tabpage(commits)

    child.cmd('Iter')

    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(child.lua_get(S .. ':is_open()'), true)
    eq(child.api.nvim_get_current_win(), child.lua_get(S .. '.panel.win'))
end

T['close']['r opens the review on the file'] = function()
    open_status()
    move_to('a.txt')

    child.type_keys('r')
    helpers.wait_until(child, 'require("iter").current_review ~= nil')

    eq(child.lua_get(S), vim.NIL)
    eq(
        child.lua_get('require("iter").current_review.tree:file().path'),
        'a.txt'
    )
end

T['address'] = new_set()

T['address']['iter://status/<path> reveals the file and keeps the sidebar open'] = function()
    open_status()

    child.lua('require("iter").open_uri("iter://status/a.txt")')
    wait_preview({ 'unstaged a.txt' })
    eq(cursor_path(), 'a.txt')

    child.lua('require("iter").open_uri("iter://status")')
    eq(child.lua_get(S .. ':is_open()'), true)
end

T['refresh'] = new_set()

T['refresh']['a poll picks up a write from outside'] = function()
    configure('{ refresh = { poll_ms = 50 } }')
    open_status()
    move_to('a.txt')
    wait_preview({ 'unstaged a.txt' })

    helpers.write_file(
        vim.fs.joinpath(repo, 'a.txt'),
        { 'one', 'two changed', 'three', 'four', 'five' }
    )
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_get_lines(require('iter').drawer.tree.buf, 7, 8, false)[1]:match('+3 −1$')]]
    )
    helpers.write_file(vim.fs.joinpath(repo, 'polled.txt'), { 'new' })
    helpers.wait_until(child, S .. ':file_at("polled.txt") ~= nil')

    eq(cursor_path(), 'a.txt')
end

T['commits'] = new_set()

--- The panel's Recent commits and hint lines, every short sha as `sha`.
---@return string[]
local function commit_lines()
    local lines = panel_lines()
    local first = assert(vim.iter(ipairs(lines)):find(function(_, line)
        return line == ' Recent commits'
    end))

    return vim.tbl_map(function(line)
        return (line:gsub('%f[%w]%x%x%x%x%x%x%x+%f[%W]', 'sha'))
    end, vim.list_slice(lines, first))
end

--- Put the cursor on the first commit, as `j` from the last file does.
local function to_commit()
    move_to('new.txt')
    child.type_keys('j')
end

--- Wait until the pane shows the summary of a commit, and return its lines.
---@return string[]
local function wait_summary()
    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_buf(' .. S .. '.pane) == ' .. S .. '.summary_buf'
    )

    return child.api.nvim_buf_get_lines(
        child.lua_get(S .. '.summary_buf'),
        0,
        -1,
        false
    )
end

T['commits']['the recent commits sit above the hints, ↑ on unpushed ones'] = function()
    local remote = helpers.create_remote(repo)
    helpers.git(repo, { 'commit', '--quiet', '--allow-empty', '-m', 'second' })

    open_status()

    eq(commit_lines(), {
        ' Recent commits',
        '   sha second            ↑ 2h',
        '   sha initial             2h',
        '',
        ' s stage  u unstage  d discard',
        ' <CR> open  r review  ? help',
    })
    helpers.expect_screenshot(child, 'status-sidebar-commits')
    helpers.cleanup(remote)
end

T['commits']['a commit under the cursor shows its summary in the window'] = function()
    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    to_commit()

    local lines = wait_summary()

    eq(lines[3], ' initial')
    eq(
        child.api.nvim_buf_get_name(child.lua_get(S .. '.summary_buf')),
        'iter://status#preview'
    )
    eq(child.lua_get(S .. '.tree:node()'), vim.NIL)
    eq(child.lua_get(S .. '.tree:extra().subject'), 'initial')
    helpers.expect_screenshot(child, 'status-sidebar-commit-summary')

    child.type_keys('k')
    wait_preview({ 'unstaged new.txt' })
end

T['commits']['q after a summary gives the window back its buffer and options'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()

    open_status()
    to_commit()
    wait_summary()
    child.type_keys('k')
    wait_preview({ 'unstaged new.txt' })
    to_commit()
    wait_summary()
    child.type_keys('q')

    eq(child.lua_get(S), vim.NIL)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(pane_opts(), PANE_OPTS)
    eq(#child.api.nvim_list_bufs(), 1)
end

T['commits']['s, u, d and I on a commit do nothing'] = function()
    open_status()
    to_commit()

    local before = status()

    child.type_keys('s', 'u', 'd', 'I')

    eq(status(), before)
    eq(child.lua_get('_G.notes'), {})
    eq(child.lua_get('_G.confirms'), {})
end

T['commits']['<CR> on a commit opens the commits tab on its files'] = function()
    open_status()
    to_commit()
    child.type_keys('<CR>')

    local C = [[require('iter').current_commits]]

    helpers.wait_until(
        child,
        C
            .. ' ~= nil and '
            .. C
            .. '.files ~= nil and '
            .. C
            .. '.previewed ~= nil'
    )
    eq(child.lua_get(S), vim.NIL)
    eq(
        child.lua_get(C .. '.opened.head'),
        vim.trim(helpers.git(repo, { 'rev-parse', 'HEAD' }))
    )
    eq(child.lua_get(C .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
end

T['commits']['r on a commit opens the review from it'] = function()
    open_status()
    to_commit()
    child.type_keys('r')

    local R = [[require('iter').current_review]]

    helpers.wait_until(
        child,
        R .. ' ~= nil and ' .. R .. '.changes.since ~= nil'
    )
    eq(child.lua_get(S), vim.NIL)
    eq(child.lua_get([[require('iter.store').load(vim.fn.getcwd()).base]]), {
        kind = 'commit',
        sha = vim.trim(helpers.git(repo, { 'rev-parse', 'HEAD' })),
    })
end

T['commits']['drawer.commits = 0 shows no commits'] = function()
    configure('{ drawer = { commits = 0 } }')

    open_status()

    local lines = panel_lines()

    eq(vim.tbl_contains(lines, ' Recent commits'), false)
    eq(vim.list_slice(lines, #lines - 1), {
        ' s stage  u unstage  d discard',
        ' <CR> open  r review  ? help',
    })
end

T['commits']['a clean tree puts the cursor on the newest commit'] = function()
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'all' })
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()

    eq(child.lua_get(S .. '.tree:extra().subject'), 'all')
    child.lua('vim.wait(300)')
    eq(child.api.nvim_win_get_buf(child.lua_get(S .. '.pane')), buf)

    child.type_keys('j')

    eq(wait_summary()[3], ' initial')
end

T['hand back'] = new_set()

--- The window options the panel sets, as the current window has them.
---@return table<string, any>
local function panel_opts()
    return child.lua_get([[{
        winhighlight = vim.wo.winhighlight,
        winfixwidth = vim.wo.winfixwidth,
        cursorline = vim.wo.cursorline,
    }]])
end

local NO_PANEL_OPTS =
    { winhighlight = '', winfixwidth = false, cursorline = false }

T['hand back'][':edit in the window closes the sidebar and keeps the file'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.api.nvim_set_current_win(child.lua_get('_G.pane'))
    child.cmd('edit b.txt')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'), 'b.txt')
    eq(pane_opts(), PANE_OPTS)
    eq(child.v.errmsg, '')
end

T['hand back'][':edit in the window over a summary closes the sidebar'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()

    open_status()
    to_commit()
    wait_summary()
    child.api.nvim_set_current_win(child.lua_get('_G.pane'))
    child.cmd('edit b.txt')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'), 'b.txt')
    eq(pane_opts(), PANE_OPTS)
    eq(child.v.errmsg, '')
end

T['hand back'][':edit in the sidebar closes it and edits the file in the window'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.cmd('edit b.txt')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_win(), child.lua_get('_G.pane'))
    eq(child.fn.fnamemodify(child.api.nvim_buf_get_name(0), ':t'), 'b.txt')
    eq(pane_opts(), PANE_OPTS)
    eq(panel_opts(), NO_PANEL_OPTS)
    eq(child.v.errmsg, '')
end

T['hand back'][':enew in the sidebar puts the tree back and leaves no buffer'] = function()
    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    local bufs = #child.api.nvim_list_bufs()

    child.cmd('enew')
    helpers.wait_until(
        child,
        'vim.api.nvim_get_current_buf() == ' .. S .. '.tree.buf'
    )

    eq(child.lua_get(S .. ':is_open()'), true)
    eq(#child.api.nvim_list_bufs(), bufs)
end

T['hand back'][':split in the window gives the new window the file'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.api.nvim_set_current_win(child.lua_get(S .. '.pane'))
    child.cmd('split')
    helpers.wait_until(child, 'vim.api.nvim_get_current_buf() == ' .. buf)
    child.lua('_G.pane = vim.api.nvim_get_current_win()')

    eq(pane_opts(), PANE_OPTS)
    eq(child.lua_get(S .. ':is_open()'), true)
    eq(
        child.api.nvim_win_get_buf(child.lua_get(S .. '.pane')),
        child.lua_get(S .. '.view.buf')
    )
end

T['hand back'][":close of the last window beside the sidebar leaves the window's buffer"] = function()
    child.cmd('edit long.txt')
    child.cmd('normal! 30Gzt')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    local panel = child.lua_get(S .. '.panel.win')

    child.cmd(
        'call win_execute(' .. child.lua_get(S .. '.pane') .. ', "close")'
    )
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_win() ~= panel, true)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.fn.winsaveview().topline, 30)
    eq(panel_opts(), NO_PANEL_OPTS)
    eq(child.v.errmsg, '')
end

T['hand back'][":only in the sidebar leaves the window's buffer"] = function()
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.cmd('only')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(panel_opts(), NO_PANEL_OPTS)
    eq(child.v.errmsg, '')
end

T['hand back']['<C-w>c in the diff closes the sidebar'] = function()
    child.cmd('edit long.txt')
    child.cmd('vsplit')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.api.nvim_set_current_win(child.lua_get(S .. '.pane'))
    child.type_keys('<C-w>c')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.v.errmsg, '')
end

T['hand back']['<C-w>c in the window over a summary closes the sidebar'] = function()
    child.cmd('edit long.txt')
    local buf = child.api.nvim_get_current_buf()

    open_status()
    to_commit()
    wait_summary()
    child.api.nvim_set_current_win(child.lua_get(S .. '.pane'))
    child.type_keys('<C-w>c')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.v.errmsg, '')
end

T['hand back'][':q in the sidebar gives the window back'] = function()
    child.cmd('edit long.txt')
    set_pane_opts()
    local buf = child.api.nvim_get_current_buf()

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    child.cmd('quit')
    helpers.wait_until(child, S .. ' == nil')

    eq(#child.api.nvim_list_wins(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(pane_opts(), PANE_OPTS)
end

T['hand back']['a restored session keeps the window and no buffer of iter'] = function()
    child.cmd('edit long.txt')
    open_status()
    to_commit()
    wait_summary()
    child.cmd('tabnew')
    child.cmd('edit a.txt')
    open_status()
    wait_preview({ 'unstaged a.txt' })
    child.type_keys('|')
    helpers.wait_until(child, S .. '.view.old ~= nil')

    local session = vim.fn.tempname()
    child.cmd('mksession! ' .. vim.fn.fnameescape(session))
    eq(
        table
            .concat(vim.fn.readfile(session), '\n')
            :find('iter://status/a.txt', 1, true) ~= nil,
        true
    )
    child.stop()
    helpers.start_child(child, repo)
    stub_ui()
    child.cmd('source ' .. vim.fn.fnameescape(session))
    child.lua('vim.wait(100)')

    eq(child.lua_get(S), vim.NIL)
    eq(
        child.lua_get([[#vim.tbl_filter(function(b)
            return vim.startswith(vim.api.nvim_buf_get_name(b), 'iter://')
        end, vim.api.nvim_list_bufs())]]),
        0
    )
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(#child.api.nvim_tabpage_list_wins(1), 1)
    eq(#child.api.nvim_tabpage_list_wins(2), 1)
    eq(child.v.errmsg, '')
    vim.fn.delete(session)
end

T['hand back']['a 50-column tab gives the sidebar half of it'] = function()
    child.o.columns = 50

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })

    eq(child.api.nvim_win_get_width(child.lua_get(S .. '.panel.win')), 25)
    helpers.expect_screenshot(child, 'status-sidebar-narrow')
end

T['hand back']['a layout switch and a window resize keep the width, an editor resize sets it'] = function()
    child.o.columns = 160

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })
    local panel = child.lua_get(S .. '.panel.win')

    child.type_keys('|')
    eq(child.api.nvim_win_get_width(panel), 34)
    child.type_keys('-')
    eq(child.api.nvim_win_get_width(panel), 34)

    child.cmd('vertical resize 40')
    child.lua('vim.wait(50)')
    eq(child.api.nvim_win_get_width(panel), 40)

    child.o.columns = 140
    child.lua('vim.wait(50)')
    eq(child.api.nvim_win_get_width(panel), 34)

    child.o.columns = 50
    child.lua('vim.wait(50)')
    eq(child.api.nvim_win_get_width(panel), 25)
end

T['hand back']['the tab line counts the windows without the sidebar'] = function()
    child.o.columns = 120
    child.o.showtabline = 2
    child.o.tabline = [[%!v:lua.require'iter'.tabline()]]
    child.cmd('tabnew')

    local function tabline()
        return child.lua_get([[(function()
            vim.cmd.redraw()
            local cells = {}
            for col = 1, vim.o.columns do
                table.insert(cells, vim.fn.screenstring(1, col))
            end
            return table.concat(cells)
        end)()]])
    end

    open_status()
    wait_preview({ 'unstaged dir/sub/d.txt' })

    eq(tabline():find(' 2 d/s/d.txt ', 1, true), nil)
    eq(tabline():find(' d/s/d.txt ', 1, true) ~= nil, true)

    to_commit()
    wait_summary()
    eq(tabline():find(' status ', 1, true) ~= nil, true)

    child.api.nvim_set_current_win(child.lua_get(S .. '.pane'))
    child.cmd('vsplit')
    eq(tabline():find(' 2 ', 1, true) ~= nil, true)
end

return T
