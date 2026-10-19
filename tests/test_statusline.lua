local helpers = dofile('tests/helpers.lua')
local changes = require('iter.changes')
local git = require('iter.git')
local statusline = require('iter.statusline')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local original_cwd
---@type string
local repo

local T = new_set({
    hooks = {
        pre_case = function()
            original_cwd = vim.fn.getcwd()
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'changed' })
            helpers.write_file(vim.fs.joinpath(repo, 'new.txt'), { 'new' })
            vim.cmd.cd(vim.fn.fnameescape(repo))
        end,
        post_case = function()
            vim.cmd.cd(vim.fn.fnameescape(original_cwd))
            helpers.cleanup(repo)
        end,
    },
})

T['get()'] = new_set()

T['get()']['returns the part cached by update()'] = function()
    statusline.update(changes.build(git.status_snapshot(repo)))

    eq(statusline.get(), 'main · 2')
end

T['get()']['counts a file on both sides once'] = function()
    helpers.git(repo, { 'add', 'a.txt' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'again' })
    statusline.update(changes.build(git.status_snapshot(repo)))

    eq(statusline.get(), 'main · 2')
end

T['get()']['reads a new root once in the background'] = function()
    eq(statusline.get(), '')
    eq(
        vim.wait(2000, function()
            return statusline.get() ~= ''
        end, 10),
        true
    )
    eq(statusline.get(), 'main · 2')
end

T['get()']['a failed first read is tried again'] = function()
    local dir = vim.fn.resolve(vim.fn.tempname())

    helpers.write_file(vim.fs.joinpath(dir, '.git'), { 'gitdir: /nowhere' })
    vim.cmd.cd(vim.fn.fnameescape(dir))

    eq(statusline.get(), '')
    vim.wait(300)
    eq(statusline.get(), '')
    vim.wait(300)

    vim.fn.delete(vim.fs.joinpath(dir, '.git'))
    helpers.git(dir, { 'init', '--quiet', '-b', 'main' })
    helpers.write_file(vim.fs.joinpath(dir, 'x.txt'), { 'x' })
    vim.wait(300)

    eq(
        vim.wait(2000, function()
            return statusline.get() ~= ''
        end, 10),
        true
    )
    eq(statusline.get(), 'main · 1')

    helpers.cleanup(dir)
end

T['setup()'] = new_set()

T['setup()']['an event reads the status again'] = function()
    statusline.setup()
    statusline.update(changes.build(git.status_snapshot(repo)))
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b' })
    helpers.write_file(vim.fs.joinpath(repo, 'c.txt'), { 'c' })

    eq(statusline.get(), 'main · 2')

    vim.api.nvim_exec_autocmds('FocusGained', {})

    eq(
        vim.wait(2000, function()
            return statusline.get() == 'main · 4'
        end, 10),
        true
    )
    vim.api.nvim_del_augroup_by_name('iter.statusline')
end

T['get()']['is empty outside a repository'] = function()
    local dir = vim.fn.resolve(vim.fn.tempname())

    vim.fn.mkdir(dir, 'p')
    vim.cmd.cd(vim.fn.fnameescape(dir))

    eq(statusline.get(), '')

    helpers.cleanup(dir)
end

return T
