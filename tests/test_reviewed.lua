local helpers = dofile('tests/helpers.lua')
local git = require('iter.git')
local store = require('iter.store')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local repo
---@type table
local reviewed
---@type integer
local spawns
---@type function
local original_run

---@param path string
---@param lines string[]
local function write(path, lines)
    helpers.write_file(vim.fs.joinpath(repo, path), lines)
end

---@param paths string[]
---@return table<string, IterReviewedState>
local function states(paths)
    local data = assert(store.load(repo))

    return reviewed.states(repo, paths, data.reviewed)
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({
                ['a.txt'] = { 'one', 'two' },
                ['b.txt'] = { 'bee' },
                ['sp ace/ü.txt'] = { 'odd' },
            })
            package.loaded['iter.reviewed'] = nil
            reviewed = require('iter.reviewed')
            spawns = 0
            original_run = git.run
            ---@diagnostic disable-next-line: duplicate-set-field
            git.run = function(args, opts)
                if args[1] == 'hash-object' then
                    spawns = spawns + 1
                end

                return original_run(args, opts)
            end
        end,
        post_case = function()
            git.run = original_run
            helpers.cleanup(repo)

            local data = vim.fn.stdpath('data')
            if vim.startswith(data, vim.env.ITER_TEST_HOME .. '/') then
                vim.fn.delete(data .. '/iter', 'rf')
            end
        end,
    },
})

T['states()'] = new_set()

T['states()']['a file without a record is unreviewed'] = function()
    eq(states({ 'a.txt' }), { ['a.txt'] = 'unreviewed' })
end

T['states()']['toggle marks reviewed and the second toggle unreviews'] = function()
    eq(reviewed.toggle(repo, 'a.txt'), 'reviewed')
    eq(states({ 'a.txt', 'b.txt' }), {
        ['a.txt'] = 'reviewed',
        ['b.txt'] = 'unreviewed',
    })

    eq(reviewed.toggle(repo, 'a.txt'), 'unreviewed')
    eq(states({ 'a.txt' }), { ['a.txt'] = 'unreviewed' })
    eq(assert(store.load(repo)).reviewed, {})
end

T['states()']['the record holds git hash-object of the worktree file'] = function()
    reviewed.toggle(repo, 'a.txt')

    local expected = vim.trim(helpers.git(repo, { 'hash-object', 'a.txt' }))
    local record = assert(store.load(repo)).reviewed['a.txt']

    eq(record.hash, expected)
    eq(type(record.at), 'number')
end

T['states()']['an edit turns reviewed into changed'] = function()
    reviewed.toggle(repo, 'a.txt')
    write('a.txt', { 'one', 'two', 'three' })

    eq(states({ 'a.txt' }), { ['a.txt'] = 'changed' })
end

T['states()']['toggling a changed file views the new content'] = function()
    reviewed.toggle(repo, 'a.txt')
    write('a.txt', { 'one', 'two', 'three' })

    eq(reviewed.toggle(repo, 'a.txt'), 'reviewed')
    eq(states({ 'a.txt' }), { ['a.txt'] = 'reviewed' })
end

T['states()']['an edit back to the reviewed content is reviewed again'] = function()
    reviewed.toggle(repo, 'a.txt')
    write('a.txt', { 'other' })
    eq(states({ 'a.txt' }), { ['a.txt'] = 'changed' })

    write('a.txt', { 'one', 'two' })
    eq(states({ 'a.txt' }), { ['a.txt'] = 'reviewed' })
end

T['states()']['staging keeps a file reviewed'] = function()
    write('a.txt', { 'one', 'two', 'three' })
    reviewed.toggle(repo, 'a.txt')

    helpers.git(repo, { 'add', 'a.txt' })
    eq(states({ 'a.txt' }), { ['a.txt'] = 'reviewed' })

    helpers.git(repo, { 'reset', '--quiet', 'a.txt' })
    eq(states({ 'a.txt' }), { ['a.txt'] = 'reviewed' })
end

T['states()']['a deleted file is reviewed with the hash deleted'] = function()
    vim.fn.delete(vim.fs.joinpath(repo, 'b.txt'))

    eq(states({ 'b.txt' }), { ['b.txt'] = 'unreviewed' })
    eq(reviewed.toggle(repo, 'b.txt'), 'reviewed')
    eq(assert(store.load(repo)).reviewed['b.txt'].hash, 'deleted')
    eq(states({ 'b.txt' }), { ['b.txt'] = 'reviewed' })

    write('b.txt', { 'back' })
    eq(states({ 'b.txt' }), { ['b.txt'] = 'changed' })
end

T['states()']['a file deleted after it was reviewed is changed'] = function()
    reviewed.toggle(repo, 'b.txt')
    vim.fn.delete(vim.fs.joinpath(repo, 'b.txt'))

    eq(states({ 'b.txt' }), { ['b.txt'] = 'changed' })
end

T['states()']['paths with spaces and non-ASCII characters hash'] = function()
    eq(reviewed.toggle(repo, 'sp ace/ü.txt'), 'reviewed')
    write('sp ace/ü.txt', { 'odd', 'more' })

    eq(states({ 'sp ace/ü.txt', 'a.txt' }), {
        ['sp ace/ü.txt'] = 'changed',
        ['a.txt'] = 'unreviewed',
    })
end

T['states()']['records survive a new module instance'] = function()
    reviewed.toggle(repo, 'a.txt')

    package.loaded['iter.reviewed'] = nil
    reviewed = require('iter.reviewed')

    eq(states({ 'a.txt' }), { ['a.txt'] = 'reviewed' })
end

T['hashing'] = new_set()

T['hashing']['one batch for all files, none while stat is unchanged'] = function()
    reviewed.toggle(repo, 'a.txt')
    spawns = 0

    states({ 'a.txt', 'b.txt', 'sp ace/ü.txt' })
    eq(spawns, 1)

    states({ 'a.txt', 'b.txt', 'sp ace/ü.txt' })
    states({ 'a.txt', 'b.txt', 'sp ace/ü.txt' })
    eq(spawns, 1)
end

T['hashing']['only the file whose stat changed is hashed again'] = function()
    states({ 'a.txt', 'b.txt' })
    spawns = 0

    write('b.txt', { 'bee', 'changed' })
    states({ 'a.txt', 'b.txt' })

    eq(spawns, 1)
end

T['hashing']['a deleted file spawns nothing'] = function()
    vim.fn.delete(vim.fs.joinpath(repo, 'b.txt'))
    spawns = 0

    states({ 'b.txt' })

    eq(spawns, 0)
end

T['hashing']['the cache forgets paths that left the set'] = function()
    states({ 'a.txt', 'b.txt' })
    states({ 'a.txt' })
    spawns = 0

    states({ 'a.txt', 'b.txt' })

    eq(spawns, 1)
end

T['hashing']['equal mtime and size but another ctime or inode hash again'] = function()
    states({ 'a.txt' })
    spawns = 0

    local real = vim.uv.fs_stat
    local stat = assert(real(vim.fs.joinpath(repo, 'a.txt')))
    local variant = 'ctime'

    ---@param path string
    ---@return uv.fs_stat.result?
    local function fake_stat(path)
        if not vim.endswith(path, 'a.txt') then
            return real(path)
        end

        local copy = vim.deepcopy(stat)

        if variant == 'ctime' then
            copy.ctime.nsec = copy.ctime.nsec + 1
        else
            copy.ino = copy.ino + 1
        end

        return copy
    end

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.fs_stat = fake_stat

    local ok, err = pcall(function()
        states({ 'a.txt' })
        eq(spawns, 1)

        variant = 'ino'
        states({ 'a.txt' })
        eq(spawns, 2)
    end)

    vim.uv.fs_stat = real
    assert(ok, err)
end

T['summary()'] = new_set()

T['summary()']['counts reviewed and changed files'] = function()
    eq(
        reviewed.summary({
            ['a'] = 'reviewed',
            ['b'] = 'changed',
            ['c'] = 'unreviewed',
            ['d'] = 'reviewed',
        }),
        { reviewed = 2, changed = 1, total = 4 }
    )
end

T['summary()']['no files gives zeros'] = function()
    eq(reviewed.summary({}), { reviewed = 0, changed = 0, total = 0 })
end

return T
