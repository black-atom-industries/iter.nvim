local helpers = dofile('tests/helpers.lua')
local marks = require('iter.annotations.marks')

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

-- One annotation of each kind on `m.txt`, one on `n.txt`, one on the review.
local ANNOTATIONS = {
    {
        scope = 'line',
        body = 'Line annotation',
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
        body = 'A range annotation that is long enough to wrap at the width of '
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
        body = 'Deleted line annotation',
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
        body = 'File annotation',
        anchor = { path = 'm.txt', side = 'new' },
    },
    {
        scope = 'line',
        body = 'Outdated annotation',
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
        body = 'Hidden annotation',
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
        body = 'Other file annotation',
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
        body = 'Review annotation',
        anchor = { side = 'new' },
    },
}

--- Store `annotations` for the child's repository.
---@param annotations table[]
local function seed(annotations)
    child.lua(
        [[
        local store = require('iter.store')
        for _, annotation in ipairs(...) do
            annotation.outdated = annotation.outdated or false
            assert(store.put_annotation(vim.fn.getcwd(), annotation))
        end
    ]],
        { annotations }
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

--- Each annotation mark of the review's diff buffer as `<lnum> <text>`, the
--- text being its virtual lines joined by `|` with trailing blanks cut.
---@return string[]
local function placed()
    return child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.annotations']
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

T['diff view']['shows each annotation kind under its row'] = function()
    seed(ANNOTATIONS)
    open_review()

    eq(placed(), {
        '1 ▎ File annotation',
        '3 ▎ Line annotation',
        '9 ▎ A range annotation that is long enough to wrap at the width of the'
            .. '|▎ diff window, which is eighty columns minus the rail',
        '11 ▎ Deleted line annotation',
        '13 ▎ outdated · Outdated annotation',
        '15 ▎ Hidden annotation',
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'marks-diff')
end

T['diff view']['dims outdated annotations'] = function()
    seed(ANNOTATIONS)
    open_review()

    local groups = child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.annotations']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
            result[mark[2] + 1] = mark[4].virt_lines[1][2][2]
        end
        return result
    end)()]])

    eq(groups[3], 'IterDiffAnnotation')
    eq(groups[13], 'IterDiffAnnotationOutdated')
end

T['diff view']['rewraps the text when the window width changes'] = function()
    seed({ ANNOTATIONS[2] })
    open_review()

    eq(placed(), {
        '9 ▎ A range annotation that is long enough to wrap at the width of the'
            .. '|▎ diff window, which is eighty columns minus the rail',
    })

    child.o.columns = 50
    helpers.wait_until(
        child,
        [[#vim.api.nvim_buf_get_extmarks(require('iter').current_review.drawer.view.buf, vim.api.nvim_get_namespaces()['iter.diff.annotations'], 0, -1, { details = true })[1][4].virt_lines > 2]]
    )

    eq(placed(), {
        '9 ▎ A range annotation that is long enough'
            .. '|▎ to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus'
            .. '|▎ the rail',
    })

    -- Stacked at 50 columns, the count still ends the full-width cell.
    eq(
        child.lua_get(
            R
                .. [[.drawer.layout .. '|' .. vim.api.nvim_buf_get_lines(]]
                .. R
                .. [[.drawer.buf, 1, 2, false)[1] ]]
        ),
        'stacked| M ○ m.txt' .. string.rep(' ', 36) .. '[1] '
    )
end

T['diff view']['rewraps when only the diff window narrows'] = function()
    seed({ ANNOTATIONS[2] })
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
        [[#vim.api.nvim_buf_get_extmarks(require('iter').current_review.drawer.view.buf, vim.api.nvim_get_namespaces()['iter.diff.annotations'], 0, -1, { details = true })[1][4].virt_lines > 2]]
    )

    eq(
        child.lua_get([[vim.api.nvim_win_get_width(]] .. R .. [[.diff_win)]]),
        50
    )
    eq(placed(), {
        '9 ▎ A range annotation that is long enough'
            .. '|▎ to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus'
            .. '|▎ the rail',
    })
    eq(child.lua_get(R .. '.drawer.layout'), 'columns')
end

T['diff view']['expanding a gap moves a hidden annotation to its line'] = function()
    seed({ ANNOTATIONS[6] })
    open_review()

    eq(placed(), { '15 ▎ Hidden annotation' })

    child.lua([[
        local view = require('iter').current_review.drawer.view
        view:expand(15)
    ]])

    -- The gap of nine lines opens whole: l12 to l20 on rows 15 to 23.
    eq(placed(), { '19 ▎ Hidden annotation' })
    eq(child.lua_get(R .. '.drawer.view.rows[19].text'), 'l16')
end

T['diff view']['a refresh picks up annotations written meanwhile'] = function()
    open_review()
    eq(placed(), {})

    seed({ ANNOTATIONS[1] })
    child.lua(R .. '.drawer:refresh()')

    eq(placed(), { '3 ▎ Line annotation' })
end

T['diff view']['a fully staged file outdates a lost annotation'] = function()
    helpers.git(repo, { 'add', 'm.txt' })
    seed({ ANNOTATIONS[5] })
    open_review('unstaged n.txt')
    child.lua([[
        local d = require('iter').current_review.drawer
        d:step_file(1)
    ]])
    wait_diff('staged m.txt')

    eq(placed(), { '13 ▎ outdated · Outdated annotation' })
end

T['diff view']['a partly staged file leaves a lost annotation out'] = function()
    helpers.git(repo, { 'add', 'm.txt' })
    helpers.write_file(
        vim.fs.joinpath(repo, 'm.txt'),
        vim.list_extend(
            { 'top' },
            vim.fn.readfile(vim.fs.joinpath(repo, 'm.txt'))
        )
    )
    seed({ ANNOTATIONS[5] })
    open_review()
    child.lua([[
        local d = require('iter').current_review.drawer
        d:step_file(1)
        d:step_file(1)
    ]])
    wait_diff('staged m.txt')

    eq(placed(), {})
end

T['diff view']['a failed store read keeps the annotations'] = function()
    seed({ ANNOTATIONS[1] })
    open_review()
    eq(placed(), { '3 ▎ Line annotation' })

    child.lua([[
        local path = require('iter.store').path(vim.fn.getcwd())
        vim.fn.writefile({ '{"version":2,"annotations":[],"viewed":{}}' }, path)
        require('iter').current_review.drawer:refresh()
    ]])

    eq(placed(), { '3 ▎ Line annotation' })
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
    seed({ ANNOTATIONS[1] })
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

    seed({ ANNOTATIONS[2] })
    child.lua(R .. [[.drawer:refresh('poll')]])

    eq(child.lua_get('_G.loads'), 1)
    eq(#placed(), 2)
end

T['keys'] = new_set()

T['keys'][']a and [a step through the annotation rows in order'] = function()
    seed(ANNOTATIONS)
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
    seed(ANNOTATIONS)
    child.cmd('edit m.txt')
    eq(child.lua_get(BUFFER_MAP), 0)

    open_review()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    eq(
        child.lua_get([[vim.fn.maparg(']a', 'n', false, true).desc]]),
        'Next annotation'
    )
    eq(
        child.lua_get([[vim.fn.maparg('[a', 'n', false, true).desc]]),
        'Previous annotation'
    )

    child.cmd('tabprevious')
    eq(child.lua_get(BUFFER_MAP), 0)
end

T['counts'] = new_set()

T['counts']['the review drawer shows counts on rows and in the header'] = function()
    seed(ANNOTATIONS)
    open_review()

    local lines = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]] .. R .. [[.drawer.buf, 0, -1, false)]]
    )

    -- The count sits at the right end of the cell, which keeps its width.
    eq(
        vim.split(lines[2], '│')[1],
        ' M ○ m.txt' .. string.rep(' ', 25) .. '[6] '
    )
    eq(
        vim.split(lines[3], '│')[1],
        ' M ○ n.txt' .. string.rep(' ', 25) .. '[1] '
    )

    local title = child.lua_get([[(function()
        local text = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(]] .. R .. [[.drawer.win).title) do
            text = text .. chunk[1]
        end
        return text
    end)()]])

    eq(title, 'HEAD main · viewed 0 of 2 · 8 annotations')
end

T['counts']['the status drawer shows no counts and no marks'] = function()
    seed(ANNOTATIONS)
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
        local ns = vim.api.nvim_get_namespaces()['iter.diff.annotations']
        return {
            lines = vim.api.nvim_buf_get_lines(d.buf, 0, -1, false),
            title = title,
            marks = ns and #vim.api.nvim_buf_get_extmarks(d.view.buf, ns, 0, -1, {}) or 0,
            next_annotation = (function()
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
    eq(state.next_annotation, '')
end

T['normal buffer'] = new_set()

local function setup_iter()
    child.lua([[require('iter').setup()]])
end

--- Each annotation mark of the current buffer as `<lnum> <text>`, the text
--- being its virtual lines joined by `|` with outer blanks cut, and each
--- sign as `<lnum> sign`.
---@return string[]
local function buffer_marks()
    return child.lua_get([[(function()
        local ns = vim.api.nvim_get_namespaces()['iter.buffer.annotations']
        if ns == nil then
            return {}
        end
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
            local d = mark[4]
            if d.sign_text ~= nil then
                table.insert(result, (mark[2] + 1) .. ' sign')
            end
            if d.virt_lines ~= nil then
                local lines = {}
                for _, line in ipairs(d.virt_lines) do
                    local text = ''
                    for _, chunk in ipairs(line) do
                        text = text .. chunk[1]
                    end
                    table.insert(lines, vim.trim(text))
                end
                table.insert(result, (mark[2] + 1) .. ' ' .. table.concat(lines, '|'))
            end
        end
        return result
    end)()]])
end

--- The stored annotations as `<body> <start>-<end>[ outdated]`.
---@return string[]
local function stored()
    return child.lua_get([[(function()
        local result = {}
        for _, c in ipairs(require('iter.store').load(vim.fn.getcwd()).annotations) do
            local a = c.anchor
            table.insert(result, string.format('%s %s-%s%s', c.body,
                tostring(a.start_line), tostring(a.end_line),
                c.outdated and ' outdated' or ''))
        end
        return result
    end)()]])
end

--- Count `iter.git.run` calls in the child from now on, in `_G.git_runs`.
local function count_git_runs()
    child.lua([[
        local git = require('iter.git')
        local run = git.run
        _G.git_runs = 0
        git.run = function(...)
            _G.git_runs = _G.git_runs + 1
            return run(...)
        end
    ]])
end

-- A line, a range, an outdated, a deleted-line and a file annotation on
-- `m.txt`, which has 19 lines in the worktree.
local BUFFER_ANNOTATIONS = {
    ANNOTATIONS[1],
    ANNOTATIONS[2],
    ANNOTATIONS[3],
    ANNOTATIONS[4],
    ANNOTATIONS[5],
    ANNOTATIONS[7],
}

T['normal buffer']['shows line and range annotations with signs'] = function()
    seed(BUFFER_ANNOTATIONS)
    setup_iter()
    child.o.number = true
    child.o.signcolumn = 'auto'
    child.cmd('edit m.txt')

    eq(buffer_marks(), {
        '1 sign',
        '1 ▎ Line annotation',
        '4 sign',
        '5 sign',
        '6 sign',
        '6 ▎ A range annotation that is long enough to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus the rail',
        '9 sign',
        '9 ▎ outdated · Outdated annotation',
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'marks-buffer')
end

T['normal buffer']['nothing shows without setup()'] = function()
    seed(BUFFER_ANNOTATIONS)
    child.cmd('edit m.txt')

    eq(buffer_marks(), {})
    eq(
        child.lua_get(
            [[pcall(vim.api.nvim_get_autocmds, { group = 'iter.buffer_annotations' })]]
        ),
        false
    )
end

T['normal buffer']['setup() shows the buffers already in windows'] = function()
    seed({ ANNOTATIONS[1] })
    child.cmd('edit m.txt')
    setup_iter()

    eq(buffer_marks(), { '1 sign', '1 ▎ Line annotation' })
end

T['normal buffer']['saving after inserting lines above moves the annotations'] = function()
    seed({ ANNOTATIONS[1], ANNOTATIONS[2] })
    setup_iter()
    child.cmd('edit m.txt')
    child.api.nvim_buf_set_lines(0, 0, 0, false, { 'new a', 'new b' })
    child.cmd('write')

    eq(stored(), {
        'Line annotation 3-3',
        ANNOTATIONS[2].body .. ' 6-8',
    })
    eq(buffer_marks()[1], '3 sign')
    eq(buffer_marks()[2], '3 ▎ Line annotation')
    eq(buffer_marks()[5], '8 sign')
end

T['normal buffer']['a reload after an outside edit moves the marks'] = function()
    seed({ ANNOTATIONS[1], ANNOTATIONS[2] })
    setup_iter()
    child.cmd('edit m.txt')

    local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
    table.insert(lines, 1, 'agent a')
    table.insert(lines, 1, 'agent b')
    helpers.write_file(vim.fs.joinpath(repo, 'm.txt'), lines)
    child.o.autoread = true
    child.cmd('checktime')

    eq(child.api.nvim_buf_get_lines(0, 0, 1, false), { 'agent b' })
    eq(buffer_marks(), {
        '3 sign',
        '3 ▎ Line annotation',
        '6 sign',
        '7 sign',
        '8 sign',
        '8 ▎ A range annotation that is long enough to wrap at the width of the diff'
            .. '|▎ window, which is eighty columns minus the rail',
    })
end

T['normal buffer']['saving after deleting the anchored line outdates it'] = function()
    seed({ ANNOTATIONS[1], ANNOTATIONS[2] })
    setup_iter()
    child.cmd('edit m.txt')
    child.cmd('1delete')
    child.cmd('write')

    eq(stored(), {
        'Line annotation 1-1 outdated',
        ANNOTATIONS[2].body .. ' 3-5',
    })
    eq(buffer_marks()[2], '1 ▎ outdated · Line annotation')
    eq(child.v.errmsg, '')
end

T['normal buffer']['saving the last line away keeps the annotation on the buffer'] = function()
    seed({
        {
            scope = 'line',
            body = 'Last line',
            anchor = {
                path = 'm.txt',
                side = 'new',
                start_line = 19,
                end_line = 19,
                lines = { 'l20' },
            },
        },
    })
    setup_iter()
    child.cmd('edit m.txt')
    child.cmd('10,$delete')
    child.cmd('write')

    eq(stored(), { 'Last line 19-19 outdated' })
    eq(buffer_marks(), { '9 sign', '9 ▎ outdated · Last line' })
    eq(child.v.errmsg, '')
end

T['normal buffer']['an unchanged save leaves the store file alone'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')

    local stat = [[(function()
        local s = vim.uv.fs_stat(require('iter.store').path(vim.fn.getcwd()))
        return { s.ino, s.mtime.sec, s.mtime.nsec }
    end)()]]
    local before = child.lua_get(stat)
    child.cmd('write')

    eq(child.lua_get(stat), before)
end

T['normal buffer']['writing to another file does not move the annotations'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')
    child.api.nvim_buf_set_lines(0, 0, 0, false, { 'new a' })
    child.cmd('write other.txt')

    eq(stored(), { 'Line annotation 1-1' })
end

T['normal buffer']['buffers outside repos and non-file buffers spawn no git'] = function()
    local outside = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(outside, 'p')
    helpers.write_file(vim.fs.joinpath(outside, 'x.txt'), { 'x' })

    seed({ ANNOTATIONS[1] })
    setup_iter()
    count_git_runs()
    child.cmd('enew')
    child.cmd('help')
    child.cmd('only')
    child.cmd('edit ' .. vim.fn.fnameescape(outside .. '/x.txt'))
    child.cmd('edit ' .. vim.fn.fnameescape(outside .. '/x.txt'))

    eq(child.lua_get('_G.git_runs'), 0)
    eq(buffer_marks(), {})

    helpers.cleanup(outside)
end

T['normal buffer']['showing a repo buffer again spawns no git'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')
    count_git_runs()
    child.cmd('edit n.txt')
    child.cmd('buffer m.txt')

    eq(child.lua_get('_G.git_runs'), 0)
    eq(buffer_marks(), { '1 sign', '1 ▎ Line annotation' })
end

T['normal buffer']['an annotation written meanwhile shows on the next enter'] = function()
    setup_iter()
    child.cmd('edit m.txt')
    eq(buffer_marks(), {})

    seed({ ANNOTATIONS[1] })
    child.cmd('edit n.txt')
    child.cmd('buffer m.txt')

    eq(buffer_marks(), { '1 sign', '1 ▎ Line annotation' })
end

T['normal buffer']['a branch switch shows the other branch annotations'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')
    helpers.git(repo, { 'checkout', '--quiet', '-b', 'other' })
    child.cmd('edit n.txt')
    child.cmd('buffer m.txt')

    eq(buffer_marks(), {})

    helpers.git(repo, { 'checkout', '--quiet', 'main' })
    child.cmd('edit n.txt')
    child.cmd('buffer m.txt')

    eq(buffer_marks(), { '1 sign', '1 ▎ Line annotation' })
end

T['normal buffer']['a linked worktree shows its branch annotations'] = function()
    local linked = vim.fn.resolve(vim.fn.tempname())
    helpers.git(repo, { 'worktree', 'add', '--quiet', '-b', 'wt', linked })
    child.cmd('cd ' .. vim.fn.fnameescape(linked))
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')

    eq(buffer_marks(), { '1 sign', '1 ▎ Line annotation' })

    helpers.cleanup(linked)
end

T['normal buffer']['adds no keymaps and no buffer-local autocmds'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()

    local count =
        [[#vim.api.nvim_get_autocmds({ group = 'iter.buffer_annotations' })]]
    local autocmds = child.lua_get(count)
    child.cmd('edit m.txt')

    eq(child.lua_get([[vim.api.nvim_buf_get_keymap(0, 'n')]]), {})
    eq(child.lua_get(BUFFER_MAP), 0)

    child.cmd('edit n.txt')
    child.cmd('bwipeout m.txt')
    child.cmd('edit m.txt')
    child.cmd('bwipeout m.txt')

    eq(child.lua_get(count), autocmds)
    eq(
        child.lua_get(
            [[#vim.api.nvim_get_autocmds({ group = 'iter.buffer_annotations', buffer = 0 })]]
        ),
        0
    )
end

T['normal buffer']['a second setup() adds no autocmds'] = function()
    setup_iter()

    local count =
        [[#vim.api.nvim_get_autocmds({ group = 'iter.buffer_annotations' })]]
    local autocmds = child.lua_get(count)
    setup_iter()

    eq(child.lua_get(count), autocmds)
end

T['normal buffer']['rewraps when the window width changes'] = function()
    seed({ ANNOTATIONS[2] })
    setup_iter()
    child.cmd('edit m.txt')
    child.cmd('vsplit')
    child.cmd('vertical resize 40')

    eq(#vim.split(buffer_marks()[4], '|', { plain = true }) > 2, true)
end

T['normal buffer']['a buffer without annotations reads none of its lines'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.lua([[
        local get_lines = vim.api.nvim_buf_get_lines
        _G.line_reads = 0
        vim.api.nvim_buf_get_lines = function(...)
            if debug.getinfo(2, 'S').source:find('iter/annotations/marks', 1, true) then
                _G.line_reads = _G.line_reads + 1
            end
            return get_lines(...)
        end
    ]])
    child.cmd('edit n.txt')
    eq(child.lua_get('_G.line_reads'), 0)

    child.cmd('edit m.txt')
    eq(child.lua_get('_G.line_reads') > 0, true)
end

T['normal buffer']['a failing save of moved annotations warns once'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit m.txt')
    child.lua([[require('iter.store').update = function()
        return nil, 'disk full'
    end]])

    for _ = 1, 2 do
        child.api.nvim_buf_set_lines(0, 0, 0, false, { 'new' })
        child.cmd('write')
    end

    eq(child.lua_get('_G.notes'), {
        { '[iter] Cannot save the moved annotations: disk full', 3 },
    })
    eq(stored(), { 'Line annotation 1-1' })
end

T['normal buffer'][':file and :saveas re-render for the new name'] = function()
    seed({ ANNOTATIONS[1] })
    setup_iter()
    child.cmd('edit n.txt')
    eq(buffer_marks(), {})

    child.cmd('file m.txt')
    eq(buffer_marks(), { '1 sign', '1 ▎ outdated · Line annotation' })

    child.cmd('silent saveas copy.txt')
    eq(buffer_marks(), {})
end

T['normal buffer']['a float showing the buffer keeps the normal window wrap'] = function()
    seed({ ANNOTATIONS[2] })
    setup_iter()
    child.cmd('edit m.txt')

    local before = buffer_marks()
    child.lua(
        [[vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = 'editor', row = 1, col = 1, width = 30, height = 5,
    })]]
    )
    child.cmd('buffer m.txt')

    eq(buffer_marks(), before)
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
---@return IterAnnotation
local function annotation(body, a)
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

---@param result IterAnnotationMark[]
---@return string[]
local function summary(result)
    return vim.tbl_map(function(mark)
        return string.format(
            '%d %s%s',
            mark.lnum,
            mark.annotation.body,
            mark.outdated and ' (outdated)' or ''
        )
    end, result)
end

T['place()']['puts old-side annotations only in the view of their base'] = function()
    local annotations = {
        annotation('index', {
            side = 'old',
            base = 'index',
            start_line = 2,
            end_line = 2,
            lines = { 'b' },
        }),
        annotation('head', {
            side = 'old',
            base = 'HEAD',
            start_line = 2,
            end_line = 2,
            lines = { 'b' },
        }),
    }

    eq(summary(marks.place(file_diff('unstaged'), annotations)), { '4 index' })
    eq(summary(marks.place(file_diff('staged'), annotations)), { '4 head' })
end

T['place()']['outdates new-side annotations only against the worktree'] = function()
    local annotations = {
        annotation('found', {
            side = 'new',
            start_line = 2,
            end_line = 2,
            lines = { 'B' },
        }),
        annotation('gone', {
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'gone' },
        }),
    }

    eq(
        summary(marks.place(file_diff('unstaged'), annotations)),
        { '5 found', '6 gone (outdated)' }
    )
    -- The index is not the version the anchor follows, so a miss there says
    -- nothing about the annotation.
    eq(summary(marks.place(file_diff('staged'), annotations)), { '5 found' })
end

T['place()']['puts what has no row on the header'] = function()
    local file = file_diff('unstaged')
    local annotations = {
        annotation('file', { side = 'new' }),
        annotation('beyond', {
            side = 'new',
            start_line = 40,
            end_line = 40,
            lines = { 'gone' },
        }),
        annotation('elsewhere', {
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
        summary(marks.place(file, annotations)),
        { '1 file', '1 beyond (outdated)' }
    )
end

T['place()']['outdates against the index when it is the worktree'] = function()
    local annotations = {
        annotation('gone', {
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'gone' },
        }),
    }

    eq(
        summary(
            marks.place(
                file_diff('staged'),
                annotations,
                { new_follows = true }
            )
        ),
        { '6 gone (outdated)' }
    )
end

T['place()']['uses stored lines when the versions are missing'] = function()
    local file = file_diff('unstaged')
    file.old_lines, file.new_lines = nil, nil
    local stored = annotation('stored', {
        side = 'new',
        start_line = 2,
        end_line = 2,
        lines = { 'x' },
    })
    stored.outdated = true

    eq(summary(marks.place(file, { stored })), { '5 stored (outdated)' })
end

T['place()']['places old-side annotations of a rename by its old path'] = function()
    local file = file_diff('staged')
    file.path, file.orig_path = 'g.txt', 'f.txt'

    eq(
        summary(marks.place(file, {
            annotation('old', {
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
            annotation('one two three\n\nabcdefghijkl', { side = 'new' }),
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
