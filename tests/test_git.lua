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
        ['untracked_dir/'] = '??',
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

T['untracked_files()'] = new_set()

T['untracked_files()']['lists files in a directory, not ignored ones'] = function()
    write('.gitignore', { '*.log' })
    helpers.git(repo, { 'add', '.gitignore' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'ignore' })
    write('dir/a.txt', { 'a' })
    write('dir/sub/b.txt', { 'b' })
    write('dir/skip.log', { 'x' })
    write('other/c.txt', { 'c' })

    eq(git.untracked_files(repo, 'dir/'), { 'dir/a.txt', 'dir/sub/b.txt' })
end

T['untracked_files()']['treats the path literally and skips tracked files'] = function()
    write('we[ir]d/a.txt', { 'a' })
    write('weird/b.txt', { 'b' })

    eq(git.untracked_files(repo, 'we[ir]d/'), { 'we[ir]d/a.txt' })
    eq(git.untracked_files(repo, 'tracked.txt'), {})
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

T['run()'] = new_set()

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
