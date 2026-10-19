local helpers = dofile('tests/helpers.lua')
local git = require('iter.git')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local original_cwd
---@type string
local repo

---@param path string
---@return GitStatusEntry?
local function entry(path)
    for _, e in ipairs(git.status_snapshot(repo).entries) do
        if e.path == path then
            return e
        end
    end
end

---@param path string
---@param lines string[]
local function write(path, lines)
    helpers.write_file(vim.fs.joinpath(repo, path), lines)
end

local T = new_set({
    hooks = {
        pre_case = function()
            original_cwd = vim.fn.getcwd()
            repo = helpers.create_repo({ ['tracked.txt'] = { 'one' } })
            vim.cmd.cd(vim.fn.fnameescape(repo))
        end,
        post_case = function()
            vim.cmd.cd(vim.fn.fnameescape(original_cwd))
            helpers.cleanup(repo)
        end,
    },
})

T['status_snapshot()'] = new_set()

T['status_snapshot()']['is safe outside a git repository'] = function()
    local not_repo = vim.fn.tempname()
    vim.fn.mkdir(not_repo, 'p')
    vim.cmd.cd(vim.fn.fnameescape(not_repo))

    local snapshot = git.status_snapshot()
    helpers.cleanup(not_repo)

    eq(snapshot.root, '')
    eq(snapshot.branch, '')
    eq(snapshot.entries, {})
    eq(snapshot.error, 'Not inside a git repository')
end

T['status_snapshot()']['collects branch, root and porcelain entries'] = function()
    write('tracked.txt', { 'one', 'two' })
    write('staged.txt', { 'staged' })
    write('untracked.txt', { 'untracked' })
    helpers.git(repo, { 'add', 'staged.txt' })

    local snapshot = git.status_snapshot()

    eq(vim.fn.resolve(snapshot.root), repo)
    eq(snapshot.branch, 'main')
    eq(snapshot.error, nil)
    eq(
        entry('tracked.txt'),
        { staged = ' ', unstaged = 'M', path = 'tracked.txt' }
    )
    eq(
        entry('staged.txt'),
        { staged = 'A', unstaged = ' ', path = 'staged.txt' }
    )
    eq(
        entry('untracked.txt'),
        { staged = '?', unstaged = '?', path = 'untracked.txt' }
    )
end

T['status_snapshot()']['reports every fixture state'] = function()
    local fixture = helpers.create_fixture_repo()
    vim.cmd.cd(vim.fn.fnameescape(fixture))

    local states = {}
    for _, e in ipairs(git.status_snapshot().entries) do
        states[e.path] = e.staged .. e.unstaged
    end
    helpers.cleanup(fixture)

    eq(states, {
        ['deleted.txt'] = ' D',
        ['modified.txt'] = ' M',
        ['staged.txt'] = 'M ',
        ['untracked.txt'] = '??',
        ['untracked_dir/a.txt'] = '??',
        ['untracked_dir/b.txt'] = '??',
    })
end

T['stage(), unstage(), discard() and delete_untracked()'] = function()
    write('tracked.txt', { 'changed' })
    write('untracked.txt', { 'untracked' })

    eq(git.stage(repo, { 'tracked.txt' }), true)
    eq(entry('tracked.txt').staged, 'M')

    eq(git.unstage(repo, { 'tracked.txt' }), true)
    eq(entry('tracked.txt').staged, ' ')

    eq(git.discard(repo, { 'tracked.txt' }), true)
    eq(entry('tracked.txt'), nil)

    eq(git.delete_untracked(repo, { 'untracked.txt' }), true)
    eq(entry('untracked.txt'), nil)
end

T['path actions treat paths literally'] = function()
    write('a.txt', { 'a' })
    write('[ab].txt', { 'glob' })
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'more' })
    write('a.txt', { 'a changed' })
    write('[ab].txt', { 'glob changed' })
    write('*.log', { 'star' })
    write('x.log', { 'x' })

    eq(git.stage(repo, { '[ab].txt' }), true)
    eq(entry('a.txt').staged, ' ')
    eq(git.unstage(repo, { '[ab].txt' }), true)

    eq(git.discard(repo, { '[ab].txt' }), true)
    eq(entry('[ab].txt'), nil)
    eq(entry('a.txt').unstaged, 'M')

    eq(git.delete_untracked(repo, { '*.log' }), true)
    eq(entry('*.log'), nil)
    eq(entry('x.log').staged, '?')
end

T['ahead()'] = new_set()

T['ahead()']['is nil without an upstream'] = function()
    eq(git.ahead(repo), nil)
end

T['ahead()']['counts commits ahead of the upstream'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    eq(git.ahead(repo), 0)

    write('tracked.txt', { 'one', 'two' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'second' })
    eq(git.ahead(repo), 1)
    eq(git.status_snapshot().ahead, 1)
end

T['status_snapshot()']['lists each untracked file, not ignored ones'] = function()
    write('.gitignore', { '*.log' })
    helpers.git(repo, { 'add', '.gitignore' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'ignore' })
    write('dir/a.txt', { 'a' })
    write('dir/sub/b.txt', { 'b' })
    write('dir/skip.log', { 'x' })

    local paths = vim.tbl_map(function(e)
        return e.path
    end, git.status_snapshot().entries)

    table.sort(paths)
    eq(paths, { 'dir/a.txt', 'dir/sub/b.txt' })
end

T['status_snapshot()']['lists a nested repository as one directory row'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'nested', 'a.txt'), { 'a' })
    helpers.git(vim.fs.joinpath(repo, 'nested'), { 'init', '--quiet' })

    eq(entry('nested/'), { staged = '?', unstaged = '?', path = 'nested/' })
    eq(entry('nested/a.txt'), nil)
end

T['status_snapshot()']['flags a detached HEAD'] = function()
    eq(git.status_snapshot().detached, false)

    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    eq(git.status_snapshot().detached, true)
end

T['status_snapshot()']['reads the ahead count with one rev-list'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    local run = git.run
    local history = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    git.run = function(args, opts)
        if args[1] == 'rev-list' or args[1] == 'log' then
            table.insert(history, args[1])
        end
        return run(args, opts)
    end

    local ok, snapshot = pcall(git.status_snapshot)
    git.run = run

    eq(ok, true)
    eq(snapshot.ahead, 0)
    eq(history, { 'rev-list' })
end

---@type string?
local remote

T['recent()'] = new_set({
    hooks = {
        post_case = function()
            helpers.cleanup(remote)
            remote = nil
        end,
    },
})

---@param message string
local function commit(message)
    helpers.git(repo, { 'commit', '--quiet', '--allow-empty', '-m', message })
end

--- `↑`/`  ` mark and subject of each commit.
---@param recent GitRecent
---@return string[]
local function rows(recent)
    return vim.tbl_map(function(c)
        return (c.unpushed and '↑ ' or '  ') .. c.subject
    end, recent.commits)
end

---@return string
local function with_remote()
    remote = helpers.create_remote(repo)
    return remote
end

T['recent()']['without an upstream: commits, no markers, no counts'] = function()
    commit('second')
    local recent = assert(git.recent(repo, 3))

    eq(recent.upstream, nil)
    eq({ recent.ahead, recent.behind }, { 0, 0 })
    eq(rows(recent), { '  second', '  initial' })
    eq(recent.commits[1].time, 1767225600)
    eq(#recent.commits[1].sha >= 7, true)
end

T['recent()']['ahead only marks the unpushed commits'] = function()
    with_remote()
    commit('second')
    commit('third')
    local recent = assert(git.recent(repo, 3))

    eq(recent.upstream, 'origin/main')
    eq({ recent.ahead, recent.behind }, { 2, 0 })
    eq(rows(recent), { '↑ third', '↑ second', '  initial' })
end

T['recent()']['behind only counts the fetched upstream commits'] = function()
    helpers.push_from_clone(with_remote(), 'theirs')
    eq(assert(git.recent(repo, 3)).behind, 0)

    helpers.git(repo, { 'fetch', '--quiet' })
    local recent = assert(git.recent(repo, 3))

    eq({ recent.ahead, recent.behind }, { 0, 1 })
    eq(rows(recent), { '  initial' })
end

T['recent()']['ahead and behind at once'] = function()
    helpers.push_from_clone(with_remote(), 'theirs')
    helpers.git(repo, { 'fetch', '--quiet' })
    commit('mine')
    local recent = assert(git.recent(repo, 3))

    eq({ recent.ahead, recent.behind }, { 1, 1 })
    eq(rows(recent), { '↑ mine', '  initial' })
end

T['recent()']['keeps the count of commits, 0 lists none'] = function()
    with_remote()
    commit('second')
    commit('third')

    eq(rows(assert(git.recent(repo, 1))), { '↑ third' })

    local none = assert(git.recent(repo, 0))
    eq(none.commits, {})
    eq(none.ahead, 2)
end

T['recent()']['is nil on an unborn HEAD'] = function()
    local unborn = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(unborn, 'p')
    helpers.git(unborn, { 'init', '--quiet', '-b', 'main' })

    eq(git.recent(unborn, 3), nil)
    helpers.cleanup(unborn)
end

T['recent()']['a detached HEAD lists commits without an upstream'] = function()
    with_remote()
    commit('second')
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    local recent = assert(git.recent(repo, 3))

    eq(recent.upstream, nil)
    eq(rows(recent), { '  second', '  initial' })
end

T['recent()']['reuses prev after one rev-parse while nothing moved'] = function()
    with_remote()
    commit('second')
    local run = git.run
    local history = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    git.run = function(args, opts)
        table.insert(history, args[1])
        return run(args, opts)
    end

    local ok, first, second, third = pcall(function()
        local a = git.recent(repo, 3)
        local b = git.recent(repo, 3, a)
        commit('third')
        return a, b, git.recent(repo, 3, b)
    end)
    git.run = run

    eq(ok, true)
    eq(second == first, true)
    eq(third == second, false)
    eq(history, {
        'rev-parse',
        'rev-list',
        'log',
        'rev-parse',
        'rev-parse',
        'rev-list',
        'log',
    })
end

T['status_snapshot()']['leaves ahead out on request'] = function()
    helpers.git(repo, { 'branch', 'base' })
    helpers.git(repo, { 'branch', '--set-upstream-to=base' })
    commit('second')

    eq(git.status_snapshot(repo).ahead, 1)
    eq(git.status_snapshot(repo, { ahead = false }).ahead, nil)
end

T['git_paths()'] = new_set()

T['git_paths()']['are absolute in a normal repository'] = function()
    eq(
        git.git_paths(repo, { 'index', 'HEAD' }),
        { repo .. '/.git/index', repo .. '/.git/HEAD' }
    )
end

T['git_paths()']['point into the common dir in a linked worktree'] = function()
    local worktree = repo .. '-wt'
    helpers.git(repo, { 'worktree', 'add', '--quiet', '-b', 'feat', worktree })

    local paths = git.git_paths(worktree, { 'index', 'HEAD' })
    helpers.cleanup(worktree)

    local dir = repo .. '/.git/worktrees/' .. vim.fs.basename(worktree)
    eq(paths, { dir .. '/index', dir .. '/HEAD' })
end

T['git_paths()']['is nil outside a repository'] = function()
    local not_repo = vim.fn.tempname()
    vim.fn.mkdir(not_repo, 'p')

    local paths = git.git_paths(not_repo, { 'index' })
    helpers.cleanup(not_repo)

    eq(paths, nil)
end

T['diff_ids()'] = new_set()

T['diff_ids()']['keys each side of a changed file by side and path'] = function()
    write('tracked.txt', { 'one', 'two' })
    git.stage(repo, { 'tracked.txt' })
    write('tracked.txt', { 'one', 'two', 'three' })
    write('new.txt', { 'new' })

    local ids = assert(git.diff_ids(repo))
    local keys = vim.tbl_keys(ids)
    table.sort(keys)

    eq(keys, { 'staged\0tracked.txt', 'unstaged\0tracked.txt' })

    local index = vim.trim(helpers.git(repo, { 'rev-parse', ':tracked.txt' }))

    eq(ids['staged\0tracked.txt']:find(index, 1, true) ~= nil, true)
    eq(ids['unstaged\0tracked.txt']:find(index, 1, true) ~= nil, true)
end

T['diff_ids()']['an index change changes the entry, a worktree edit does not'] = function()
    write('tracked.txt', { 'one', 'two' })

    local before = assert(git.diff_ids(repo))['unstaged\0tracked.txt']

    write('tracked.txt', { 'one', 'two', 'three' })
    eq(assert(git.diff_ids(repo))['unstaged\0tracked.txt'], before)

    helpers.git(repo, { 'add', 'tracked.txt' })
    write('tracked.txt', { 'one' })
    eq(assert(git.diff_ids(repo))['unstaged\0tracked.txt'] ~= before, true)
end

T['diff_ids()']['keys a staged rename by its new path'] = function()
    helpers.git(repo, { 'mv', 'tracked.txt', 'moved.txt' })

    local ids = assert(git.diff_ids(repo))

    eq(vim.tbl_keys(ids), { 'staged\0moved.txt' })
    eq(ids['staged\0moved.txt']:find('tracked.txt', 1, true) ~= nil, true)
end

T['run()'] = new_set()

T['ignore()'] = new_set()

---@return string
local function gitignore()
    local file = assert(io.open(vim.fs.joinpath(repo, '.gitignore'), 'rb'))
    local content = file:read('*a')

    file:close()

    return content
end

T['ignore()']['creates .gitignore with the path anchored to the root'] = function()
    write('dir/new.txt', { 'x' })

    eq(git.ignore(repo, 'dir/new.txt'), true)
    eq(gitignore(), '/dir/new.txt\n')
    eq(entry('dir/new.txt'), nil)
end

T['ignore()']['ends a last line without a newline first'] = function()
    local file = assert(io.open(vim.fs.joinpath(repo, '.gitignore'), 'wb'))
    file:write('*.log')
    file:close()
    write('b.txt', { 'b' })

    eq(git.ignore(repo, 'b.txt'), true)
    eq(gitignore(), '*.log\n/b.txt\n')
    eq(entry('b.txt'), nil)
end

T['ignore()']['a directory stays a directory pattern'] = function()
    write('nested/a.txt', { 'a' })

    eq(git.ignore(repo, 'nested/'), true)
    eq(gitignore(), '/nested/\n')
    eq(entry('nested/a.txt'), nil)
end

T['ignore()']['escapes glob characters so only the path matches'] = function()
    write('a[1].txt', { 'x' })
    write('a1.txt', { 'y' })

    eq(git.ignore(repo, 'a[1].txt'), true)
    eq(gitignore(), '/a\\[1].txt\n')
    eq(entry('a[1].txt'), nil)
    eq(entry('a1.txt') ~= nil, true)
end

T['file_diff()'] = new_set()

---@param args string[]
---@param fn fun()
local function with_diff_args(args, fn)
    local iter = require('iter')
    local before = iter.config
    iter.config = require('iter.config').resolve({ diff = { args = args } })
    local ok, err = pcall(fn)
    iter.config = before
    assert(ok, err)
end

---@param args string[]
---@return string[] hunk headers
local function hunk_headers(args)
    local headers = {}

    with_diff_args(args, function()
        local source = git.file_diff(
            repo,
            { path = 'long.txt', side = 'unstaged', code = 'M' }
        )
        for _, line in ipairs(source.raw) do
            if vim.startswith(line, '@@') then
                table.insert(headers, line:match('^@@ .- @@'))
            end
        end
    end)

    return headers
end

T['file_diff()']['passes diff.args to git diff'] = function()
    local lines = {}
    for i = 1, 30 do
        lines[i] = 'l' .. i
    end
    write('long.txt', lines)
    helpers.git(repo, { 'add', 'long.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'long' })
    lines[3] = 'l3 changed'
    lines[12] = 'l12 changed'
    write('long.txt', lines)

    eq(hunk_headers({}), { '@@ -1,6 +1,6 @@', '@@ -9,7 +9,7 @@' })
    eq(hunk_headers({ '-U5' }), { '@@ -1,17 +1,17 @@' })
    eq(hunk_headers({ '--histogram', '-U1' }), {
        '@@ -2,3 +2,3 @@',
        '@@ -11,3 +11,3 @@',
    })
end

T['run()']['logs the command, not its output'] = function()
    local log_path = require('iter.log').path()
    eq(vim.startswith(log_path, vim.env.ITER_TEST_HOME), true)
    local before = vim.fn.filereadable(log_path) == 1
            and #vim.fn.readfile(log_path)
        or 0
    write('secret.txt', { 'SECRET CONTENT' })
    require('iter').setup({ debug = true })

    git.run({ 'add', 'secret.txt' }, { cwd = repo })
    git.run({ 'diff', '--cached' }, { cwd = repo })
    require('iter').setup()

    local lines = vim.list_slice(vim.fn.readfile(log_path), before + 1)
    local text = table.concat(lines, '\n')
    eq(text:find('git --no-optional-locks diff --cached', 1, true) ~= nil, true)
    eq(text:find('SECRET CONTENT', 1, true), nil)
end

return T
