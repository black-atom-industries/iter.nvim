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

--- Three unstaged files: `a.txt` and `c.txt` change their one line;
--- `b.txt` has 20 lines with a hunk at each end and a gap between.
---@return string
local function create_repo()
    local path = helpers.create_repo({
        ['a.txt'] = { 'a' },
        ['b.txt'] = numbered('b', 1, 20),
        ['c.txt'] = { 'c' },
    })
    local b = numbered('b', 1, 20)

    b[1], b[20] = 'b1x', 'b20x'
    helpers.write_file(vim.fs.joinpath(path, 'a.txt'), { 'ax' })
    helpers.write_file(vim.fs.joinpath(path, 'b.txt'), b)
    helpers.write_file(vim.fs.joinpath(path, 'c.txt'), { 'cx' })

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

---@param args string[]
---@return string
local function git_out(args)
    return helpers.git(repo, args)
end

--- Open the review, wait for the first file's diff, then switch to all
--- files with `m` in the drawer.
local function open_all()
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )
    child.type_keys('m')
    helpers.wait_until(child, R .. [[.drawer.view.document.sections[3] ~= nil]])
end

---@return string[]
local function pane_lines()
    return child.lua_get(
        [[vim.api.nvim_buf_get_lines(]]
            .. R
            .. [[.drawer.view.buf, 0, -1, false)]]
    )
end

---@return string? side and path of the drawer selection
local function selected()
    return child.lua_get([[(function()
        local item = ]] .. R .. [[.drawer:selected()
        return item and (item.side .. ' ' .. item.path) or vim.NIL
    end)()]])
end

--- Focus the diff pane and put its cursor on the first row whose text is
--- `text`, of `kind` when given.
---@param text string
---@param kind? string
local function cursor_on(text, kind)
    child.lua(
        [[
        local text, kind = ...
        local r = require('iter').current_review
        vim.api.nvim_set_current_win(r.diff_win)
        for lnum, row in ipairs(r.drawer.view.rows) do
            if row.text == text and (kind == nil or row.kind == kind) then
                vim.api.nvim_win_set_cursor(r.diff_win, { lnum, 0 })
                return
            end
        end
        error('no row ' .. text)
    ]],
        { text, kind }
    )
end

---@return string kind and text of the diff pane's cursor row
local function cursor_row()
    return child.lua_get([[(function()
        local r = require('iter').current_review
        local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
        local row = r.drawer.view.rows[lnum]
        return row.kind .. ' ' .. row.text
    end)()]])
end

--- Select the `side` item with `path` in the review drawer.
---@param side string
---@param path string
local function select_item(side, path)
    child.lua(
        [[
        local side, path = ...
        local d = require('iter').current_review.drawer
        vim.api.nvim_set_current_win(d.win)
        for lnum, row in ipairs(d.rows) do
            if row[side] ~= nil and row[side].path == path then
                vim.api.nvim_win_set_cursor(d.win, { lnum, 0 })
                d:select(lnum, side)
                return
            end
        end
        error('no row ' .. side .. ' ' .. path)
    ]],
        { side, path }
    )
end

---@return string
local function statusline()
    return child.lua_get([[require('iter').statusline()]])
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_repo()
            helpers.start_child(child, repo)
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['mode'] = new_set()

T['mode']['m shows every file in drawer order, a blank line between'] = function()
    open_all()

    local lines = pane_lines()

    eq(lines[1], 'a.txt')
    eq(vim.list_slice(lines, 1, 5), { 'a.txt', '@@ -1 +1 @@', 'a', 'ax', '' })
    eq(lines[6], 'b.txt')
    eq(lines[#lines - 4], '')
    eq(vim.list_slice(lines, #lines - 3), { 'c.txt', '@@ -1 +1 @@', 'c', 'cx' })
    eq(statusline(), 'review · all files · a.txt · 1/3')
end

T['mode']['screenshot of three files'] = function()
    child.stop()
    helpers.cleanup(repo)
    repo = helpers.create_repo({
        ['a.txt'] = { 'a' },
        ['b.txt'] = { 'b' },
        ['c.txt'] = { 'c' },
    })

    for _, name in ipairs({ 'a', 'b', 'c' }) do
        helpers.write_file(
            vim.fs.joinpath(repo, name .. '.txt'),
            { name .. 'x' }
        )
    end

    helpers.start_child(child, repo)
    open_all()
    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.type_keys('gg')

    helpers.expect_screenshot(child, 'review-all-files')
end

T['mode']['m toggles back to the selected file'] = function()
    open_all()
    cursor_on('cx')
    child.type_keys('k')
    helpers.wait_until(child, R .. [[.drawer:selected().path == 'c.txt']])

    child.type_keys('m')

    eq(child.lua_get(R .. [[.drawer.view.document.sections[2] == nil]]), true)
    eq(pane_lines(), { 'c.txt', '@@ -1 +1 @@', 'c', 'cx' })
    eq(cursor_row(), 'del c')
    eq(statusline(), 'review · c.txt · 3/3')

    child.type_keys('m')
    eq(cursor_row(), 'del c')
    eq(statusline(), 'review · all files · c.txt · 3/3')
end

T['mode']['an untracked header reads untracked and counts only annotations'] = function()
    helpers.write_file(vim.fs.joinpath(repo, 'd.txt'), { 'd1', 'd2' })
    open_all()
    helpers.wait_until(child, R .. [[.drawer.view.document.sections[4] ~= nil]])

    local header = [[(function()
        local r = require('iter').current_review
        local view = r.drawer.view
        local result = {}
        for index, section in ipairs(view.document.sections) do
            local ns = vim.api.nvim_get_namespaces()['iter.diff']
            local line = section.first - 1
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, ns, { line, 0 }, { line, -1 }, { details = true })) do
                if mark[4].virt_text_pos == 'right_align' then
                    local chunks = mark[4].virt_text
                    result[index] = chunks[#chunks][1]
                end
            end
        end
        return result
    end)()]]

    eq(child.lua_get(header), {
        '+1 −1 · 0 annotations ',
        '+2 −2 · 0 annotations ',
        '+1 −1 · 0 annotations ',
        'untracked · +2 ',
    })
end

T['mode']['the key hint line names the other mode'] = function()
    local footer = [[(function()
        local text = ''
        for _, chunk in ipairs(vim.api.nvim_win_get_config(]] .. R .. [[.drawer.win).footer) do
            text = text .. chunk[1]
        end
        return text
    end)()]]

    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )
    eq(child.lua_get(footer):find('m all files', 1, true) ~= nil, true)

    child.type_keys('m')
    eq(child.lua_get(footer):find('m one file', 1, true) ~= nil, true)
end

T['mode']['stays for the review tab until it closes'] = function()
    open_all()
    select_item('unstaged', 'b.txt')
    child.type_keys('<C-d>')
    eq(child.lua_get(R .. [[.drawer.all_files]]), true)
    eq(#pane_lines() > 20, true)

    child.type_keys('q')
    helpers.wait_until(child, R .. [[ == nil or not ]] .. R .. [[:is_open()]])
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )

    eq(child.lua_get(R .. [[.drawer.all_files]]), false)
    eq(pane_lines()[1], 'a.txt')
    eq(child.lua_get(R .. [[.drawer.view.document.sections[2] == nil]]), true)
end

T['follow'] = new_set()

T['follow']['the drawer selection follows the cursor across a file boundary'] = function()
    open_all()
    cursor_on('ax')
    eq(selected(), 'unstaged a.txt')

    local generation = child.lua_get(R .. [[.drawer.view.generation]])

    child.type_keys('j')
    eq(selected(), 'unstaged a.txt')
    child.type_keys('j')
    helpers.wait_until(child, R .. [[.drawer:selected().path == 'b.txt']])
    eq(cursor_row(), 'header b.txt')
    eq(statusline(), 'review · all files · b.txt · 2/3')

    child.type_keys('G')
    helpers.wait_until(child, R .. [[.drawer:selected().path == 'c.txt']])

    -- The pane keeps its focus and is not drawn again.
    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    child.lua('vim.wait(100)')
    eq(child.lua_get(R .. [[.drawer.view.generation]]), generation)
    eq(cursor_row(), 'add cx')
end

T['follow']['selecting a file in the drawer puts its header on top'] = function()
    open_all()
    select_item('unstaged', 'c.txt')

    helpers.wait_until(
        child,
        string.format(
            [[(function()
        local r = %s
        local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
        return r.drawer.view.rows[lnum].text == 'c.txt'
    end)()]],
            R
        )
    )
    eq(cursor_row(), 'header c.txt')
    eq(
        child.lua_get([[vim.fn.line('w0', ]] .. R .. [[.diff_win)]]),
        child.lua_get(R .. [[.drawer.view.document.sections[3].first]])
    )
    eq(
        child.lua_get(
            'vim.api.nvim_get_current_win() == ' .. R .. '.drawer.win'
        ),
        true
    )
end

T['jumps'] = new_set()

T['jumps'][']f and [f land on file headers'] = function()
    open_all()
    cursor_on('ax')

    child.type_keys(']f')
    eq(cursor_row(), 'header b.txt')
    eq(selected(), 'unstaged b.txt')
    child.type_keys(']f')
    eq(cursor_row(), 'header c.txt')
    eq(selected(), 'unstaged c.txt')
    child.type_keys(']f')
    eq(cursor_row(), 'header c.txt')

    child.type_keys('[f')
    eq(cursor_row(), 'header b.txt')
    eq(selected(), 'unstaged b.txt')
    child.type_keys('[f', '[f')
    eq(cursor_row(), 'header a.txt')
    eq(selected(), 'unstaged a.txt')
end

T['jumps'][']c and [c move across files'] = function()
    open_all()
    cursor_on('ax')

    child.type_keys(']c')
    eq(cursor_row(), 'hunk @@ -1,4 +1,4 @@')
    child.type_keys(']c', ']c')
    eq(cursor_row(), 'hunk @@ -1 +1 @@')
    eq(selected(), 'unstaged c.txt')
    child.type_keys('[c')
    eq(cursor_row(), 'hunk @@ -17,4 +17,4 @@ b16')
end

T['jumps']['<CR> on a gap expands it and keeps the files below'] = function()
    open_all()
    cursor_on('', 'gap')
    child.type_keys('<CR>')

    local lines = pane_lines()

    eq(vim.list_contains(lines, 'b10'), true)
    eq(vim.list_slice(lines, #lines - 3), { 'c.txt', '@@ -1 +1 @@', 'c', 'cx' })
    cursor_on('cx')
    eq(selected(), 'unstaged c.txt')
end

T['jumps']['an edit from outside redraws its file and keeps the others'] = function()
    open_all()
    cursor_on('', 'gap')
    child.type_keys('<CR>')
    cursor_on('b20x')
    child.lua('_G.b = ' .. R .. '.drawer.view.document.sections[2].file')

    helpers.write_file(vim.fs.joinpath(repo, 'c.txt'), { 'cy' })
    helpers.wait_until(
        child,
        'vim.list_contains(vim.api.nvim_buf_get_lines('
            .. R
            .. ".drawer.view.buf, 0, -1, false), 'cy')",
        6000
    )

    eq(cursor_row(), 'add b20x')
    eq(
        child.lua_get(
            'rawequal(_G.b, ' .. R .. '.drawer.view.document.sections[2].file)'
        ),
        true
    )
    eq(vim.list_contains(pane_lines(), 'b10'), true)
end

T['staging'] = new_set()

T['staging']['s stages the hunk of the second file under the cursor'] = function()
    open_all()
    cursor_on('b20x')
    child.type_keys('s')

    helpers.wait_until(child, R .. [[.drawer.view.document.sections[4] ~= nil]])
    eq(git_out({ 'diff', '--cached', '--name-only' }), 'b.txt\n')
    eq(git_out({ 'diff', '--cached' }):find('+b20x', 1, true) ~= nil, true)
    eq(git_out({ 'diff', '--cached' }):find('+b1x', 1, true), nil)

    -- Unstaged a, b, c, then the staged b; the cursor stays in the unstaged
    -- b, on the hunk that is left.
    eq(
        child.lua_get(
            [[vim.tbl_map(function(s) return s.key:gsub('%z', ' ') end, ]]
                .. R
                .. [[.drawer.view.document.sections)]]
        ),
        { 'unstaged a.txt', 'unstaged b.txt', 'unstaged c.txt', 'staged b.txt' }
    )
    eq(cursor_row(), 'hunk @@ -1,4 +1,4 @@')
    eq(selected(), 'unstaged b.txt')
    eq(child.lua_get(R .. [[.drawer.all_files]]), true)
    eq(child.lua_get('_G.notes'), {})
end

--- The key of the section under the diff pane's cursor, with a space.
---@return string
local function cursor_section()
    return child.lua_get([[(function()
        local section = ]] .. R .. [[.drawer.view:at()
        return (section.key:gsub('%z', ' '))
    end)()]])
end

T['staging']['the last hunk of a file follows it to the other side, and back'] = function()
    open_all()
    cursor_on('ax')
    child.type_keys('s')

    helpers.wait_until(
        child,
        [[require('iter.diff.document').find(]]
            .. R
            .. [[.drawer.view.document, 'staged\0a.txt') ~= nil]]
    )
    eq(git_out({ 'diff', '--cached', '--name-only' }), 'a.txt\n')
    eq(cursor_section(), 'staged a.txt')
    eq(cursor_row(), 'add ax')
    eq(selected(), 'staged a.txt')

    cursor_on('ax')
    child.type_keys('u')

    helpers.wait_until(
        child,
        [[require('iter.diff.document').find(]]
            .. R
            .. [[.drawer.view.document, 'staged\0a.txt') == nil]]
    )
    eq(git_out({ 'diff', '--cached' }), '')
    eq(cursor_section(), 'unstaged a.txt')
    eq(selected(), 'unstaged a.txt')
    eq(child.lua_get('_G.notes'), {})
end

T['staging']['a visual range over two files stages nothing'] = function()
    open_all()
    cursor_on('ax')
    child.type_keys('V', 'j', 'j', 'j', 's')

    eq(child.fn.mode(), 'n')
    eq(child.lua_get('_G.notes'), {
        { '[iter] The selection spans two files', vim.log.levels.WARN },
    })
    eq(git_out({ 'diff', '--cached' }), '')
end

T['staging']['visual s stages lines within one file'] = function()
    open_all()
    cursor_on('b20', 'del')
    child.type_keys('V', 'j', 's')

    helpers.wait_until(child, R .. [[.drawer.view.document.sections[4] ~= nil]])
    eq(git_out({ 'diff', '--cached' }):find('+b20x', 1, true) ~= nil, true)
    eq(git_out({ 'diff', '--cached' }):find('+b1x', 1, true), nil)
end

T['annotations'] = new_set()

T['annotations']['a annotates a line of the third file'] = function()
    child.lua([[require('iter').setup()]])
    open_all()
    cursor_on('cx')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Check c', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.drawer.view.marks == 1')

    local stored = child.lua_get(
        [[require('iter.store').load(vim.fn.getcwd()).annotations]]
    )
    eq(#stored, 1)
    eq(stored[1].anchor.path, 'c.txt')
    eq(stored[1].anchor.start_line, 1)

    -- The mark sits below the row in the third file, and ]a finds it from the
    -- top of the first.
    local lnum = child.lua_get(R .. [[.drawer.view.marks[1].lnum]])
    eq(child.lua_get(R .. [[.drawer.view.rows[...].text]], { lnum }), 'cx')

    cursor_on('ax')
    child.type_keys(']a')
    eq(cursor_row(), 'add cx')
    eq(selected(), 'unstaged c.txt')
end

T['annotations']['the Annotations column shows its annotation in all files'] = function()
    child.lua([[require('iter').setup()]])
    open_all()
    cursor_on('cx')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Check c', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.drawer.view.marks == 1')

    cursor_on('ax')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    child.type_keys('l')

    local lnum = child.lua_get(R .. [[.drawer.view.marks[1].lnum]])

    helpers.wait_until(
        child,
        'vim.api.nvim_win_get_cursor(' .. R .. '.diff_win)[1] == ' .. lnum
    )
    eq(child.lua_get(R .. [[.drawer.all_files]]), true)
    eq(child.lua_get('#' .. R .. [[.drawer.view.document.sections]]), 3)
    eq(cursor_section(), 'unstaged c.txt')
    eq(cursor_row(), 'add cx')
end

T['annotations']['<CR> in the column jumps to the side the preview showed'] = function()
    -- b.txt on both sides: b1x staged, b20x unstaged, so b1x hides in a gap
    -- of the unstaged diff.
    local b = numbered('b', 1, 20)
    b[1] = 'b1x'
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)
    git_out({ 'add', 'b.txt' })
    b[20] = 'b20x'
    helpers.write_file(vim.fs.joinpath(repo, 'b.txt'), b)

    child.lua([[require('iter').setup()]])
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )
    child.type_keys('m')
    helpers.wait_until(child, R .. [[.drawer.view.document.sections[4] ~= nil]])

    cursor_on('b1x', 'add')
    eq(cursor_section(), 'staged b.txt')
    child.type_keys('a')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('Staged line', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.drawer.view.marks == 2')

    cursor_on('ax')
    child.lua('vim.api.nvim_set_current_win(' .. R .. '.drawer.win)')
    child.type_keys('l')
    helpers.wait_until(
        child,
        string.format(
            [[(function()
        local r = %s
        local lnum = vim.api.nvim_win_get_cursor(r.diff_win)[1]
        return r.drawer.view.rows[lnum].text == 'b1x'
    end)()]],
            R
        )
    )

    child.type_keys('<CR>')

    eq(
        child.lua_get('vim.api.nvim_get_current_win() == ' .. R .. '.diff_win'),
        true
    )
    eq(cursor_section(), 'staged b.txt')
    eq(cursor_row(), 'add b1x')
end

T['annotations']['A annotates the file under the cursor'] = function()
    open_all()
    cursor_on('b20x')
    child.type_keys('A')
    helpers.wait_until(child, [[require('iter.annotations.editor').is_shown()]])
    child.type_keys('About b', '<C-s>')
    helpers.wait_until(child, '#' .. R .. '.drawer.view.marks == 1')

    local stored = child.lua_get(
        [[require('iter.store').load(vim.fn.getcwd()).annotations]]
    )
    eq({ stored[1].scope, stored[1].anchor.path }, { 'file', 'b.txt' })
end

T['viewed'] = new_set()

T['viewed']['v toggles the file under the cursor'] = function()
    open_all()
    cursor_on('cx')
    child.type_keys('v')

    helpers.wait_until(child, R .. [[.viewed['c.txt'] == 'viewed']])
    eq(child.lua_get(R .. ".viewed['a.txt']"), 'unviewed')
    eq(child.lua_get(R .. [[.drawer.all_files]]), true)
    eq(cursor_row(), 'add cx')
end

T['goto'] = new_set()

T['goto']['gf opens the file under the cursor at its line'] = function()
    local origin = child.api.nvim_get_current_tabpage()
    open_all()
    cursor_on('b20x')
    child.type_keys('gf')

    eq(
        child.lua_get([[{
        line = vim.api.nvim_win_get_cursor(0)[1],
        tab = vim.api.nvim_get_current_tabpage(),
        name = vim.fs.basename(vim.api.nvim_buf_get_name(0)),
    }]]),
        { line = 20, tab = origin, name = 'b.txt' }
    )
end

T['viewport'] = new_set()

T['viewport']['a large review decorates only around the lines in view'] = function()
    child.stop()
    helpers.cleanup(repo)

    local files = {}

    for i = 1, 40 do
        files[string.format('f%02d.txt', i)] = numbered('value ', 1, 30)
    end

    repo = helpers.create_repo(files)

    for i = 1, 40 do
        local lines = numbered('value ', 1, 30)

        for l = 2, 30, 4 do
            lines[l] = 'value ' .. l .. ' changed'
        end

        helpers.write_file(
            vim.fs.joinpath(repo, string.format('f%02d.txt', i)),
            lines
        )
    end

    helpers.start_child(child, repo)
    stub_ui()
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.view:is_shown()]]
    )
    child.type_keys('m')
    helpers.wait_until(
        child,
        R .. [[.drawer.view.document.sections[40] ~= nil]]
    )

    local words = [[(function()
        local view = ]] .. R .. [[.drawer.view
        local ns = vim.api.nvim_get_namespaces()['iter.diff.words']
        local marks = vim.api.nvim_buf_get_extmarks(view.buf, ns, 0, -1, {})
        local first, last = math.huge, 0
        for _, mark in ipairs(marks) do
            first = math.min(first, mark[2] + 1)
            last = math.max(last, mark[2] + 1)
        end
        return { count = #marks, first = first, last = last, lines = #view.rows }
    end)()]]

    local before = child.lua_get(words)

    eq(before.lines > 1500, true)
    eq(before.count > 0, true)
    eq(before.first < 10, true)
    eq(before.last < 200, true)

    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]])
    child.type_keys('G')
    helpers.wait_until(
        child,
        string.format([[(%s).last == (%s).lines]], words, words)
    )

    local after = child.lua_get(words)
    eq(after.first < 10, true)
    eq(after.count > before.count, true)
    eq(selected(), 'unstaged f40.txt')
end

return T
