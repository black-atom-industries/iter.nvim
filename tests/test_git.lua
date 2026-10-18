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
    for _, e in ipairs(git.status()) do
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

T['stage(), unstage() and discard'] = function()
    write('tracked.txt', { 'changed' })
    write('untracked.txt', { 'untracked' })

    eq(git.stage(entry('tracked.txt') --[[@as GitStatusEntry]]), true)
    eq(entry('tracked.txt').staged, 'M')

    eq(git.unstage(entry('tracked.txt') --[[@as GitStatusEntry]]), true)
    eq(entry('tracked.txt').staged, ' ')

    eq(git.discard_unstaged_entries({ entry('tracked.txt') }), true)
    eq(entry('tracked.txt'), nil)

    eq(git.discard_untracked_entries({ entry('untracked.txt') }), true)
    eq(entry('untracked.txt'), nil)
end

T['file_change_counts()'] = new_set()

T['file_change_counts()']['counts added and modified lines'] = function()
    write('tracked.txt', { 'one changed', 'two', 'four' })

    local counts, err = git.file_change_counts('tracked.txt')

    eq(err, nil)
    eq(counts, { added = 2, modified = 1, deleted = 0 })
end

T['file_change_counts()']['counts untracked lines as added'] = function()
    write('untracked.txt', { 'one', 'two' })

    local counts, err = git.file_change_counts('untracked.txt')

    eq(err, nil)
    eq(counts, { added = 2, modified = 0, deleted = 0 })
end

T['file_change_counts()']['counts deleted lines'] = function()
    write('tracked.txt', { 'one', 'two', 'three' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'three lines' })
    write('tracked.txt', { 'one' })

    local counts, err = git.file_change_counts('tracked.txt')

    eq(err, nil)
    eq(counts, { added = 0, modified = 0, deleted = 2 })
end

T['file_change_counts()']['rejects directories and the root'] = function()
    write('tracked-dir/file.txt', { 'one' })
    helpers.git(repo, { 'add', 'tracked-dir/file.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'track directory' })

    for _, path in ipairs({ 'tracked-dir', repo }) do
        local counts, err = git.file_change_counts(path)

        eq(err, 'File change counts are not available for directories')
        eq(counts, { added = 0, modified = 0, deleted = 0 })
    end
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

return T
