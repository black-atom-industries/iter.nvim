local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local commits = require('iter.ui.commits')
local git = require('iter.git')

---@type string
local repo

local T = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({ ['a.txt'] = { 'a1', 'a2' } })
            helpers.write_file(
                vim.fs.joinpath(repo, 'a.txt'),
                { 'a1', 'a2 new' }
            )
            helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'b1' })
            helpers.git(repo, { 'add', '--all' })
            helpers.git(
                repo,
                { 'commit', '--quiet', '-m', 'edit a', '-m', 'Add b too.' }
            )
        end,
        post_case = function()
            helpers.cleanup(repo)
        end,
    },
})

---@param lines IterRenderLine[]
---@return string[]
local function texts(lines)
    return vim.tbl_map(function(line)
        return (line.text:gsub('%s+$', ''))
    end, lines)
end

T['summary()'] = new_set()

T['summary()']['one commit: its message, then its files'] = function()
    local newest = assert(git.recent(repo, 2)).commits[1]
    local lines = assert(commits.summary(repo, newest, newest))
    eq(vim.list_slice(texts(lines), 2), {
        '',
        ' edit a',
        '',
        ' Add b too.',
        '',
        ' 2 files  +2 −1',
        ' +1 −1  a.txt',
        ' +1 −0  b.txt',
    })
end

T['summary()']['a range sums up the commits from the oldest'] = function()
    local recent = assert(git.recent(repo, 2))
    local lines =
        assert(commits.summary(repo, recent.commits[2], recent.commits[1]))
    local text = texts(lines)

    eq(vim.tbl_contains(text, ' initial'), true)
    eq(vim.tbl_contains(text, ' edit a'), true)
    eq(text[#text - 2], ' 2 files  +3 −0')
end

T['summary()']['nil with an error for a commit git does not know'] = function()
    local unknown = {
        sha = '0000000',
        full_sha = string.rep('0', 40),
        subject = '',
        time = 0,
        unpushed = false,
    }
    local lines, err = commits.summary(repo, unknown, unknown)

    eq(lines, nil)
    eq(type(err), 'string')
    eq(err ~= '', true)
end

return T
