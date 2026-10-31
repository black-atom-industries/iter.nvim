local helpers = dofile('tests/helpers.lua')
local H = dofile('tests/helpers_review.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = H.R
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

--- Tree order is `m.txt` (staged), then `n.txt` (unstaged); `c.txt` is
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

-- Stored in this order; the annotations window sorts them.
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

-- Every annotation in the review's tree order (m.txt, n.txt), then other
-- files by name, the review last.
local ORDER = {
    'Needs a test',
    'Why this change?',
    'Extract a helper\nfor these lines',
    'Why remove it?',
    'Stale remark',
    'Rename the variable',
    'Not in the changes',
    'Overall looks good',
}

-- The annotations window of the review's tab.
local S = [[require('iter.ui.sidebar').of(require('iter').current_review.tab)]]

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
    H.open(child)
    helpers.wait_until(child, R .. [[.view:is_shown()]])
end

--- Move the annotations window's cursor onto the note with `body`, as a
--- key press would.
---@param body string
local function goto_note(body)
    local lnum = child.lua_get([[(function(body)
            local s = ]] .. S .. [[
            for lnum, row in pairs(s.rows) do
                if row.item ~= nil and row.item.annotation.body == body then
                    return lnum
                end
            end
            return vim.NIL
        end)(...)]], { body })

    assert(lnum ~= vim.NIL, 'no note ' .. body)
    child.type_keys(lnum .. 'G')
end

--- Open the review, focus its annotations window and put its cursor on
--- `Rename the variable`.
local function open_column()
    open_review()
    child.lua(S .. ':focus()')
    goto_note('Rename the variable')
end

--- The title line of the annotations window.
---@return string
local function title()
    return vim.trim(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(' .. S .. '.buf, 0, 1, false)[1]'
        )
    )
end

--- The bodies of the annotations window's notes, top to bottom.
---@return string[]
local function bodies()
    return child.lua_get([[(function()
        local s = ]] .. S .. [[
        local lnums = {}
        for lnum, row in pairs(s.rows) do
            if row.item ~= nil then
                table.insert(lnums, lnum)
            end
        end
        table.sort(lnums)
        return vim.tbl_map(function(lnum)
            return s.rows[lnum].item.annotation.body
        end, lnums)
    end)()]])
end

---@return string? body of the note under the annotations window's cursor
local function selected()
    return child.lua_get([[(function()
        local s = ]] .. S .. [[
        local row = s and s:row()
        return row and row.item and row.item.annotation.body or vim.NIL
    end)()]])
end

--- Wait until the view draws the annotation with `body` as focused.
---@param body string
local function wait_focus(body)
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local view = %s.view
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
        local view = require('iter').current_review.view
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
            for _, mark in ipairs(]] .. R .. [[.view.marks) do
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

T['list'] = new_set()

T['list']['lists every annotation in tree order, review last'] = function()
    open_review()

    eq(title(), 'Annotations (8) · 1 outdated')
    eq(bodies(), ORDER)
    eq(child.v.errmsg, '')
end

T['list']['a file gone from the worktree outdates its annotations everywhere'] = function()
    os.remove(vim.fs.joinpath(repo, 'n.txt'))
    open_review()
    H.select(child, 'unstaged', 'n.txt')
    H.wait_diff(child, 'unstaged n.txt')

    eq(title(), 'Annotations (8) · 2 outdated')
    helpers.wait_until(child, R .. [[.view.marks[1] ~= nil]])
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

T['list']['the tree counts annotations per file'] = function()
    open_review()

    local rows = child.lua_get([[(function()
        local r = require('iter').current_review
        local out = {}
        for lnum, row in pairs(r.tree.items) do
            local text = vim.api.nvim_buf_get_lines(r.tree.buf, lnum - 1, lnum, false)[1]
            out[row.node.path] = vim.trim((text:gsub('%s+', ' ')))
        end
        return out
    end)()]])

    eq(rows['m.txt'], '● M m.txt ✎5')
    eq(rows['n.txt'], '○ M n.txt ✎1')
end

T['list']['the progress follows reviewed and changed files'] = function()
    open_review()
    H.select(child, 'unstaged', 'n.txt')
    H.wait_diff(child, 'unstaged n.txt')
    child.type_keys('r')
    helpers.wait_until(child, R .. [[.reviewed['n.txt'] == 'reviewed']])

    local progress = 'vim.trim(vim.api.nvim_buf_get_lines('
        .. R
        .. '.tree.buf, 2, 3, false)[1])'

    eq(
        child.lua_get(progress),
        'reviewed ▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱ 1 of 2'
    )

    helpers.write_file(vim.fs.joinpath(repo, 'n.txt'), { 'changed' })
    child.lua([[require('iter').current_review:refresh_annotations()]])
    helpers.wait_until(child, R .. [[.reviewed['n.txt'] == 'changed']])

    eq(
        child.lua_get(progress),
        'reviewed ▱▱▱▱▱▱▱▱▱ 0 of 2 · ↻ 1'
    )
end

T['list']['screenshot'] = function()
    open_column()
    goto_note('Why this change?')
    wait_focus('Why this change?')

    helpers.expect_screenshot(child, 'review-annotations')
end

T['list']['a long file list scrolls beside a still annotations window'] = function()
    for i = 1, 20 do
        helpers.write_file(
            vim.fs.joinpath(repo, string.format('f%02d.txt', i)),
            { 'f' }
        )
    end

    open_review()
    helpers.wait_until(child, '#' .. R .. '.changes.unstaged == 21')
    child.type_keys('G')
    H.wait_diff(child, 'unstaged n.txt')

    local tops = child.lua_get([[(function()
        local r = ]] .. R .. [[
        local s = require('iter.ui.sidebar').of(r.tab)
        return {
            files = vim.fn.getwininfo(r.panel.win)[1].topline,
            annotations = vim.fn.getwininfo(s.win)[1].topline,
        }
    end)()]])

    eq(tops.files > 1, true)
    eq(tops.annotations, 1)
    helpers.expect_screenshot(child, 'review-long-files')
end

T['preview'] = new_set()

T['preview']['moving onto a note shows its file with the annotation focused'] = function()
    open_column()
    H.wait_diff(child, 'unstaged n.txt')
    wait_focus('Rename the variable')

    eq(diff_cursor(), mark_lnum('Rename the variable'))

    goto_note('Why this change?')
    H.wait_diff(child, 'staged m.txt')
    wait_focus('Why this change?')

    eq(diff_cursor(), mark_lnum('Why this change?'))

    local groups = mark_groups()
    eq(groups['Why this change?'], 'IterDiffAnnotationFocus')
    eq(groups['Needs a test'], 'IterDiffAnnotation')
    eq(groups['outdated · Stale remark'], 'IterDiffAnnotationOutdated')
    eq(child.lua_get(S .. '.win == vim.api.nvim_get_current_win()'), true)
end

T['preview']['a deleted line shows on the side of its base'] = function()
    open_column()
    goto_note('Why remove it?')
    wait_focus('Why remove it?')

    eq(child.lua_get(R .. [[.view.files[1].side]]), 'staged')
    eq(diff_cursor(), mark_lnum('Why remove it?'))
end

T['preview']['a file outside the changes shows at HEAD with its annotation'] = function()
    open_column()
    goto_note('Not in the changes')
    eq(selected(), 'Not in the changes')
    wait_focus('Not in the changes')

    local file = child.lua_get(R .. [[.view.files[1] ]])

    eq({ file.path, file.side, file.base }, { 'c.txt', 'commit', 'HEAD' })
    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf('
                .. R
                .. '.diff_win), 1, 3, false)'
        ),
        { 'c1', 'c2' }
    )
    eq(diff_cursor(), mark_lnum('Not in the changes'))
    helpers.expect_screenshot(child, 'review-annotation-outside')
end

T['preview']['the file outside the changes takes no annotations'] = function()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg) table.insert(_G.notes, msg) end
    ]])
    open_column()
    goto_note('Not in the changes')
    wait_focus('Not in the changes')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.diff_win)')
    child.type_keys('a')

    eq(
        child.lua_get('_G.notes'),
        { '[iter] The file has no changes in this review' }
    )
end

T['preview']['a review annotation keeps the pane'] = function()
    open_column()
    goto_note('Extract a helper\nfor these lines')
    wait_focus('Extract a helper\nfor these lines')

    goto_note('Overall looks good')
    eq(selected(), 'Overall looks good')
    child.lua('vim.wait(150)')

    local shown = child.lua_get(R .. [[.view.files[1].path]])

    child.lua('vim.wait(150)')
    eq(child.lua_get(R .. [[.view.files[1].path]]), shown)
    eq(child.lua_get(R .. '.view.focus'), vim.NIL)
    eq(child.lua_get(R .. '.view:is_shown()'), true)
end

T['preview']['a file of the tree drops the focus'] = function()
    open_column()
    wait_focus('Rename the variable')

    H.select(child, 'unstaged', 'n.txt')
    helpers.wait_until(child, R .. '.view.focus == nil')
    H.wait_diff(child, 'unstaged n.txt')
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
    open_review()
    child.lua(S .. ':focus()')
    goto_note('At the very end')
    wait_focus('At the very end')

    local shown = child.lua_get([[(function()
        vim.cmd.redraw()
        local win = require('iter').current_review.diff_win
        local pos = vim.fn.win_screenpos(win)
        for row = pos[1], pos[1] + vim.api.nvim_win_get_height(win) - 1 do
            local cells = {}
            for col = pos[2], pos[2] + vim.api.nvim_win_get_width(win) - 1 do
                table.insert(cells, vim.fn.screenstring(row, col))
            end
            if table.concat(cells):find('At the very end', 1, true) then
                return row
            end
        end
        return 0
    end)()]])

    eq(shown > 0, true)
end

T['preview']['a partly staged file shows the note in its Staged section'] = function()
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
    open_review()
    child.lua(S .. ':focus()')
    goto_note('On the staged line')
    wait_focus('On the staged line')

    eq(
        child.lua_get([[(function()
            local r = require('iter').current_review
            local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
            local section = require('iter.diff.document').at(r.view.document, lnum)
            return { section.file.side, r.view.rows[lnum].text }
        end)()]]),
        { 'staged', 'b2 staged' }
    )
end

T['yank'] = new_set({
    hooks = {
        pre_case = function()
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
                _G.echoes = {}
                local echo = vim.api.nvim_echo
                vim.api.nvim_echo = function(chunks, ...)
                    table.insert(_G.echoes, chunks[1][1])
                    return echo(chunks, ...)
                end
            ]])
        end,
    },
})

---@param text string
---@return boolean
local function copied(text)
    return child.fn.getreg('+'):find(text, 1, true) ~= nil
end

---@return string[]
local function stored_bodies()
    return vim.tbl_map(function(annotation)
        return annotation.body
    end, stored())
end

T['yank']['y on a note copies that annotation'] = function()
    open_column()
    goto_note('Why this change?')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Why this change?'), true)
    eq(copied('Rename the variable'), false)

    child.type_keys('y')
    helpers.wait_until(child, '#' .. R .. '.annotations == 7')
    eq(vim.tbl_contains(stored_bodies(), 'Why this change?'), false)
end

T['yank']['y on a file row copies the annotations of that file'] = function()
    open_review()
    H.select(child, 'unstaged', 'n.txt')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Rename the variable'), true)
    eq(copied('Why this change?'), false)
    eq(copied('Overall looks good'), false)

    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])
    eq(#stored(), 8)
end

T['yank']['y on a renamed file row copies the annotations of its old path'] = function()
    helpers.git(repo, { 'mv', 'c.txt', 'r.txt' })
    open_review()
    H.select(child, 'staged', 'r.txt')
    eq(child.lua_get(R .. '.tree:file().items[1].orig_path'), 'c.txt')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Not in the changes'), true)
    eq(copied('Rename the variable'), false)
end

T['yank']['Y copies all annotations and clears them on y'] = function()
    open_column()
    child.type_keys('Y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 8 annotations. Clear them? [y/N]' }
    )
    eq(copied('Overall looks good'), true)
    eq(copied('Rename the variable'), true)

    child.type_keys('y')
    helpers.wait_until(child, '#' .. R .. '.annotations == 0')
    eq(#stored(), 0)
end

T['yank']['y in the diff pane copies the annotation under the cursor'] = function()
    open_column()
    goto_note('Why this change?')
    child.type_keys('<CR>')
    wait_focus('Why this change?')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Why this change?'), true)
    eq(copied('Extract a helper'), false)
end

T['yank']['y in the diff pane without an annotation copies the file'] = function()
    open_review()
    H.select(child, 'unstaged', 'n.txt')
    H.wait_diff(child, 'unstaged n.txt')
    child.type_keys('<CR>')
    child.lua([[vim.api.nvim_win_set_cursor(]] .. R .. [[.diff_win, { 1, 0 })]])
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Rename the variable'), true)
end

T['yank']['Y in the diff pane copies all annotations'] = function()
    open_review()
    child.type_keys('<CR>')
    child.type_keys('Y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 8 annotations. Clear them? [y/N]' }
    )
    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])
end

T['yank']['d in the diff pane deletes the annotation under the cursor'] = function()
    open_column()
    goto_note('Why this change?')
    child.type_keys('<CR>')
    wait_focus('Why this change?')
    child.type_keys('d')
    helpers.wait_until(child, '#' .. R .. '.annotations == 7')

    eq(vim.tbl_contains(stored_bodies(), 'Why this change?'), false)
end

T['keys'] = new_set()

T['keys']['<CR> jumps into the diff at the annotation'] = function()
    open_column()
    goto_note('Extract a helper\nfor these lines')
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(child.lua_get(R .. [[.view.files[1].path]]), 'm.txt')
    eq(diff_cursor(), mark_lnum('Extract a helper\nfor these lines'))
end

T['keys']['a refresh after <CR> keeps the diff cursor'] = function()
    open_column()
    child.type_keys('<CR>')
    H.wait_diff(child, 'unstaged n.txt')
    -- n.txt is the last file in tree order: r stays on it.
    child.type_keys('gg', 'r')
    helpers.wait_until(child, R .. [[.reviewed['n.txt'] == 'reviewed']])

    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(diff_cursor(), 1)
end

T['keys'][']f after <CR> steps from the shown file'] = function()
    open_column()
    goto_note('Why this change?')
    child.type_keys('<CR>')
    H.wait_diff(child, 'staged m.txt')
    child.type_keys(']f')

    H.wait_diff(child, 'unstaged n.txt')
end

T['keys']['<CR> on a file outside the changes opens it in the first tab'] = function()
    open_column()
    goto_note('Not in the changes')
    child.type_keys('<CR>')

    eq(child.api.nvim_get_current_tabpage(), 1)
    eq(vim.fs.basename(child.api.nvim_buf_get_name(0)), 'c.txt')
    eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T['keys']['e edits the annotation in the float'] = function()
    open_column()
    goto_note('Why this change?')
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
        [[vim.tbl_contains(vim.tbl_map(function(a) return a.body end, ]]
            .. R
            .. [[.annotations), 'Why this change? Please explain.')]]
    )

    eq(bodies()[2], 'Why this change? Please explain.')
end

T['keys']['d keeps the annotation when the confirm is declined'] = function()
    open_column()
    child.lua([[_G.confirm_answer = 2]])
    child.type_keys('d')

    eq(
        child.lua_get([[_G.confirms]]),
        { 'Delete the annotation?\nRename the variable' }
    )
    eq(#stored(), 8)
    eq(bodies(), ORDER)
end

T['keys']['annotating in the diff adds a note'] = function()
    clear_store()
    open_review()
    H.select(child, 'unstaged', 'n.txt')
    H.wait_diff(child, 'unstaged n.txt')
    child.type_keys('<CR>')
    child.lua([[
        local r = require('iter').current_review
        for lnum, row in ipairs(r.view.rows) do
            if row.text == 'n3 new' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('a')
    helpers.wait_until(child, E .. '.is_shown()')
    child.type_keys('A new note', '<C-s>')

    helpers.wait_until(child, '#' .. R .. '.annotations == 1')
    helpers.wait_until(child, S .. '.signature ~= nil')
    child.lua([[require('iter.ui.sidebar').refresh_all()]])
    eq(bodies(), { 'A new note' })
end

T['keys']['<CR> on a review annotation opens it in the editor'] = function()
    open_column()
    goto_note('Overall looks good')
    eq(selected(), 'Overall looks good')
    child.type_keys('<CR>')

    helpers.wait_until(child, E .. '.is_shown()')
    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'Overall looks good',
    })
end

T['api'] = new_set()

T['api']['annotations() opens the review with its annotations focused'] = function()
    child.cmd('edit c.txt')
    child.lua([[require('iter').annotations()]])
    helpers.wait_until(child, R .. ' ~= nil')

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.lua_get(S .. '.win == vim.api.nvim_get_current_win()'), true)
    eq(selected(), 'Needs a test')
end

T['api']['annotations() switches to the open review'] = function()
    open_review()
    child.cmd('tabfirst')
    child.lua([[require('iter').annotations()]])

    eq(#child.api.nvim_list_tabpages(), 2)
    eq(child.api.nvim_get_current_tabpage(), child.lua_get(R .. '.tab'))
    eq(child.lua_get(S .. '.win == vim.api.nvim_get_current_win()'), true)
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

T['clean'][':Iter review on a clean tree lists the review annotation'] = function()
    child.cmd('Iter review')
    helpers.wait_until(child, R .. ' ~= nil and ' .. R .. '.panel ~= nil')

    eq(child.v.errmsg, '')
    eq(notes(), {})
    eq(bodies(), { 'Overall looks good' })
    eq(
        vim.trim(
            child.lua_get(
                'vim.api.nvim_buf_get_lines('
                    .. R
                    .. '.tree.buf, 4, 5, false)[1]'
            )
        ),
        'Working tree clean'
    )
end

T['clean']['annotations() on a clean tree focuses the annotations'] = function()
    child.lua([[require('iter').annotations()]])
    helpers.wait_until(child, R .. ' ~= nil')

    eq(child.v.errmsg, '')
    eq(selected(), 'Overall looks good')
end

return T
