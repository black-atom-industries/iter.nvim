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

T['unstage() without commits keeps the worktree file'] = function()
    local fresh = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(fresh, 'p')
    helpers.git(fresh, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(fresh, 'm.txt'), { 'one' })
    helpers.write_file(vim.fs.joinpath(fresh, 'n.txt'), { 'one' })
    helpers.git(fresh, { 'add', '--all' })
    helpers.write_file(vim.fs.joinpath(fresh, 'n.txt'), { 'two' })

    local ok, err = git.unstage(fresh, { 'm.txt', 'n.txt' })
    local entries = git.status_snapshot(fresh).entries
    local n = vim.fn.readfile(vim.fs.joinpath(fresh, 'n.txt'))
    helpers.cleanup(fresh)

    eq({ ok, err }, { true, '' })
    eq(entries, {
        { staged = '?', unstaged = '?', path = 'm.txt' },
        { staged = '?', unstaged = '?', path = 'n.txt' },
    })
    eq(n, { 'two' })
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
    eq(recent.commits[1].author, 'Iter Test')
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
---@return string[] hunk headers
local function hunk_headers(args)
    local headers = {}
    local source = git.file_diff(
        repo,
        { path = 'long.txt', side = 'unstaged', code = 'M' },
        args
    )

    for _, line in ipairs(source.raw) do
        if vim.startswith(line, '@@') then
            table.insert(headers, line:match('^@@ .- @@'))
        end
    end

    return headers
end

T['file_diff()']['passes args to git diff'] = function()
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

T['run()']['checks for git once and reports a missing one once'] = function()
    local original_executable = vim.fn.executable
    local original_notify = vim.notify
    local checks, notes = 0, {}

    package.loaded['iter.git'] = nil
    local fresh = require('iter.git')

    local ok, err = pcall(function()
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.executable = function()
            checks = checks + 1
            return 0
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(message, level)
            table.insert(notes, { message, level })
        end

        eq(fresh.run({ 'status' }, { cwd = repo }).exit_code, 127)
        eq(fresh.root(), '')
    end)

    vim.fn.executable = original_executable
    vim.notify = original_notify
    package.loaded['iter.git'] = git
    assert(ok, err)

    eq(checks, 1)
    eq(notes, {
        { '[iter] `git` is not executable', vim.log.levels.ERROR },
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

T['against a base'] = new_set()

---@param args string[]
---@return string
local function rev(args)
    return vim.trim(helpers.git(repo, args))
end

--- On `feat`, created from `main`: a commit editing `edit.txt`, a commit
--- renaming `old.txt` to `new.txt`; a commit on `main` after the fork; then
--- uncommitted, `keep.txt` edited, `gone.txt` deleted and `untracked.txt`
--- new.
---@return string base merge-base of `feat` and `main`
local function create_branch_repo()
    write('keep.txt', { 'k1', 'k2' })
    write('edit.txt', { 'e1', 'e2', 'e3' })
    write('old.txt', { 'rename me', 'line two', 'line three' })
    write('gone.txt', { 'bye' })
    helpers.git(repo, { 'add', '--all' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'files' })

    local base = rev({ 'rev-parse', 'HEAD' })

    helpers.git(repo, { 'switch', '--quiet', '-c', 'feat', 'main' })
    write('edit.txt', { 'e1', 'e2 changed', 'e3' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'edit' })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'rename' })
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    write('main.txt', { 'main only' })
    helpers.git(repo, { 'add', 'main.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'main' })
    helpers.git(repo, { 'switch', '--quiet', 'feat' })
    write('keep.txt', { 'k1', 'k2 edited' })
    vim.fn.delete(vim.fs.joinpath(repo, 'gone.txt'))
    write('untracked.txt', { 'fresh' })

    return base
end

---@return GitStatusEntry[]
local function entries()
    return git.status_snapshot(repo).entries
end

T['against a base']['base_changes() lists committed and uncommitted changes'] = function()
    local base = create_branch_repo()

    eq(git.base_changes(repo, base, entries()), {
        { path = 'edit.txt', side = 'base', code = 'M', base = base },
        { path = 'gone.txt', side = 'base', code = 'D', base = base },
        { path = 'keep.txt', side = 'base', code = 'M', base = base },
        {
            path = 'new.txt',
            orig_path = 'old.txt',
            side = 'base',
            code = 'R',
            base = base,
        },
        { path = 'untracked.txt', side = 'base', code = '?', base = base },
    })
end

T['against a base']['base_changes() takes untracked files from the given status'] = function()
    local base = create_branch_repo()
    local paths = vim.tbl_map(function(item)
        return item.path
    end, assert(git.base_changes(repo, base, {})))

    eq(paths, { 'edit.txt', 'gone.txt', 'keep.txt', 'new.txt' })
end

T['against a base']['base_changes() is nil with the error on a bad base'] = function()
    local items, err = git.base_changes(repo, 'nope', {})

    eq(items, nil)
    eq(type(err), 'string')
end

T['against a base']['file_diff() reads the base and the worktree'] = function()
    local base = create_branch_repo()
    local by_path = {}

    for _, item in ipairs(assert(git.base_changes(repo, base, entries()))) do
        by_path[item.path] = item
    end

    local edit = assert(git.file_diff(repo, by_path['edit.txt'], {}))

    eq(edit.old_lines, { 'e1', 'e2', 'e3' })
    eq(edit.new_lines, { 'e1', 'e2 changed', 'e3' })
    eq(vim.tbl_contains(edit.raw, '-e2'), true)
    eq(vim.tbl_contains(edit.raw, '+e2 changed'), true)

    local renamed = assert(git.file_diff(repo, by_path['new.txt'], {}))

    eq(renamed.old_lines, { 'rename me', 'line two', 'line three' })
    eq(renamed.new_lines, { 'rename me', 'line two', 'line three' })
    eq(vim.tbl_contains(renamed.raw, 'rename from old.txt'), true)

    local gone = assert(git.file_diff(repo, by_path['gone.txt'], {}))

    eq(gone.old_lines, { 'bye' })
    eq(gone.new_lines, {})

    local keep = assert(git.file_diff(repo, by_path['keep.txt'], {}))

    eq(keep.old_lines, { 'k1', 'k2' })
    eq(keep.new_lines, { 'k1', 'k2 edited' })

    local fresh = assert(git.file_diff(repo, by_path['untracked.txt'], {}))

    eq(fresh.old_lines, {})
    eq(fresh.new_lines, { 'fresh' })
end

T['against a base']['file_diff() refuses a base change without its base'] = function()
    write('tracked.txt', { 'one', 'two' })

    local source, err = git.file_diff(
        repo,
        { path = 'tracked.txt', side = 'base', code = 'M' },
        {}
    )

    eq(source, nil)
    eq(err, 'No base for tracked.txt')
end

T['against a base']['diff_ids() keys the base read by base and path'] = function()
    local base = create_branch_repo()
    local ids = assert(git.diff_ids(repo, base))
    local keys = vim.tbl_keys(ids)
    table.sort(keys)

    eq(keys, {
        'base\0edit.txt',
        'base\0gone.txt',
        'base\0keep.txt',
        'base\0new.txt',
    })

    local before = ids['base\0keep.txt']

    write('keep.txt', { 'k1', 'k2 edited again' })
    eq(assert(git.diff_ids(repo, base))['base\0keep.txt'], before)
end

T['against a base']['resolve_base() takes the merge-base of a branch'] = function()
    local base = create_branch_repo()

    eq(git.resolve_base(repo, { kind = 'branch', ref = 'main' }), base)
end

T['against a base']['resolve_base() takes the parent of a commit'] = function()
    local base = create_branch_repo()
    local first = rev({ 'rev-parse', 'feat~1' })

    eq(git.resolve_base(repo, { kind = 'commit', sha = first }), base)
end

T['against a base']['resolve_base() takes the commit of a typed ref itself'] = function()
    create_branch_repo()

    local first = rev({ 'rev-parse', 'feat~1' })

    eq(
        git.resolve_base(repo, { kind = 'rev', ref = 'feat~1', sha = first }),
        first
    )
end

T['against a base']['resolve_base() refuses a commit no longer in the history of HEAD'] = function()
    create_branch_repo()

    local first = rev({ 'rev-parse', 'feat~1' })
    local tip = rev({ 'rev-parse', 'feat' })

    helpers.git(repo, { 'stash', '--quiet', '--include-untracked' })
    helpers.git(repo, { 'rebase', '--quiet', 'main' })

    for _, spec in ipairs({
        { kind = 'commit', sha = first },
        { kind = 'rev', ref = 'feat~1', sha = first },
        { kind = 'commit', sha = tip },
    }) do
        local sha, err = git.resolve_base(repo, spec)

        eq(sha, nil)
        eq(err, 'Not in the history of HEAD')
    end
end

T['against a base']['resolve_base() takes the empty tree for a root commit'] = function()
    local root_commit = rev({ 'rev-list', '--max-parents=0', 'HEAD' })
    local empty = rev({ 'hash-object', '-t', 'tree', '/dev/null' })

    eq(git.resolve_base(repo, { kind = 'commit', sha = root_commit }), empty)

    local items = assert(git.base_changes(repo, empty, entries()))

    eq(items, {
        { path = 'tracked.txt', side = 'base', code = 'A', base = empty },
    })
    eq(assert(git.file_diff(repo, items[1], {})).new_lines, { 'one' })
end

T['against a base']['resolve_base() is nil with the error on an unknown ref'] = function()
    local sha, err = git.resolve_base(repo, { kind = 'branch', ref = 'nope' })

    eq(sha, nil)
    eq(type(err), 'string')

    sha, err = git.resolve_base(repo, { kind = 'commit', sha = 'nope' })

    eq(sha, nil)
    eq(type(err), 'string')
end

T['parent_branch()'] = new_set({
    hooks = {
        post_case = function()
            helpers.cleanup(remote)
            remote = nil
        end,
    },
})

--- Create `branch` at the current commit the way `worktree add -b` does,
--- so its reflog says `Created from HEAD`.
---@param branch string
local function branch_from_head(branch)
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    helpers.git(repo, { 'checkout', '--quiet', '-b', branch })
end

T['parent_branch()']['takes the branch the reflog names'] = function()
    commit('m1')
    helpers.git(repo, { 'switch', '--quiet', '-c', 'feat', 'main' })
    commit('f1')
    helpers.git(repo, { 'branch', 'near' })
    commit('f2')

    eq(git.parent_branch(repo), 'main')
end

T['parent_branch()']['falls back when the reflog says HEAD'] = function()
    commit('m1')
    branch_from_head('feat')
    commit('f1')
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    commit('m2')
    helpers.git(repo, { 'switch', '--quiet', 'feat' })

    eq(git.parent_branch(repo), 'main')
end

T['parent_branch()']['falls back when the reflog names a deleted branch'] = function()
    commit('m1')
    helpers.git(repo, { 'branch', 'tmp' })
    helpers.git(repo, { 'switch', '--quiet', '-c', 'feat', 'tmp' })
    helpers.git(repo, { 'branch', '-D', 'tmp' })
    commit('f1')

    eq(git.parent_branch(repo), 'main')
end

T['parent_branch()']['finds the branch a stacked branch forked from'] = function()
    branch_from_head('feat/a')
    commit('a1')
    commit('a2')
    branch_from_head('feat/b')
    commit('b1')

    eq(git.parent_branch(repo), 'feat/a')
end

T['parent_branch()']['takes a closer child branch over the parent'] = function()
    branch_from_head('feat/a')
    commit('a1')
    branch_from_head('feat/b')
    commit('b1')
    helpers.git(repo, { 'switch', '--quiet', 'feat/a' })
    commit('a2')
    commit('a3')

    eq(git.parent_branch(repo), 'feat/b')
end

T['parent_branch()']['gives ties to the default branch'] = function()
    commit('m1')
    helpers.git(repo, { 'branch', 'aaa' })
    branch_from_head('feat')
    commit('f1')

    eq(git.parent_branch(repo), 'main')
end

T['parent_branch()']['counts the remote default branch'] = function()
    remote = helpers.create_remote(repo)
    helpers.git(repo, { 'remote', 'set-head', 'origin', 'main' })
    branch_from_head('feat')
    commit('f1')
    helpers.git(repo, { 'branch', '-D', 'main' })

    eq(git.parent_branch(repo), 'origin/main')
end

T['parent_branch()']['is nil on the default branch'] = function()
    branch_from_head('feat')
    commit('f1')
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    commit('m1')

    eq(git.parent_branch(repo), nil)
end

T['parent_branch()']['is nil on a detached HEAD every branch contains'] = function()
    commit('m1')
    helpers.git(repo, { 'checkout', '--quiet', '--detach', 'HEAD~1' })

    eq(git.parent_branch(repo), nil)
end

T['parent_branch()']['finds the parent of a detached HEAD ahead of it'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    commit('d1')

    eq(git.parent_branch(repo), 'main')
end

T['base refs'] = new_set()

T['base refs']['branches() lists local then remote branches, no symrefs'] = function()
    helpers.git(repo, { 'branch', 'feat/a' })
    helpers.create_remote(repo)
    helpers.git(repo, { 'remote', 'set-head', 'origin', 'main' })

    eq(git.branches(repo), { 'feat/a', 'main', 'origin/main' })
end

T['base refs']['base_spec() names a branch, a remote branch or a commit'] = function()
    helpers.git(repo, { 'branch', 'feat' })
    helpers.create_remote(repo)

    local head = vim.trim(helpers.git(repo, { 'rev-parse', 'HEAD' }))

    eq(git.base_spec(repo, 'feat'), { kind = 'branch', ref = 'feat' })
    eq(
        git.base_spec(repo, 'origin/main'),
        { kind = 'branch', ref = 'origin/main' }
    )
    eq(
        git.base_spec(repo, head:sub(1, 7)),
        { kind = 'rev', ref = head:sub(1, 7), sha = head }
    )
    eq(git.base_spec(repo, 'HEAD'), { kind = 'rev', ref = 'HEAD', sha = head })
end

T['base refs']['commit_sha() gives the full sha of a ref'] = function()
    local head = vim.trim(helpers.git(repo, { 'rev-parse', 'HEAD' }))

    eq(git.commit_sha(repo, head:sub(1, 7)), head)
    eq({ git.commit_sha(repo, 'nope') }, { nil, 'Unknown ref nope' })
    eq({ git.commit_sha(repo, '--all') }, { nil, 'Unknown ref --all' })
end

T['base refs']['base_spec() refuses an unknown ref and an option'] = function()
    eq({ git.base_spec(repo, 'nope') }, { nil, 'Unknown ref nope' })
    eq({ git.base_spec(repo, '--all') }, { nil, 'Unknown ref --all' })
end

return T
