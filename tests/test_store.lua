local helpers = dofile('tests/helpers.lua')
local store = require('iter.store')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

---@type string
local repo
---@type string[]
local warnings
---@type function
local original_notify

---@param path string
---@return string?
local function read(path)
    local file = io.open(path, 'rb')

    if file == nil then
        return nil
    end

    local text = file:read('*a')
    file:close()
    return text
end

---@param path string
---@param text string
local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local file = assert(io.open(path, 'wb'))
    file:write(text)
    file:close()
end

---@param body string
---@return IterComment
local function comment(body)
    return {
        scope = 'line',
        anchor = {
            path = 'a.txt',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'one' },
        },
        body = body,
        outdated = false,
    }
end

---@param data IterStoreFile
---@return string[]
local function bodies(data)
    local list = vim.tbl_map(function(c)
        return c.body
    end, data.comments)
    table.sort(list)
    return list
end

---@param dir string
---@return string[]
local function entries(dir)
    local names = {}

    for name in vim.fs.dir(dir) do
        table.insert(names, name)
    end

    table.sort(names)
    return names
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'one' } })
            warnings = {}
            original_notify = vim.notify
            rawset(vim, 'notify', function(message, level)
                if level == vim.log.levels.WARN then
                    table.insert(warnings, message)
                end
            end)
        end,
        post_case = function()
            rawset(vim, 'notify', original_notify)
            helpers.cleanup(repo)

            local data = vim.fn.stdpath('data')
            if vim.startswith(data, vim.env.ITER_TEST_HOME .. '/') then
                vim.fn.delete(data .. '/iter', 'rf')
            end
        end,
    },
})

T['path()'] = new_set()

T['path()']['lives in the test data dir, per repo and branch'] = function()
    local path = assert(store.path(repo))
    local name = vim.fs.basename(repo)

    eq(vim.startswith(path, vim.env.ITER_TEST_HOME .. '/'), true)
    eq(vim.startswith(path, vim.fn.stdpath('data') .. '/iter/'), true)
    eq(
        path:match('/iter/(.+)/main%.json$')
            :match('^' .. vim.pesc(name) .. '%-%x%x%x%x%x%x%x%x$')
            ~= nil,
        true
    )
end

T['path()']['percent-encodes slashes and percent signs'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '-b', 'feat/x' })
    eq(vim.fs.basename(assert(store.path(repo))), 'feat%2Fx.json')

    helpers.git(repo, { 'checkout', '--quiet', '-b', 'a%b/c' })
    eq(vim.fs.basename(assert(store.path(repo))), 'a%25b%2Fc.json')
end

T['path()']['uses HEAD.json when detached'] = function()
    helpers.git(repo, { 'checkout', '--quiet', '--detach' })

    eq(vim.fs.basename(assert(store.path(repo))), 'HEAD.json')
end

T['path()']['uses the branch name of an unborn branch'] = function()
    local empty = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(empty, 'p')
    helpers.git(empty, { 'init', '--quiet', '-b', 'trunk' })

    local path = store.path(empty)
    helpers.cleanup(empty)

    eq(vim.fs.basename(assert(path)), 'trunk.json')
end

T['path()']['is shared by a linked worktree'] = function()
    local linked = vim.fn.resolve(vim.fn.tempname())
    helpers.git(repo, { 'worktree', 'add', '--quiet', '-b', 'wt', linked })

    local main_path = assert(store.path(repo))
    local linked_path = store.path(linked)
    local nested_path = store.path(repo .. '/.git/..')
    helpers.cleanup(linked)

    eq(vim.fs.dirname(assert(linked_path)), vim.fs.dirname(main_path))
    eq(vim.fs.basename(linked_path), 'wt.json')
    eq(nested_path, main_path)
    eq(
        vim.startswith(
            vim.fs.basename(vim.fs.dirname(main_path)),
            vim.fs.basename(repo) .. '-'
        ),
        true
    )
end

T['path()']['differs between two repos of the same name'] = function()
    local other_parent = vim.fn.resolve(vim.fn.tempname())
    local other = other_parent .. '/' .. vim.fs.basename(repo)
    vim.fn.mkdir(other, 'p')
    helpers.git(other, { 'init', '--quiet', '-b', 'main' })

    local other_path = store.path(other)
    helpers.cleanup(other_parent)

    MiniTest.expect.no_equality(other_path, store.path(repo))
end

T['path()']['fails outside a repository'] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')

    local path, err = store.path(dir)
    helpers.cleanup(dir)

    eq(path, nil)
    eq(type(err), 'string')
end

T['load()'] = new_set()

T['load()']['reads a missing file as empty'] = function()
    eq(store.load(repo), { version = 1, comments = {}, viewed = {} })
    eq(warnings, {})
end

T['load()']['round-trips comments and viewed records'] = function()
    local saved = assert(store.put_comment(repo, comment('first')))
    assert(
        store.set_viewed(repo, 'a.txt', { hash = 'abc123', at = 1700000000 })
    )

    local data = assert(store.load(repo))

    eq(data.version, 1)
    eq(data.comments, { saved })
    eq(data.viewed, { ['a.txt'] = { hash = 'abc123', at = 1700000000 } })
    eq(type(saved.id), 'string')
    eq(type(saved.created_at), 'number')
    eq(saved.updated_at, saved.created_at)
end

T['load()']['round-trips anchored text that is not UTF-8'] = function()
    local latin1 = comment('latin-1')
    latin1.anchor.lines = { 'caf\233' }

    assert(store.put_comment(repo, latin1))

    eq(assert(store.load(repo)).comments[1].anchor.lines, { 'caf\233' })
    eq(warnings, {})
end

T['load()']['keeps a corrupt file aside and warns once'] = function()
    local path = assert(store.path(repo))
    write(path, '{ not json')

    eq(store.load(repo), { version = 1, comments = {}, viewed = {} })
    eq(store.load(repo), { version = 1, comments = {}, viewed = {} })

    eq(#warnings, 1)
    eq(warnings[1]:find('corrupt', 1, true) ~= nil, true)

    local names = entries(vim.fs.dirname(path))
    eq(#names, 1)
    eq(vim.startswith(names[1], 'main.json.corrupt-'), true)
    eq(read(vim.fs.dirname(path) .. '/' .. names[1]), '{ not json')
end

T['load()']['treats a file of the wrong shape as corrupt'] = function()
    local path = assert(store.path(repo))

    for _, text in ipairs({
        '[]',
        '"text"',
        '{"version":1,"comments":3,"viewed":{}}',
        '{"version":1,"comments":[],"viewed":7}',
        '{"comments":[],"viewed":{}}',
        '{"version":1,"comments":["x"],"viewed":{}}',
    }) do
        write(path, text)
        eq(store.load(repo), { version = 1, comments = {}, viewed = {} })
    end

    eq(#warnings, 6)
    eq(#entries(vim.fs.dirname(path)), 6)
end

T['load()']['leaves a file of a newer version alone'] = function()
    local path = assert(store.path(repo))
    local text = '{"version":2,"comments":[],"viewed":{}}'
    write(path, text)

    local data, err = store.load(repo)
    eq(data, nil)
    eq(err, 'store written by a newer iter')

    local saved, put_err = store.put_comment(repo, comment('refused'))
    eq(saved, nil)
    eq(put_err, 'store written by a newer iter')

    eq(read(path), text)
    eq(entries(vim.fs.dirname(path)), { 'main.json' })
    eq(#warnings, 1)
end

T['load()']['never overwrites an earlier corrupt copy'] = function()
    local path = assert(store.path(repo))

    write(path, 'first')
    store.load(repo)
    write(path, 'second')
    store.load(repo)

    local dir = vim.fs.dirname(path)
    local kept = vim.tbl_map(function(name)
        return read(dir .. '/' .. name)
    end, entries(dir))
    table.sort(kept)

    eq(kept, { 'first', 'second' })
end

T['load()']['writes after a corrupt file start from empty'] = function()
    local path = assert(store.path(repo))
    write(path, 'garbage')

    assert(store.put_comment(repo, comment('fresh')))

    eq(bodies(assert(store.load(repo))), { 'fresh' })
    eq(#warnings, 1)
end

T['writes'] = new_set()

T['writes']['update and remove comments by id'] = function()
    local first = assert(store.put_comment(repo, comment('first')))
    local second = assert(store.put_comment(repo, comment('second')))

    first.body = 'edited'
    first.outdated = true
    local edited = assert(store.put_comment(repo, first))

    eq(edited.id, first.id)
    eq(edited.created_at, first.created_at)
    eq(bodies(assert(store.load(repo))), { 'edited', 'second' })

    assert(store.remove_comments(repo, { first.id }))

    eq(assert(store.load(repo)).comments, { second })
end

T['writes']['edit only a comment that still exists'] = function()
    local kept = assert(store.put_comment(repo, comment('kept')))
    local gone = assert(store.put_comment(repo, comment('gone')))
    assert(store.remove_comments(repo, { gone.id }))
    local path = assert(store.path(repo))
    local before = assert(vim.uv.fs_stat(path)).ino

    gone.body = 'edited after delete'
    local saved, err = store.edit_comment(repo, gone)

    eq(saved, nil)
    eq(err, 'The comment no longer exists')
    eq(assert(vim.uv.fs_stat(path)).ino, before)
    eq(bodies(assert(store.load(repo))), { 'kept' })

    kept.body = 'edited'
    local edited = assert(store.edit_comment(repo, kept))

    eq(edited.created_at, kept.created_at)
    eq(bodies(assert(store.load(repo))), { 'edited' })
end

T['writes']['report a store directory that cannot be made'] = function()
    local dir = vim.fs.dirname(assert(store.path(repo)))
    write(vim.fs.dirname(dir), 'a file where a directory belongs')

    local saved, err = store.put_comment(repo, comment('x'))

    eq(saved, nil)
    eq(
        vim.startswith(assert(err), 'Cannot create the comment store directory'),
        true
    )
end

T['writes']['give every comment its own id'] = function()
    local ids = {}

    for i = 1, 50 do
        ids[assert(store.put_comment(repo, comment(tostring(i)))).id] = true
    end

    eq(vim.tbl_count(ids), 50)
end

T['writes']['clear a viewed record'] = function()
    assert(store.set_viewed(repo, 'a.txt', { hash = 'h', at = 1 }))
    assert(store.set_viewed(repo, 'b.txt', { hash = 'deleted', at = 2 }))
    assert(store.set_viewed(repo, 'a.txt', nil))

    eq(
        assert(store.load(repo)).viewed,
        { ['b.txt'] = { hash = 'deleted', at = 2 } }
    )
end

T['writes']['replace the file by rename and leave no temp file'] = function()
    assert(store.put_comment(repo, comment('first')))
    local path = assert(store.path(repo))
    local before = assert(vim.uv.fs_stat(path)).ino

    assert(store.put_comment(repo, comment('second')))

    MiniTest.expect.no_equality(assert(vim.uv.fs_stat(path)).ino, before)
    eq(entries(vim.fs.dirname(path)), { 'main.json' })
end

T['writes']['keep an empty viewed table an object'] = function()
    assert(store.put_comment(repo, comment('first')))

    local text = assert(read(assert(store.path(repo))))

    eq(text:find('"viewed":{}', 1, true) ~= nil, true)
end

T['writes']['fail outside a repository'] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')

    local saved, err = store.put_comment(dir, comment('x'))
    helpers.cleanup(dir)

    eq(saved, nil)
    eq(type(err), 'string')
end

T['two instances'] = new_set({
    hooks = {
        pre_case = function()
            child.start({ '-u', helpers.minimal_init })
        end,
        post_case = function()
            child.stop()
        end,
    },
})

---@param body string
---@return IterComment
local function child_put(body)
    return child.lua(
        'return require("iter.store").put_comment(...)',
        { repo, comment(body) }
    )
end

T['two instances']['share the test data dir'] = function()
    eq(child.fn.stdpath('data'), vim.fn.stdpath('data'))
end

T['two instances']['keep both interleaved comments'] = function()
    local stale = assert(store.load(repo))

    child_put('from child')
    assert(store.put_comment(repo, comment('from parent')))

    eq(#stale.comments, 0)
    eq(bodies(assert(store.load(repo))), { 'from child', 'from parent' })
    eq(
        bodies(child.lua('return require("iter.store").load(...)', { repo })),
        { 'from child', 'from parent' }
    )
end

T['two instances']['do not undo each other on delete'] = function()
    local mine = assert(store.put_comment(repo, comment('mine')))
    child_put('theirs')

    assert(store.remove_comments(repo, { mine.id }))
    child_put('later')

    eq(bodies(assert(store.load(repo))), { 'later', 'theirs' })
end

T['branches'] = new_set()

T['branches']['follow a checkout'] = function()
    assert(store.put_comment(repo, comment('on main')))

    helpers.git(repo, { 'checkout', '--quiet', '-b', 'other' })
    eq(assert(store.load(repo)).comments, {})
    assert(store.put_comment(repo, comment('on other')))

    helpers.git(repo, { 'checkout', '--quiet', 'main' })
    eq(bodies(assert(store.load(repo))), { 'on main' })

    helpers.git(repo, { 'checkout', '--quiet', 'other' })
    eq(bodies(assert(store.load(repo))), { 'on other' })

    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    eq(assert(store.load(repo)).comments, {})
    eq(vim.fs.basename(assert(store.path(repo))), 'HEAD.json')
end

return T
