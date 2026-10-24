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
---@return IterAnnotation
local function annotation(body)
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
    end, data.annotations)
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
    eq(store.load(repo), { version = 2, annotations = {}, reviewed = {} })
    eq(warnings, {})
end

T['load()']['round-trips annotations and reviewed records'] = function()
    local saved = assert(store.put_annotation(repo, annotation('first')))
    assert(
        store.set_reviewed(repo, 'a.txt', { hash = 'abc123', at = 1700000000 })
    )

    local data = assert(store.load(repo))

    eq(data.version, 2)
    eq(data.annotations, { saved })
    eq(data.reviewed, { ['a.txt'] = { hash = 'abc123', at = 1700000000 } })
    eq(type(saved.id), 'string')
    eq(type(saved.created_at), 'number')
    eq(saved.updated_at, saved.created_at)
end

T['load()']['round-trips the columns and quote of a passage'] = function()
    local passage = annotation('passage')
    passage.anchor.start_col = 4
    passage.anchor.end_col = 9
    passage.anchor.quote = 'gr\195\182\195\159e\nzwei'

    local saved = assert(store.put_annotation(repo, passage))
    local loaded = assert(store.load(repo)).annotations[1]

    eq(loaded, saved)
    eq(loaded.anchor.quote, 'gr\195\182\195\159e\nzwei')
    eq({ loaded.anchor.start_col, loaded.anchor.end_col }, { 4, 9 })
end

T['load()']['round-trips anchored text that is not UTF-8'] = function()
    local latin1 = annotation('latin-1')
    latin1.anchor.lines = { 'caf\233' }

    assert(store.put_annotation(repo, latin1))

    eq(assert(store.load(repo)).annotations[1].anchor.lines, { 'caf\233' })
    eq(warnings, {})
end

T['load()']['keeps a corrupt file aside and warns once'] = function()
    local path = assert(store.path(repo))
    write(path, '{ not json')

    eq(store.load(repo), { version = 2, annotations = {}, reviewed = {} })
    eq(store.load(repo), { version = 2, annotations = {}, reviewed = {} })

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
        '{"version":2,"annotations":3,"reviewed":{}}',
        '{"version":2,"annotations":[],"reviewed":7}',
        '{"annotations":[],"reviewed":{}}',
        '{"version":2,"annotations":["x"],"reviewed":{}}',
    }) do
        write(path, text)
        eq(store.load(repo), { version = 2, annotations = {}, reviewed = {} })
    end

    eq(#warnings, 6)
    eq(#entries(vim.fs.dirname(path)), 6)
end

T['load()']['leaves a file of a newer version alone'] = function()
    local path = assert(store.path(repo))
    local text = '{"version":3,"annotations":[],"reviewed":{}}'
    write(path, text)

    local data, err = store.load(repo)
    eq(data, nil)
    eq(err, 'store written by a newer iter')

    local saved, put_err = store.put_annotation(repo, annotation('refused'))
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

    assert(store.put_annotation(repo, annotation('fresh')))

    eq(bodies(assert(store.load(repo))), { 'fresh' })
    eq(#warnings, 1)
end

T['writes'] = new_set()

T['writes']['update and remove annotations by id'] = function()
    local first = assert(store.put_annotation(repo, annotation('first')))
    local second = assert(store.put_annotation(repo, annotation('second')))

    first.body = 'edited'
    first.outdated = true
    local edited = assert(store.put_annotation(repo, first))

    eq(edited.id, first.id)
    eq(edited.created_at, first.created_at)
    eq(bodies(assert(store.load(repo))), { 'edited', 'second' })

    assert(store.remove_annotations(repo, { first.id }))

    eq(assert(store.load(repo)).annotations, { second })
end

T['writes']['edit only an annotation that still exists'] = function()
    local kept = assert(store.put_annotation(repo, annotation('kept')))
    local gone = assert(store.put_annotation(repo, annotation('gone')))
    assert(store.remove_annotations(repo, { gone.id }))
    local path = assert(store.path(repo))
    local before = assert(vim.uv.fs_stat(path)).ino

    gone.body = 'edited after delete'
    local saved, err = store.edit_annotation(repo, gone)

    eq(saved, nil)
    eq(err, 'The annotation no longer exists')
    eq(assert(vim.uv.fs_stat(path)).ino, before)
    eq(bodies(assert(store.load(repo))), { 'kept' })

    kept.body = 'edited'
    local edited = assert(store.edit_annotation(repo, kept))

    eq(edited.created_at, kept.created_at)
    eq(bodies(assert(store.load(repo))), { 'edited' })
end

T['writes']['report a store directory that cannot be made'] = function()
    local dir = vim.fs.dirname(assert(store.path(repo)))
    write(vim.fs.dirname(dir), 'a file where a directory belongs')

    local saved, err = store.put_annotation(repo, annotation('x'))

    eq(saved, nil)
    eq(
        vim.startswith(
            assert(err),
            'Cannot create the annotation store directory'
        ),
        true
    )
end

T['writes']['give every annotation its own id'] = function()
    local ids = {}

    for i = 1, 50 do
        ids[assert(store.put_annotation(repo, annotation(tostring(i)))).id] =
            true
    end

    eq(vim.tbl_count(ids), 50)
end

T['writes']['clear a reviewed record'] = function()
    assert(store.set_reviewed(repo, 'a.txt', { hash = 'h', at = 1 }))
    assert(store.set_reviewed(repo, 'b.txt', { hash = 'deleted', at = 2 }))
    assert(store.set_reviewed(repo, 'a.txt', nil))

    eq(
        assert(store.load(repo)).reviewed,
        { ['b.txt'] = { hash = 'deleted', at = 2 } }
    )
end

T['writes']['replace the file by rename and leave no temp file'] = function()
    assert(store.put_annotation(repo, annotation('first')))
    local path = assert(store.path(repo))
    local before = assert(vim.uv.fs_stat(path)).ino

    assert(store.put_annotation(repo, annotation('second')))

    MiniTest.expect.no_equality(assert(vim.uv.fs_stat(path)).ino, before)
    eq(entries(vim.fs.dirname(path)), { 'main.json' })
end

T['writes']['keep an empty reviewed table an object'] = function()
    assert(store.put_annotation(repo, annotation('first')))

    local text = assert(read(assert(store.path(repo))))

    eq(text:find('"reviewed":{}', 1, true) ~= nil, true)
end

T['writes']['fail outside a repository'] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')

    local saved, err = store.put_annotation(dir, annotation('x'))
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
---@return IterAnnotation
local function child_put(body)
    return child.lua(
        'return require("iter.store").put_annotation(...)',
        { repo, annotation(body) }
    )
end

T['two instances']['share the test data dir'] = function()
    eq(child.fn.stdpath('data'), vim.fn.stdpath('data'))
end

T['two instances']['keep both interleaved annotations'] = function()
    local stale = assert(store.load(repo))

    child_put('from child')
    assert(store.put_annotation(repo, annotation('from parent')))

    eq(#stale.annotations, 0)
    eq(bodies(assert(store.load(repo))), { 'from child', 'from parent' })
    eq(
        bodies(child.lua('return require("iter.store").load(...)', { repo })),
        { 'from child', 'from parent' }
    )
end

T['two instances']['do not undo each other on delete'] = function()
    local mine = assert(store.put_annotation(repo, annotation('mine')))
    child_put('theirs')

    assert(store.remove_annotations(repo, { mine.id }))
    child_put('later')

    eq(bodies(assert(store.load(repo))), { 'later', 'theirs' })
end

T['branches'] = new_set()

T['branches']['follow a checkout'] = function()
    assert(store.put_annotation(repo, annotation('on main')))

    helpers.git(repo, { 'checkout', '--quiet', '-b', 'other' })
    eq(assert(store.load(repo)).annotations, {})
    assert(store.put_annotation(repo, annotation('on other')))

    helpers.git(repo, { 'checkout', '--quiet', 'main' })
    eq(bodies(assert(store.load(repo))), { 'on main' })

    helpers.git(repo, { 'checkout', '--quiet', 'other' })
    eq(bodies(assert(store.load(repo))), { 'on other' })

    helpers.git(repo, { 'checkout', '--quiet', '--detach' })
    eq(assert(store.load(repo)).annotations, {})
    eq(vim.fs.basename(assert(store.path(repo))), 'HEAD.json')
end

T['cached()'] = new_set()

T['cached()']['reads again only when the file changed'] = function()
    assert(store.put_annotation(repo, annotation('first')))
    eq(bodies(store.cached(repo)), { 'first' })

    local real_read = store.read
    local reads = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    store.read = function(...)
        reads = reads + 1
        return real_read(...)
    end

    local ok, err = pcall(function()
        local before = store.cached(repo)
        eq(store.cached(repo) == before, true)
        eq(reads, 0)

        assert(store.put_annotation(repo, annotation('second')))
        eq(bodies(store.cached(repo)), { 'first', 'second' })
        eq(reads, 1)

        store.cached(repo, true)
        eq(reads, 2)
    end)

    store.read = real_read
    assert(ok, err)
end

T['cached()']['keeps the data when a read fails'] = function()
    assert(store.put_annotation(repo, annotation('kept')))
    eq(bodies(store.cached(repo)), { 'kept' })

    write(assert(store.path(repo)), '{"version":3,"annotations":[]}')

    eq(bodies(store.cached(repo)), { 'kept' })
end

T['cached()']['follows a checkout'] = function()
    assert(store.put_annotation(repo, annotation('on main')))
    eq(bodies(store.cached(repo)), { 'on main' })

    helpers.git(repo, { 'checkout', '--quiet', '-b', 'other' })
    eq(store.cached(repo).annotations, {})
end

T['cached()']['starts empty on a branch whose store cannot be read'] = function()
    assert(store.put_annotation(repo, annotation('on main')))
    eq(bodies(store.cached(repo)), { 'on main' })

    helpers.git(repo, { 'checkout', '--quiet', '-b', 'other' })
    write(
        assert(store.path(repo)),
        '{"version":99,"annotations":[],"reviewed":{}}'
    )

    eq(store.cached(repo).annotations, {})
end

T['lock'] = new_set()

--- Bodies of the annotations in the store file on disk.
---@return string[]
local function on_disk()
    local text = read(assert(store.path(repo)))

    if text == nil then
        return {}
    end

    return bodies(vim.json.decode(text))
end

---@return string
local function lock_path()
    return assert(store.path(repo)) .. '.lock'
end

T['lock']['a held lock keeps the change and saves it with the next one'] = function()
    write(lock_path(), 'another instance')

    eq(assert(store.put_annotation(repo, annotation('first'))).body, 'first')
    eq(assert(store.put_annotation(repo, annotation('second'))).body, 'second')
    eq(on_disk(), {})
    eq(bodies(store.cached(repo)), { 'first', 'second' })
    eq(#warnings, 1)
    eq(
        warnings[1]:find('Cannot lock the annotation store', 1, true) ~= nil,
        true
    )

    vim.uv.fs_unlink(lock_path())
    assert(store.put_annotation(repo, annotation('third')))

    eq(on_disk(), { 'first', 'second', 'third' })
    eq(bodies(store.cached(repo)), { 'first', 'second', 'third' })
    eq(vim.uv.fs_stat(lock_path()), nil)
    eq(read(lock_path()), nil)
end

T['lock']['cached() keeps showing a queued change'] = function()
    assert(store.put_annotation(repo, annotation('zero')))
    eq(bodies(store.cached(repo)), { 'zero' })

    write(lock_path(), 'another instance')
    assert(store.put_annotation(repo, annotation('one')))

    eq(bodies(store.cached(repo)), { 'one', 'zero' })
    eq(bodies(store.cached(repo)), { 'one', 'zero' })
    eq(bodies(store.cached(repo, true)), { 'one', 'zero' })
    eq(on_disk(), { 'zero' })

    vim.uv.fs_unlink(lock_path())
end

T['lock']['takes over a lock older than the stale timeout'] = function()
    write(lock_path(), 'a crashed instance')
    local old = os.time() - 60
    assert(vim.uv.fs_utime(lock_path(), old, old))

    assert(store.put_annotation(repo, annotation('first')))

    eq(on_disk(), { 'first' })
    eq(warnings, {})
    eq(vim.uv.fs_stat(lock_path()), nil)
end

T['lock']['a stale lock that cannot be moved is waited for, not spun on'] = function()
    write(lock_path(), 'a crashed instance')
    local old = os.time() - 60
    assert(vim.uv.fs_utime(lock_path(), old, old))

    local real_rename = vim.uv.fs_rename
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.fs_rename = function(from, to)
        if vim.endswith(from, '.lock') then
            return nil, 'EBUSY: resource busy', 'EBUSY'
        end

        return real_rename(from, to)
    end

    local started = vim.uv.hrtime()
    local ok, saved = pcall(store.put_annotation, repo, annotation('kept'))
    local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
    vim.uv.fs_rename = real_rename

    eq(ok, true)
    eq(saved ~= nil, true)
    eq(elapsed_ms < 5000, true)
    eq(#warnings, 1)
    eq(on_disk(), {})

    vim.uv.fs_unlink(lock_path())
    assert(store.put_annotation(repo, annotation('next')))
    eq(on_disk(), { 'kept', 'next' })
end

T['lock']['leaving Neovim saves a queued change once the lock goes stale'] = function()
    write(lock_path(), 'a slow instance')
    local aged = os.time() - 8
    assert(vim.uv.fs_utime(lock_path(), aged, aged))

    local script = string.format(
        [[lua local saved = require('iter.store').put_annotation(%q, {
            scope = 'review',
            anchor = { side = 'new' },
            body = 'queued',
            outdated = false,
        })
        local file = io.open(%q)
        local text = file and file:read('*a') or ''
        io.stdout:write(text:find('queued', 1, true) and 'written' or 'queued')
        vim.cmd(saved and 'qa!' or 'cquit 1')]],
        repo,
        assert(store.path(repo))
    )
    local result = vim.system({
        'nvim',
        '--headless',
        '--noplugin',
        '-u',
        'tests/minimal_init.lua',
        '-c',
        script,
    }, { env = vim.fn.environ(), clear_env = true }):wait(30000)

    eq(result.code, 0)
    eq(result.stdout, 'queued')
    eq(result.stderr:find('Lost', 1, true), nil)
    eq(on_disk(), { 'queued' })
    eq(vim.uv.fs_stat(lock_path()), nil)
end

T['lock']['is released when the change fails'] = function()
    local ok = pcall(store.update, repo, function()
        error('boom')
    end)

    eq(ok, false)
    eq(vim.uv.fs_stat(lock_path()), nil)
    assert(store.put_annotation(repo, annotation('after')))
    eq(on_disk(), { 'after' })
end

T['lock']['leaves the lock of another instance alone'] = function()
    assert(store.update(repo, function()
        vim.uv.fs_unlink(lock_path())
        write(lock_path(), 'another instance')
    end))

    eq(read(lock_path()), 'another instance')
    vim.uv.fs_unlink(lock_path())
end

T['lock']['three instances writing at once lose no change'] = function()
    local count = 15
    local script = string.format(
        [[lua local store = require('iter.store')
        local ok = pcall(function()
            for i = 1, %d do
                assert(store.put_annotation(%q, {
                    scope = 'review',
                    anchor = { side = 'new' },
                    body = vim.env.ITER_WRITER .. i,
                    outdated = false,
                }))
            end
        end)
        vim.cmd(ok and 'qa!' or 'cquit 1')]],
        count,
        repo
    )
    local jobs = {}

    for _, writer in ipairs({ 'a', 'b', 'c' }) do
        local env = vim.fn.environ()
        env.ITER_WRITER = writer
        table.insert(
            jobs,
            vim.system({
                'nvim',
                '--headless',
                '--noplugin',
                '-u',
                'tests/minimal_init.lua',
                '-c',
                script,
            }, { env = env, clear_env = true })
        )
    end

    for _, job in ipairs(jobs) do
        eq(job:wait(30000).code, 0)
    end

    eq(#on_disk(), 3 * count)
    eq(vim.uv.fs_stat(lock_path()), nil)
end

return T
