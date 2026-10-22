local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = [[require('iter').current_review]]
local E = [[require('iter.annotations.editor')]]

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

--- Drawer order is `n.txt` (unstaged), then `m.txt` (staged); `c.txt` is
--- committed and unchanged. `m.txt` has l3 changed and l8 deleted.
---@return string
local function create_annotations_repo()
    local path = helpers.create_repo({
        ['m.txt'] = numbered('l', 1, 20),
        ['n.txt'] = numbered('n', 1, 5),
        ['c.txt'] = numbered('c', 1, 10),
    })

    local m = numbered('l', 1, 20)
    m[3] = 'l3 new'
    table.remove(m, 8)
    helpers.write_file(vim.fs.joinpath(path, 'm.txt'), m)
    helpers.git(path, { 'add', 'm.txt' })

    local n = numbered('n', 1, 5)
    n[3] = 'n3 new'
    helpers.write_file(vim.fs.joinpath(path, 'n.txt'), n)

    return path
end

---@param path string
---@param start integer
---@param stop integer
---@param lines string[]
---@return table
local function anchor(path, start, stop, lines)
    return {
        path = path,
        side = 'new',
        start_line = start,
        end_line = stop,
        lines = lines,
    }
end

-- Stored in this order; the column sorts them.
local ANNOTATIONS = {
    {
        scope = 'line',
        body = 'Rename the variable',
        anchor = anchor('n.txt', 3, 3, { 'n3 new' }),
    },
    {
        scope = 'line',
        body = 'Why this change?',
        anchor = anchor('m.txt', 3, 3, { 'l3 new' }),
    },
    {
        scope = 'range',
        body = 'Extract a helper\nfor these lines',
        anchor = anchor('m.txt', 4, 6, { 'l4', 'l5', 'l6' }),
    },
    {
        scope = 'line',
        body = 'Why remove it?',
        anchor = {
            path = 'm.txt',
            side = 'old',
            base = 'HEAD',
            start_line = 8,
            end_line = 8,
            lines = { 'l8' },
        },
    },
    {
        scope = 'line',
        body = 'Stale remark',
        anchor = anchor('m.txt', 9, 9, { 'vanished' }),
    },
    {
        scope = 'file',
        body = 'Needs a test',
        anchor = { path = 'm.txt', side = 'new' },
    },
    {
        scope = 'line',
        body = 'Not in the changes',
        anchor = anchor('c.txt', 2, 2, { 'c2' }),
    },
    {
        scope = 'review',
        body = 'Overall looks good',
        anchor = { side = 'new' },
    },
}

-- The Annotations column as the drawer shows it at 120 columns.
local LISTING = {
    'Annotations (8) · 1 outdated',
    'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2',
    'n.txt:3     Rename the variable',
    'm.txt       Needs a test',
    'm.txt:3     Why this change?',
    'm.txt:4–6   Extract a helper',
    'm.txt:8 old Why remove it?',
    'm.txt:9     Stale remark',
    'c.txt:2     Not in the changes',
    'review      Overall looks good',
}

local function seed()
    child.lua(
        [[
        local store = require('iter.store')
        for _, annotation in ipairs(...) do
            assert(store.put_annotation(vim.fn.getcwd(), annotation))
        end
    ]],
        { ANNOTATIONS }
    )
end

local function clear_store()
    child.lua([[
        local store = require('iter.store')
        local ids = {}
        for _, c in ipairs(store.load(vim.fn.getcwd()).annotations) do
            table.insert(ids, c.id)
        end
        store.remove_annotations(vim.fn.getcwd(), ids)
    ]])
end

local function stub_ui()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
        _G.confirms = {}
        _G.confirm_answer = 1
        vim.fn.confirm = function(msg)
            table.insert(_G.confirms, msg)
            return _G.confirm_answer
        end
    ]])
end

---@return string[]
local function notes()
    return vim.tbl_map(function(note)
        return note[1]
    end, child.lua_get('_G.notes'))
end

---@return table[]
local function stored()
    return child.lua_get(
        [[require('iter.store').load(vim.fn.getcwd()).annotations]]
    )
end

--- Open the review tab and wait until the diff pane shows a file.
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

--- Open the review and press l into the Annotations window.
local function open_column()
    open_review()
    child.type_keys('l')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
end

--- The Annotations column in its own window, one trimmed cell per line.
---@return string[]
local function column()
    local lines = child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.side_buf, 0, -1, false)]]
    )
    local cells = {}

    for _, line in ipairs(lines) do
        local cell = vim.trim(line)

        if cell ~= '' then
            table.insert(cells, cell)
        end
    end

    return cells
end

---@return string? body of the selected annotation row
local function selected()
    return child.lua_get([[(function()
        local item = ]] .. R .. [[.drawer:item()
        return item and item.annotation and item.annotation.body or vim.NIL
    end)()]])
end

--- Move the drawer cursor down `count` rows in the column.
---@param count integer
local function down(count)
    for _ = 1, count do
        child.type_keys('j')
    end
end

--- Wait until the diff pane shows `expected` (`side path`).
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

--- Wait until the view draws the annotation with `body` as focused.
---@param body string
local function wait_focus(body)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local view = %s.drawer.view
                if view.focus == nil then
                    return false
                end
                for _, mark in ipairs(view.marks) do
                    if mark.annotation.id == view.focus then
                        return mark.annotation.body == %q
                    end
                end
            end)()]],
            R,
            body
        )
    )
end

--- Highlight group of each annotation's first virtual line in the diff,
--- by the first line of its body.
---@return table<string, string>
local function mark_groups()
    return child.lua_get([[(function()
        local view = require('iter').current_review.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.annotations']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, { details = true })) do
            for _, line in ipairs(mark[4].virt_lines) do
                local last = line[#line]
                local text = vim.trim(last[1])
                if not vim.startswith(text, 'for these') then
                    result[text] = last[2]
                end
            end
        end
        return result
    end)()]])
end

--- The diff row the annotation with `body` sits below.
---@param body string
---@return integer?
local function mark_lnum(body)
    return child.lua_get([[(function(body)
            for _, mark in ipairs(]] .. R .. [[.drawer.view.marks) do
                if mark.annotation.body == body then
                    return mark.lnum
                end
            end
            return vim.NIL
        end)(...)]], { body })
end

---@return integer
local function diff_cursor()
    return child.lua_get(
        [[vim.api.nvim_win_get_cursor(]] .. R .. [[.diff_win)[1] ]]
    )
end

---@return string
local function footer()
    return child.lua_get([[(function()
        local text = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(]] .. R .. [[.drawer.win).footer) do
            text = text .. chunk[1]
        end
        return text
    end)()]])
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_annotations_repo()
            helpers.start_child(child, repo, { lines = 30, columns = 120 })
            child.lua([[require('iter').setup()]])
            stub_ui()
            seed()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['column'] = new_set()

T['column']['lists every annotation in drawer order, review last'] = function()
    open_review()

    eq(column(), LISTING)
    eq(child.v.errmsg, '')
end

T['column']['a file gone from the worktree outdates its annotations everywhere'] = function()
    os.remove(vim.fs.joinpath(repo, 'n.txt'))
    open_review()
    wait_diff('unstaged n.txt')

    eq(column()[1], 'Annotations (8) · 2 outdated')
    eq(column()[3], 'n.txt:3     Rename the variable')
    helpers.wait_until(child, R .. [[.drawer.view.marks[1] ~= nil]])
    eq(
        mark_groups()['outdated · Rename the variable'],
        'IterDiffAnnotationOutdated'
    )

    local text = child.lua_get([[require('iter.export').text(
        require('iter.store').load(vim.fn.getcwd()).annotations,
        {
            intro = '',
            lines_of = require('iter.annotations.list').reader(vim.fn.getcwd()),
        }
    )]])
    eq(text:find('n.txt:3 (outdated)', 1, true) ~= nil, true)
end

T['column']['dims outdated rows and titles with the outdated count'] = function()
    open_review()

    local groups = child.lua_get([[(function()
        local buf = require('iter').current_review.drawer.side_buf
        local ns = vim.api.nvim_get_namespaces()['iter.ui.render']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
            local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
            local text = vim.trim(line:sub(mark[3] + 1, mark[4].end_col))
            result[text] = mark[4].hl_group
        end
        return result
    end)()]])

    eq(groups['Annotations (8)'], 'IterDrawerTitle')
    eq(groups['· 1 outdated'], 'IterDrawerHint')
    eq(groups['m.txt:9     Stale remark'], 'IterDiffAnnotationOutdated')
    eq(groups['m.txt:3'], 'IterDrawerKey')
end

T['column']['the progress row follows reviewed and changed files'] = function()
    open_review()
    child.type_keys('r')
    helpers.wait_until(child, R .. [[.reviewed['n.txt'] == 'reviewed']])

    eq(
        column()[2],
        'reviewed ▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱ 1 of 2'
    )

    helpers.write_file(vim.fs.joinpath(repo, 'n.txt'), { 'changed' })
    child.lua([[require('iter').current_review:refresh_annotations()]])
    helpers.wait_until(child, R .. [[.reviewed['n.txt'] == 'changed']])

    eq(
        column()[2],
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2 · ↻ 1'
    )
end

T['column']['the header keeps the branch and counts files'] = function()
    open_review()

    local title = child.lua_get([[(function()
        local text = ''
        for _, chunk in ipairs(]] .. R .. [[.drawer.float.opts.title) do
            text = text .. chunk[1]
        end
        return text
    end)()]])

    eq(vim.startswith(title, 'HEAD main '), true)
    eq(vim.endswith(title, ' 2 files '), true)
    -- One column in, the header fills the rest of the 120-column drawer.
    eq(child.fn.strdisplaywidth(title), 119)
end

T['column']['l reaches the column, the progress row is skipped'] = function()
    open_column()

    eq(selected(), 'Rename the variable')
    eq(footer(), '<CR> jump  e edit  x delete  y yank  h files  ? help')

    child.type_keys('k')
    eq(selected(), 'Rename the variable')

    child.type_keys('h')
    eq(child.lua_get(R .. '.drawer.column'), 'unstaged')
    eq(
        footer(),
        's stage  u unstage  d discard  I ignore  <CR> open  r reviewed  = all files  | split  ? help'
    )
end

T['column']['h and l select again the file and the annotation they left'] = function()
    open_column()
    down(2)
    eq(selected(), 'Why this change?')

    child.type_keys('h')
    eq(child.lua_get(R .. '.drawer:selected().path'), 'n.txt')

    child.type_keys('j')
    eq(child.lua_get(R .. '.drawer:selected().side'), 'staged')

    child.type_keys('l')
    eq(selected(), 'Why this change?')

    child.type_keys('h')
    eq(child.lua_get(R .. '.drawer:selected().side'), 'staged')
end

T['column']['takes no border from a global winborder'] = function()
    child.o.winborder = 'solid'
    open_review()

    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]]
                .. R
                .. [[.drawer.float.side_win).border]]
        ),
        'none'
    )
end

T['column']['without annotations the column shows the progress only'] = function()
    clear_store()
    open_review()

    eq(column(), {
        'Annotations (0)',
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2',
    })

    child.type_keys('l')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(selected(), vim.NIL)

    child.type_keys('e', 'x', '<CR>')
    eq(notes(), {
        '[iter] No annotation selected',
        '[iter] No annotation selected',
    })
    eq(child.lua_get(R .. '.drawer.view:is_shown()'), true)
end

T['column']['stacks below the breakpoint'] = function()
    child.o.columns = 60
    open_review()

    local lines = child.lua_get(
        [[vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.buf, 0, -1, false))]]
    )

    eq(child.lua_get(R .. '.drawer.layout'), 'stacked')
    eq(vim.list_slice(lines, 6, 9), {
        '',
        'Annotations (8) · 1 outdated',
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2',
        'n.txt:3     Rename the variable',
    })

    -- j walks from the files into the annotations, past the progress row.
    child.type_keys('j', 'j')
    eq(selected(), 'Rename the variable')
end

T['column']['screenshot'] = function()
    open_column()
    down(2)
    wait_focus('Why this change?')

    helpers.expect_screenshot(child, 'review-annotations')
end

T['column']['a long file list scrolls under the Annotations window'] = function()
    for i = 1, 20 do
        helpers.write_file(
            vim.fs.joinpath(repo, string.format('f%02d.txt', i)),
            { 'f' }
        )
    end

    open_review()
    helpers.wait_until(child, '#' .. R .. '.drawer.changes.unstaged == 21')
    child.type_keys('G')
    wait_diff('staged m.txt')

    local tops = child.lua_get([[(function()
        local d = ]] .. R .. [[.drawer
        return {
            files = vim.fn.getwininfo(d.win)[1].topline,
            annotations = vim.fn.getwininfo(d.float.side_win)[1].topline,
        }
    end)()]])

    eq(tops.files > 1, true)
    eq(tops.annotations, 1)
    helpers.expect_screenshot(child, 'review-long-files')
end

T['preview'] = new_set()

T['preview']['moving onto a row shows its file with the annotation focused'] = function()
    open_column()
    wait_diff('unstaged n.txt')
    wait_focus('Rename the variable')

    eq(diff_cursor(), mark_lnum('Rename the variable'))

    down(2)
    wait_diff('staged m.txt')
    wait_focus('Why this change?')

    eq(diff_cursor(), mark_lnum('Why this change?'))

    local groups = mark_groups()
    eq(groups['Why this change?'], 'IterDiffAnnotationFocus')
    eq(groups['Needs a test'], 'IterDiffAnnotation')
    eq(groups['outdated · Stale remark'], 'IterDiffAnnotationOutdated')
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == ]]
                .. R
                .. [[.drawer.float.side_win]]
        ),
        true
    )
end

T['preview']['a deleted line shows on the side of its base'] = function()
    open_column()
    down(4)
    wait_focus('Why remove it?')

    eq(child.lua_get(R .. [[.drawer.view.files[1].side]]), 'staged')
    eq(diff_cursor(), mark_lnum('Why remove it?'))
end

T['preview']['a review annotation and a file outside the changes keep the pane'] = function()
    open_column()
    down(3)
    wait_focus('Extract a helper\nfor these lines')

    down(3)
    eq(selected(), 'Not in the changes')
    child.lua('vim.wait(150)')
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(child.lua_get(R .. '.drawer.view.focus'), vim.NIL)

    down(1)
    eq(selected(), 'Overall looks good')
    child.lua('vim.wait(150)')
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(child.lua_get(R .. '.drawer.view:is_shown()'), true)
end

T['preview']['a file row drops the focus'] = function()
    open_column()
    wait_focus('Rename the variable')

    child.type_keys('h', 'h')
    eq(child.lua_get(R .. '.drawer.column'), 'unstaged')
    helpers.wait_until(child, R .. '.drawer.view.focus == nil')
    wait_diff('unstaged n.txt')
    eq(mark_groups()['Rename the variable'], 'IterDiffAnnotation')
end

T['preview']['an annotation at the end of a long diff comes into view'] = function()
    clear_store()

    local lines = numbered('n', 1, 5)
    lines[3] = 'n3 new'

    for i = 6, 80 do
        lines[i] = 'x' .. i
    end

    helpers.write_file(vim.fs.joinpath(repo, 'n.txt'), lines)
    child.lua(
        [[assert(require('iter.store').put_annotation(vim.fn.getcwd(), ...))]],
        {
            {
                scope = 'line',
                body = 'At the very end',
                anchor = anchor('n.txt', 80, 80, { 'x80' }),
            },
        }
    )
    open_column()
    wait_focus('At the very end')

    local shown = child.lua_get([[(function()
        vim.cmd.redraw()
        for row = 1, vim.o.lines do
            local cells = {}
            for col = 1, vim.o.columns do
                table.insert(cells, vim.fn.screenstring(row, col))
            end
            if table.concat(cells):find('At the very end', 1, true) then
                return row
            end
        end
        return 0
    end)()]])
    local diff_bottom = child.lua_get([[(function()
        local win = require('iter').current_review.diff_win
        return vim.fn.win_screenpos(win)[1] + vim.api.nvim_win_get_height(win) - 1
    end)()]])

    eq(shown > 0 and shown <= diff_bottom, true)
end

T['preview']['a staged-only change of a file in both columns shows the staged diff'] = function()
    clear_store()

    local b = numbered('b', 1, 40)
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
    helpers.git(repo, { 'add', 'b.txt' })
    helpers.git(repo, { 'commit', '--quiet', '-m', 'b' })
    b[2] = 'b2 staged'
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
    helpers.git(repo, { 'add', 'b.txt' })
    b[30] = 'b30 unstaged'
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
    child.lua(
        [[assert(require('iter.store').put_annotation(vim.fn.getcwd(), ...))]],
        {
            {
                scope = 'line',
                body = 'On the staged line',
                anchor = anchor('b.txt', 2, 2, { 'b2 staged' }),
            },
        }
    )
    open_column()
    wait_focus('On the staged line')

    eq(child.lua_get(R .. [[.drawer.view.files[1].side]]), 'staged')
    eq(
        child.lua_get([[(function()
            local r = require('iter').current_review
            local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
            return r.drawer.view.rows[lnum].text
        end)()]]),
        'b2 staged'
    )
end

T['keys'] = new_set()

T['keys']['<CR> jumps into the diff at the annotation'] = function()
    open_column()
    down(3)
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(diff_cursor(), mark_lnum('Extract a helper\nfor these lines'))
end

T['keys']['a refresh after <CR> keeps the diff cursor'] = function()
    open_column()
    down(2)
    child.type_keys('<CR>')
    wait_diff('staged m.txt')
    child.type_keys('gg', 'r')
    helpers.wait_until(child, R .. [[.reviewed['m.txt'] == 'reviewed']])

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(diff_cursor(), 1)
    eq(child.lua_get(R .. '.drawer.view.focus ~= nil'), true)
end

T['keys'][']f after <CR> steps from the shown file'] = function()
    open_column()
    child.type_keys('<CR>')
    wait_diff('unstaged n.txt')
    child.type_keys(']f')

    wait_diff('staged m.txt')
end

T['keys']['<CR> on a file outside the changes opens it in the first tab'] = function()
    open_column()
    down(6)
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_tabpage(), 1)
    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'c.txt')
    eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T['keys']['e edits the annotation in the float'] = function()
    open_column()
    down(2)
    child.type_keys('e')

    helpers.wait_until(
        child,
        E
            .. [[.is_shown() and vim.api.nvim_get_current_win() == ]]
            .. E
            .. '.win()'
    )
    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'Why this change?',
    })

    child.type_keys(' Please explain.', '<C-s>')
    helpers.wait_until(child, 'not ' .. E .. '.is_shown()')
    helpers.wait_until(
        child,
        R
            .. [[.drawer:item().annotation.body == 'Why this change? Please explain.']]
    )

    eq(column()[5], 'm.txt:3     Why this change? Please ex…')
end

T['keys']['x keeps the annotation when the confirm is declined'] = function()
    open_column()
    child.lua([[_G.confirm_answer = 2]])
    child.type_keys('x')

    eq(
        child.lua_get([[_G.confirms]]),
        { 'Delete the annotation?\nRename the variable' }
    )
    eq(#stored(), 8)
    eq(column(), LISTING)
end

T['keys']['x deletes and the next row takes the selection'] = function()
    open_column()
    down(2)
    wait_focus('Why this change?')
    child.type_keys('x')

    helpers.wait_until(child, '#' .. R .. '.annotations == 7')
    eq(#stored(), 7)
    eq(column()[1], 'Annotations (7) · 1 outdated')
    eq(selected(), 'Extract a helper\nfor these lines')
    wait_focus('Extract a helper\nfor these lines')
    eq(child.lua_get(R .. '.drawer.view:is_shown()'), true)
end

T['keys']['deleting the last annotation leaves the progress row selected'] = function()
    clear_store()
    child.lua(
        [[assert(require('iter.store').put_annotation(vim.fn.getcwd(), ...))]],
        { ANNOTATIONS[1] }
    )
    open_column()
    child.type_keys('x')

    helpers.wait_until(child, '#' .. R .. '.annotations == 0')
    eq(column(), {
        'Annotations (0)',
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2',
    })
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(child.lua_get(R .. '.drawer.view:is_shown()'), true)
end

T['keys']['annotating in the diff adds a row'] = function()
    clear_store()
    open_review()
    child.type_keys('<CR>')
    child.lua([[
        local r = require('iter').current_review
        for lnum, row in ipairs(r.drawer.view.rows) do
            if row.text == 'n3 new' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('a')
    helpers.wait_until(child, E .. '.is_shown()')
    child.type_keys('A new note', '<C-s>')

    helpers.wait_until(child, '#' .. R .. '.annotations == 1')
    eq(column(), {
        'Annotations (1)',
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 2',
        'n.txt:3 A new note',
    })
end

T['keys']['<CR> on a review annotation opens it in the editor'] = function()
    open_column()
    down(7)
    eq(selected(), 'Overall looks good')
    child.type_keys('<CR>')

    helpers.wait_until(child, E .. '.is_shown()')
    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'Overall looks good',
    })
end

T['api'] = new_set()

T['api']['annotations() opens the review on the column from a buffer'] = function()
    child.cmd('edit c.txt')
    child.lua([[require('iter').annotations()]])
    helpers.wait_until(child, R .. ' ~= nil')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == ]]
                .. R
                .. [[.drawer.float.side_win]]
        ),
        true
    )
    eq(selected(), 'Rename the variable')
end

T['api']['annotations() switches to the open review'] = function()
    open_review()
    child.cmd('tabfirst')
    child.lua([[require('iter').annotations()]])

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.api.nvim_get_current_tabpage(), child.lua_get(R .. '.tab'))
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
end

T['api']['annotations() outside a repository warns'] = function()
    child.cmd('cd /')
    child.lua([[require('iter').annotations()]])

    eq(child.lua_get(R), vim.NIL)
    eq(notes(), { '[iter] Not inside a git repository' })
end

T['api']['L opens nothing any more'] = function()
    open_review()

    eq(child.lua_get([[vim.fn.maparg('L', 'n', false, true).buffer or 0]]), 0)
end

T['clean'] = new_set({
    hooks = {
        pre_case = function()
            child.stop()
            helpers.cleanup(repo)
            repo = helpers.create_repo({ ['a.txt'] = { 'a' } })
            helpers.start_child(child, repo, { lines = 30, columns = 120 })
            child.lua([[require('iter').setup()]])
            stub_ui()
            child.lua(
                [[assert(require('iter.store').put_annotation(vim.fn.getcwd(), ...))]],
                { ANNOTATIONS[8] }
            )
        end,
    },
})

T['clean'][':Iter review on a clean tree selects the review annotation'] = function()
    child.cmd('Iter review')
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.drawer.win ~= nil')

    eq(child.v.errmsg, '')
    eq(notes(), {})
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(selected(), 'Overall looks good')
    eq(column(), {
        'Annotations (1)',
        'reviewed ▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ 0 of 0',
        'review Overall looks good',
    })
end

T['clean']['annotations() on a clean tree opens the column'] = function()
    child.lua([[require('iter').annotations()]])
    helpers.wait_until(child, R .. ' ~= nil')

    eq(child.v.errmsg, '')
    eq(child.lua_get(R .. '.drawer.column'), 'annotations')
    eq(selected(), 'Overall looks good')
end

return T
