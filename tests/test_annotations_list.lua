local helpers = dofile('tests/helpers.lua')
local list = require('iter.annotations.list')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

---@type string
local repo

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'one', 'two' } })
        end,
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

T['file_lines()'] = new_set()

T['file_lines()']['reads each version'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'one', 'new' })

    eq(list.file_lines(repo, 'a.txt'), { 'one', 'new' })
    eq(list.file_lines(repo, 'a.txt', 'HEAD'), { 'one', 'two' })
    eq(list.file_lines(repo, 'a.txt', 'index'), { 'one', 'two' })
end

T['file_lines()']['a path missing from the version has no lines'] = function()
    os.remove(vim.fs.joinpath(repo, 'a.txt'))
    helpers.git(repo, { 'rm', '--quiet', '--cached', 'a.txt' })

    eq(list.file_lines(repo, 'a.txt'), {})
    eq(list.file_lines(repo, 'a.txt', 'index'), {})
    eq(list.file_lines(repo, 'gone.txt', 'HEAD'), {})
end

T['file_lines()']['a version that cannot be read gives nil'] = function()
    local unborn = vim.fn.tempname()
    vim.fn.mkdir(unborn, 'p')
    helpers.git(unborn, { 'init', '--quiet' })

    eq(list.file_lines(unborn, 'a.txt', 'HEAD'), nil)

    helpers.cleanup(unborn)
end

T['line_of()'] = new_set()

T['line_of()']['falls back to the stored flag only without content'] = function()
    local annotation = {
        scope = 'line',
        anchor = {
            path = 'a.txt',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'one' },
        },
        outdated = true,
    }

    eq({ list.line_of(annotation, { 'x', 'one' }) }, { 2, 2, false })
    eq({ list.line_of(annotation, {}) }, { nil, nil, true })
    annotation.outdated = false
    eq({ list.line_of(annotation, {}) }, { nil, nil, true })
    eq({ list.line_of(annotation, nil) }, { nil, nil, false })
end

return T
