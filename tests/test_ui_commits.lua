local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local C = [[require('iter').current_commits]]
local R = [[require('iter').current_review]]

---@param args string[]
---@return string
local function rev(args)
    return vim.trim(helpers.git(repo, args))
end

--- On the initial commit adding `a.txt`: `edit a` changes its second line,
--- `add b` adds `b.txt`, `rename b` moves it to `c.txt` and has a body.
---@return string
local function create_commits_repo()
    local path = helpers.create_repo({ ['a.txt'] = { 'a1', 'a2', 'a3' } })

    helpers.write_file(vim.fs.joinpath(path, 'a.txt'), { 'a1', 'a2 new', 'a3' })
    helpers.git(path, { 'commit', '--quiet', '-am', 'edit a' })
    helpers.write_file(vim.fs.joinpath(path, 'b.txt'), { 'b1' })
    helpers.git(path, { 'add', 'b.txt' })
    helpers.git(path, { 'commit', '--quiet', '-m', 'add b' })
    helpers.git(path, { 'mv', 'b.txt', 'c.txt' })
    helpers.git(
        path,
        { 'commit', '--quiet', '-m', 'rename b', '-m', 'Move it to c.' }
    )

    return path
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_commits_repo()
            helpers.start_child(child, repo, { lines = 30, columns = 100 })
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

--- Run `:Iter commits` and wait for the tab and its first preview.
local function open_commits()
    child.cmd('Iter commits')
    helpers.wait_until(child, C .. ' ~= nil and ' .. C .. '.previewed ~= nil')
end

---@param name string
---@return string
local function sha(name)
    return rev({ 'rev-parse', name })
end

---@param name string
---@return string
local function short(name)
    return rev({ 'rev-parse', '--short', name })
end

--- The lines of the summary once the main window shows `base..head`.
---@param base string
---@param head string
---@return string[]
local function summary(base, head)
    helpers.wait_until(
        child,
        string.format('%s.previewed == %q', C, base .. '..' .. head)
    )
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf(' .. C .. '.win) == ' .. C .. '.buf'
        ),
        true
    )

    return child.api.nvim_buf_get_lines(
        child.lua_get(C .. '.buf'),
        0,
        -1,
        false
    )
end

--- The file the diff shows once it shows `path` of `base..head`.
---@param base string
---@param head string
---@param path string
---@return table
local function shown_file(base, head, path)
    helpers.wait_until(
        child,
        string.format(
            '%s.previewed == %q',
            C,
            base .. '..' .. head .. ':' .. path
        )
    )

    return child.lua_get(
        [[(function(f) return { code = f.code, path = f.path, old = f.old_lines, new = f.new_lines } end)(]]
            .. C
            .. [[.view.files[1])]]
    )
end

--- The lines of the page the panel shows, without trailing blanks, up to
--- the last non-blank line before the hints.
---@return string[]
local function page()
    local lines = child.lua_get(
        'vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf('
            .. C
            .. '.panel.win), 0, -1, false)'
    )
    local result = {}

    for _, line in ipairs(lines) do
        table.insert(result, (line:gsub('%s+$', '')))
    end

    while #result > 0 and result[#result] ~= '' do
        table.remove(result)
    end

    while #result > 0 and result[#result] == '' do
        table.remove(result)
    end

    return result
end

---@return integer
local function panel_win()
    return child.lua_get(C .. '.panel.win')
end

local function empty_tree()
    return vim.trim(
        vim.fn.system({ 'git', 'hash-object', '-t', 'tree', '/dev/null' })
    )
end

T['commits'] = new_set()

T['commits'][':Iter commits opens a tab with the list and the summary'] = function()
    open_commits()

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(C .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(child.t.iter_label, 'iter commits')
    eq(#child.api.nvim_tabpage_list_wins(0), 2)
    eq(child.api.nvim_get_current_win(), panel_win())
    eq(page(), {
        ' Commits main · last 4',
        '',
        '   ' .. short('HEAD') .. ' rename b',
        '   ' .. short('HEAD~1') .. ' add b',
        '   ' .. short('HEAD~2') .. ' edit a',
        '   ' .. short('HEAD~3') .. ' initial',
    })
    eq(child.api.nvim_win_get_cursor(panel_win()), { 3, 0 })
    summary(sha('HEAD~1'), sha('HEAD'))
    helpers.expect_screenshot(child, 'commits-list')
end

T['commits']['the summary shows the message and the files of the commit'] = function()
    open_commits()

    eq(summary(sha('HEAD~1'), sha('HEAD')), {
        ' ' .. short('HEAD') .. '  2026-01-01 00:00  Iter Test',
        '',
        ' rename b',
        '',
        ' Move it to c.',
        '',
        ' 1 file  +0 −0',
        ' +0 −0  b.txt → c.txt',
    })

    child.type_keys('j')

    eq(summary(sha('HEAD~2'), sha('HEAD~1')), {
        ' ' .. short('HEAD~1') .. '  2026-01-01 00:00  Iter Test',
        '',
        ' add b',
        '',
        ' 1 file  +1 −0',
        ' +1 −0  b.txt',
    })
end

T['commits']['the cursor stays on the commits'] = function()
    open_commits()
    child.type_keys('gg')

    eq(child.api.nvim_win_get_cursor(panel_win()), { 3, 0 })

    child.type_keys('G')

    eq(child.api.nvim_win_get_cursor(panel_win()), { 6, 0 })

    local lines = summary(empty_tree(), sha('HEAD~3'))

    eq(lines[#lines], ' +3 −0  a.txt')
end

T['commits']['q closes the tab and goes back to the tab it came from'] = function()
    child.cmd('edit a.txt')

    local buf = child.api.nvim_get_current_buf()

    open_commits()
    child.type_keys('q')

    eq(child.lua_get(C), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 1)
    eq(child.api.nvim_get_current_buf(), buf)
end

T['commits']['closing the main window closes the tab'] = function()
    open_commits()
    child.lua('vim.api.nvim_win_close(' .. C .. '.win, true)')
    helpers.wait_until(child, C .. ' == nil')

    eq(#child.api.nvim_list_tabpages(), 1)
end

T['commits']['closing the list window closes the tab'] = function()
    open_commits()
    child.cmd('close')
    helpers.wait_until(child, C .. ' == nil')

    eq(#child.api.nvim_list_tabpages(), 1)
end

T['commits'][':edit of a file in the list window opens it in the tab it came from'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    open_commits()
    child.cmd('edit a.txt')
    helpers.wait_until(
        child,
        'vim.api.nvim_get_current_tabpage() == ' .. origin
    )

    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'a.txt')
    eq(child.lua_get(C .. ':is_open()'), true)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. C
                .. '.panel.win) == '
                .. C
                .. '.list.buf'
        ),
        true
    )
end

T['commits'][':edit of a file in the main window opens it in the tab it came from'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    open_commits()
    child.lua('vim.api.nvim_set_current_win(' .. C .. '.win)')
    child.cmd('edit a.txt')
    helpers.wait_until(
        child,
        'vim.api.nvim_get_current_tabpage() == ' .. origin
    )

    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'a.txt')
    summary(sha('HEAD~1'), sha('HEAD'))

    child.cmd('Iter commits')
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'c.txt')
    child.lua('vim.api.nvim_set_current_win(' .. C .. '.win)')
    child.cmd('edit a.txt')
    helpers.wait_until(
        child,
        'vim.api.nvim_get_current_tabpage() == ' .. origin
    )

    eq(child.lua_get(C .. '.view:is_shown()'), true)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. C
                .. '.panel.win) == '
                .. C
                .. '.files.buf'
        ),
        true
    )
end

T['commits'][':Iter commits switches to the open tab'] = function()
    open_commits()
    child.cmd('tabprevious')
    child.cmd('Iter commits')

    eq(child.lua_get(C .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    eq(child.api.nvim_get_current_win(), panel_win())
    eq(#child.api.nvim_list_tabpages(), 2)
end

T['commits']['? lists the keys'] = function()
    open_commits()
    child.type_keys('?')

    local text =
        table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')

    for _, desc in ipairs({
        "Open the commit's files, the selection's, or go to the diff",
        'Review from the commit, or the oldest selected one',
        "Close the directory, or the file's directory",
        'Back to the commits, or close',
    }) do
        eq({ desc, text:find(desc, 1, true) ~= nil }, { desc, true })
    end
end

T['enter'] = new_set()

T['enter']['iter.commits({ sha }) opens the tab on the commit and its files'] = function()
    child.lua('require("iter").commits({ sha = ... })', { sha('HEAD~2') })

    shown_file(sha('HEAD~3'), sha('HEAD~2'), 'a.txt')
    eq(page(), {
        ' Commits ‹ ' .. short('HEAD~2'),
        ' edit a',
        ' 1 file · +1 −1',
        '',
        '   M a.txt                     ±2',
    })
    eq(child.api.nvim_get_current_win(), panel_win())
    helpers.expect_screenshot(child, 'commits-entered')

    child.type_keys('q')

    eq(child.api.nvim_win_get_cursor(panel_win()), { 5, 0 })
end

T['enter']['an open tab goes back to the list and enters the commit'] = function()
    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'c.txt')
    child.cmd('tabprevious')

    child.lua('require("iter").commits({ sha = ... })', { short('HEAD~1') })

    eq(child.lua_get(C .. '.tab == vim.api.nvim_get_current_tabpage()'), true)
    shown_file(sha('HEAD~2'), sha('HEAD~1'), 'b.txt')
    eq(page()[1], ' Commits ‹ ' .. short('HEAD~1'))
end

T['enter']['a commit not in the list warns and shows the list'] = function()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
    ]])
    child.lua('require("iter").commits({ sha = ... })', { string.rep('0', 40) })
    summary(sha('HEAD~1'), sha('HEAD'))

    eq(child.lua_get(C .. '.files'), vim.NIL)
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] 0000000 is not among the last 100 commits',
            vim.log.levels.WARN,
        },
    })
end

T['range'] = new_set()

T['range']['V sums up the selected commits as one change'] = function()
    open_commits()
    child.type_keys('j', 'V', 'j')

    eq(summary(sha('HEAD~3'), sha('HEAD~1')), {
        ' ' .. short('HEAD~1') .. '  2026-01-01 00:00  Iter Test',
        '',
        ' add b',
        '',
        ' ' .. short('HEAD~2') .. '  2026-01-01 00:00  Iter Test',
        '',
        ' edit a',
        '',
        ' 2 files  +2 −1',
        ' +1 −1  a.txt',
        ' +1 −0  b.txt',
    })
    eq(
        page()[2],
        ' 2 selected · ' .. short('HEAD~2') .. '..' .. short('HEAD~1')
    )
    eq(child.fn.mode(), 'V')
    eq(child.fn.line('v'), 4)
    helpers.expect_screenshot(child, 'commits-range')

    -- Visual mode ends with the cursor on the last row it moved to.
    child.type_keys('<Esc>')

    summary(sha('HEAD~3'), sha('HEAD~2'))
    eq(page()[2], '')
end

T['files'] = new_set()

T['files']["<CR> shows the commit's files as a tree with line counts"] = function()
    open_commits()
    child.type_keys('jj')
    summary(sha('HEAD~3'), sha('HEAD~2'))
    child.type_keys('<CR>')

    eq(shown_file(sha('HEAD~3'), sha('HEAD~2'), 'a.txt'), {
        code = 'M',
        path = 'a.txt',
        old = { 'a1', 'a2', 'a3' },
        new = { 'a1', 'a2 new', 'a3' },
    })
    eq(page(), {
        ' Commits ‹ ' .. short('HEAD~2'),
        ' edit a',
        ' 1 file · +1 −1',
        '',
        '   M a.txt                     ±2',
    })
    eq(child.api.nvim_get_current_win(), panel_win())
    eq(child.lua_get('vim.wo[' .. C .. '.win].linebreak'), false)
    eq(child.lua_get('vim.wo[' .. C .. '.win].wrap'), false)
    helpers.expect_screenshot(child, 'commits-files')
end

T['files']['<CR> on a selection lists the files of its commits'] = function()
    open_commits()
    child.type_keys('j', 'V', 'j', '<CR>')

    local base, head = sha('HEAD~3'), sha('HEAD~1')

    eq(shown_file(base, head, 'a.txt').code, 'M')
    eq(child.fn.mode(), 'n')
    eq(page(), {
        ' Commits ‹ ' .. short('HEAD~2') .. '..' .. short('HEAD~1'),
        ' 2 commits',
        ' 2 files · +2 −1',
        '',
        '   M a.txt                     ±2',
        '   A b.txt                     +1',
    })

    child.type_keys('j')

    eq(shown_file(base, head, 'b.txt'), {
        code = 'A',
        path = 'b.txt',
        old = {},
        new = { 'b1' },
    })
end

T['files']['<CR> goes to the diff, <C-j> back, and it never stages'] = function()
    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'c.txt')
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_win(), child.lua_get(C .. '.win'))

    local maps = child.lua_get([[vim.tbl_map(function(m)
        return m.lhs
    end, vim.api.nvim_buf_get_keymap(0, 'n'))]])

    eq(vim.tbl_contains(maps, 's'), false)
    eq(vim.tbl_contains(maps, 'a'), false)

    child.type_keys('<C-j>')

    eq(child.api.nvim_get_current_win(), panel_win())
end

T['files']['q goes back to the commit it opened, q again closes'] = function()
    open_commits()
    child.type_keys('j', '<CR>')
    shown_file(sha('HEAD~2'), sha('HEAD~1'), 'b.txt')
    child.type_keys('q')

    eq(child.lua_get(C .. '.files'), vim.NIL)
    eq(child.api.nvim_win_get_cursor(panel_win()), { 4, 0 })
    eq(page()[1], ' Commits main · last 4')
    summary(sha('HEAD~2'), sha('HEAD~1'))

    child.type_keys('q')

    eq(child.lua_get(C), vim.NIL)
end

T['files']['a long subject is cut by display cells'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a1' })
    helpers.git(repo, { 'commit', '--quiet', '-am', string.rep('漢字', 12) })

    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'a.txt')

    local subject = page()[2]

    eq(vim.fn.strdisplaywidth(subject) <= 34, true)
    eq(vim.endswith(subject, '…'), true)
end

T['files']['h and l close and open a directory'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'd', 'e.txt'), { 'e1' })
    helpers.write_file(vim.fs.joinpath(repo, 'd', 'f.txt'), { 'f1', 'f2' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a1' })
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'add d' })

    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'd/e.txt')

    local rows = {
        '   ▾ d/',
        '     A e.txt                   +1',
        '     A f.txt                   +2',
        '   M a.txt                     −2',
    }

    eq(vim.list_slice(page(), 5), rows)

    child.type_keys('h')

    eq(vim.list_slice(page(), 5), {
        '   ▸ d/',
        '   M a.txt                     −2',
    })

    child.type_keys('l')

    eq(vim.list_slice(page(), 5)[2], '     A e.txt                   +1')

    child.type_keys('h', '<CR>')

    eq(#page(), 8)
end

T['files']['in the split layout the tree stays at the left edge'] = function()
    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'c.txt')
    child.type_keys('|')
    helpers.wait_until(child, C .. '.view.old ~= nil')

    eq(child.api.nvim_win_get_position(panel_win())[2], 0)
    eq(child.api.nvim_win_get_width(panel_win()), 34)
    eq(#child.api.nvim_tabpage_list_wins(0), 3)
end

T['files']['a resize keeps the split panes even'] = function()
    child.o.columns = 200
    open_commits()
    child.type_keys('<CR>', '|')
    helpers.wait_until(child, C .. '.view.old ~= nil')

    child.o.columns = 100
    helpers.wait_until(
        child,
        string.format(
            [[math.abs(vim.api.nvim_win_get_width(%s.view.old.win)
                - vim.api.nvim_win_get_width(%s.view.win)) <= 1]],
            C,
            C
        )
    )
    eq(child.api.nvim_win_get_width(panel_win()), 34)
end

T['files']["under 'auto' a resize switches the layout"] = function()
    child.lua([[require('iter').setup({ diff = { layout = 'auto' } })]])
    child.o.columns = 200
    open_commits()
    child.type_keys('<CR>')
    helpers.wait_until(child, C .. '.view.old ~= nil')

    child.o.columns = 100
    helpers.wait_until(child, C .. '.view.old == nil')
    eq(child.lua_get(C .. '.view.layout'), 'unified')
end

T['review'] = new_set()

--- The base title of the review's tree and its files as `code path`.
---@return table
local function file_columns()
    return child.lua_get([[(function()
        local r = ]] .. R .. [[
        local items = {}
        for _, item in ipairs(r:files()) do
            table.insert(items, item.code .. ' ' .. item.path)
        end
        local subtitle = vim.api.nvim_buf_get_lines(r.tree.buf, 1, 2, false)[1]
        return { { title = (vim.trim(subtitle):gsub(' · .*$', '')), items = items } }
    end)()]])
end

--- Wait for the review to compare with a base, then return the stored one.
---@return table
local function reviewed_base()
    helpers.wait_until(
        child,
        R .. ' ~= nil and ' .. R .. '.changes.since ~= nil'
    )

    return child.lua_get([[require('iter.store').load(vim.fn.getcwd()).base]])
end

T['review']['r reviews from the commit up to the worktree'] = function()
    open_commits()
    child.type_keys('j')
    summary(sha('HEAD~2'), sha('HEAD~1'))
    child.type_keys('r')

    local add = sha('HEAD~1')

    eq(reviewed_base(), { kind = 'commit', sha = add })
    eq(child.lua_get(C), vim.NIL)
    eq(#child.api.nvim_list_tabpages(), 2)
    eq(file_columns(), {
        { title = 'From ' .. add:sub(1, 7), items = { 'A c.txt' } },
    })
end

T['review']['r on a selection reviews from its oldest commit'] = function()
    open_commits()
    child.type_keys('V', 'j')
    summary(sha('HEAD~2'), sha('HEAD'))
    child.type_keys('r')

    eq(reviewed_base(), { kind = 'commit', sha = sha('HEAD~1') })
    eq(child.fn.mode(), 'n')
end

T['review']['r among the files reviews from the oldest opened commit'] = function()
    open_commits()
    child.type_keys('j', 'V', 'j', '<CR>')
    shown_file(sha('HEAD~3'), sha('HEAD~1'), 'a.txt')
    child.type_keys('r')

    eq(reviewed_base(), { kind = 'commit', sha = sha('HEAD~2') })
end

return T
