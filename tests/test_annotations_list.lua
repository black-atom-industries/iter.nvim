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

T['file_lines()']['reads the version of a commit'] = function()
    local first = vim.trim(helpers.git(repo, { 'rev-parse', 'HEAD' }))

    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'one', 'three' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'edit' })

    eq(list.file_lines(repo, 'a.txt', first), { 'one', 'two' })
    eq(list.file_lines(repo, 'gone.txt', first), {})
    eq(list.file_lines(repo, 'a.txt', string.rep('0', 40)), nil)
end

T['resolve()'] = new_set()

T['resolve()']['an old-side annotation on a base follows the commit it stores'] = function()
    helpers.git(repo, { 'switch', '--quiet', '-c', 'feat' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'one' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'drop two' })

    local base = vim.trim(helpers.git(repo, { 'merge-base', 'HEAD', 'main' }))
    ---@param lines string[]
    ---@return IterAnnotation
    local function deleted(lines)
        return {
            id = 'x',
            scope = 'line',
            body = 'Why?',
            anchor = {
                path = 'a.txt',
                side = 'old',
                base = base,
                start_line = 2,
                end_line = 2,
                lines = lines,
            },
            outdated = false,
            created_at = 0,
            updated_at = 0,
        }
    end

    eq({ list.resolve(deleted({ 'two' }), list.reader(repo)) }, {
        2,
        2,
        false,
    })

    -- `main` moving on leaves the stored version as it was.
    helpers.git(repo, { 'switch', '--quiet', 'main' })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'one', 'zwei' })
    helpers.git(repo, { 'commit', '--quiet', '-am', 'on main' })
    helpers.git(repo, { 'switch', '--quiet', 'feat' })

    eq({ list.resolve(deleted({ 'two' }), list.reader(repo)) }, {
        2,
        2,
        false,
    })
    eq({ list.resolve(deleted({ 'gone' }), list.reader(repo)) }, {
        nil,
        nil,
        true,
    })
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

T['line_of()']['returns the columns of a passage'] = function()
    local annotation = {
        scope = 'line',
        anchor = {
            path = 'a.txt',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'one two' },
            start_col = 4,
            end_col = 7,
            quote = 'two',
        },
        outdated = false,
    }

    eq({ list.line_of(annotation, { 'x', 'so one two' }) }, {
        2,
        2,
        false,
        7,
        10,
    })
    eq({ list.line_of(annotation, { 'one' }) }, { nil, nil, true })
end

return T
