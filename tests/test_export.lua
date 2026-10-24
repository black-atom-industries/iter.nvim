local helpers = dofile('tests/helpers.lua')
local export = require('iter.export')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = [[require('iter').current_review]]
local INTRO = 'I reviewed your changes and have these annotations.\n'
    .. 'Please address them.'

---@param path string
---@param start integer
---@param stop integer
---@param lines string[]
---@param side? 'old'|'new'
---@return table
local function anchor(path, start, stop, lines, side)
    return {
        path = path,
        side = side or 'new',
        base = side == 'old' and 'HEAD' or nil,
        start_line = start,
        end_line = stop,
        lines = lines,
    }
end

local A_LUA = { '-- head', 'local x = 1', '', 'return x' }
local FILES = {
    ['a.lua'] = A_LUA,
    ['doc.md'] = { '```lua', 'x', '```' },
}

-- Stored in this order; the export sorts them.
local FIXTURE = {
    {
        id = '1',
        scope = 'review',
        body = 'Overall fine\r\nbut tidy up\n\n',
        anchor = { side = 'new' },
        outdated = false,
    },
    {
        id = '2',
        scope = 'range',
        body = 'Rename it',
        anchor = anchor('a.lua', 1, 3, { 'local x = 1', '', 'return x' }),
        outdated = false,
    },
    {
        id = '3',
        scope = 'line',
        body = 'Why removed?',
        anchor = anchor('a.lua', 9, 9, { 'old line' }, 'old'),
        outdated = false,
    },
    {
        id = '4',
        scope = 'line',
        body = 'Stale',
        anchor = anchor('a.lua', 5, 5, { 'gone' }),
        outdated = false,
    },
    {
        id = '5',
        scope = 'file',
        body = 'Needs tests',
        anchor = { path = 'a.lua', side = 'new' },
        outdated = false,
    },
    {
        id = '6',
        scope = 'range',
        body = 'Fix\r\nthis',
        anchor = anchor('doc.md', 1, 3, { '```lua\r', 'x', '```' }),
        outdated = false,
    },
    {
        id = '7',
        scope = 'line',
        body = 'Both',
        anchor = anchor('b.lua', 3, 3, { 'was' }, 'old'),
        outdated = true,
    },
}

---@param annotations table[]
---@param order? string[]
---@param versions? table<string, table<string, string[]>> lines by version, then path; `FILES` as the worktree by default
---@return string
local function text(annotations, order, versions)
    versions = versions or { worktree = FILES }

    return export.text(annotations, {
        intro = INTRO,
        order = order,
        lines_of = function(path, version)
            return (versions[version] or {})[path]
        end,
    })
end

local T = new_set()

T['text'] = new_set()

T['text']['lists a fixture store in exact text'] = function()
    eq(
        text(FIXTURE, { 'doc.md', 'a.lua' }),
        table.concat({
            INTRO,
            '',
            '1. doc.md:1-3',
            '   ````markdown',
            '   ```lua',
            '   x',
            '   ```',
            '   ````',
            '   Fix',
            '   this',
            '2. a.lua (file)',
            '   Needs tests',
            '3. a.lua:2-4',
            '   ```lua',
            '   local x = 1',
            '',
            '   return x',
            '   ```',
            '   Rename it',
            '4. a.lua:5 (outdated)',
            '   ```lua',
            '   gone',
            '   ```',
            '   Stale',
            '5. a.lua:9 (old side)',
            '   ```lua',
            '   old line',
            '   ```',
            '   Why removed?',
            '6. b.lua:3 (old side, outdated)',
            '   ```lua',
            '   was',
            '   ```',
            '   Both',
            '7. Review',
            '   Overall fine',
            '   but tidy up',
        }, '\n')
    )
end

T['text']['resolves an old-side annotation against its base'] = function()
    local annotations = {
        {
            id = 'moved',
            scope = 'line',
            body = 'Moved',
            anchor = anchor('a.lua', 9, 9, { 'old line' }, 'old'),
            outdated = true,
        },
        {
            id = 'gone',
            scope = 'line',
            body = 'Gone',
            anchor = anchor('b.lua', 3, 3, { 'was' }, 'old'),
            outdated = false,
        },
    }
    local out = text(annotations, nil, {
        worktree = FILES,
        HEAD = {
            ['a.lua'] = { 'one', 'old line' },
            ['b.lua'] = { 'one', 'two', 'three' },
        },
    })

    eq(out:find('\n1. a.lua:2 (old side)\n', 1, true) ~= nil, true)
    eq(out:find('\n2. b.lua:3 (old side, outdated)\n', 1, true) ~= nil, true)
end

T['text']['has no carriage returns'] = function()
    eq(text(FIXTURE):find('\r', 1, true), nil)
end

T['text']['follows name order without a given order'] = function()
    local out = text(FIXTURE)

    eq(out:find('\n1. a.lua (file)\n', 1, true) ~= nil, true)
    eq(out:find('\n6. doc.md:1-3\n', 1, true) ~= nil, true)
end

T['text']['uses a fence longer than any backtick run in the code'] = function()
    local out = text({
        {
            id = 'x',
            scope = 'line',
            body = 'c',
            anchor = anchor('a.lua', 1, 1, { 'x = [=[ `````` ]=]' }),
            outdated = false,
        },
    })

    eq(
        out,
        table.concat({
            INTRO,
            '',
            '1. a.lua:1 (outdated)',
            '   ```````lua',
            '   x = [=[ `````` ]=]',
            '   ```````',
            '   c',
        }, '\n')
    )
end

T['text']['omits the language of an unknown filetype'] = function()
    local out = text({
        {
            id = 'x',
            scope = 'line',
            body = 'c',
            anchor = anchor('notes.zzzunknown', 1, 1, { 'a' }),
            outdated = false,
        },
    })

    eq(out:find('\n   ```\n   a\n   ```\n', 1, true) ~= nil, true)
end

T['text']['indents to the width of the item number'] = function()
    local annotations = {}

    for i = 1, 10 do
        table.insert(annotations, {
            id = tostring(i),
            scope = 'review',
            body = 'r' .. i .. '\nsecond',
            anchor = { side = 'new' },
            outdated = false,
        })
    end

    local lines = vim.split(text(annotations), '\n')

    eq(lines[#lines - 2], '10. Review')
    eq(lines[#lines - 1], '    r10')
    eq(lines[#lines], '    second')
end

T['text']['an empty store is only the intro'] = function()
    eq(text({}), INTRO .. '\n')
end

T['yank'] = new_set({
    hooks = {
        pre_case = function()
            repo = helpers.create_repo({
                ['a.lua'] = { 'one', 'two', 'three' },
                ['b.txt'] = { 'b' },
            })
            helpers.write_file(
                vim.fs.joinpath(repo, 'a.lua'),
                { 'one', 'two new', 'three' }
            )
            helpers.start_child(child, repo)
            child.lua([[
                _G.clip = {}
                vim.g.clipboard = {
                    name = 'test',
                    copy = {
                        ['+'] = function(lines) _G.clip = lines end,
                        ['*'] = function(lines) _G.clip = lines end,
                    },
                    paste = {
                        ['+'] = function() return { _G.clip, 'l' } end,
                        ['*'] = function() return { _G.clip, 'l' } end,
                    },
                }
                _G.notes = {}
                vim.notify = function(msg, level)
                    table.insert(_G.notes, { msg, level })
                end
                _G.echoes = {}
                local echo = vim.api.nvim_echo
                vim.api.nvim_echo = function(chunks, ...)
                    table.insert(_G.echoes, chunks[1][1])
                    return echo(chunks, ...)
                end
            ]])
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

local function seed()
    child.lua([[
        local store = require('iter.store')
        local root = vim.fn.getcwd()
        assert(store.put_annotation(root, {
            scope = 'review',
            body = 'Overall fine',
            anchor = { side = 'new' },
        }))
        assert(store.put_annotation(root, {
            scope = 'line',
            body = 'Why this?',
            anchor = {
                path = 'a.lua', side = 'new', start_line = 2, end_line = 2,
                lines = { 'two new' },
            },
        }))
    ]])
end

local EXPECTED = table.concat({
    'I reviewed your changes and have these annotations.',
    'Please address them.',
    '',
    '1. a.lua:2',
    '   ```lua',
    '   two new',
    '   ```',
    '   Why this?',
    '2. Review',
    '   Overall fine',
    '',
}, '\n')

---@return integer
local function stored_count()
    return child.lua_get(
        [[#require('iter.store').load(vim.fn.getcwd()).annotations]]
    )
end

---@return string[]
local function notes()
    return vim.tbl_map(function(note)
        return note[1]
    end, child.lua_get('_G.notes'))
end

local function open_review()
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                return r and r.drawer.win and r.drawer.view:is_shown()
            end)()]],
            R
        )
    )
end

local function expect_copied()
    eq(child.fn.getreg('+'), EXPECTED)
    eq(child.fn.getreg('"'), EXPECTED)
    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 2 annotations. Clear them? [y/N]' }
    )
end

T['yank']['Y in the drawer copies all and clears on y'] = function()
    seed()
    open_review()
    child.type_keys('Y')
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 0]]
    )
    expect_copied()
    eq(child.lua_get(R .. [[:is_open()]]), true)
end

T['yank']['n keeps the annotations'] = function()
    seed()
    open_review()
    child.type_keys('Y')
    child.type_keys('n')
    helpers.wait_until(child, [[#_G.echoes == 1 and vim.fn.mode() == 'n']])
    expect_copied()
    eq(stored_count(), 2)
end

T['yank']['Enter keeps the annotations'] = function()
    seed()
    open_review()
    child.type_keys('Y')
    child.type_keys('<CR>')
    helpers.wait_until(child, [[#_G.echoes == 1 and vim.fn.mode() == 'n']])
    eq(stored_count(), 2)
end

T['yank']['Esc keeps the annotations'] = function()
    seed()
    open_review()
    child.type_keys('Y')
    child.type_keys('<Esc>')
    helpers.wait_until(child, [[#_G.echoes == 1 and vim.fn.mode() == 'n']])
    expect_copied()
    eq(stored_count(), 2)
end

T['yank']['Y in the diff pane works'] = function()
    seed()
    open_review()
    child.type_keys('<CR>')
    helpers.wait_until(
        child,
        [[vim.api.nvim_get_current_win() == ]] .. R .. [[.diff_win]]
    )
    child.type_keys('Y')
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 0]]
    )
    expect_copied()
end

T['yank']['clearing refreshes the review'] = function()
    seed()
    open_review()
    child.type_keys('Y')
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[not table.concat(vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.buf, 0, -1, false), '\n'):find('annotations')]]
    )
end

T['yank']['clears only the annotations that were copied'] = function()
    seed()
    child.lua_notify([[require('iter').yank()]])
    helpers.wait_until(child, [[#_G.echoes == 1]])
    assert(require('iter.store').put_annotation(repo, {
        scope = 'review',
        body = 'Late',
        anchor = { side = 'new' },
    }))
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 1]]
    )
    eq(
        child.lua_get(
            [[require('iter.store').load(vim.fn.getcwd()).annotations[1].body]]
        ),
        'Late'
    )
end

T['yank']['copies and clears annotations queued under a held lock'] = function()
    seed()
    child.lua([[
        local store = require('iter.store')
        local root = vim.fn.getcwd()
        local lock = assert(store.path(root)) .. '.lock'
        vim.fn.writefile({ 'another instance' }, lock)
        assert(store.put_annotation(root, {
            scope = 'line',
            body = 'Queued',
            anchor = {
                path = 'a.lua', side = 'new', start_line = 1, end_line = 1,
                lines = { 'one' },
            },
        }))
    ]])
    eq(stored_count(), 2)
    child.lua_notify([[require('iter').yank()]])
    helpers.wait_until(child, [[#_G.echoes == 1]])
    eq(child.fn.getreg('+'):find('Queued', 1, true) ~= nil, true)
    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 3 annotations. Clear them? [y/N]' }
    )
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').cached(vim.fn.getcwd(), true).annotations == 0]]
    )
    child.lua([[
        vim.uv.fs_unlink(require('iter.store').path(vim.fn.getcwd()) .. '.lock')
    ]])
end

--- The id of the stored annotation with `body`.
---@param body string
---@return string
local function id_of(body)
    return child.lua_get(
        [[(function(body)
            for _, a in ipairs(require('iter.store').load(vim.fn.getcwd()).annotations) do
                if a.body == body then
                    return a.id
                end
            end
        end)(...)]],
        { body }
    )
end

T['yank']['ids copies only those annotations and asks about one'] = function()
    seed()
    child.lua_notify(
        [[require('iter').yank({ ids = { ... } })]],
        { id_of('Why this?') }
    )
    helpers.wait_until(child, [[#_G.echoes == 1]])
    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(child.fn.getreg('+'):find('Why this?', 1, true) ~= nil, true)
    eq(child.fn.getreg('+'):find('Overall fine', 1, true), nil)
    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])
    eq(stored_count(), 2)
end

T['yank']['ids removes only those annotations on y'] = function()
    seed()
    child.lua_notify(
        [[require('iter').yank({ ids = { ... } })]],
        { id_of('Why this?') }
    )
    helpers.wait_until(child, [[#_G.echoes == 1]])
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 1]]
    )
    eq(
        child.lua_get(
            [[require('iter.store').load(vim.fn.getcwd()).annotations[1].body]]
        ),
        'Overall fine'
    )
end

T['yank']['ids that match nothing warn'] = function()
    seed()
    child.lua([[require('iter').yank({ ids = {} })]])
    eq(notes(), { '[iter] No annotations to copy' })
    eq(child.lua_get('_G.echoes'), {})
    eq(child.fn.getreg('"'), '')
    eq(stored_count(), 2)
end

T['yank']['the API works without a review'] = function()
    seed()
    child.lua_notify([[require('iter').yank()]])
    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 0]]
    )
    expect_copied()
end

T['yank']['warns when there is nothing to copy'] = function()
    open_review()
    child.type_keys('y')
    helpers.wait_until(child, [[#_G.notes == 1]])
    eq(notes(), { '[iter] No annotations to copy' })
    eq(child.lua_get('_G.echoes'), {})
    eq(child.fn.getreg('"'), '')
    eq(child.fn.getreg('+'), '')
    eq(child.fn.mode(), 'n')
end

T['yank']['the API warns outside a repository'] = function()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    child.cmd('cd ' .. vim.fn.fnameescape(dir))
    child.lua([[require('iter').yank()]])
    eq(notes(), { '[iter] Not inside a git repository' })
end

T['yank']['uses the configured intro'] = function()
    child.lua(
        [[require('iter').setup({ export = { intro = 'Check these.' } })]]
    )
    seed()
    child.lua_notify([[require('iter').yank()]])
    child.type_keys('n')
    helpers.wait_until(child, [[#_G.echoes == 1 and vim.fn.mode() == 'n']])
    eq(vim.startswith(child.fn.getreg('"'), 'Check these.\n\n1. a.lua:2'), true)
end

return T
