local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

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

--- Run `command` and wait for the review drawer.
---@param command? string
local function open_review(command)
    child.cmd(command or 'Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.win ~= nil]]
    )
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

--- The file columns of the review drawer: title and `code path` of each
--- item.
---@return { title: string, items: string[] }[]
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

--- Stub `vim.ui.select` to record its items and pick the one whose label
--- starts with `pick`.
---@param pick string
local function stub_select(pick)
    child.lua(
        [[
        local pick = ...
        _G.choices = nil
        vim.ui.select = function(items, opts, on_choice)
            _G.choices = vim.tbl_map(opts.format_item, items)
            _G.prompt = opts.prompt
            for _, item in ipairs(items) do
                if vim.startswith(opts.format_item(item), pick) then
                    return on_choice(item)
                end
            end
            on_choice(nil)
        end
    ]],
        { pick }
    )
end

--- The stored base of the review's branch.
---@return table?
local function stored_base()
    return child.lua_get([[require('iter.store').load(vim.fn.getcwd()).base]])
end

--- The review drawer's header without its highlight groups.
---@return string
local function header_text()
    return (
        child
            .lua_get('vim.wo[' .. R .. '.drawer.win].winbar')
            :gsub('%%#[%w]+#', '')
            :gsub('%%%*', '')
    )
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

T['open'][':Iter review main lists the changes since main in one column'] = function()
    open_review('Iter review main')
    wait_diff('base a.txt')

    eq(file_columns(), {
        {
            title = 'Since main',
            items = { 'M a.txt', 'M b.txt', 'A c.txt', '? d.txt' },
        },
    })
    eq(child.t.iter_label, 'iter review')
    helpers.expect_screenshot(child, 'base-review')
end

T['open']['from the wide breakpoint the column sits beside Annotations'] = function()
    child.o.columns = 180
    open_review('Iter review main')
    wait_diff('base a.txt')

    helpers.expect_screenshot(child, 'base-review-wide')
end

T['open']['in a narrow drawer the header keeps the file count'] = function()
    child.o.columns = 40
    open_review('Iter review main')
    wait_diff('base a.txt')

    local header = child
        .lua_get('vim.wo[' .. R .. '.drawer.win].winbar')
        :gsub('%%#[%w]+#', '')
        :gsub('%%%*', '')

    eq(header:find('since', 1, true), nil)
    eq(vim.trim(header):match('4 files$') ~= nil, true)
end

T['open']['without a base the review shows working changes'] = function()
    open_review()

    eq(file_columns(), {
        { title = 'Unstaged', items = { 'M b.txt', '? d.txt' } },
        { title = 'Staged', items = {} },
    })
    eq(stored_base(), vim.NIL)
end

T['open'][':Iter review on an open review switches its base'] = function()
    open_review()
    child.cmd('Iter review main')

    helpers.wait_until(child, R .. '.drawer.changes.since ~= nil')
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
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.drawer.win ~= nil')

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

    open_review('Iter review feat~1')
    wait_diff('base a.txt')

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
    open_review('Iter review main')
    wait_diff('base a.txt')
    child.type_keys('=')
    helpers.wait_until(child, R .. '.drawer.all_shown')

    eq(
        child.lua_get([[vim.tbl_map(function(section)
            return section.key
        end, ]] .. R .. [[.drawer.view.document.sections)]]),
        { 'base\0a.txt', 'base\0b.txt', 'base\0c.txt', 'base\0d.txt' }
    )
    helpers.expect_screenshot(child, 'base-all-files')
end

T['diff']['| shows the diff side by side, the base on the left'] = function()
    child.o.columns = 120
    open_review('Iter review main')
    wait_diff('base a.txt')
    child.type_keys('|')
    helpers.wait_until(child, R .. '.drawer.view.layout == "split"')

    helpers.expect_screenshot(child, 'base-split')
end

T['diff']['the footer offers b in place of the staging keys'] = function()
    open_review('Iter review main')
    wait_diff('base a.txt')

    local footer = child.lua_get([[(function()
        local text = {}
        for _, chunk in ipairs(]] .. R .. [[.drawer:footer()) do
            table.insert(text, chunk[1])
        end
        return table.concat(text)
    end)()]])

    eq(footer:find('b base', 1, true) ~= nil, true)
    eq(footer:find('stage', 1, true), nil)
    eq(footer:find('discard', 1, true), nil)
end

T['refusals'] = new_set()

T['refusals']['s, u, d and I on a base row warn and change nothing'] = function()
    setup([[{ confirm = { discard = false, ignore = false } }]])
    open_review('Iter review main')
    wait_diff('base a.txt')

    local before = index_state()

    select_item('base', 'b.txt')
    child.type_keys('s', 'u', 'd')
    select_item('base', 'd.txt')
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
    open_review('Iter review main')
    select_item('base', 'b.txt')
    wait_diff('base b.txt')

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

T['picker'] = new_set()

T['picker']['b offers the parent first, working changes, branches and commits'] = function()
    stub_select('nothing')
    open_review()
    child.type_keys('b')

    local edit = rev({ 'rev-parse', '--short', 'feat' })
    local add = rev({ 'rev-parse', '--short', 'feat~1' })
    local initial = rev({ 'rev-parse', '--short', 'feat~2' })

    eq(child.lua_get('_G.prompt'), 'Review since')
    eq(child.lua_get('_G.choices'), {
        'main (parent)',
        'Working changes',
        edit .. ' edit a',
        add .. ' add c',
        initial .. ' initial',
    })
end

T['picker']['a picked branch shows and is remembered for the branch'] = function()
    stub_select('main (parent)')
    open_review()
    child.type_keys('b')

    helpers.wait_until(child, R .. '.drawer.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since main')
    eq(child.lua_get(R .. '.drawer:selected().path'), 'a.txt')

    child.type_keys('q')
    open_review()

    eq(file_columns()[1].title, 'Since main')

    stub_select('Working changes')
    child.type_keys('b')

    helpers.wait_until(child, R .. '.drawer.changes.since == nil')
    eq(file_columns()[1].title, 'Unstaged')
    eq(stored_base(), vim.NIL)
end

T['picker']['a picked commit is part of the review'] = function()
    local edit = rev({ 'rev-parse', 'feat' })

    stub_select(edit:sub(1, 7))
    open_review()
    child.type_keys('b')

    helpers.wait_until(child, R .. '.drawer.changes.since ~= nil')
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
    stub_select('main')
    open_review()
    child.type_keys('b')

    helpers.wait_until(child, R .. '.drawer.changes.since ~= nil')
    eq(file_columns()[1].title, 'Since main')
    eq(stored_base(), vim.NIL)

    child.cmd('Iter review feat~1')
    helpers.wait_until(child, R .. '.drawer.changes.since.label == "feat~1"')
    eq(stored_base(), vim.NIL)
end

T['picker']['? lists b'] = function()
    open_review()
    child.type_keys('?')

    local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = vim.tbl_filter(function(line)
        return line:find('Pick what the review compares with', 1, true) ~= nil
    end, lines)

    eq(#found, 1)
    eq(vim.startswith(vim.trim(found[1]), 'b '), true)
end

T['reviewed'] = new_set()

--- The drawer line of the `side` item with `path`.
---@param side string
---@param path string
---@return string
local function row_line(side, path)
    return child.lua_get(
        [[(function(side, path)
            local d = require('iter').current_review.drawer
            for lnum, row in ipairs(d.rows) do
                if row[side] ~= nil and row[side].path == path then
                    return vim.api.nvim_buf_get_lines(d.buf, lnum - 1, lnum, false)[1]
                end
            end
        end)(...)]],
        { side, path }
    )
end

--- Mark the `side` item with `path` reviewed with `r`.
---@param side string
---@param path string
local function mark(side, path)
    select_item(side, path)
    child.type_keys('r')
    helpers.wait_until(
        child,
        string.format('%s.reviewed[%q] == "reviewed"', R, path)
    )
end

--- Switch the review's base through `b` to the picker item starting with
--- `pick`.
---@param pick string
---@param since boolean whether the review compares with a base afterwards
local function switch(pick, since)
    stub_select(pick)
    child.type_keys('b')
    helpers.wait_until(
        child,
        R .. '.drawer.changes.since ' .. (since and '~=' or '==') .. ' nil'
    )
end

T['reviewed']['a mark in working changes does not show since main'] = function()
    open_review()
    mark('unstaged', 'b.txt')
    eq(row_line('unstaged', 'b.txt'):find('✓', 1, true) ~= nil, true)

    switch('main (parent)', true)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'unreviewed')
    eq(row_line('base', 'b.txt'):find('○', 1, true) ~= nil, true)

    switch('Working changes', false)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'reviewed')
end

T['reviewed']['a mark since main does not show in working changes'] = function()
    open_review('Iter review main')
    mark('base', 'b.txt')
    eq(row_line('base', 'b.txt'):find('✓', 1, true) ~= nil, true)

    switch('Working changes', false)
    eq(child.lua_get(R .. '.reviewed["b.txt"]'), 'unreviewed')
    eq(row_line('unstaged', 'b.txt'):find('○', 1, true) ~= nil, true)
    eq(
        child.lua_get(
            [[vim.tbl_keys(require('iter.store').load(vim.fn.getcwd()).reviewed_by_base)]]
        ),
        { 'branch:main' }
    )

    switch('main (parent)', true)
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

    open_review()

    eq(file_columns()[1].title, 'Unstaged')
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

    open_review()

    eq(file_columns()[1].title, 'Unstaged')
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
    open_review('Iter review main')
    wait_diff('base a.txt')

    helpers.git(repo, { 'merge', '--quiet', '--no-edit', 'main' })

    local main = rev({ 'rev-parse', 'main' })

    helpers.wait_until(
        child,
        string.format('%s.drawer.changes.since.sha == %q', R, main)
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
    open_review('Iter review main')
    wait_diff('base a.txt')

    helpers.git(repo, { 'switch', '--quiet', 'other' })
    helpers.wait_until(
        child,
        string.format(
            '%s.drawer.changes.since ~= nil and %s.drawer.changes.since.label == %q',
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
            .. '.drawer.changes.since ~= nil and '
            .. R
            .. '.drawer.changes.since.label == "main"'
    )
    eq(stored_base(), { kind = 'branch', ref = 'main' })
end

T['base']['a checkout to a branch whose base is gone keeps its store'] = function()
    other_with_base({ kind = 'branch', ref = 'gone' })
    setup([[{ refresh = { poll_ms = 100 } }]])
    open_review('Iter review main')
    wait_diff('base a.txt')

    helpers.git(repo, { 'switch', '--quiet', 'other' })
    helpers.wait_until(child, R .. '.drawer.changes.since == nil')

    eq(file_columns()[1].title, 'Unstaged')
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
    open_review('Iter review main')
    wait_diff('base a.txt')

    if split then
        child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
        child.type_keys('|')
        helpers.wait_until(child, R .. '.drawer.view.old ~= nil')
        child.lua([[
            local v = require('iter').current_review.drawer.view
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
    helpers.wait_until(child, R .. '.drawer.view.marks[1] ~= nil')

    return child.lua_get([[(function()
        local v = ]] .. R .. [[.drawer.view
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

    local label = 'a.txt:3 old ' .. base:sub(1, 7) .. ' Why gone?'

    helpers.wait_until(
        child,
        string.format(
            [[(function()
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                    local buf = vim.api.nvim_win_get_buf(win)
                    local text = table.concat(
                        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
                        '\n'
                    )
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

    stub_select(edit:sub(1, 7))
    open_review()
    child.type_keys('b')
    helpers.wait_until(child, R .. '.drawer.changes.since ~= nil')
    wait_diff('base a.txt')
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

T['annotations']['Y in the drawer and in the sidebar copy the same text'] = function()
    annotate_deleted('Why gone?')
    child.lua([[
        _G.echoes = {}
        local echo = vim.api.nvim_echo
        vim.api.nvim_echo = function(chunks, ...)
            table.insert(_G.echoes, chunks[1][1])
            return echo(chunks, ...)
        end
    ]])
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.drawer.win)]])
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
