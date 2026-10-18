local helpers = dofile('tests/helpers.lua')
local git = require('iter.git')
local changes = require('iter.changes')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local original_cwd
---@type string?
local repo

---@param items IterChange[]
---@return string[]
local function paths(items)
    return vim.tbl_map(function(item)
        return item.path
    end, items)
end

---@param entries GitStatusEntry[]
---@param extra? table
---@return GitStatusSnapshot
local function snapshot(entries, extra)
    return vim.tbl_extend('force', {
        branch = 'main',
        entries = entries,
        root = '/nowhere',
    }, extra or {})
end

local T = new_set({
    hooks = {
        pre_case = function()
            original_cwd = vim.fn.getcwd()
        end,
        post_case = function()
            vim.cmd.cd(vim.fn.fnameescape(original_cwd))
            helpers.cleanup(repo)
            repo = nil
        end,
    },
})

--- Repo with a staged rename, a modified file, an untracked directory (with a
--- nested directory and an ignored file inside), and ignored files elsewhere.
local function create_repo()
    repo = helpers.create_repo({
        ['.gitignore'] = { '*.log', 'ignored_dir/' },
        ['old.txt'] = { 'one', 'two', 'three', 'four', 'five' },
        ['mod.txt'] = { 'a' },
    })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })
    helpers.write_file(vim.fs.joinpath(repo, 'mod.txt'), { 'b' })
    helpers.write_file(vim.fs.joinpath(repo, 'dir', 'a.txt'), { 'a' })
    helpers.write_file(vim.fs.joinpath(repo, 'dir', 'sub', 'b.txt'), { 'b' })
    helpers.write_file(vim.fs.joinpath(repo, 'dir', 'skip.log'), { 'x' })
    helpers.write_file(vim.fs.joinpath(repo, 'top.log'), { 'x' })
    helpers.write_file(vim.fs.joinpath(repo, 'ignored_dir', 'f.txt'), { 'x' })
    helpers.write_file(vim.fs.joinpath(repo, 'z.txt'), { 'z' })
    vim.cmd.cd(vim.fn.fnameescape(repo))
end

T['build()'] = new_set()

T['build()']['splits a real snapshot into sides, untracked last'] = function()
    create_repo()
    local result = changes.build(git.status_snapshot())

    eq(result.root, repo)
    eq(result.branch, 'main')
    eq(paths(result.staged), { 'new.txt' })
    eq(result.staged[1].code, 'R')
    eq(result.staged[1].orig_path, 'old.txt')
    eq(result.staged[1].side, 'staged')
    eq(paths(result.unstaged), { 'mod.txt', 'dir/', 'z.txt' })
    eq(result.unstaged[1].code, 'M')
    eq(result.unstaged[2].code, '?')
    eq(result.unstaged[2].dir, true)
    eq(result.unstaged[3].code, '?')
    eq(result.unstaged[3].dir, nil)
    eq(result.ahead, nil)
end

T['build()']['lists a partly staged file on both sides'] = function()
    local result = changes.build(snapshot({
        { staged = 'M', unstaged = 'M', path = 'both.txt' },
        { staged = 'A', unstaged = ' ', path = 'added.txt' },
        { staged = ' ', unstaged = 'D', path = 'gone.txt' },
    }))

    eq(paths(result.staged), { 'both.txt', 'added.txt' })
    eq(paths(result.unstaged), { 'both.txt', 'gone.txt' })
    eq(result.unstaged[1].code, 'M')
    eq(result.unstaged[2].code, 'D')
end

T['build()']['puts untracked files after tracked ones'] = function()
    local result = changes.build(snapshot({
        { staged = '?', unstaged = '?', path = 'a_new.txt' },
        { staged = ' ', unstaged = 'M', path = 'z_mod.txt' },
    }))

    eq(paths(result.unstaged), { 'z_mod.txt', 'a_new.txt' })
    eq(result.staged, {})
end

T['build()']['keeps the rename origin on the renamed side only'] = function()
    local result = changes.build(snapshot({
        { staged = 'R', unstaged = 'M', path = 'b.txt', orig_path = 'a.txt' },
    }))

    eq(result.staged[1].orig_path, 'a.txt')
    eq(result.unstaged[1].orig_path, nil)
end

T['build()']['lists a conflict once, unstaged, with code U'] = function()
    local result = changes.build(snapshot({
        { staged = 'U', unstaged = 'U', path = 'c.txt' },
        { staged = 'D', unstaged = 'D', path = 'd.txt' },
    }))

    eq(result.staged, {})
    eq(paths(result.unstaged), { 'c.txt', 'd.txt' })
    eq(result.unstaged[1].code, 'U')
    eq(result.unstaged[2].code, 'U')
end

T['build()']['names a detached HEAD "HEAD" and carries ahead'] = function()
    local detached =
        changes.build(snapshot({}, { branch = 'abc1234', detached = true }))
    local ahead = changes.build(snapshot({}, { ahead = 2 }))

    eq(detached.branch, 'HEAD')
    eq(ahead.ahead, 2)
end

T['expand()'] = new_set()

T['expand()']['lists untracked files without ignored ones'] = function()
    create_repo()
    local result = changes.build(git.status_snapshot())
    local dir = result.unstaged[2]

    eq(changes.expand(result.root, dir), true)
    eq(dir.expanded, true)
    eq(paths(dir.children), { 'dir/a.txt', 'dir/sub/b.txt' })
    eq(dir.children[1].code, '?')
    eq(dir.children[1].side, 'unstaged')

    changes.collapse(dir)
    eq(dir.expanded, false)
end

T['expand()']['ignores a plain file'] = function()
    create_repo()
    local result = changes.build(git.status_snapshot())

    eq(changes.expand(result.root, result.unstaged[1]), false)
    eq(result.unstaged[1].children, nil)
end

T['files()'] = new_set()

T['files()']['returns the exact untracked files of a directory'] = function()
    create_repo()
    local result = changes.build(git.status_snapshot())

    eq(
        changes.files(result.root, result.unstaged[2]),
        { 'dir/a.txt', 'dir/sub/b.txt' }
    )
    eq(changes.files(result.root, result.unstaged[3]), { 'z.txt' })
end

T['files()']['lists afresh instead of trusting stale children'] = function()
    create_repo()
    local result = changes.build(git.status_snapshot())
    local dir = result.unstaged[2]
    changes.expand(result.root, dir)
    helpers.write_file(vim.fs.joinpath(repo, 'dir', 'late.txt'), { 'l' })

    eq(
        changes.files(result.root, dir),
        { 'dir/a.txt', 'dir/late.txt', 'dir/sub/b.txt' }
    )
end

T['odd paths'] = new_set()

T['odd paths']['keep spaces and non-ASCII characters'] = function()
    repo = helpers.create_odd_paths_repo()
    vim.cmd.cd(vim.fn.fnameescape(repo))
    local result = changes.build(git.status_snapshot())
    local dir = result.unstaged[2]

    eq(paths(result.unstaged), { 'sp ace/ü.txt', 'ne w/' })
    eq(dir.dir, true)
    eq(changes.files(result.root, dir), { 'ne w/ö ä.txt' })
    eq(changes.expand(result.root, dir), true)
    eq(paths(dir.children), { 'ne w/ö ä.txt' })
end

T['truncate()'] = new_set()

T['truncate()']['keeps a path that fits'] = function()
    eq(changes.truncate('src/a.lua', 9), 'src/a.lua')
    eq(changes.truncate('src/a.lua', 20), 'src/a.lua')
end

T['truncate()']['cuts from the left with an ellipsis'] = function()
    local cut = changes.truncate('lua/iter/ui/drawer.lua', 12)

    eq(cut, '…/drawer.lua')
    eq(vim.fn.strdisplaywidth(cut), 12)
end

T['truncate()']['handles tiny widths and wide characters'] = function()
    local wide = changes.truncate('日本語/ファイル.lua', 10)

    eq(changes.truncate('abc', 1), '…')
    eq(changes.truncate('abc', 0), '')
    eq(wide, '…イル.lua')
    eq(vim.fn.strdisplaywidth(wide) <= 10, true)
end

return T
