local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local C = [[require('iter').commits_drawer]]
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

--- Run `:Iter commits` and wait for the drawer and its first preview.
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

--- The lines of the summary once it shows `base..head`.
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
            'vim.api.nvim_win_get_buf('
                .. C
                .. '.pane) == '
                .. C
                .. '.summary_buf'
        ),
        true
    )

    return child.api.nvim_buf_get_lines(
        child.lua_get(C .. '.summary_buf'),
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

--- The drawer's lines, trimmed.
---@return string[]
local function rows()
    return vim.tbl_map(
        vim.trim,
        child.api.nvim_buf_get_lines(child.lua_get(C .. '.buf'), 0, -1, false)
    )
end

--- The drawer's header without its highlight groups.
---@return string
local function header()
    return (
        child
            .lua_get('vim.wo[' .. C .. '.win].winbar')
            :gsub('%%#[%w]+#', '')
            :gsub('%%%*', '')
    )
end

local function empty_tree()
    return vim.trim(
        vim.fn.system({ 'git', 'hash-object', '-t', 'tree', '/dev/null' })
    )
end

T['commits'] = new_set()

T['commits'][':Iter commits lists the commits newest first'] = function()
    open_commits()

    eq(
        vim.tbl_map(function(line)
            return line:sub(10)
        end, rows()),
        {
            '2026-01-01 00:00  Iter Test  rename b  Move it to c.',
            '2026-01-01 00:00  Iter Test  add b',
            '2026-01-01 00:00  Iter Test  edit a',
            '2026-01-01 00:00  Iter Test  initial',
        }
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(C .. '.win'))
    summary(sha('HEAD~1'), sha('HEAD'))
    helpers.expect_screenshot(child, 'commits-drawer')
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

T['commits']['the root commit sums up its files as added'] = function()
    open_commits()
    child.type_keys('G')

    local lines = summary(empty_tree(), sha('HEAD~3'))

    eq(lines[#lines], ' +3 −0  a.txt')
end

T['commits']['q closes and gives the pane its buffer and options back'] = function()
    child.cmd('edit a.txt')
    child.wo.number = true

    local buf = child.api.nvim_get_current_buf()

    open_commits()

    eq(child.wo.number, false)

    child.type_keys('q')

    eq(child.lua_get(C), vim.NIL)
    eq(child.api.nvim_get_current_buf(), buf)
    eq(child.wo.number, true)
end

T['commits']['? lists the keys'] = function()
    open_commits()
    child.type_keys('?')

    local text =
        table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), '\n')

    for _, desc in ipairs({
        "Open the commit's files, the selection's, or go to the diff",
        'Review from the commit, or the oldest selected one',
        'Back to the commits, or close',
    }) do
        eq({ desc, text:find(desc, 1, true) ~= nil }, { desc, true })
    end
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
    eq(header():find('2 selected', 1, true) ~= nil, true)
    helpers.expect_screenshot(child, 'commits-range')

    -- Visual mode ends with the cursor on the last row it moved to.
    child.type_keys('<Esc>')

    summary(sha('HEAD~3'), sha('HEAD~2'))
end

T['files'] = new_set()

T['files']['<CR> lists the files of the commit and shows the first'] = function()
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
    eq(rows(), { 'M a.txt' })
    eq(header(), ' ' .. short('HEAD~2') .. ' edit a · 1 file')
    eq(child.api.nvim_get_current_win(), child.lua_get(C .. '.win'))
    helpers.expect_screenshot(child, 'commits-files')
end

T['files']['<CR> on a selection lists the files of its commits'] = function()
    open_commits()
    child.type_keys('j', 'V', 'j', '<CR>')

    local base, head = sha('HEAD~3'), sha('HEAD~1')

    eq(shown_file(base, head, 'a.txt').code, 'M')
    eq(child.fn.mode(), 'n')
    eq(rows(), { 'M a.txt', 'A b.txt' })
    eq(
        header(),
        ' 2 commits '
            .. short('HEAD~2')
            .. '..'
            .. short('HEAD~1')
            .. ' · 2 files'
    )

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

    eq(child.api.nvim_get_current_win(), child.lua_get(C .. '.view.win'))

    local maps = child.lua_get([[vim.tbl_map(function(m)
        return m.lhs
    end, vim.api.nvim_buf_get_keymap(0, 'n'))]])

    eq(vim.tbl_contains(maps, 's'), false)
    eq(vim.tbl_contains(maps, 'a'), false)

    child.type_keys('<C-j>')

    eq(child.api.nvim_get_current_win(), child.lua_get(C .. '.win'))
end

T['files']['q goes back to the commit it opened, q again closes'] = function()
    open_commits()
    child.type_keys('j', '<CR>')
    shown_file(sha('HEAD~2'), sha('HEAD~1'), 'b.txt')
    child.type_keys('q')

    eq(child.lua_get(C .. '.level'), 'commits')
    eq(child.api.nvim_win_get_cursor(child.lua_get(C .. '.win')), { 2, 0 })
    summary(sha('HEAD~2'), sha('HEAD~1'))

    child.type_keys('q')

    eq(child.lua_get(C), vim.NIL)
end

T['files']['in the split layout the drawer covers both sides'] = function()
    open_commits()
    child.type_keys('<CR>')
    shown_file(sha('HEAD~1'), sha('HEAD'), 'c.txt')
    child.type_keys('|')
    helpers.wait_until(child, C .. '.view.old ~= nil')
    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_position(' .. C .. '.win)[2] == 0'
    )

    eq(
        child.lua_get('vim.api.nvim_win_get_width(' .. C .. '.win)'),
        child.o.columns
    )
end

T['review'] = new_set()

--- The review drawer's file column titles and items.
---@return table
local function file_columns()
    return child.lua_get([[(function()
        local result = {}
        for _, column in ipairs(]] .. R .. [[.drawer:columns()) do
            local items = {}
            for _, item in ipairs(column.items) do
                table.insert(items, item.code .. ' ' .. item.path)
            end
            table.insert(result, { title = column.title, items = items })
        end
        return result
    end)()]])
end

--- Wait for the review to compare with a base, then return the stored one.
---@return table
local function reviewed_base()
    helpers.wait_until(
        child,
        R .. ' ~= nil and ' .. R .. '.drawer.changes.since ~= nil'
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
