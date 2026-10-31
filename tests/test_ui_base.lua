local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

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

---@param args string[]
---@return string
local function rev(args)
    return vim.trim(helpers.git(repo, args))
end

--- On `feat`, branched from `main`: a commit adding `c.txt`, then one
--- editing `a.txt`; a commit on `main` after the fork adds `main.txt`.
--- Uncommitted on `feat`: `b.txt` edited, `d.txt` untracked.
---@return string
local function create_base_repo()
    local path = helpers.create_repo({
        ['a.txt'] = numbered('a', 1, 30),
        ['b.txt'] = numbered('b', 1, 10),
    })

    helpers.git(path, { 'switch', '--quiet', '-c', 'feat' })
    helpers.write_file(vim.fs.joinpath(path, 'c.txt'), { 'c1', 'c2' })
    helpers.git(path, { 'add', 'c.txt' })
    helpers.git(path, { 'commit', '--quiet', '-m', 'add c' })

    local a = numbered('a', 1, 30)
    a[3] = 'a3 changed'
    helpers.write_file(vim.fs.joinpath(path, 'a.txt'), a)
    helpers.git(path, { 'commit', '--quiet', '-am', 'edit a' })

    helpers.git(path, { 'switch', '--quiet', 'main' })
    helpers.write_file(vim.fs.joinpath(path, 'main.txt'), { 'main only' })
    helpers.git(path, { 'add', 'main.txt' })
    helpers.git(path, { 'commit', '--quiet', '-m', 'on main' })
    helpers.git(path, { 'switch', '--quiet', 'feat' })

    local b = numbered('b', 1, 10)
    b[2] = 'b2 changed'
    helpers.write_file(vim.fs.joinpath(path, 'b.txt'), b)
    helpers.write_file(vim.fs.joinpath(path, 'd.txt'), { 'd' })

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

--- What the review's tree lists: the subtitle's words and `code path` of
--- each change in tree order.
---@return { title: string, items: string[] }[]
local function file_columns()
    return child.lua_get([[(function()
        local r = ]] .. R .. [[
        local items = {}
        for _, item in ipairs(r:files()) do
            table.insert(items, item.code .. ' ' .. item.path)
        end
        local subtitle = vim.api.nvim_buf_get_lines(r.tree.buf, 1, 2, false)[1]
        return { { title = vim.trim(subtitle):gsub(' · .*$', ''), items = items } }
    end)()]])
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

--- The items of the open base list, their runs of blanks squeezed.
---@return string[]
local function picker_items()
    helpers.wait_until(
        child,
        R .. '.picker ~= nil and ' .. R .. '.panel.page == ' .. R .. '.picker'
    )

    return child.lua_get([[(function()
        local page = require('iter').current_review.picker
        local lines = vim.api.nvim_buf_get_lines(page.buf, 0, -1, false)
        local out = {}
        for lnum, index in pairs(page.indexes) do
            out[index] = vim.trim((lines[lnum]:gsub('%s+', ' ')))
        end
        return out
    end)()]])
end

--- Open the base list with `b` and pick the item that starts with `label`.
---@param label string
local function pick(label)
    child.type_keys('b')

    for index, item in ipairs(picker_items()) do
        if vim.startswith(item, label) then
            child.lua(
                R
                    .. '.panel:set_cursor('
                    .. R
                    .. '.picker:line_of('
                    .. index
                    .. '))'
            )
            child.type_keys('<CR>')
            return
        end
    end

    error('no picker item ' .. label)
end

--- The stored base of the review's branch.
---@return table?
local function stored_base()
    return child.lua_get([[require('iter.store').load(vim.fn.getcwd()).base]])
end

--- The tree's title line, with a blank after it.
---@return string
local function header_text()
    return vim.trim(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.tree.buf, 0, 1, false)[1]'
        )
    ) .. ' '
end

--- What `git` says about the index and `b.txt`, to tell any write.
---@return table
local function index_state()
    return {
        tree = rev({ 'write-tree' }),
        files = rev({ 'ls-files', '-s' }),
        b = vim.fn.readblob(vim.fs.joinpath(repo, 'b.txt')),
        a = vim.fn.readblob(vim.fs.joinpath(repo, 'a.txt')),
        d = vim.fn.readblob(vim.fs.joinpath(repo, 'd.txt')),
        gitignore = vim.uv.fs_stat(vim.fs.joinpath(repo, '.gitignore')) ~= nil,
    }
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_base_repo()
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

T['open'][':Iter review main lists the changes since main without staging icons'] = function()
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    eq(file_columns(), {
        {
            title = 'Since main',
            items = { 'M a.txt', 'M b.txt', 'A c.txt', '? d.txt' },
        },
    })
    eq(child.t.iter_label, 'iter review')
    eq(header_text():find('Review since main (', 1, true) ~= nil, true)
    eq(
        vim.trim(
            child.lua_get(
                'vim.api.nvim_buf_get_lines('
                    .. R
                    .. '.tree.buf, 4, 5, false)[1]'
            )
        ),
        'M a.txt'
    )
    helpers.expect_screenshot(child, 'base-review')
end

T['open']['below the breakpoint at 180 columns the annotations sit below the tree'] = function()
    setup([[{ annotate = { review_breakpoint = 1000 } }]])
    child.o.columns = 180
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    helpers.expect_screenshot(child, 'base-review-wide')
end

T['open']['the subtitle names the base and counts the files'] = function()
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    eq(
        vim.trim(
            child.lua_get(
                'vim.api.nvim_buf_get_lines('
                    .. R
                    .. '.tree.buf, 1, 2, false)[1]'
            )
        ),
        'Since main · 4 files'
    )
end

T['open']['without a base the review shows working changes'] = function()
    H.open(child)

    eq(file_columns(), {
        { title = 'Working changes', items = { 'M b.txt', '? d.txt' } },
    })
    eq(stored_base(), vim.NIL)
end

T['open'][':Iter review on an open review switches its base'] = function()
    H.open(child)
    child.cmd('Iter review main')

    helpers.wait_until(child, R .. '.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since main')
    eq(stored_base(), { kind = 'branch', ref = 'main' })
end

T['open'][':Iter review with an unknown ref errors and opens nothing'] = function()
    child.cmd('Iter review nope')

    eq(child.lua_get(R .. ' == nil'), true)
    eq(
        child.lua_get('_G.notes'),
        { { '[iter] Unknown ref nope', vim.log.levels.ERROR } }
    )
end

T['open'][':Iter review completes branch names'] = function()
    eq(child.fn.getcompletion('Iter review ', 'cmdline'), { 'feat', 'main' })
    eq(child.fn.getcompletion('Iter review m', 'cmdline'), { 'main' })
end

T['open']['iter.review() takes a typed commit as the base and starts after it'] = function()
    local edit = rev({ 'rev-parse', 'feat' })

    child.lua([[require('iter').review({ base = ... })]], { edit })
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.panel ~= nil')

    eq(file_columns(), {
        {
            title = 'Since ' .. edit:sub(1, 7),
            items = { 'M b.txt', '? d.txt' },
        },
    })
    eq(stored_base(), { kind = 'rev', ref = edit, sha = edit })
    eq(
        header_text():find('since ' .. edit:sub(1, 7) .. ' ', 1, true) ~= nil,
        true
    )
end

T['open'][':Iter review with a typed ref names it in the header'] = function()
    local add = rev({ 'rev-parse', 'feat~1' })

    H.open(child, 'Iter review feat~1')
    H.wait_diff(child, 'base a.txt')

    eq(file_columns(), {
        { title = 'Since feat~1', items = { 'M a.txt', 'M b.txt', '? d.txt' } },
    })
    eq(
        header_text():find('since feat~1 (' .. add:sub(1, 7) .. ')', 1, true)
            ~= nil,
        true
    )
    eq(stored_base(), { kind = 'rev', ref = 'feat~1', sha = add })
end

T['open'][':Iter review with two refs errors'] = function()
    local ok, err = pcall(child.cmd, 'Iter review main feat')

    eq(ok, false)
    eq(
        tostring(err):find('Too many arguments for review', 1, true) ~= nil,
        true
    )
    eq(child.lua_get(R .. ' == nil'), true)
end

T['diff'] = new_set()

T['diff']['= shows every file since the base in one scroll'] = function()
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')
    child.type_keys('=')
    helpers.wait_until(child, R .. '.preview.all_shown')

    eq(
        child.lua_get([[vim.tbl_map(function(section)
            return section.key
        end, ]] .. R .. [[.view.document.sections)]]),
        { 'base\0a.txt', 'base\0b.txt', 'base\0c.txt', 'base\0d.txt' }
    )
    helpers.expect_screenshot(child, 'base-all-files')
end

T['diff']['| shows the diff side by side, the base on the left'] = function()
    child.o.columns = 120
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.view.layout == "split"')

    helpers.expect_screenshot(child, 'base-split')
end

T['diff']['the tree hints offer b in place of the staging keys'] = function()
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    local footer = child.lua_get(
        'table.concat(vim.api.nvim_buf_get_lines('
            .. R
            .. '.tree.buf, -3, -1, false), " ")'
    )

    eq(footer:find('b base', 1, true) ~= nil, true)
    eq(footer:find('stage', 1, true), nil)
    eq(footer:find('discard', 1, true), nil)
end

T['refusals'] = new_set()

T['refusals']['s, u, d and I on a base row warn and change nothing'] = function()
    setup([[{ confirm = { discard = false, ignore = false } }]])
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    local before = index_state()

    H.select(child, 'base', 'b.txt')
    child.type_keys('s', 'u', 'd')
    H.select(child, 'base', 'd.txt')
    child.type_keys('d', 'I')

    eq(child.lua_get('_G.notes'), {
        { '[iter] Staging does not apply against a base', vim.log.levels.WARN },
        {
            '[iter] Unstaging does not apply against a base',
            vim.log.levels.WARN,
        },
        { '[iter] Discard does not apply against a base', vim.log.levels.WARN },
        { '[iter] Discard does not apply against a base', vim.log.levels.WARN },
        {
            '[iter] Ignoring does not apply against a base',
            vim.log.levels.WARN,
        },
    })
    eq(index_state(), before)
end

T['refusals']['hunk and line staging in the diff warn and change nothing'] = function()
    H.open(child, 'Iter review main')
    H.select(child, 'base', 'b.txt')
    H.wait_diff(child, 'base b.txt')

    local before = index_state()

    cursor_on('b2 changed')
    child.type_keys('s')
    child.type_keys('u')
    child.type_keys('V', 'k', 's')
    eq(child.fn.mode(), 'n')
    child.type_keys('V', 'u')
    eq(child.fn.mode(), 'n')

    eq(child.lua_get('_G.notes'), {
        { '[iter] Staging does not apply against a base', vim.log.levels.WARN },
        {
            '[iter] Unstaging does not apply against a base',
            vim.log.levels.WARN,
        },
        { '[iter] Staging does not apply against a base', vim.log.levels.WARN },
        {
            '[iter] Unstaging does not apply against a base',
            vim.log.levels.WARN,
        },
    })
    eq(index_state(), before)
end

--- Wait until the diff window shows the base summary whose first line
--- starts with `title`, and return its lines without trailing blanks.
---@param title string
---@return string[]
local function summary_lines(title)
    helpers.wait_until(
        child,
        string.format(
            '%s.summary_buf ~= nil and vim.api.nvim_win_get_buf(%s.diff_win) == %s.summary_buf and vim.startswith(vim.api.nvim_buf_get_lines(%s.summary_buf, 0, 1, false)[1], %q)',
            R,
            R,
            R,
            R,
            ' ' .. title
        )
    )

    return vim.tbl_map(
        function(line)
            return (line:gsub('%s+$', ''))
        end,
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.summary_buf, 0, -1, false)'
        )
    )
end

--- Put the base list's cursor on the item that starts with `label`.
---@param label string
local function move_to(label)
    for index, item in ipairs(picker_items()) do
        if vim.startswith(item, label) then
            child.lua(
                R
                    .. '.panel:set_cursor('
                    .. R
                    .. '.picker:line_of('
                    .. index
                    .. '))'
            )
            return
        end
    end

    error('no picker item ' .. label)
end

-- The diff window's options the base summary changes.
local WINOPTS = [[(function()
    local win = require('iter').current_review.diff_win
    local out = {}
    for _, name in ipairs({ 'number', 'wrap', 'linebreak', 'breakindent', 'cursorline', 'list', 'spell', 'signcolumn', 'statuscolumn' }) do
        out[name] = vim.api.nvim_get_option_value(name, { scope = 'local', win = win })
    end
    return out
end)()]]

T['picker'] = new_set()

T['picker']['b offers the parent first, working changes, branches and commits'] = function()
    H.open(child)
    child.type_keys('b')

    local items = picker_items()
    local edit = rev({ 'rev-parse', '--short', 'feat' })
    local add = rev({ 'rev-parse', '--short', 'feat~1' })
    local initial = rev({ 'rev-parse', '--short', 'feat~2' })

    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. R .. '.picker.buf, 0, 2, false)'
        ),
        { ' Base of the review', ' / search' }
    )
    eq(items, {
        'since main parent',
        'Working changes',
        edit .. ' edit a',
        add .. ' add c',
        initial .. ' initial',
    })
    eq(child.lua_get([[require('iter').statusline()]]), 'review · base · 1/5')
end

--- The section titles of the open base list, by the item they sit above,
--- each checked to be a line of the list.
---@return table<string, string>
local function picker_sections()
    return child.lua_get([[(function()
        local page = require('iter').current_review.picker
        local lines = vim.api.nvim_buf_get_lines(page.buf, 0, -1, false)
        local titles = {}
        for index, title in pairs(page.opts.sections) do
            local lnum = page:line_of(index)
            if vim.trim(lines[lnum - 1]) == title then
                titles[tostring(index)] = title
            end
        end
        return titles
    end)()]])
end

T['picker']['sections title the branches and the commits'] = function()
    helpers.git(repo, { 'branch', 'other', 'main' })
    H.open(child)
    child.type_keys('b')

    eq(picker_items()[3], 'other')
    eq(picker_sections(), { ['3'] = 'Branches', ['4'] = 'Commits' })
end

T['picker']['on the default branch the upstream merge base follows working changes'] = function()
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    helpers.create_remote(repo)
    helpers.write_file(vim.fs.joinpath(repo, 'main.txt'), { 'main changed' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'unpushed' })

    local pushed = rev({ 'rev-parse', '--short', 'origin/main' })

    H.open(child)
    child.type_keys('b')

    local items = picker_items()

    eq(items[1], 'Working changes')
    eq(items[2], 'since origin/main upstream')
    eq(vim.tbl_contains(items, 'main'), false)
    eq(pushed ~= '', true)

    pick('since origin/main')
    helpers.wait_until(child, R .. '.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since origin/main')
    eq(file_columns()[1].items, { 'M b.txt', '? d.txt', 'M main.txt' })
end

T['picker']['b shows the list in the tree window, q goes back without a change'] = function()
    H.open(child)
    child.type_keys('b')
    picker_items()

    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. H.LIST_WIN
                .. ') == '
                .. R
                .. '.picker.buf'
        ),
        true
    )
    summary_lines('since main')
    helpers.expect_screenshot(child, 'base-picker')

    child.type_keys('q')

    eq(child.lua_get(R .. '.picker'), vim.NIL)
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
    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))
    eq(file_columns()[1].title, 'Working changes')
end

T['picker'][':edit of a file in the list window opens it in the first tab and keeps the list'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    child.type_keys('b')
    picker_items()

    child.cmd('edit d.txt')
    child.lua('vim.wait(100)')

    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. H.LIST_WIN
                .. ') == '
                .. R
                .. '.picker.buf'
        ),
        true
    )
    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'd.txt')
end

T['picker']['the list stays when another window takes the focus'] = function()
    H.open(child)
    child.type_keys('b')
    picker_items()
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.lua('vim.wait(50)')

    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. H.LIST_WIN
                .. ') == '
                .. R
                .. '.picker.buf'
        ),
        true
    )
end

T['picker']['a refresh keeps the picker open and focused, the summary read again'] = function()
    setup([[{ refresh = { poll_ms = 100 } }]])
    H.open(child)
    child.type_keys('b')
    picker_items()

    local win = child.lua_get(H.LIST_WIN)

    helpers.write_file(vim.fs.joinpath(repo, 'e.txt'), { 'new' })
    helpers.wait_until(
        child,
        'vim.iter('
            .. R
            .. ':files()):any(function(f) return f.path == "e.txt" end)'
    )

    eq(child.lua_get(R .. '.panel.page == ' .. R .. '.picker'), true)
    eq(child.api.nvim_get_current_win(), win)
    local lines = summary_lines('since main')

    eq(lines[#lines], ' + 2 untracked')
end

T['picker']['a picked branch shows and is remembered for the branch'] = function()
    H.open(child)
    pick('since main')

    helpers.wait_until(child, R .. '.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since main')
    eq(H.selected(child), 'a.txt')

    child.type_keys('q')
    H.open(child)

    eq(file_columns()[1].title, 'Since main')

    pick('Working changes')

    helpers.wait_until(child, R .. '.changes.since == nil')
    eq(file_columns()[1].title, 'Working changes')
    eq(stored_base(), vim.NIL)
end

T['picker']['a picked commit is part of the review'] = function()
    local edit = rev({ 'rev-parse', 'feat' })

    H.open(child)
    pick(edit:sub(1, 7))

    helpers.wait_until(child, R .. '.changes.since ~= nil')
    eq(file_columns(), {
        {
            title = 'From ' .. edit:sub(1, 7),
            items = { 'M a.txt', 'M b.txt', '? d.txt' },
        },
    })
    eq(
        header_text():find('from ' .. edit:sub(1, 7) .. ' ', 1, true) ~= nil,
        true
    )
    eq(stored_base(), { kind = 'commit', sha = edit })
end

T['picker']['on a detached HEAD a pick applies to the open review only'] = function()
    helpers.git(repo, { 'switch', '--quiet', '--detach' })
    H.open(child)
    pick('since main')

    helpers.wait_until(child, R .. '.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since main')
    eq(stored_base(), vim.NIL)

    child.cmd('Iter review feat~1')
    helpers.wait_until(child, R .. '.changes.since.label == "feat~1"')
    eq(stored_base(), vim.NIL)
end

T['picker']['the diff window previews the base under the cursor'] = function()
    H.open(child)
    child.type_keys('b')

    local merge = rev({ 'merge-base', 'HEAD', 'main' }):sub(1, 7)
    local edit = rev({ 'rev-parse', '--short', 'feat' })
    local add = rev({ 'rev-parse', '--short', 'feat~1' })
    local lines = summary_lines('since main')

    eq(
        lines[1]:gsub('%s+', ' '),
        ' since main (' .. merge .. ') 2 commits · 4 files'
    )
    eq(vim.list_slice(lines, 2, #lines), {
        ' Committed on feat since it left main',
        '',
        ' ' .. edit .. ' edit a',
        ' ' .. add .. ' add c',
        ' + working changes in 2 files',
        '',
        ' +1 −1  a.txt',
        ' +1 −1  b.txt',
        ' +2 −0  c.txt',
        ' + 1 untracked',
    })
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.summary_buf)'),
        'iter://review#base#preview'
    )
    eq(
        child.lua_get('vim.api.nvim_buf_get_name(' .. R .. '.picker.buf)'),
        'iter://review#base'
    )

    move_to('Working changes')

    local working = summary_lines('Working changes')

    working[1] = working[1]:gsub('%s+', ' ')
    eq(working, {
        ' Working changes 2 files',
        '',
        ' +1 −1  b.txt',
        ' + 1 untracked',
    })

    move_to(edit)

    local preview = summary_lines('from ' .. edit)

    eq(preview[#preview - 1], ' +1 −1  b.txt')
    helpers.expect_screenshot(child, 'base-preview-commit')
end

T['picker']['q and <CR> give the diff window its diff and options back'] = function()
    H.open(child)
    H.wait_diff(child, 'unstaged b.txt')

    local before = child.lua_get(WINOPTS)

    child.type_keys('b')
    summary_lines('since main')
    eq(child.lua_get(WINOPTS .. '.wrap'), true)
    eq(child.lua_get(WINOPTS .. '.number'), false)
    eq(
        child.lua_get('require("iter.ui.sidebar").of(' .. R .. '.tab) ~= nil'),
        true
    )

    child.type_keys('q')

    eq(child.lua_get(R .. '.summary_buf'), vim.NIL)
    eq(child.lua_get(R .. '.view:is_shown()'), true)
    eq(child.lua_get(WINOPTS), before)

    child.type_keys('b')
    summary_lines('since main')
    child.type_keys('<CR>')
    helpers.wait_until(child, R .. '.changes.since ~= nil')

    eq(child.lua_get(R .. '.view:is_shown()'), true)
    eq(child.lua_get(WINOPTS), before)
    eq(
        child.lua_get('require("iter.ui.sidebar").of(' .. R .. '.tab) ~= nil'),
        true
    )
end

T['picker'][':edit of a file in the diff window keeps the summary'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    H.open(child)
    child.type_keys('b')
    summary_lines('since main')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.cmd('edit d.txt')
    child.lua('vim.wait(100)')

    eq(child.api.nvim_get_current_tabpage(), origin)
    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'd.txt')
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. R
                .. '.diff_win) == '
                .. R
                .. '.summary_buf'
        ),
        true
    )
end

T['picker'][':edit iter://review#base opens the base list'] = function()
    child.cmd('edit ' .. vim.fn.fnameescape('iter://review#base'))
    picker_items()
    summary_lines('since main')

    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))

    child.cmd('edit')
    child.cmd('edit ' .. vim.fn.fnameescape('iter://review#base'))

    eq(#picker_items(), 5)
    eq(child.api.nvim_get_current_win(), child.lua_get(H.LIST_WIN))
    eq(child.lua_get('_G.notes'), {})
end

T['picker']['a resize keeps the summary and fits it to the new width'] = function()
    setup([[{ diff = { layout = 'auto' } }]])
    H.open(child)
    child.type_keys('b')
    summary_lines('since main')
    child.o.columns = 200
    -- The annotations window moves on a scheduled callback and WinResized
    -- follows the next redraw, which `vim.wait` doesn't make.
    child.lua('vim.wait(100)')
    helpers.wait_until(
        child,
        'vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines('
            .. R
            .. '.summary_buf, 0, 1, false)[1]) == vim.api.nvim_win_get_width('
            .. R
            .. '.diff_win)'
    )

    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. R
                .. '.diff_win) == '
                .. R
                .. '.summary_buf'
        ),
        true
    )
    eq(
        child.lua_get('vim.api.nvim_win_get_width(' .. R .. '.diff_win)') > 80,
        true
    )
end

T['picker']['a base that cannot be read shows a line saying so'] = function()
    helpers.git(repo, { 'branch', 'other', 'main' })
    H.open(child)
    child.type_keys('b')
    summary_lines('since main')
    helpers.git(repo, { 'branch', '--quiet', '-D', 'other' })
    move_to('other')

    eq(summary_lines('Cannot read this base'), { ' Cannot read this base' })
    eq(#child.lua_get('_G.notes'), 1)
end

T['picker']['before the first commit Working changes lists the files as additions'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    helpers.git(repo, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'a1', 'a2' })
    helpers.git(repo, { 'add', 'a.txt' })
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
    helpers.start_child(child, repo)
    stub_ui()
    H.open(child)
    child.type_keys('b')

    local lines = summary_lines('Working changes')

    eq(vim.list_slice(lines, 2, #lines), {
        '',
        ' +2 −0  a.txt',
        ' + 1 untracked',
    })
    eq(child.lua_get('_G.notes'), {})
end

T['picker']['? lists b'] = function()
    H.open(child)
    child.type_keys('?')

    local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = vim.tbl_filter(function(line)
        return line:find('Pick what the review compares with', 1, true) ~= nil
    end, lines)

    eq(#found, 1)
    eq(vim.startswith(vim.trim(found[1]), 'b '), true)
end

T['reviewed'] = new_set()

--- The tree's row of `path`; `_` is the side the row was on in other
--- layouts.
---@param _ string
---@param path string
---@return string
local function row_line(_, path)
    return child.lua_get(
        [[(function(path)
            local r = require('iter').current_review
            for lnum, row in pairs(r.tree.items) do
                if row.node.path == path then
                    return vim.api.nvim_buf_get_lines(r.tree.buf, lnum - 1, lnum, false)[1]
                end
            end
        end)(...)]],
        { path }
    )
end

--- Mark the `side` item with `path` reviewed with `r`.
---@param side string
---@param path string
local function mark(side, path)
    H.select(child, side, path)
    child.type_keys('r')
    helpers.wait_until(
        child,
        string.format('%s.reviewed[%q] == "reviewed"', R, path)
    )
end

--- Switch the review's base through `b` to the picker item starting with
--- `label`.
---@param label string
---@param since boolean whether the review compares with a base afterwards
local function switch(label, since)
    pick(label)
    helpers.wait_until(
        child,
        R .. '.changes.since ' .. (since and '~=' or '==') .. ' nil'
    )
end

T['reviewed']['a mark in working changes does not show since main'] = function()
    H.open(child)
    mark('unstaged', 'b.txt')
    eq(row_line('unstaged', 'b.txt'):find('✓', 1, true) ~= nil, true)

    switch('since main', true)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'unreviewed')
    eq(row_line('base', 'b.txt'):find('✓', 1, true), nil)

    switch('Working changes', false)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'reviewed')
end

T['reviewed']['a mark since main does not show in working changes'] = function()
    H.open(child, 'Iter review main')
    mark('base', 'b.txt')
    eq(row_line('base', 'b.txt'):find('✓', 1, true) ~= nil, true)

    switch('Working changes', false)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'unreviewed')
    eq(row_line('unstaged', 'b.txt'):find('✓', 1, true), nil)
    eq(
        child.lua_get(
            [[vim.tbl_keys(require('iter.store').load(vim.fn.getcwd()).reviewed_by_base)]]
        ),
        { 'branch:main' }
    )

    switch('since main', true)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'reviewed')
end

T['base'] = new_set()

T['base']['a remembered branch that is gone falls back to working changes'] = function()
    helpers.git(repo, { 'branch', 'old', 'main' })
    child.lua(
        [[require('iter.store').set_base(vim.fn.getcwd(), ...)]],
        { { kind = 'branch', ref = 'old' } }
    )
    helpers.git(repo, { 'branch', '-D', 'old' })

    H.open(child)

    eq(file_columns()[1].title, 'Working changes')
    eq(#child.lua_get('_G.notes'), 1)
    eq(
        vim.startswith(
            child.lua_get('_G.notes[1][1]'),
            '[iter] Cannot compare with old'
        ),
        true
    )
    eq(stored_base(), vim.NIL)
end

T['base']['a remembered commit no longer in the history of HEAD falls back to working changes'] = function()
    local edit = rev({ 'rev-parse', 'feat' })

    child.lua(
        [[require('iter.store').set_base(vim.fn.getcwd(), ...)]],
        { { kind = 'commit', sha = edit } }
    )
    helpers.git(repo, { 'commit', '--quiet', '--amend', '-m', 'edit a again' })

    H.open(child)

    eq(file_columns()[1].title, 'Working changes')
    eq(child.lua_get('_G.notes'), {
        {
            '[iter] Cannot compare with '
                .. edit:sub(1, 7)
                .. ' (Not in the history of HEAD); showing working changes',
            vim.log.levels.WARN,
        },
    })
    eq(stored_base(), vim.NIL)
end

T['base']['a refresh resolves the base again'] = function()
    setup([[{ refresh = { poll_ms = 100 } }]])
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    helpers.git(repo, { 'merge', '--quiet', '--no-edit', 'main' })

    local main = rev({ 'rev-parse', 'main' })

    helpers.wait_until(
        child,
        string.format('%s.changes.since.sha == %q', R, main)
    )
    eq(file_columns()[1].items, { 'M a.txt', 'M b.txt', 'A c.txt', '? d.txt' })
end

--- Create `other` from `main` and store `spec` as its base.
---@param spec table
local function other_with_base(spec)
    helpers.git(repo, { 'branch', 'other', 'main' })
    helpers.git(repo, { 'switch', '--quiet', 'other' })
    child.lua(
        [[require('iter.store').set_base(vim.fn.getcwd(), ...)]],
        { spec }
    )
    helpers.git(repo, { 'switch', '--quiet', 'feat' })
end

T['base']['a checkout switches to the base the new branch remembers'] = function()
    local main = rev({ 'rev-parse', 'main' })

    other_with_base({ kind = 'commit', sha = main })
    setup([[{ refresh = { poll_ms = 100 } }]])
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    helpers.git(repo, { 'switch', '--quiet', 'other' })
    helpers.wait_until(
        child,
        string.format(
            '%s.changes.since ~= nil and %s.changes.since.label == %q',
            R,
            R,
            main:sub(1, 7)
        )
    )

    eq(file_columns()[1].items, { 'M b.txt', '? d.txt', 'A main.txt' })
    eq(stored_base(), { kind = 'commit', sha = main })

    helpers.git(repo, { 'switch', '--quiet', 'feat' })
    helpers.wait_until(
        child,
        R
            .. '.changes.since ~= nil and '
            .. R
            .. '.changes.since.label == "main"'
    )
    eq(stored_base(), { kind = 'branch', ref = 'main' })
end

T['base']['a checkout to a branch whose base is gone keeps its store'] = function()
    other_with_base({ kind = 'branch', ref = 'gone' })
    setup([[{ refresh = { poll_ms = 100 } }]])
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    helpers.git(repo, { 'switch', '--quiet', 'other' })
    helpers.wait_until(child, R .. '.changes.since == nil')

    eq(file_columns()[1].title, 'Working changes')
    eq(
        vim.startswith(
            child.lua_get('_G.notes[#_G.notes][1]'),
            '[iter] Cannot compare with gone'
        ),
        true
    )
    eq(stored_base(), { kind = 'branch', ref = 'gone' })
end

T['annotations'] = new_set()

--- Annotate the deleted line `a3` of `a.txt` since main with `body`, in the
--- left window of the split layout when `split`. Returns the stored anchor.
---@param body string
---@param split? boolean
---@return table
local function annotate_deleted(body, split)
    child.o.columns = 120
    H.open(child, 'Iter review main')
    H.wait_diff(child, 'base a.txt')

    if split then
        child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
        child.type_keys('|')
        helpers.wait_until(child, R .. '.view.old ~= nil')
        child.lua([[
            local v = require('iter').current_review.view
            vim.api.nvim_set_current_win(v.old.win)
            for lnum, line in ipairs(
                vim.api.nvim_buf_get_lines(v.old.buf, 0, -1, false)
            ) do
                if line == 'a3' then
                    vim.api.nvim_win_set_cursor(v.old.win, { lnum, 0 })
                    return
                end
            end
            error('no line a3')
        ]])
    else
        cursor_on('a3')
    end

    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys(body, '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 1')

    return child.lua_get(R .. '.annotations[1].anchor')
end

--- The mark of the only annotation in the diff view, with the kind of the
--- row it sits on in the old version's pane.
---@return table
local function deleted_mark()
    helpers.wait_until(child, R .. '.view.marks[1] ~= nil')

    return child.lua_get([[(function()
        local v = ]] .. R .. [[.view
        local mark = v.marks[1]
        local rows = v.old and v.old.rows or v.rows
        local row = rows[mark.lnum]
        return {
            kind = row.kind,
            text = row.text,
            outdated = mark.outdated,
            field = mark.span and mark.span.field or vim.NIL,
        }
    end)()]])
end

T['annotations']['while the base list shows, the annotations window leaves the diff window alone'] = function()
    annotate_deleted('note')
    child.lua(R .. ':focus_tree()')
    child.type_keys('b')
    summary_lines('since main')
    child.lua(R .. ':focus_annotations()')

    local win = child.api.nvim_get_current_win()

    child.type_keys('gg', 'G', '<CR>')
    child.lua('vim.wait(100)')

    eq(child.api.nvim_get_current_win(), win)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_buf('
                .. R
                .. '.diff_win) == '
                .. R
                .. '.summary_buf'
        ),
        true
    )
end

T['annotations']['a deleted line since main keeps the merge-base and sits on its del row'] = function()
    local base = rev({ 'merge-base', 'HEAD', 'main' })

    eq(annotate_deleted('Why gone?'), {
        path = 'a.txt',
        side = 'old',
        base = base,
        start_line = 3,
        end_line = 3,
        lines = { 'a3' },
    })
    eq(
        deleted_mark(),
        { kind = 'del', text = 'a3', outdated = false, field = 'old' }
    )
    eq(child.lua_get('_G.notes'), {})

    -- The annotations window's row, its runs of blanks squeezed.
    local label = '3 old ' .. base:sub(1, 7) .. ' Why gone?'

    helpers.wait_until(
        child,
        string.format(
            [[(function()
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                    local buf = vim.api.nvim_win_get_buf(win)
                    local text = table.concat(
                        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                        '\n'
                    ):gsub('[ \t]+', ' ')
                    if text:find(%q, 1, true) then
                        return true
                    end
                end
                return false
            end)()]],
            label
        )
    )
end

T['annotations']['in the split layout it sits on the del row of the left window'] = function()
    local base = rev({ 'merge-base', 'HEAD', 'main' })

    eq(annotate_deleted('Why gone?', true).base, base)
    eq(
        deleted_mark(),
        { kind = 'del', text = 'a3', outdated = false, field = 'old' }
    )
end

T['annotations']['a deleted line from a picked commit keeps its parent and sits on its del row'] = function()
    local edit = rev({ 'rev-parse', 'feat' })

    H.open(child)
    pick(edit:sub(1, 7))
    helpers.wait_until(child, R .. '.changes.since ~= nil')
    H.wait_diff(child, 'base a.txt')
    cursor_on('a3')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Why gone?', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 1')

    eq(
        child.lua_get(R .. '.annotations[1].anchor.base'),
        rev({ 'rev-parse', 'feat^' })
    )
    eq(
        deleted_mark(),
        { kind = 'del', text = 'a3', outdated = false, field = 'old' }
    )
end

T['annotations']['Y in the tree and in the sidebar copy the same text'] = function()
    annotate_deleted('Why gone?')
    child.lua([[
        _G.echoes = {}
        local echo = vim.api.nvim_echo
        vim.api.nvim_echo = function(chunks, ...)
            table.insert(_G.echoes, chunks[1][1])
            return echo(chunks, ...)
        end
    ]])
    H.focus_list(child)
    child.type_keys('Y', 'n')
    helpers.wait_until(child, [[#_G.echoes == 1 and vim.fn.mode() == 'n']])

    local from_drawer = child.fn.getreg('"')

    child.fn.setreg('"', '')
    child.cmd('Iter annotate')
    helpers.wait_until(
        child,
        [[vim.startswith(vim.api.nvim_buf_get_name(0), 'iter://annotate/')]]
    )
    child.type_keys('Y', 'n')
    helpers.wait_until(child, [[#_G.echoes == 2 and vim.fn.mode() == 'n']])

    eq(child.fn.getreg('"'), from_drawer)
    local base = rev({ 'merge-base', 'HEAD', 'main' }):sub(1, 7)

    eq(vim.split(from_drawer, '\n')[4], 'Reviewed since main (' .. base .. ')')
    eq(
        from_drawer:find('a.txt:3 (old side, ' .. base .. ')', 1, true) ~= nil,
        true
    )
end

return T
