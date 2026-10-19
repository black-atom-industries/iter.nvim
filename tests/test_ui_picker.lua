local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = [[require('iter').current_review]]
local P = [[require('iter.annotations.picker')]]
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
local function create_picker_repo()
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

-- Stored in this order; the picker sorts them.
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

local function wait_picker()
    helpers.wait_until(
        child,
        P
            .. [[.is_open() and vim.api.nvim_get_current_win() == ]]
            .. P
            .. [[.prompt_win()]]
    )
end

---@return boolean
local function picker_open()
    return child.lua_get(P .. [[.is_open()]])
end

--- Open the picker from the drawer of the review.
local function open_from_drawer()
    open_review()
    child.type_keys('L')
    wait_picker()
end

---@return string[]
local function results()
    return child.lua_get([[vim.api.nvim_buf_get_lines(
            vim.api.nvim_win_get_buf(]] .. P .. [[.win()), 0, -1, false)]])
end

---@return string?
local function selected()
    return child.lua_get([[(function()
        local c = ]] .. P .. [[.selected()
        return c and c.body or vim.NIL
    end)()]])
end

---@return string
local function mode()
    return child.api.nvim_get_mode().mode
end

---@return string
local function current_name()
    return vim.fs.basename(child.api.nvim_buf_get_name(0))
end

---@return integer
local function cursor_line()
    return child.api.nvim_win_get_cursor(0)[1]
end

---@return integer
local function window_count()
    return child.lua_get([[#vim.api.nvim_list_wins()]])
end

---@return integer
local function picker_buffers()
    return child.lua_get([[#vim.tbl_filter(function(b)
        return vim.bo[b].filetype == 'iterpicker'
    end, vim.api.nvim_list_bufs())]])
end

---@return boolean
local function picker_augroup()
    return child.lua_get(
        [[pcall(vim.api.nvim_get_autocmds, { group = 'iter.picker' })]]
    )
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

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_picker_repo()
            helpers.start_child(child, repo, { lines = 30 })
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

local LISTING = {
    'n.txt',
    '  L3      Rename the variable',
    'm.txt',
    '  file    Needs a test',
    '  L3      Why this change?',
    '  L4-6    Extract a helper …',
    '  L8 old  Why remove it?',
    '  L9      outdated · Stale remark',
    'c.txt',
    '  L2      Not in the changes',
    'Review',
    '          Overall looks good',
}

T['open'] = new_set()

T['open']['L in the review drawer lists the groups in drawer order'] = function()
    open_from_drawer()

    eq(results(), LISTING)
    eq(selected(), 'Rename the variable')
    eq(mode(), 'i')

    local zindex = child.lua_get(
        [[vim.api.nvim_win_get_config(]] .. P .. [[.win()).zindex]]
    )
    local drawer = child.lua_get(R .. [[.drawer.config.options.drawer.zindex]])
    eq(zindex, drawer + 10)

    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. P .. [[.prompt_win()).zindex]]
        ),
        drawer + 10
    )
end

T['open']['screenshot'] = function()
    open_from_drawer()
    helpers.expect_screenshot(child, 'picker')
end

T['open']['L in the diff pane opens it'] = function()
    open_review()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.type_keys('L')
    wait_picker()

    eq(results(), LISTING)
end

T['open']['annotations() lists files alphabetically outside the review'] = function()
    child.cmd('edit c.txt')
    child.lua([[require('iter').annotations()]])
    wait_picker()

    eq(results(), {
        'c.txt',
        '  L2      Not in the changes',
        'm.txt',
        '  file    Needs a test',
        '  L3      Why this change?',
        '  L4-6    Extract a helper …',
        '  L8 old  Why remove it?',
        '  L9      outdated · Stale remark',
        'n.txt',
        '  L3      Rename the variable',
        'Review',
        '          Overall looks good',
    })
end

T['open']['without annotations it warns and opens nothing'] = function()
    child.lua([[
        local store = require('iter.store')
        local ids = {}
        for _, c in ipairs(store.load(vim.fn.getcwd()).annotations) do
            table.insert(ids, c.id)
        end
        store.remove_annotations(vim.fn.getcwd(), ids)
        require('iter').annotations()
    ]])

    eq(picker_open(), false)
    eq(notes(), { '[iter] No annotations' })
end

T['open']['outside a repository it warns'] = function()
    child.cmd('cd /')
    child.lua([[require('iter').annotations()]])

    eq(picker_open(), false)
    eq(notes(), { '[iter] Not inside a git repository' })
end

T['filter'] = new_set()

T['filter']['typing narrows the list'] = function()
    open_from_drawer()
    child.type_keys('helper')

    eq(results(), { 'm.txt', '  L4-6  Extract a helper …' })
    eq(selected(), 'Extract a helper\nfor these lines')
end

T['filter']['matches the path, case-insensitively, over several words'] = function()
    open_from_drawer()
    child.type_keys('N.TXT')

    eq(results(), { 'n.txt', '  L3  Rename the variable' })

    child.type_keys('<C-u>', 'm.txt why')

    eq(results(), {
        'm.txt',
        '  L3      Why this change?',
        '  L8 old  Why remove it?',
    })
end

T['filter']['matches the whole body and the outdated label'] = function()
    open_from_drawer()
    child.type_keys('for these')

    eq(results(), { 'm.txt', '  L4-6  Extract a helper …' })

    child.type_keys('<C-u>', 'outdated')

    eq(results(), { 'm.txt', '  L9  outdated · Stale remark' })
end

T['filter']['folds non-ASCII case'] = function()
    child.lua([[require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'review', body = 'Ärger mit Übung', anchor = { side = 'new' },
    })]])
    open_from_drawer()
    child.type_keys('ärger')
    eq(results(), { 'Review', '    Ärger mit Übung' })

    child.type_keys('<C-u>', 'ÜBUNG')
    eq(results(), { 'Review', '    Ärger mit Übung' })
end

T['filter']['backspace widens it again and no match says so'] = function()
    open_from_drawer()
    child.type_keys('zzz')

    eq(results(), { '  No matching annotations' })
    eq(selected(), vim.NIL)

    child.type_keys('<CR>')
    eq(picker_open(), true)

    child.type_keys('<BS>', '<BS>', '<BS>')
    eq(results(), LISTING)
end

T['keys'] = new_set()

T['keys']['<C-n> and <C-p> move and wrap'] = function()
    open_from_drawer()
    child.type_keys('<C-n>')
    eq(selected(), 'Needs a test')

    child.type_keys('<C-n>', '<C-p>')
    eq(selected(), 'Needs a test')

    child.type_keys('<C-p>', '<C-p>')
    eq(selected(), 'Overall looks good')

    child.type_keys('<C-n>')
    eq(selected(), 'Rename the variable')
    eq(mode(), 'i')
end

T['keys']['the selected row is marked and stays in view'] = function()
    child.lua([[vim.o.lines = 16]])
    open_from_drawer()
    child.type_keys('<C-p>')

    local marked = child.lua_get([[(function()
            local buf = vim.api.nvim_win_get_buf(]] .. P .. [[.win())
            local ns = vim.api.nvim_create_namespace('iter.picker.selected')
            local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
            return marks[1] and marks[1][2] + 1 or vim.NIL
        end)()]])
    eq(marked, 12)

    local visible =
        child.lua_get([[vim.api.nvim_win_call(]] .. P .. [[.win(), function()
                return vim.fn.line('w0') <= 12 and 12 <= vim.fn.line('w$')
            end)]])
    eq(visible, true)
end

T['keys']['<Esc> closes and leaves nothing behind'] = function()
    open_review()
    local wins = window_count()
    local win = child.lua_get(R .. [[.drawer.win]])
    child.type_keys('L')
    wait_picker()
    eq(window_count(), wins + 2)

    child.type_keys('<Esc>')

    helpers.wait_until(child, 'not ' .. P .. '.is_open()')
    eq(window_count(), wins)
    eq(picker_buffers(), 0)
    eq(picker_augroup(), false)
    eq(mode(), 'n')
    eq(child.api.nvim_get_current_win(), win)
end

T['keys']['both floats follow a resize'] = function()
    open_from_drawer()
    local function width()
        return child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. P .. [[.win()).width]]
        )
    end
    local before = width()

    child.o.columns = 60
    child.cmd('doautocmd VimResized')

    eq(width() < before, true)
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. P .. [[.prompt_win()).width]]
        ),
        width()
    )
end

T['keys']['leaving the prompt closes the picker'] = function()
    open_from_drawer()
    child.cmd('tabnew')
    local tab = child.lua_get([[vim.api.nvim_get_current_tabpage()]])

    helpers.wait_until(child, 'not ' .. P .. '.is_open()')
    eq(child.lua_get([[vim.api.nvim_get_current_tabpage()]]), tab)
    eq(picker_buffers(), 0)
    eq(picker_augroup(), false)
end

T['keys']['<Esc> also closes in normal mode'] = function()
    open_from_drawer()
    child.cmd('stopinsert')
    child.type_keys('<Esc>')

    eq(picker_open(), false)
end

T['jump'] = new_set()

T['jump']['<CR> shows an annotation of a changed file in the review'] = function()
    open_from_drawer()
    child.type_keys('helper', '<CR>')

    eq(picker_open(), false)
    eq(mode(), 'n')
    eq(
        child.lua_get([[vim.api.nvim_get_current_tabpage()]]),
        child.lua_get(R .. '.tab')
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.diff_win'))
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')

    local lnum = mark_lnum('Extract a helper\nfor these lines')
    eq(type(lnum), 'number')
    eq(cursor_line(), lnum)
    eq(picker_buffers(), 0)
    eq(picker_augroup(), false)
end

T['jump']['<CR> on a file annotation lands on the header row'] = function()
    open_from_drawer()
    child.type_keys('needs', '<CR>')

    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(cursor_line(), mark_lnum('Needs a test'))
end

T['jump']['<CR> on an annotation of a file outside the changes opens the buffer'] = function()
    open_from_drawer()
    child.type_keys('not in', '<CR>')

    eq(
        child.lua_get([[vim.api.nvim_get_current_tabpage()]]),
        child.lua_get(R .. '.origin_tab')
    )
    eq(current_name(), 'c.txt')
    eq(cursor_line(), 2)
    eq(mode(), 'n')
    eq(child.lua_get(R .. [[:is_open()]]), true)
end

T['jump']['<CR> on an old-side annotation shows the review, opening it'] = function()
    child.cmd('edit c.txt')
    child.lua([[require('iter').annotations()]])
    wait_picker()
    child.type_keys('remove', '<CR>')

    helpers.wait_until(
        child,
        R .. [[ and ]] .. R .. [[.drawer.view:is_shown()]]
    )
    eq(child.lua_get(R .. [[:is_open()]]), true)
    eq(
        child.lua_get([[vim.api.nvim_get_current_tabpage()]]),
        child.lua_get(R .. '.tab')
    )
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(child.lua_get(R .. [[.drawer.view.files[1].side]]), 'staged')

    local lnum = mark_lnum('Why remove it?')
    eq(cursor_line(), lnum)
    eq(child.lua_get(R .. [[.drawer.view.rows[]] .. lnum .. [[].kind]]), 'del')
end

T['jump']['<CR> on an old-side annotation switches the open review to its file'] = function()
    open_from_drawer()
    child.type_keys('<Esc>')
    child.lua(R .. [[.drawer:step_file(-1)]])
    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'n.txt')

    child.type_keys('L')
    wait_picker()
    child.type_keys('remove', '<CR>')

    eq(child.lua_get(R .. [[.drawer.view.files[1].path]]), 'm.txt')
    eq(cursor_line(), mark_lnum('Why remove it?'))
end

T['jump']['<CR> opens the buffer of a new-side annotation where the line moved'] = function()
    local lines = { 'x1', 'x2' }
    vim.list_extend(lines, numbered('c', 1, 10))
    helpers.write_file(vim.fs.joinpath(repo, 'c.txt'), lines)

    child.cmd('edit n.txt')
    child.lua([[require('iter').annotations()]])
    wait_picker()
    child.type_keys('not in', '<CR>')

    eq(current_name(), 'c.txt')
    eq(cursor_line(), 4)
    eq(child.lua_get(R), vim.NIL)
end

T['jump']['<CR> clamps an outdated annotation to the file'] = function()
    child.lua([[
        require('iter.store').put_annotation(vim.fn.getcwd(), {
            scope = 'line',
            body = 'Far away',
            anchor = {
                path = 'c.txt',
                side = 'new',
                start_line = 50,
                end_line = 50,
                lines = { 'gone' },
            },
        })
        vim.cmd.edit('n.txt')
        require('iter').annotations()
    ]])
    wait_picker()
    child.type_keys('far', '<CR>')

    eq(current_name(), 'c.txt')
    eq(cursor_line(), 10)
end

T['jump']['<CR> on a file annotation outside the changes opens line 1'] = function()
    child.lua([[
        require('iter.store').put_annotation(vim.fn.getcwd(), {
            scope = 'file',
            body = 'Whole file',
            anchor = { path = 'c.txt', side = 'new' },
        })
        vim.cmd.edit('n.txt')
        require('iter').annotations()
    ]])
    wait_picker()
    child.type_keys('whole', '<CR>')

    eq(current_name(), 'c.txt')
    eq(cursor_line(), 1)
end

T['jump']['<CR> on a review annotation opens the review'] = function()
    child.cmd('edit c.txt')
    child.lua([[require('iter').annotations()]])
    wait_picker()
    child.type_keys('overall', '<CR>')

    eq(child.lua_get(R .. [[:is_open()]]), true)
    eq(
        child.lua_get([[vim.api.nvim_get_current_tabpage()]]),
        child.lua_get(R .. '.tab')
    )
end

T['jump']['<CR> on a review annotation focuses the open review'] = function()
    open_review()
    child.cmd('tabnew')
    child.lua([[require('iter').annotations()]])
    wait_picker()
    child.type_keys('overall', '<CR>')

    eq(
        child.lua_get([[vim.api.nvim_get_current_tabpage()]]),
        child.lua_get(R .. '.tab')
    )
    eq(child.api.nvim_get_current_win(), child.lua_get(R .. '.drawer.win'))
end

T['jump']['<CR> on an annotation of a deleted file warns'] = function()
    child.lua([[
        require('iter.store').put_annotation(vim.fn.getcwd(), {
            scope = 'file',
            body = 'Ghost',
            anchor = { path = 'gone.txt', side = 'new' },
        })
        vim.cmd.edit('n.txt')
        require('iter').annotations()
    ]])
    wait_picker()
    child.type_keys('ghost', '<CR>')

    eq(notes(), { '[iter] gone.txt is deleted' })
    eq(picker_open(), false)
end

T['edit'] = new_set()

T['edit']['<C-e> edits the selected annotation in the float'] = function()
    open_from_drawer()
    child.type_keys('why this', '<C-e>')

    helpers.wait_until(
        child,
        E
            .. [[.is_shown() and vim.api.nvim_get_current_win() == ]]
            .. E
            .. '.win()'
    )
    eq(picker_open(), false)
    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'Why this change?',
    })
    eq(mode(), 'i')

    child.type_keys(' Please explain.', '<C-s>')

    local annotations = stored()
    eq(#annotations, 8)

    local edited = vim.tbl_filter(function(c)
        return vim.startswith(c.body, 'Why this')
    end, annotations)
    eq(#edited, 1)
    eq(edited[1].body, 'Why this change? Please explain.')
end

T['delete'] = new_set()

T['delete']['<C-x> keeps the annotation when the confirm is declined'] = function()
    open_from_drawer()
    child.lua([[_G.confirm_answer = 2]])
    child.type_keys('<C-x>')

    eq(
        child.lua_get([[_G.confirms]]),
        { 'Delete the annotation?\nRename the variable' }
    )
    eq(#stored(), 8)
    eq(picker_open(), true)
    eq(results(), LISTING)
end

T['delete']['<C-x> deletes after the confirm and keeps the picker open'] = function()
    open_from_drawer()
    child.type_keys('<C-x>')

    eq(#stored(), 7)
    eq(picker_open(), true)
    eq(results()[1], 'm.txt')
    eq(selected(), 'Needs a test')
    eq(mode(), 'i')

    helpers.wait_until(child, [[#]] .. R .. [[.drawer.annotations == 7]])
end

T['delete']['<C-x> on the last row selects the one before'] = function()
    open_from_drawer()
    child.type_keys('<C-p>', '<C-x>')

    eq(#stored(), 7)
    eq(selected(), 'Not in the changes')
end

T['delete']['<C-x> on the last annotation closes the picker'] = function()
    child.lua([[
        local store = require('iter.store')
        local ids = {}
        for i, c in ipairs(store.load(vim.fn.getcwd()).annotations) do
            if i > 1 then
                table.insert(ids, c.id)
            end
        end
        store.remove_annotations(vim.fn.getcwd(), ids)
    ]])
    open_from_drawer()
    child.type_keys('<C-x>')

    eq(#stored(), 0)
    eq(picker_open(), false)
    eq(picker_buffers(), 0)
    eq(picker_augroup(), false)
end

T['delete']['<C-x> removes the mark from a buffer showing the annotation'] = function()
    child.cmd('edit n.txt')
    local function virt_lines()
        return child.lua_get([[#vim.api.nvim_buf_get_extmarks(0,
                vim.api.nvim_create_namespace('iter.buffer.annotations'), 0, -1,
                { details = true })]])
    end
    local before = virt_lines()
    eq(before > 0, true)

    child.lua([[require('iter').annotations()]])
    wait_picker()
    child.type_keys('rename', '<C-x>')

    eq(virt_lines(), 0)
end

return T
