local helpers = dofile('tests/helpers.lua')

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

--- `f.lua`, 40 lines, with two hunks and a gap between them: line 3
--- changes, line 5 goes, two lines come after line 8; line 36 changes.
---@return string
local function create_repo()
    local lines = numbered('local v = ', 1, 40)
    local path = helpers.create_repo({ ['f.lua'] = lines })
    local new = vim.deepcopy(lines)

    new[3] = 'local v = 3 + 0'
    new[36] = 'local v = 36 + 0'
    table.insert(new, 9, 'local w = 1')
    table.insert(new, 10, 'local w = 2')
    table.remove(new, 5)
    helpers.write_file(vim.fs.joinpath(path, 'f.lua'), new)

    return path
end

local function stub_ui()
    child.lua([[
        _G.notes = {}
        vim.notify = function(msg, level)
            table.insert(_G.notes, { msg, level })
        end
    ]])
end

--- Open the review on the first file and wait for its diff.
local function open_review()
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )
end

--- Move into the diff pane and press `|`.
local function split()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.type_keys('|')
    helpers.wait_until(child, R .. [[.drawer.view.old ~= nil]])
end

---@return string[]
local function left_lines()
    return child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.view.old.buf, 0, -1, false)]]
    )
end

---@return string[]
local function right_lines()
    return child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.view.buf, 0, -1, false)]]
    )
end

--- Row kinds of both panes as `old | new`.
---@return string[]
local function kinds()
    return child.lua_get([[(function()
        local v = ]] .. R .. [[.drawer.view
        local out = {}
        for lnum, row in ipairs(v.rows) do
            out[lnum] = v.old.rows[lnum].kind .. ' | ' .. row.kind
        end
        return out
    end)()]])
end

--- Focus `win` ('left' or 'right') and put the cursor on the first line
--- whose text there is `text`.
---@param win 'left'|'right'
---@param text string
local function cursor_on(win, text)
    child.lua(
        [[
        local side, text = ...
        local v = require('iter').current_review.drawer.view
        local pane = side == 'left' and v.old or v
        vim.api.nvim_set_current_win(pane.win)
        local lines = vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false)
        for lnum, line in ipairs(lines) do
            if line == text then
                vim.api.nvim_win_set_cursor(pane.win, { lnum, 0 })
                return
            end
        end
        error('no line ' .. text)
    ]],
        { win, text }
    )
end

--- Cursor line and top line of both panes.
---@return integer[][]
local function positions()
    return child.lua_get([[(function()
        local v = ]] .. R .. [[.drawer.view
        local out = {}
        for _, win in ipairs({ v.old.win, v.win }) do
            local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
            table.insert(out, { view.lnum, view.topline })
        end
        return out
    end)()]])
end

--- Screen rows of each pane, virtual lines included.
---@return integer[]
local function heights()
    return child.lua_get([[(function()
        local v = ]] .. R .. [[.drawer.view
        return {
            vim.api.nvim_win_text_height(v.old.win, {}).all,
            vim.api.nvim_win_text_height(v.win, {}).all,
        }
    end)()]])
end

---@return string
local function statusline()
    return child.lua_get([[require('iter').statusline()]])
end

---@param args string[]
---@return string
local function git_out(args)
    return helpers.git(repo, args)
end

--- Store an annotation of the review.
---@param annotation table
local function add_annotation(annotation)
    child.lua(
        [[
        local annotation = ...
        local root = require('iter').current_review.drawer.changes.root
        assert(require('iter.store').put_annotation(root, annotation))
        require('iter').current_review:refresh_annotations()
    ]],
        { annotation }
    )
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_repo()
            helpers.start_child(child, repo, { lines = 30, columns = 100 })
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['split'] = new_set()

T['split']['| shows the old side left, aligned with fillers'] = function()
    open_review()

    local before = child.lua_get([[(function()
        local r = ]] .. R .. [[
        return {
            vim.api.nvim_win_get_height(r.spacer_win),
            vim.api.nvim_win_get_position(r.drawer.win)[1],
        }
    end)()]])

    split()

    local left, right = left_lines(), right_lines()

    eq(#left, #right)
    eq(left[1], 'f.lua')
    eq(right[1], 'f.lua')
    eq(kinds(), {
        'header | header',
        'hunk | hunk',
        'context | context',
        'context | context',
        'del | add',
        'context | context',
        'del | filler',
        'context | context',
        'context | context',
        'context | context',
        'filler | add',
        'filler | add',
        'context | context',
        'context | context',
        'context | context',
        'gap | gap',
        'hunk | hunk',
        'context | context',
        'context | context',
        'context | context',
        'del | add',
        'context | context',
        'context | context',
        'context | context',
        'gap | gap',
    })
    eq(left[2], '@@ -1,11')
    eq(right[2], '@@ +1,12')
    eq({ left[5], right[5] }, { 'local v = 3', 'local v = 3 + 0' })
    eq({ left[7], right[7] }, { 'local v = 5', '' })
    eq({ left[11], right[11] }, { '', 'local w = 1' })
    eq(statusline(), 'review · split · f.lua · 1/1')

    local layout = child.lua_get([[(function()
        local r = ]] .. R .. [[
        local v = r.drawer.view
        return {
            vim.api.nvim_win_get_position(v.old.win)[2]
                < vim.api.nvim_win_get_position(v.win)[2],
            v.win == r.diff_win,
            vim.wo[v.win].scrollbind and vim.wo[v.old.win].scrollbind,
            vim.wo[v.win].cursorbind and vim.wo[v.old.win].cursorbind,
            vim.api.nvim_win_get_height(r.spacer_win),
            vim.api.nvim_win_get_position(r.drawer.win)[1],
        }
    end)()]])

    eq(layout, { true, true, true, true, before[1], before[2] })
end

T['split']['screenshot side by side'] = function()
    open_review()
    split()
    add_annotation({
        scope = 'range',
        body = 'Why the second local?',
        anchor = {
            path = 'f.lua',
            side = 'new',
            start_line = 8,
            end_line = 9,
            lines = { 'local w = 1', 'local w = 2' },
        },
    })
    child.type_keys('gg')

    helpers.expect_screenshot(child, 'review-split')
end

T['split']['| and - are idempotent and - restores one pane'] = function()
    open_review()

    local before = child.lua_get([[(function()
        local r = ]] .. R .. [[
        return {
            #vim.api.nvim_tabpage_list_wins(r.tab),
            #vim.api.nvim_list_bufs(),
            vim.api.nvim_win_get_width(r.diff_win),
        }
    end)()]])

    split()
    child.type_keys('|')
    eq(
        child.lua_get([[#vim.api.nvim_tabpage_list_wins(]] .. R .. [[.tab)]]),
        before[1] + 1
    )

    child.type_keys('-')
    helpers.wait_until(child, R .. [[.drawer.view.old == nil]])
    child.type_keys('-')

    local after = child.lua_get([[(function()
        local r = ]] .. R .. [[
        local v = r.drawer.view
        return {
            #vim.api.nvim_tabpage_list_wins(r.tab),
            #vim.api.nvim_list_bufs(),
            vim.api.nvim_win_get_width(r.diff_win),
            vim.wo[r.diff_win].scrollbind,
            vim.wo[r.diff_win].cursorbind,
            vim.api.nvim_get_current_win() == r.diff_win,
            v.document.layout,
        }
    end)()]])

    eq(
        after,
        { before[1], before[2], before[3], false, false, true, 'unified' }
    )
    eq(right_lines()[2], '@@ -1,11 +1,12 @@')
    eq(statusline(), 'review · f.lua · 1/1')
end

T['split']['- from the left window moves into the right one'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 5')
    child.type_keys('-')
    helpers.wait_until(child, R .. [[.drawer.view.old == nil]])

    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == ]] .. R .. [[.diff_win]]
        ),
        true
    )
    eq(
        child.lua_get([[(function()
            local v = ]] .. R .. [[.drawer.view
            local lnum = vim.api.nvim_win_get_cursor(v.win)[1]
            local row = v.rows[lnum]
            return row.kind .. ' ' .. row.text
        end)()]]),
        'del local v = 5'
    )
end

T['split']['closing the left window goes back to one pane'] = function()
    open_review()
    split()
    child.lua(
        [[vim.api.nvim_win_close(]] .. R .. [[.drawer.view.old.win, true)]]
    )
    helpers.wait_until(
        child,
        R
            .. [[.drawer.view.layout == 'unified' and ]]
            .. R
            .. [[.drawer.view:is_shown()]]
    )

    eq(right_lines()[2], '@@ -1,11 +1,12 @@')
    eq(child.lua_get(R .. [[:is_open()]]), true)
end

T['split']['closing the review leaves no window or buffer behind'] = function()
    local before = child.lua_get([[#vim.api.nvim_list_bufs()]])

    open_review()
    split()
    child.lua([[_G.old_buf = ]] .. R .. [[.drawer.view.old.buf]])
    child.type_keys('q')
    helpers.wait_until(child, [[require('iter').current_review == nil]])

    eq(child.lua_get([[vim.api.nvim_buf_is_valid(_G.old_buf)]]), false)
    eq(child.lua_get([[#vim.api.nvim_list_tabpages()]]), 1)
    eq(child.lua_get([[#vim.api.nvim_list_wins()]]), 1)
    eq(child.lua_get([[#vim.api.nvim_list_bufs()]]), before)
end

T['split']['the status preview maps neither | nor -'] = function()
    child.cmd('Iter status')
    helpers.wait_until(
        child,
        [[require('iter').drawer ~= nil and require('iter').drawer.view:is_shown()]]
    )

    local maps = child.lua_get([[(function()
        local buf = require('iter').drawer.view.buf
        local out = {}
        for _, lhs in ipairs({ '|', '-' }) do
            local map = vim.api.nvim_buf_call(buf, function()
                return vim.fn.maparg(lhs, 'n', false, true)
            end)
            table.insert(out, map.buffer == 1)
        end
        return out
    end)()]])

    eq(maps, { false, false })
end

T['split']['resizing keeps the panes the same width'] = function()
    open_review()
    split()

    local widths = {}

    for _, columns in ipairs({ 140, 200, 70 }) do
        child.o.columns = columns
        helpers.wait_until(
            child,
            string.format(
                [[(function()
            local v = %s.drawer.view
            local a = vim.api.nvim_win_get_width(v.old.win)
            local b = vim.api.nvim_win_get_width(v.win)
            return a + b + 1 == %d and math.abs(a - b) <= 1
                and v.marks_width == v:text_width()
        end)()]],
                R,
                columns
            )
        )
        table.insert(
            widths,
            child.lua_get([[(function()
                local v = ]] .. R .. [[.drawer.view
                return { v:text_width(v.old), v:text_width() }
            end)()]])
        )
    end

    for _, pair in ipairs(widths) do
        eq(math.abs(pair[1] - pair[2]) <= 1, true)
    end
end

T['sync'] = new_set()

T['sync']['scrolling one window scrolls the other'] = function()
    open_review()
    split()
    child.lua([[
        local v = require('iter').current_review.drawer.view
        vim.api.nvim_set_current_win(v.win)
        v:expand(16)
    ]])
    helpers.wait_until(child, R .. [[.drawer.view.rows[16].kind ~= 'gap']])

    child.type_keys('<C-d>')
    local p = positions()

    eq(p[1], p[2])
    eq(p[2][2] > 1, true)

    cursor_on('left', 'local v = 30')
    child.type_keys('<C-e>', '<C-e>')
    child.type_keys('j')
    p = positions()
    eq(p[1], p[2])
end

T['sync']['jumps from the left window move both'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 1')
    child.type_keys(']c')

    local p = positions()

    eq(p[1], p[2])
    eq(left_lines()[p[1][1]], '@@ -33,7')

    child.type_keys('[c')
    p = positions()
    eq(p[1], p[2])
    eq(p[1][1], 2)
end

T['sync']['the drawer scrolls both windows'] = function()
    open_review()
    split()
    child.lua([[
        local v = require('iter').current_review.drawer.view
        v:expand(16)
        vim.api.nvim_set_current_win(require('iter').current_review.drawer.win)
    ]])
    child.type_keys('<C-d>')

    local p = positions()

    eq(p[1], p[2])
    eq(p[1][2] > 1, true)
end

T['sync']['<CR> on a gap in the left window expands both sides'] = function()
    open_review()
    split()
    cursor_on('left', '')
    child.lua([[
        local v = require('iter').current_review.drawer.view
        for lnum, row in ipairs(v.old.rows) do
            if row.kind == 'gap' then
                vim.api.nvim_win_set_cursor(v.old.win, { lnum, 0 })
                break
            end
        end
    ]])
    child.type_keys('<CR>')

    local left, right = left_lines(), right_lines()

    eq(#left, #right)
    eq({ left[16], right[16] }, { 'local v = 12', 'local v = 12' })
    eq(positions()[1], positions()[2])
end

T['annotations'] = new_set()

T['annotations']['a anchors on the side of the window'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 5')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Old note', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 1')

    cursor_on('right', 'local w = 2')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('New note', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 2')

    local anchors = child.lua_get([[(function()
        local out = {}
        for _, a in ipairs(]] .. R .. [[.annotations) do
            out[a.body] = { a.anchor.side, a.anchor.base or '', a.anchor.start_line }
        end
        return out
    end)()]])

    eq(anchors, {
        ['Old note'] = { 'old', 'index', 5 },
        ['New note'] = { 'new', '', 9 },
    })
end

T['annotations']['a on context in the left window anchors the new side'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 6')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Context note', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 1')

    eq(child.lua_get(R .. [[.annotations[1].anchor.side]]), 'new')
    eq(child.lua_get(R .. [[.annotations[1].anchor.start_line]]), 5)
end

T['annotations']['virtual lines on one side get blank twins on the other'] = function()
    open_review()
    split()
    add_annotation({
        scope = 'line',
        body = string.rep('A long note on the deleted line. ', 4),
        anchor = {
            path = 'f.lua',
            side = 'old',
            base = 'index',
            start_line = 5,
            end_line = 5,
            lines = { 'local v = 5' },
        },
    })
    add_annotation({
        scope = 'line',
        body = 'Short',
        anchor = {
            path = 'f.lua',
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'local v = 3 + 0' },
        },
    })
    helpers.wait_until(child, '#' .. R .. '.drawer.view.marks == 2')

    local h = heights()

    eq(h[1], h[2])
    eq(h[1] > #left_lines() + 2, true)

    local virt = child.lua_get([[(function()
        local v = ]] .. R .. [[.drawer.view
        local out = {}
        for _, buf in ipairs({ v.old.buf, v.buf }) do
            local per = {}
            for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
                if m[4].virt_lines then
                    local text = ''
                    for _, line in ipairs(m[4].virt_lines) do
                        for _, chunk in ipairs(line) do
                            text = text .. chunk[1]
                        end
                    end
                    per[m[2] + 1] = { #m[4].virt_lines, text:find('long note') ~= nil, text:find('Short') ~= nil }
                end
            end
            table.insert(out, per)
        end
        return out
    end)()]])

    -- Line 5 holds the deleted line 3 and its added line, line 7 the
    -- deleted line 5 beside a filler.
    eq(virt[1][5][2], false)
    eq(virt[1][5][3], false)
    eq(virt[2][5][3], true)
    eq(virt[1][5][1], virt[2][5][1])
    eq(virt[1][7][2], true)
    eq(virt[2][7][2], false)
    eq(virt[1][7][1], virt[2][7][1])

    -- ]a from the left window runs over both.
    cursor_on('left', 'f.lua')
    child.type_keys(']a')
    eq(positions()[1][1], 5)
    child.type_keys(']a')
    eq(positions(), { { 7, positions()[1][2] }, { 7, positions()[1][2] } })
end

T['annotations']['visual a over context and a deleted line in the left window anchors the old side'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 4')
    child.type_keys('V', 'j', 'j', 'a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Old range', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.annotations == 1')

    eq(
        child.lua_get([[(function()
            local a = ]] .. R .. [[.annotations[1].anchor
            return { a.side, a.base, a.start_line, a.end_line, a.lines }
        end)()]]),
        {
            'old',
            'index',
            4,
            6,
            { 'local v = 4', 'local v = 5', 'local v = 6' },
        }
    )
end

T['staging'] = new_set()

T['staging']['s in the left window stages the hunk'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 33')
    child.type_keys('s')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.staged == 1]])

    eq(
        git_out({ 'diff', '--cached', '--unified=0' }):match('@@ [^@]+@@'),
        '@@ -36 +36 @@'
    )
    eq(child.lua_get(R .. [[.drawer.view.old ~= nil]]), true)
end

T['staging']['visual s in the left window stages both sides of the lines'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 3')
    child.type_keys('V', 's')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.staged == 1]])

    eq(
        git_out({ 'diff', '--cached', '--unified=0' }):match('@@.*'),
        '@@ -3 +3 @@ local v = 2\n-local v = 3\n+local v = 3 + 0\n'
    )
end

T['staging']['visual s over a filler stages the one side there'] = function()
    open_review()
    split()
    cursor_on('right', 'local w = 1')
    child.type_keys('V', 'j', 's')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.staged == 1]])

    eq(
        git_out({ 'diff', '--cached', '--unified=0' }):match('@@.*'),
        '@@ -8,0 +9,2 @@ local v = 8\n+local w = 1\n+local w = 2\n'
    )
end

T['keys'] = new_set()

T['keys']['gf in the left window opens the line that took its place'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    open_review()
    split()
    cursor_on('left', 'local v = 5')
    child.type_keys('gf')

    eq(
        child.lua_get([[{
        line = vim.api.nvim_win_get_cursor(0)[1],
        tab = vim.api.nvim_get_current_tabpage(),
        name = vim.fs.basename(vim.api.nvim_buf_get_name(0)),
    }]]),
        { line = 5, tab = origin, name = 'f.lua' }
    )
end

T['keys']['v in the left window toggles viewed and keeps the split'] = function()
    open_review()
    split()
    cursor_on('left', 'local v = 5')
    child.type_keys('v')

    helpers.wait_until(child, R .. [[.viewed['f.lua'] == 'viewed']])
    eq(child.lua_get(R .. [[.drawer.view.old ~= nil]]), true)
    eq(#left_lines(), #right_lines())
end

T['keys']['the Annotations column shows an old-side annotation on both'] = function()
    open_review()
    split()
    add_annotation({
        scope = 'line',
        body = 'Why remove it?',
        anchor = {
            path = 'f.lua',
            side = 'old',
            base = 'index',
            start_line = 36,
            end_line = 36,
            lines = { 'local v = 36' },
        },
    })
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    child.type_keys('l')
    helpers.wait_until(child, R .. [[.drawer.view.focus ~= nil]])

    local p = positions()

    eq(p[1], p[2])
    eq(left_lines()[p[1][1]], 'local v = 36')

    child.type_keys('<CR>')
    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    eq(positions()[1], positions()[2])
end

T['keys'][':edit in the right window keeps both panes'] = function()
    open_review()
    split()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.cmd('edit f.lua')
    helpers.wait_until(child, R .. [[.drawer.view:is_shown()]])
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_get_name(0):match('f.lua$') ~= nil]]
    )

    eq(child.lua_get(R .. [[.drawer.view.old ~= nil]]), true)
    eq(#left_lines(), #right_lines())
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_buf(]]
                .. R
                .. [[.drawer.view.old.win) == ]]
                .. R
                .. [[.drawer.view.old.buf]]
        ),
        true
    )
end

T['drawer'] = new_set()

--- The key hint line of the drawer float.
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

T['drawer']['| and - in the drawer switch the pane and keep the focus'] = function()
    open_review()
    eq(footer():find('| split', 1, true) ~= nil, true)

    child.type_keys('|')
    helpers.wait_until(child, R .. [[.drawer.view.old ~= nil]])
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == ]]
                .. R
                .. [[.drawer:selection_win()]]
        ),
        true
    )
    eq(#left_lines(), #right_lines())
    eq(footer():find('- unified', 1, true) ~= nil, true)

    child.type_keys('-')
    helpers.wait_until(child, R .. [[.drawer.view.old == nil]])
    eq(
        child.lua_get(
            [[vim.api.nvim_get_current_win() == ]]
                .. R
                .. [[.drawer:selection_win()]]
        ),
        true
    )
    eq(footer():find('| split', 1, true) ~= nil, true)
end

T['drawer']['selecting another file shows it on both sides'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'g.lua'), { 'local g = 1' })
    git_out({ 'add', 'g.lua' })
    git_out({ 'commit', '--quiet', '-m', 'g' })
    helpers.write_file(
        vim.fs.joinpath(repo, 'g.lua'),
        { 'local g = 2', 'local h = 3' }
    )

    open_review()
    child.type_keys('|')
    helpers.wait_until(child, R .. [[.drawer.view.old ~= nil]])
    child.type_keys('j')
    helpers.wait_until(child, [[(function()
        local file = ]] .. R .. [[.drawer.view.files[1]
        return file and file.path == 'g.lua'
    end)()]])

    eq(left_lines(), { 'g.lua', '@@ -1', 'local g = 1', '' })
    eq(right_lines(), { 'g.lua', '@@ +1,2', 'local g = 2', 'local h = 3' })
    eq(positions()[1], positions()[2])
    eq(statusline(), 'review · split · g.lua · 2/2')
end

--- Restart on a repo where l3 and l4 of `f.txt` (l1..l8) change, staged
--- with `stage_all`.
---@param stage_all? boolean
local function two_pairs(stage_all)
    child.stop()
    helpers.cleanup(repo)
    repo = helpers.create_repo({ ['f.txt'] = numbered('l', 1, 8) })

    local lines = numbered('l', 1, 8)

    lines[3], lines[4] = 'l3 changed', 'l4 changed'
    helpers.write_file(vim.fs.joinpath(repo, 'f.txt'), lines)

    if stage_all then
        git_out({ 'add', 'f.txt' })
    end

    helpers.start_child(child, repo, { lines = 30, columns = 100 })
    stub_ui()
end

---@return string[]
local function index_lines()
    return vim.split(vim.trim(git_out({ 'show', ':f.txt' })), '\n')
end

T['staging']['visual s on one pair of two keeps the line in place'] = function()
    two_pairs()
    open_review()
    split()
    cursor_on('left', 'l3')
    child.type_keys('V', 's')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.staged == 1]])

    eq(
        index_lines(),
        { 'l1', 'l2', 'l3 changed', 'l4', 'l5', 'l6', 'l7', 'l8' }
    )
end

T['staging']['visual u on one pair of two keeps the line in place'] = function()
    two_pairs(true)
    open_review()
    split()
    cursor_on('right', 'l4 changed')
    child.type_keys('V', 'u')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.unstaged == 1]])

    eq(
        index_lines(),
        { 'l1', 'l2', 'l3 changed', 'l4', 'l5', 'l6', 'l7', 'l8' }
    )
end

T['staging']['unified: the del, then its add, land in place'] = function()
    two_pairs()
    open_review()
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum, row in ipairs(r.drawer.view.rows) do
            if row.kind == 'del' and row.text == 'l3' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('V', 's')
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.changes.staged == 1]])
    child.lua([[
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        r.drawer:refresh()
        for lnum, row in ipairs(r.drawer.view.rows) do
            if row.kind == 'add' and row.text == 'l3 changed' then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
            end
        end
    ]])
    eq(
        child.lua_get([[(function()
            local r = require('iter').current_review
            local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
            return r.drawer.view.rows[lnum].text
        end)()]]),
        'l3 changed'
    )
    child.type_keys('V', 's')
    helpers.wait_until(
        child,
        [[vim.trim(vim.fn.system({ 'git', 'show', ':f.txt' })):find('l3 changed') ~= nil]]
    )

    eq(
        index_lines(),
        { 'l1', 'l2', 'l3 changed', 'l4', 'l5', 'l6', 'l7', 'l8' }
    )
end

T['keys'][':edit in the left window opens the file in the origin tab'] = function()
    local origin = child.api.nvim_get_current_tabpage()

    open_review()
    split()

    local wins =
        child.lua_get([[#vim.api.nvim_tabpage_list_wins(]] .. R .. [[.tab)]])

    cursor_on('left', 'local v = 4')
    child.cmd('edit f.lua')
    helpers.wait_until(
        child,
        [[vim.api.nvim_get_current_tabpage() == ]] .. origin
    )

    eq(
        child.lua_get([[vim.fs.basename(vim.api.nvim_buf_get_name(0))]]),
        'f.lua'
    )
    eq(
        child.lua_get([[(function()
            local r = ]] .. R .. [[
            local v = r.drawer.view
            local names = {}
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(r.tab)) do
                local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
                if name:match('f%.lua$') then
                    table.insert(names, name)
                end
            end
            return {
                v.layout,
                v.old ~= nil and vim.api.nvim_win_get_buf(v.old.win) == v.old.buf,
                #vim.api.nvim_tabpage_list_wins(r.tab),
                #names,
            }
        end)()]]),
        { 'split', true, wins, 0 }
    )
    eq(#left_lines(), #right_lines())
end

T['all files'] = new_set()

T['all files']['m and | show every file on both sides'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = helpers.create_repo({
        ['a.txt'] = { 'a', 'keep' },
        ['b.txt'] = { 'b' },
        ['c.txt'] = { 'c' },
    })
    helpers.write_file(vim.fs.joinpath(repo, 'a.txt'), { 'keep' })
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), { 'bx' })
    helpers.write_file(vim.fs.joinpath(repo, 'c.txt'), { 'c', 'c2' })
    helpers.start_child(child, repo, { lines = 30, columns = 100 })
    stub_ui()

    open_review()
    split()
    child.type_keys('m')
    helpers.wait_until(child, R .. [[.drawer.view.document.sections[3] ~= nil]])

    local left, right = left_lines(), right_lines()

    eq(left, {
        'a.txt',
        '@@ -1,2',
        'a',
        'keep',
        '',
        'b.txt',
        '@@ -1',
        'b',
        '',
        'c.txt',
        '@@ -1',
        'c',
        '',
    })
    eq(right, {
        'a.txt',
        '@@ +1',
        '',
        'keep',
        '',
        'b.txt',
        '@@ +1',
        'bx',
        '',
        'c.txt',
        '@@ +1,2',
        'c',
        'c2',
    })
    eq(statusline(), 'review · all files · split · a.txt · 1/3')

    cursor_on('left', 'b')
    child.type_keys(']f')
    eq(positions()[1][1], 10)
    eq(positions()[2][1], 10)
    helpers.wait_until(child, [[(function()
        local item = ]] .. R .. [[.drawer:selected()
        return item and item.path == 'c.txt'
    end)()]])

    child.type_keys('m')
    helpers.wait_until(child, R .. [[.drawer.view.document.sections[2] == nil]])
    eq(left_lines()[1], 'c.txt')
    eq(#left_lines(), #right_lines())
end

return T
