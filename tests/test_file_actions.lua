local helpers = dofile('tests/helpers.lua')
local actions = require('iter.ui.file_actions')
local changes = require('iter.changes')
local config = require('iter.config')
local git = require('iter.git')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string?
local repo
---@type string[]
local warnings
local notify = vim.notify

local T = new_set({
    hooks = {
        pre_case = function()
            warnings = {}
            vim.notify = function(msg, level)
                if level == vim.log.levels.WARN then
                    table.insert(warnings, msg)
                end
            end
        end,
        post_case = function()
            vim.notify = notify
            helpers.cleanup(repo)
            repo = nil
        end,
    },
})

--- The changes of `repo` now, with the confirms off.
---@return IterFileActionContext
local function context()
    return {
        changes = changes.build(git.status_snapshot(repo)),
        config = config.resolve({
            confirm = { discard = false, ignore = false },
        }),
    }
end

--- The item of `side` at `path`.
---@param ctx IterFileActionContext
---@param side IterSide
---@param path string
---@return IterChange
local function item(ctx, side, path)
    for _, candidate in ipairs(ctx.changes[side]) do
        if candidate.path == path then
            return candidate
        end
    end

    error('no ' .. side .. ' item ' .. path)
end

---@return string porcelain status of `repo`
local function status()
    return vim.trim(helpers.git(repo, { 'status', '--porcelain' }))
end

T['stage()'] = new_set()

T['stage()']['stages an unstaged file'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    local result =
        assert(actions.stage(ctx, { item(ctx, 'unstaged', 'modified.txt') }))

    eq(result.ok, true)
    eq(result.fallback, 'Cannot stage modified.txt')
    eq(result.action, 'stage')
    eq(result.paths, { 'modified.txt' })
    eq(status():find('M  modified.txt', 1, true) ~= nil, true)
end

T['stage()']['unstages when every item is staged'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    local result =
        assert(actions.stage(ctx, { item(ctx, 'staged', 'staged.txt') }))

    eq(result.action, 'unstage')
    eq(result.paths, { 'staged.txt' })
    eq(status():find(' M staged.txt', 1, true) ~= nil, true)
end

T['stage()']['skips a nested repository with a warning'] = function()
    repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    helpers.git(repo, { 'init', '--quiet', 'sub' })
    helpers.write_file(vim.fs.joinpath(repo, 'sub', 'x.txt'), { 'x' })
    local ctx = context()
    local nested = item(ctx, 'unstaged', 'sub/')

    eq(nested.dir, true)
    eq(actions.stage(ctx, { nested }), nil)
    eq(warnings, { '[iter] Skipped the nested repository sub/' })
end

T['stage()']['refuses against a base'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()
    local base = vim.tbl_extend(
        'force',
        item(ctx, 'unstaged', 'modified.txt'),
        { side = 'base' }
    )

    eq(actions.stage(ctx, { base }), nil)
    eq(actions.unstage(ctx, { base }), nil)
    eq(actions.discard(ctx, base), nil)
    eq(actions.ignore(ctx, base), nil)
    eq(warnings, {
        '[iter] Staging does not apply against a base',
        '[iter] Unstaging does not apply against a base',
        '[iter] Discard does not apply against a base',
        '[iter] Ignoring does not apply against a base',
    })
end

T['unstage()'] = new_set()

T['unstage()']['unstages the staged side of an unstaged item'] = function()
    repo = helpers.create_fixture_repo()
    helpers.write_file(
        vim.fs.joinpath(repo, 'staged.txt'),
        { 'alpha', 'beta', 'gamma' }
    )
    local ctx = context()

    local result =
        assert(actions.unstage(ctx, { item(ctx, 'unstaged', 'staged.txt') }))

    eq(result.action, 'unstage')
    eq(result.fallback, 'Cannot unstage staged.txt')
    eq(status():find(' M staged.txt', 1, true) ~= nil, true)
end

T['unstage()']['names the original path of a staged rename first'] = function()
    repo = helpers.create_repo({ ['old.txt'] = { 'same' } })
    helpers.git(repo, { 'mv', 'old.txt', 'new.txt' })
    local ctx = context()

    local result =
        assert(actions.unstage(ctx, { item(ctx, 'staged', 'new.txt') }))

    eq(result.paths, { 'old.txt', 'new.txt' })
end

T['unstage()']['warns when nothing is staged'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    eq(actions.unstage(ctx, { item(ctx, 'unstaged', 'modified.txt') }), nil)
    eq(warnings, { '[iter] Nothing to unstage' })
end

T['discard()'] = new_set()

T['discard()']['refuses a staged item'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    eq(actions.discard(ctx, item(ctx, 'staged', 'staged.txt')), nil)
    eq(warnings, { '[iter] Unstage first' })
end

T['discard()']['restores a tracked file and deletes an untracked one'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    local tracked =
        assert(actions.discard(ctx, item(ctx, 'unstaged', 'modified.txt')))
    local untracked =
        assert(actions.discard(ctx, item(ctx, 'unstaged', 'untracked.txt')))

    eq(tracked.action, 'discard')
    eq(untracked.paths, { 'untracked.txt' })
    eq(
        vim.fn.readfile(vim.fs.joinpath(repo, 'modified.txt')),
        { 'one', 'two', 'three' }
    )
    eq(vim.uv.fs_stat(vim.fs.joinpath(repo, 'untracked.txt')), nil)
end

T['ignore()'] = new_set()

T['ignore()']['refuses a tracked file'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    eq(actions.ignore(ctx, item(ctx, 'unstaged', 'modified.txt')), nil)
    eq(warnings, { '[iter] Only untracked files can be ignored' })
end

T['ignore()']['appends an untracked file and fires no IterStage'] = function()
    repo = helpers.create_fixture_repo()
    local ctx = context()

    local result =
        assert(actions.ignore(ctx, item(ctx, 'unstaged', 'untracked.txt')))

    eq(result.ok, true)
    eq(result.action, nil)
    eq(result.paths, { 'untracked.txt' })
    eq(
        vim.fn.readfile(vim.fs.joinpath(repo, '.gitignore')),
        { '/untracked.txt' }
    )
end

return T
