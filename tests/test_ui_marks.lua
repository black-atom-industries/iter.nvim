local helpers = dofile('tests/helpers.lua')
local marks = require('iter.comments.marks')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = [[require('iter').current_review]]

---@param prefix string
---@param from integer
---@param to integer
---@return string[]
local function numbered(prefix, from, to)
    local lines = {}

    for i = from, to do
        table.insert(lines, prefix .. i)
    end

    return lines
end

--- `m.txt` (l1..l20) has l3 changed and l8 deleted in the worktree, one
--- hunk over new lines 1 to 10 and a gap below it; `n.txt` gains a line.
---@return string
local function create_marks_repo()
    local path = helpers.create_repo({
        ['m.txt'] = numbered('l', 1, 20),
        ['n.txt'] = { 'n1' },
    })

    local m = numbered('l', 1, 20)
    m[3] = 'l3 new'
    table.remove(m, 8)
    helpers.write_file(vim.fs.joinpath(path, 'm.txt'), m)
    helpers.write_file(vim.fs.joinpath(path, 'n.txt'), { 'n1', 'n2' })

    return path
end

-- One comment of each kind on `m.txt`, one on `n.txt`, one on the review.
local COMMENTS = {
    {
        scope = 'line',
        body = 'Line comment',
        anchor = {
            path = 'm.txt',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'l1' },
        },
    },
    {
        scope = 'range',
        body = 'A range comment that is long enough to wrap at the width of '
            .. 'the diff window, which is eighty columns minus the rail',
        anchor = {
            path = 'm.txt',
            side = 'new',
            start_line = 4,
            end_line = 6,
            lines = { 'l4', 'l5', 'l6' },
        },
    },
    {
        scope = 'line',
        body = 'Deleted line comment',
        anchor = {
            path = 'm.txt',
            side = 'old',
            base = 'index',
            start_line = 8,
            end_line = 8,
            lines = { 'l8' },
        },
    },
    {
        scope = 'file',
        body = 'File comment',
        anchor = { path = 'm.txt', side = 'new' },
    },
    {
        scope = 'line',
        body = 'Outdated comment',
        anchor = {
            path = 'm.txt',
            side = 'new',
            start_line = 9,
            end_line = 9,
            lines = { 'vanished' },
        },
    },
    {
        scope = 'line',
        body = 'Hidden comment',
        anchor = {
            path = 'm.txt',
            side = 'new',
            start_line = 15,
            end_line = 15,
            lines = { 'l16' },
        },
    },
    {
        scope = 'line',
        body = 'Other file comment',
        anchor = {
            path = 'n.txt',
            side = 'new',
            start_line = 2,
            end_line = 2,
            lines = { 'n2' },
        },
    },
    {
        scope = 'review',
        body = 'Review comment',
        anchor = { side = 'new' },
    },
}

--- Store `comments` for the child's repository.
---@param comments table[]
local function seed(comments)
    child.lua(
        [[
        local store = require('iter.store')
        for _, comment in ipairs(...) do
            comment.outdated = comment.outdated or false
            assert(store.put_comment(vim.fn.getcwd(), comment))
        end
    ]],
        { comments }
    )
end

local function stub_ui()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
    ]])
end

--- Wait until the review's diff pane shows `expected` (`side path`).
---@param expected string
local function wait_diff(expected)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                local f = r and r.drawer.view.files[1]
                return f ~= nil and f.side .. ' ' .. f.path == %q
                    and r.drawer.view:is_shown()
            end)()]],
            R,
            expected
        )
    )
end

---@param expected? string diff to wait for, `unstaged m.txt` by default
local function open_review(expected)
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.win ~= nil]]
    )
    wait_diff(expected or 'unstaged m.txt')
end

--- Each comment mark of the review's diff buffer as `<lnum> <text>`, the
--- text being its virtual lines joined by `|` with trailing blanks cut.
---@return string[]
local function placed()
    return child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.comments']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
            local lines = {}
            for _, line in ipairs(mark[4].virt_lines or {}) do
                local text = ''
                for _, chunk in ipairs(line) do
                    text = text .. chunk[1]
                end
                table.insert(lines, (text:gsub('%s+$', '')))
            end
            table.insert(result, (mark[2] + 1) .. ' ' .. table.concat(lines, '|'))
        end
        return result
    end)()]])
end

---@return integer
local function cursor_lnum()
    return child.lua_get(
        [[vim.api.nvim_win_get_cursor(require('iter').current_review.diff_win)[1] ]]
    )
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_marks_repo()
            helpers.start_child(child, repo, { lines = 36 })
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['diff view'] = new_set()

T['diff view']['shows each comment kind under its row'] = function()
    seed(COMMENTS)
    open_review()

    eq(placed(), {
        '1 ▎ File comment',
        '3 ▎ Line comment',
        '9 ▎ A range comment that is long enough to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus the rail',
        '11 ▎ Deleted line comment',
        '13 ▎ outdated · Outdated comment',
        '15 ▎ Hidden comment',
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'marks-diff')
end

T['diff view']['dims outdated comments'] = function()
    seed(COMMENTS)
    open_review()

    local groups = child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.comments']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
            result[mark[2] + 1] = mark[4].virt_lines[1][2][2]
        end
        return result
    end)()]])

    eq(groups[3], 'IterDiffComment')
    eq(groups[13], 'IterDiffCommentOutdated')
end

T['diff view']['rewraps the text when the window width changes'] = function()
    seed({ COMMENTS[2] })
    open_review()

    eq(placed(), {
        '9 ▎ A range comment that is long enough to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus the rail',
    })

    child.o.columns = 50
    helpers.wait_until(
        child,
        [[#vim.api.nvim_buf_get_extmarks(require('iter').current_review.drawer.view.buf, vim.api.nvim_get_namespaces()['iter.diff.comments'], 0, -1, { details = true })[1][4].virt_lines > 2]]
    )

    eq(placed(), {
        '9 ▎ A range comment that is long enough to'
            .. '|▎ wrap at the width of the diff window,'
            .. '|▎ which is eighty columns minus the rail',
    })

    -- Stacked at 50 columns, the count still ends the full-width cell.
    eq(
        child.lua_get(
            R
                .. [[.drawer.layout .. '|' .. vim.api.nvim_buf_get_lines(]]
                .. R
                .. [[.drawer.buf, 1, 2, false)[1] ]]
        ),
        'stacked| M m.txt' .. string.rep(' ', 38) .. '[1] '
    )
end

T['diff view']['rewraps when only the diff window narrows'] = function()
    seed({ COMMENTS[2] })
    open_review()

    child.lua([[
        local win = require('iter').current_review.diff_win
        vim.api.nvim_win_call(win, function()
            vim.cmd('rightbelow vnew')
        end)
        vim.api.nvim_win_set_width(win, 50)
    ]])
    helpers.wait_until(
        child,
        [[#vim.api.nvim_buf_get_extmarks(require('iter').current_review.drawer.view.buf, vim.api.nvim_get_namespaces()['iter.diff.comments'], 0, -1, { details = true })[1][4].virt_lines > 2]]
    )

    eq(
        child.lua_get([[vim.api.nvim_win_get_width(]] .. R .. [[.diff_win)]]),
        50
    )
    eq(placed(), {
        '9 ▎ A range comment that is long enough to'
            .. '|▎ wrap at the width of the diff window,'
            .. '|▎ which is eighty columns minus the rail',
    })
    eq(child.lua_get(R .. '.drawer.layout'), 'columns')
end

T['diff view']['expanding a gap moves a hidden comment to its line'] = function()
    seed({ COMMENTS[6] })
    open_review()

    eq(placed(), { '15 ▎ Hidden comment' })

    child.lua([[
        local view = require('iter').current_review.drawer.view
        view:expand(15)
    ]])

    -- The gap of nine lines opens whole: l12 to l20 on rows 15 to 23.
    eq(placed(), { '19 ▎ Hidden comment' })
    eq(child.lua_get(R .. '.drawer.view.rows[19].text'), 'l16')
end

T['diff view']['a refresh picks up comments written meanwhile'] = function()
    open_review()
    eq(placed(), {})

    seed({ COMMENTS[1] })
    child.lua(R .. '.drawer:refresh()')

    eq(placed(), { '3 ▎ Line comment' })
end

T['diff view']['a fully staged file outdates a lost comment'] = function()
    helpers.git(repo, { 'add', 'm.txt' })
    seed({ COMMENTS[5] })
    open_review('unstaged n.txt')
    child.lua([[
        local d = require('iter').current_review.drawer
        d:step_file(1)
    ]])
    wait_diff('staged m.txt')

    eq(placed(), { '13 ▎ outdated · Outdated comment' })
end

T['diff view']['a partly staged file leaves a lost comment out'] = function()
    helpers.git(repo, { 'add', 'm.txt' })
    helpers.write_file(
        vim.fs.joinpath(repo, 'm.txt'),
        vim.list_extend(
            { 'top' },
            vim.fn.readfile(vim.fs.joinpath(repo, 'm.txt'))
        )
    )
    seed({ COMMENTS[5] })
    open_review()
    child.lua([[
        local d = require('iter').current_review.drawer
        d:step_file(1)
        d:step_file(1)
    ]])
    wait_diff('staged m.txt')

    eq(placed(), {})
end

T['diff view']['a failed store read keeps the comments'] = function()
    seed({ COMMENTS[1] })
    open_review()
    eq(placed(), { '3 ▎ Line comment' })

    child.lua([[
        local path = require('iter.store').path(vim.fn.getcwd())
        vim.fn.writefile({ '{"version":2,"comments":[],"viewed":{}}' }, path)
        require('iter').current_review.drawer:refresh()
    ]])

    eq(placed(), { '3 ▎ Line comment' })
    eq(
        child.lua_get(
            [[#vim.api.nvim_buf_get_lines(]]
                .. R
                .. [[.drawer.buf, 1, 2, false)[1]:match('%[1%]') > 0]]
        ),
        true
    )
end

T['diff view']['a refresh reads the store only when its file changed'] = function()
    seed({ COMMENTS[1] })
    open_review()
    child.lua([[
        local store = require('iter.store')
        local load = store.load
        _G.loads = 0
        store.load = function(...)
            _G.loads = _G.loads + 1
            return load(...)
        end
        local d = require('iter').current_review.drawer
        d:refresh('poll')
        d:refresh('poll')
    ]])
    eq(child.lua_get('_G.loads'), 0)

    seed({ COMMENTS[2] })
    child.lua(R .. [[.drawer:refresh('poll')]])

    eq(child.lua_get('_G.loads'), 1)
    eq(#placed(), 2)
end

T['keys'] = new_set()

T['keys'][']a and [a step through the comment rows in order'] = function()
    seed(COMMENTS)
    open_review()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.lua([[vim.api.nvim_win_set_cursor(]] .. R .. [[.diff_win, { 1, 0 })]])

    local forward = {}

    for _ = 1, 6 do
        child.type_keys(']a')
        table.insert(forward, cursor_lnum())
    end

    eq(forward, { 3, 9, 11, 13, 15, 15 })

    local back = {}

    for _ = 1, 6 do
        child.type_keys('[a')
        table.insert(back, cursor_lnum())
    end

    eq(back, { 13, 11, 9, 3, 1, 1 })
end

-- Neovim maps `]a` globally to `:next`; only a buffer-local map is iter's.
local BUFFER_MAP = [[vim.fn.maparg(']a', 'n', false, true).buffer or 0]]

T['keys'][']a is mapped only in iter buffers'] = function()
    seed(COMMENTS)
    child.cmd('edit m.txt')
    eq(child.lua_get(BUFFER_MAP), 0)

    open_review()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    eq(
        child.lua_get([[vim.fn.maparg(']a', 'n', false, true).desc]]),
        'Next comment'
    )
    eq(
        child.lua_get([[vim.fn.maparg('[a', 'n', false, true).desc]]),
        'Previous comment'
    )

    child.cmd('tabprevious')
    eq(child.lua_get(BUFFER_MAP), 0)
end

T['counts'] = new_set()

T['counts']['the review drawer shows counts on rows and in the header'] = function()
    seed(COMMENTS)
    open_review()

    local lines = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]] .. R .. [[.drawer.buf, 0, -1, false)]]
    )

    -- The count sits at the right end of the cell, which keeps its width.
    eq(
        vim.split(lines[2], '│')[1],
        ' M m.txt' .. string.rep(' ', 27) .. '[6] '
    )
    eq(
        vim.split(lines[3], '│')[1],
        ' M n.txt' .. string.rep(' ', 27) .. '[1] '
    )

    local title = child.lua_get([[(function()
        local text = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(]] .. R .. [[.drawer.win).title) do
            text = text .. chunk[1]
        end
        return text
    end)()]])

    eq(title, 'HEAD main · 2 changes · 8 comments')
end

T['counts']['the status drawer shows no counts and no marks'] = function()
    seed(COMMENTS)
    child.cmd('edit m.txt')
    child.cmd('Iter')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.view:is_shown()]]
    )

    local state = child.lua_get([[(function()
        local d = require('iter').drawer
        local title = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(d.win).title) do
            title = title .. chunk[1]
        end
        local ns = vim.api.nvim_get_namespaces()['iter.diff.comments']
        return {
            lines = vim.api.nvim_buf_get_lines(d.buf, 0, -1, false),
            title = title,
            marks = ns and #vim.api.nvim_buf_get_extmarks(d.view.buf, ns, 0, -1, {}) or 0,
            next_comment = (function()
                for _, map in ipairs(vim.api.nvim_buf_get_keymap(d.view.buf, 'n')) do
                    if map.lhs == ']a' then
                        return map.lhs
                    end
                end
                return ''
            end)(),
        }
    end)()]])

    eq(state.title, 'HEAD main · 2 changes')
    eq(vim.trim(vim.split(state.lines[2], '│')[1]), 'M m.txt')
    eq(state.marks, 0)
    eq(state.next_comment, '')
end

T['place()'] = new_set()

---@param side 'unstaged'|'staged'
---@return IterFileDiff
local function file_diff(side)
    return {
        path = 'f.txt',
        side = side,
        code = 'M',
        raw = {},
        hunks = {},
        binary = false,
        stat = { add = 1, del = 1 },
        old_lines = { 'a', 'b', 'c' },
        new_lines = { 'a', 'B', 'c' },
        rows = {
            { kind = 'header', text = 'f.txt' },
            { kind = 'hunk', text = '@@ -1,3 +1,3 @@' },
            { kind = 'context', text = 'a', old = 1, new = 1 },
            { kind = 'del', text = 'b', old = 2 },
            { kind = 'add', text = 'B', new = 2 },
            { kind = 'context', text = 'c', old = 3, new = 3 },
        },
    }
end

---@param body string
---@param a table
---@return IterComment
local function comment(body, a)
    return {
        id = body,
        scope = a.start_line and 'line' or 'file',
        anchor = vim.tbl_extend('keep', a, { path = 'f.txt' }),
        body = body,
        outdated = false,
        created_at = 1,
        updated_at = 1,
    }
end

---@param result IterCommentMark[]
---@return string[]
local function summary(result)
    return vim.tbl_map(function(mark)
        return string.format(
            '%d %s%s',
            mark.lnum,
            mark.comment.body,
            mark.outdated and ' (outdated)' or ''
        )
    end, result)
end

T['place()']['puts old-side comments only in the view of their base'] = function()
    local comments = {
        comment('index', {
            side = 'old',
            base = 'index',
            start_line = 2,
            end_line = 2,
            lines = { 'b' },
        }),
        comment('head', {
            side = 'old',
            base = 'HEAD',
            start_line = 2,
            end_line = 2,
            lines = { 'b' },
        }),
    }

    eq(summary(marks.place(file_diff('unstaged'), comments)), { '4 index' })
    eq(summary(marks.place(file_diff('staged'), comments)), { '4 head' })
end

T['place()']['outdates new-side comments only against the worktree'] = function()
    local comments = {
        comment('found', {
            side = 'new',
            start_line = 2,
            end_line = 2,
            lines = { 'B' },
        }),
        comment('gone', {
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'gone' },
        }),
    }

    eq(
        summary(marks.place(file_diff('unstaged'), comments)),
        { '5 found', '6 gone (outdated)' }
    )
    -- The index is not the version the anchor follows, so a miss there says
    -- nothing about the comment.
    eq(summary(marks.place(file_diff('staged'), comments)), { '5 found' })
end

T['place()']['puts what has no row on the header'] = function()
    local file = file_diff('unstaged')
    local comments = {
        comment('file', { side = 'new' }),
        comment('beyond', {
            side = 'new',
            start_line = 40,
            end_line = 40,
            lines = { 'gone' },
        }),
        comment('elsewhere', {
            path = 'other.txt',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'a' },
        }),
        {
            id = 'review',
            scope = 'review',
            anchor = { side = 'new' },
            body = 'review',
            outdated = false,
            created_at = 1,
            updated_at = 1,
        },
    }

    eq(
        summary(marks.place(file, comments)),
        { '1 file', '1 beyond (outdated)' }
    )
end

T['place()']['outdates against the index when it is the worktree'] = function()
    local comments = {
        comment('gone', {
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'gone' },
        }),
    }

    eq(
        summary(
            marks.place(file_diff('staged'), comments, { new_follows = true })
        ),
        { '6 gone (outdated)' }
    )
end

T['place()']['uses stored lines when the versions are missing'] = function()
    local file = file_diff('unstaged')
    file.old_lines, file.new_lines = nil, nil
    local stored = comment('stored', {
        side = 'new',
        start_line = 2,
        end_line = 2,
        lines = { 'x' },
    })
    stored.outdated = true

    eq(summary(marks.place(file, { stored })), { '5 stored (outdated)' })
end

T['place()']['places old-side comments of a rename by its old path'] = function()
    local file = file_diff('staged')
    file.path, file.orig_path = 'g.txt', 'f.txt'

    eq(
        summary(marks.place(file, {
            comment('old', {
                side = 'old',
                base = 'HEAD',
                start_line = 2,
                end_line = 2,
                lines = { 'b' },
            }),
        })),
        { '4 old' }
    )
end

T['lines()'] = new_set()

T['lines()']['wraps on words, splits long words and keeps line breaks'] = function()
    local text = vim.tbl_map(
        function(line)
            return line[2][1]
        end,
        marks.lines(
            comment('one two three\n\nabcdefghijkl', { side = 'new' }),
            false,
            8
        )
    )

    eq(text, {
        'one   ',
        'two   ',
        'three ',
        '      ',
        'abcdef',
        'ghijkl',
    })
end

return T
