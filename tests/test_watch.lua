local helpers = dofile('tests/helpers.lua')
local watch = require('iter.watch')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

-- A poll that never fires inside a test, so only the watchers can refresh.
local NO_POLL = 600000

---@type string
local base
---@type IterWatch?
local watcher
---@type string[]
local reasons

---@param root string
---@param poll_ms? integer
local function start(root, poll_ms)
    watcher = watch.start({
        root = root,
        poll_ms = poll_ms or NO_POLL,
        on_change = function(reason)
            table.insert(reasons, reason)
        end,
    })
end

---@param count integer
local function wait_for(count)
    local ok = vim.wait(2000, function()
        return #reasons >= count
    end, 10)

    if not ok then
        error(string.format('Expected %d changes, got %d', count, #reasons), 2)
    end
end

--- Let the debounce settle, then return the number of changes so far.
---@return integer
local function settle()
    vim.wait(300)
    return #reasons
end

---@return { fs_event: integer, timer: integer } open libuv handles
local function handles()
    local counts = { fs_event = 0, timer = 0 }

    vim.uv.walk(function(handle)
        local kind = handle:get_type()

        if counts[kind] ~= nil and not handle:is_closing() then
            counts[kind] = counts[kind] + 1
        end
    end)

    return counts
end

---@return string repo
---@return string worktree linked worktree of the repo
local function linked_worktree()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    local worktree = vim.fs.joinpath(base, 'linked')

    helpers.git(repo, { 'worktree', 'add', '--quiet', '-b', 'feat', worktree })
    helpers.write_file(vim.fs.joinpath(worktree, 'one.txt'), { 'one' })
    helpers.write_file(vim.fs.joinpath(worktree, 'two.txt'), { 'two' })

    return repo, worktree
end

local T = new_set({
    hooks = {
        pre_case = function()
            base = vim.fn.resolve(vim.fn.tempname())
            vim.fn.mkdir(base, 'p')
            reasons = {}
        end,
        post_case = function()
            if watcher ~= nil then
                watcher:stop()
                watcher = nil
            end

            helpers.cleanup(base)
        end,
    },
})

T['git events'] = new_set()

T['git events']['an external git add in a normal repository'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
    start(repo)

    helpers.git(repo, { 'add', 'b.txt' })
    wait_for(1)
    eq(reasons[1], 'git')

    helpers.cleanup(repo)
end

T['git events']['two consecutive git add in a linked worktree'] = function()
    local repo, worktree = linked_worktree()
    start(worktree)

    helpers.git(worktree, { 'add', 'one.txt' })
    wait_for(1)
    local after_first = settle()

    helpers.git(worktree, { 'add', 'two.txt' })
    wait_for(after_first + 1)

    eq(vim.tbl_contains(reasons, 'poll'), false)
    helpers.cleanup(repo)
end

T['git events']['a checkout in a linked worktree'] = function()
    local repo, worktree = linked_worktree()
    start(worktree)

    helpers.git(worktree, { 'checkout', '--quiet', '-b', 'other' })
    wait_for(1)

    helpers.cleanup(repo)
end

T['git events']['debounce a burst into one change'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
    start(repo)

    helpers.git(repo, { 'add', 'b.txt' })
    wait_for(1)
    eq(settle(), 1)

    helpers.cleanup(repo)
end

T['editor events'] = new_set()

T['editor events']['FocusGained'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    start(repo)

    vim.api.nvim_exec_autocmds('FocusGained', {})
    wait_for(1)
    eq(reasons, { 'focus' })

    helpers.cleanup(repo)
end

T['editor events']['BufWritePost inside the root only'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    local outside = vim.fs.joinpath(base, 'outside.txt')
    start(repo)

    vim.cmd.edit(vim.fn.fnameescape(outside))
    vim.cmd('silent write')
    vim.cmd.bwipeout()
    eq(settle(), 0)

    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'a.txt')))
    vim.cmd('silent write')
    vim.cmd.bwipeout()
    wait_for(1)
    eq(vim.tbl_contains(reasons, 'write'), true)

    helpers.cleanup(repo)
end

T['poll'] = new_set()

T['poll']['fires every poll_ms'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    start(repo, 30)

    wait_for(3)
    eq(reasons[1], 'poll')

    helpers.cleanup(repo)
end

T['stop'] = new_set()

T['stop']['ends every event and closes its handles'] = function()
    local repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
    local before = handles()
    start(repo, 30)

    eq(handles().fs_event > before.fs_event, true)
    eq(watcher:is_active(), true)

    watcher:stop()
    watcher:stop()
    eq(watcher:is_active(), false)
    local count = settle()

    helpers.git(repo, { 'add', 'b.txt' })
    vim.api.nvim_exec_autocmds('FocusGained', {})
    eq(settle(), count)
    eq(handles(), before)

    helpers.cleanup(repo)
end

return T
