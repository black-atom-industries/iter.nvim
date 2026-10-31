local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local E = [[require('iter.annotations.editor')]]

---@param prefix string
---@param count integer
---@return string[]
local function numbered(prefix, count)
    local lines = {}

    for i = 1, count do
        table.insert(lines, prefix .. i)
    end

    return lines
end

--- Every chapter is committed and unchanged, as in a read-through.
---@return string
local function create_book_repo()
    return helpers.create_repo({
        ['ch1.md'] = numbered('one line ', 20),
        ['ch2.md'] = numbered('two line ', 10),
    })
end

local ANNOTATIONS = {
    {
        scope = 'review',
        body = 'Overall pacing is slow',
        anchor = { side = 'new' },
    },
    {
        scope = 'range',
        body = 'Tighten these',
        anchor = {
            path = 'ch2.md',
            side = 'new',
            start_line = 2,
            end_line = 3,
            lines = { 'two line 2', 'two line 3' },
        },
    },
    {
        scope = 'line',
        body = 'Stale remark',
        anchor = {
            path = 'ch1.md',
            side = 'new',
            start_line = 5,
            end_line = 5,
            lines = { 'a line that was rewritten' },
        },
    },
    {
        scope = 'line',
        body = 'he always is',
        anchor = {
            path = 'ch1.md',
            side = 'new',
            start_line = 3,
            end_line = 3,
            lines = { 'one line 3' },
        },
    },
    {
        scope = 'file',
        body = 'Middle drags after the opening scene',
        anchor = { path = 'ch1.md', side = 'new' },
    },
}

-- The sidebar at 40 columns and 24 rows, hints at the bottom.
local LISTING = {
    'Annotations (5) · 1 outdated',
    '',
    'ch1.md                                 3',
    '  file Middle drags after the opening s…',
    '  3    he always is',
    '  5    Stale remark',
    '',
    'ch2.md                                 1',
    '  2–3  Tighten these',
    '',
    'review                                 1',
    '  note Overall pacing is slow',
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
end

---@return string[]
local function notes()
    return vim.tbl_map(function(note)
        return note[1]
    end, child.lua_get('_G.notes'))
end

---@param text string
---@return boolean
local function copied(text)
    return child.fn.getreg('+'):find(text, 1, true) ~= nil
end

---@return string[]
local function stored_bodies()
    return vim.tbl_map(
        function(annotation)
            return annotation.body
        end,
        child.lua_get(
            [[require('iter.store').load(vim.fn.getcwd()).annotations]]
        )
    )
end

---@return integer? window showing the sidebar
local function sidebar_win()
    local win = child.lua_get([[(function()
        local buf = vim.fn.bufnr('iter://annotate/1')
        return buf > 0 and vim.fn.win_findbuf(buf)[1] or vim.NIL
    end)()]])

    return win ~= vim.NIL and win or nil
end

--- The sidebar's lines without the padding to its hints.
---@return string[]
local function sidebar_lines()
    local lines = child.lua_get([[vim.api.nvim_buf_get_lines(
        vim.fn.bufnr('iter://annotate/1'), 0, -1, false)]])
    local out = {}

    for _, line in ipairs(lines) do
        table.insert(out, (line:gsub('%s+$', '')))
    end

    return out
end

---@param count integer
---@return string[]
local function head(count)
    return vim.list_slice(sidebar_lines(), 1, count)
end

--- Move the sidebar cursor to the line starting with `text` after trimming.
---@param text string
local function goto_row(text)
    child.lua(
        [[
        local text = ...
        local buf = vim.fn.bufnr('iter://annotate/1')
        for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if vim.startswith(vim.trim(line), text) then
                vim.api.nvim_win_set_cursor(vim.fn.win_findbuf(buf)[1], { lnum, 0 })
                return
            end
        end
        error('no row ' .. text)
    ]],
        { text }
    )
end

---@return string
local function cursor_text()
    return vim.trim(child.lua_get([[(function()
        local buf = vim.fn.bufnr('iter://annotate/1')
        local win = vim.fn.win_findbuf(buf)[1]
        return vim.api.nvim_buf_get_lines(buf, vim.api.nvim_win_get_cursor(win)[1] - 1, vim.api.nvim_win_get_cursor(win)[1], false)[1]
    end)()]]))
end

--- Where the cursor is: buffer file name and line, window id.
---@return { name: string, line: integer, win: integer }
local function where()
    return child.lua_get([[{
        name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'),
        line = vim.api.nvim_win_get_cursor(0)[1],
        win = vim.api.nvim_get_current_win(),
    }]])
end

local function open_sidebar()
    child.cmd('Iter annotate')
    helpers.wait_until(child, [[vim.fn.bufnr('iter://annotate/1') > 0]])
end

--- Open `ch1.md` in the only window, then the sidebar. The cursor ends in the
--- sidebar; the previous window is the chapter's.
---@return integer text_win
local function open_beside_chapter()
    child.cmd('edit ch1.md')

    local win = child.lua_get('vim.api.nvim_get_current_win()')
    open_sidebar()

    return win
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_book_repo()
            helpers.start_child(child, repo, { lines = 24, columns = 120 })
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

T['open'] = new_set()

T['open']['opens on the right at the default width'] = function()
    local text_win = open_beside_chapter()
    local win = sidebar_win()

    eq(win ~= nil, true)
    eq(child.lua_get('vim.api.nvim_win_get_width(' .. win .. ')'), 40)
    eq(child.lua_get('vim.api.nvim_get_current_win()'), win)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_position('
                .. win
                .. ')[2] > vim.api.nvim_win_get_position('
                .. text_win
                .. ')[2]'
        ),
        true
    )
    eq(child.lua_get('vim.wo[' .. win .. '].winfixwidth'), true)
    eq(child.lua_get('vim.wo[' .. win .. '].number'), false)
    eq(child.lua_get('vim.bo.modifiable'), false)
    eq(child.lua_get('vim.bo.buflisted'), false)
    eq(child.v.errmsg, '')
end

T['open']['side = left opens on the left with the configured width'] = function()
    child.lua(
        [[require('iter').setup({ annotate = { side = 'left', width = 30 } })]]
    )
    local text_win = open_beside_chapter()
    local win = sidebar_win()

    eq(child.lua_get('vim.api.nvim_win_get_width(' .. win .. ')'), 30)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_position('
                .. win
                .. ')[2] < vim.api.nvim_win_get_position('
                .. text_win
                .. ')[2]'
        ),
        true
    )
end

T['open']['lists the notes by file, the file note first, the review last'] = function()
    open_beside_chapter()

    eq(head(#LISTING), LISTING)
    eq(child.v.errmsg, '')
end

T['open']['puts the cursor on the first note and the key hints at the bottom'] = function()
    open_beside_chapter()

    eq(cursor_text(), 'file Middle drags after the opening s…')

    local lines = sidebar_lines()

    eq(lines[#lines - 1], '<CR> jump  y yank  Y all')
    eq(lines[#lines], 'd delete  e edit  ? help')
end

T['open']['greys outdated notes and highlights the rest'] = function()
    open_beside_chapter()

    local groups = child.lua_get([[(function()
        local buf = vim.fn.bufnr('iter://annotate/1')
        local ns = vim.api.nvim_get_namespaces()['iter.ui.render']
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
            local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
            result[vim.trim(line:sub(mark[3] + 1, mark[4].end_col))] = mark[4].hl_group
        end
        return result
    end)()]])

    eq(groups['Annotations (5)'], 'IterDrawerTitle')
    eq(groups['· 1 outdated'], 'IterDrawerHint')
    eq(groups['ch1.md'], 'IterDrawerTitle')
    eq(groups['5    Stale remark'], 'IterDiffAnnotationOutdated')
    eq(groups['he always is'], nil)
    eq(groups['<CR>'], 'IterDrawerKey')
    eq(groups['jump'], 'IterDrawerHint')
end

T['open']['labels a passage note with its line and column'] = function()
    child.lua([[assert(require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'line',
        body = 'This word',
        anchor = {
            path = 'ch2.md',
            side = 'new',
            start_line = 6,
            end_line = 6,
            lines = { 'two line 6' },
            start_col = 4,
            end_col = 8,
            quote = 'line',
        },
    }))]])
    open_beside_chapter()

    local found = vim.tbl_filter(function(line)
        return line:find('6:5', 1, true) ~= nil
    end, sidebar_lines())

    eq(#found, 1)
    eq(found[1]:find('This word', 1, true) ~= nil, true)
end

T['open']['shows where an outdated note sat last and where a moved one is now'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'ch1.md'),
        vim.list_extend(
            { 'inserted', 'inserted too' },
            numbered('one line ', 20)
        )
    )
    open_beside_chapter()

    eq(head(6)[5], '  5    he always is')
    eq(head(6)[6], '  5    Stale remark')
end

T['open']['cuts a long path from the left and keeps the file name'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'series/books/01-avalon/manuscript/01-ch.md'),
        { 'a', 'b' }
    )
    child.lua([[assert(require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'line',
        body = 'Deep',
        anchor = {
            path = 'series/books/01-avalon/manuscript/01-ch.md',
            side = 'new',
            start_line = 1,
            end_line = 1,
            lines = { 'a' },
        },
    }))]])
    open_beside_chapter()

    eq(head(3)[3], 'ch1.md                                 3')
    eq(sidebar_lines()[11], '…s/books/01-avalon/manuscript/01-ch.md 1')
end

T['open']['the cursor starts on the first note, not on a blank row'] = function()
    open_beside_chapter()

    eq(child.lua_get('vim.api.nvim_win_get_cursor(0)[1]'), 4)
end

T['open']['the cursor starts on the only note of a single group'] = function()
    child.lua([[
        local store = require('iter.store')
        local ids = {}
        for _, a in ipairs(store.load(vim.fn.getcwd()).annotations) do
            if a.scope ~= 'review' then
                table.insert(ids, a.id)
            end
        end
        store.remove_annotations(vim.fn.getcwd(), ids)
    ]])
    open_beside_chapter()

    eq(child.lua_get('vim.api.nvim_win_get_cursor(0)[1]'), 4)
    eq(cursor_text(), 'note Overall pacing is slow')
end

T['open']['lists nothing for a repository without annotations'] = function()
    child.lua([[
        local store = require('iter.store')
        local ids = {}
        for _, a in ipairs(store.load(vim.fn.getcwd()).annotations) do
            table.insert(ids, a.id)
        end
        store.remove_annotations(vim.fn.getcwd(), ids)
    ]])
    open_beside_chapter()

    eq(head(3), { 'Annotations (0)', '', 'No annotations' })
end

T['open']['warns outside a git repository'] = function()
    local outside = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(outside, 'p')
    child.cmd('cd ' .. vim.fn.fnameescape(outside))
    child.cmd('Iter annotate')

    eq(notes(), { '[iter] Not inside a git repository' })
    eq(sidebar_win(), nil)

    helpers.cleanup(outside)
end

T['open']['screenshot'] = function()
    child.cmd('edit ch1.md')
    child.api.nvim_win_set_cursor(0, { 3, 0 })
    open_sidebar()
    goto_row('3    he always is')

    helpers.expect_screenshot(child, 'sidebar-open')
end

T['review mode'] = new_set()

--- Open the sidebar for a review stub: `_G.moved` records what the cursor
--- settles on, `_G.jumped` what `<CR>` hits, `<C-j>` sets `_G.back`.
local function open_review_mode()
    child.cmd('edit ch1.md')
    child.lua([[
        _G.moved, _G.jumped, _G.back = {}, {}, false
        require('iter.ui.sidebar').open_review(
            require('iter').config,
            vim.fn.getcwd(),
            function() end,
            {
                order = function() return { 'ch2.md' } end,
                changed = function() return { ['ch2.md'] = true } end,
                on_cursor = function(item)
                    table.insert(_G.moved, item and item.annotation.body or vim.NIL)
                end,
                jump = function(item)
                    table.insert(_G.jumped, item.annotation.body)
                end,
                handlers = {
                    focus_drawer = function() _G.back = true end,
                },
            }
        )
    ]])
    helpers.wait_until(child, [[vim.fn.bufnr('iter://annotate/1') > 0]])
end

T['review mode']['opens without taking the focus, the review order first'] = function()
    open_review_mode()

    eq(where().name, 'ch1.md')

    local lines = sidebar_lines()

    eq(vim.startswith(lines[3], 'M ch2.md'), true)
end

T['review mode']['tells the review where the cursor settles and what <CR> hits'] = function()
    open_review_mode()
    child.api.nvim_set_current_win(sidebar_win())
    goto_row('5')
    helpers.wait_until(child, [[_G.moved[#_G.moved] == 'Stale remark']])
    child.type_keys('<CR>')

    eq(child.lua_get('_G.jumped'), { 'Stale remark' })
end

T['review mode']['<C-j> runs the mode handler, outside a review it is unmapped'] = function()
    open_review_mode()
    child.api.nvim_set_current_win(sidebar_win())
    child.type_keys('<C-j>')

    eq(child.lua_get('_G.back'), true)
end

T['review mode']['the command focuses it and never closes it'] = function()
    open_review_mode()
    child.cmd('Iter annotate')

    eq(child.lua_get('vim.api.nvim_get_current_win()'), sidebar_win())

    child.cmd('Iter annotate')

    eq(child.lua_get('vim.api.nvim_get_current_win()'), sidebar_win())
end

T['open']['outside a review <C-j> is not mapped'] = function()
    open_beside_chapter()

    eq(
        child.lua_get([[vim.fn.maparg('<C-j>', 'n', false, true).buffer]]),
        vim.NIL
    )
end

T['toggle'] = new_set()

T['toggle']['a second command from the sidebar closes it'] = function()
    open_beside_chapter()
    child.cmd('Iter annotate')

    eq(sidebar_win(), nil)
    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 1)
end

T['toggle']['the command from another window focuses the sidebar'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_set_current_win(text_win)
    child.cmd('Iter annotate')

    eq(child.lua_get('vim.api.nvim_get_current_win()'), sidebar_win())
    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
end

T['toggle']['q closes it'] = function()
    open_beside_chapter()
    child.type_keys('q')

    eq(sidebar_win(), nil)
end

T['toggle']['has one sidebar per tab, each with its own buffer name'] = function()
    open_beside_chapter()
    child.cmd('tabnew')
    child.cmd('Iter annotate')

    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
    eq(child.lua_get([[vim.fn.bufnr('iter://annotate/2') > 0]]), true)
    eq(child.lua_get([[vim.fn.bufnr('iter://annotate/1') > 0]]), true)
    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()))]]
        ),
        'iter://annotate/2'
    )

    child.cmd('tabprevious')
    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
end

T['toggle']['opens from a float beside a normal window'] = function()
    child.cmd('edit ch1.md')
    child.lua(
        [[vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
        relative = 'editor', row = 2, col = 2, width = 20, height = 4,
    })]]
    )
    child.cmd('Iter annotate')

    eq(child.v.errmsg, '')
    eq(sidebar_win() ~= nil, true)
    eq(child.lua_get('vim.api.nvim_win_get_width(' .. sidebar_win() .. ')'), 40)
    eq(
        child.lua_get(
            'vim.api.nvim_win_get_config(' .. sidebar_win() .. ').relative'
        ),
        ''
    )
end

T['toggle']['wiping its buffer drops its state'] = function()
    open_beside_chapter()

    local buf = child.lua_get([[vim.fn.bufnr('iter://annotate/1')]])
    local group = 'iter.sidebar.' .. buf
    eq(
        child.lua_get(
            'pcall(vim.api.nvim_get_autocmds, { group = "' .. group .. '" })'
        ),
        true
    )

    child.cmd('edit ch2.md')
    helpers.wait_until(
        child,
        'not pcall(vim.api.nvim_get_autocmds, { group = "' .. group .. '" })'
    )

    child.cmd('Iter annotate')

    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 3)
    eq(sidebar_win() ~= nil, true)
    eq(child.v.errmsg, '')
end

T['toggle']['closing the window lets the command open it again'] = function()
    open_beside_chapter()
    child.cmd('close')
    open_sidebar()

    eq(sidebar_win() ~= nil, true)
    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
end

T['toggle']['edit of its address focuses the open sidebar'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_set_current_win(text_win)
    child.cmd('edit iter://annotate')
    helpers.wait_until(
        child,
        'vim.api.nvim_get_current_win() == ' .. sidebar_win()
    )

    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
    eq(child.v.errmsg, '')
end

T['refresh'] = new_set()

--- Lines of the sidebar buffer named `name`, joined.
---@param name string
---@return string
local function text_of(name)
    return child.lua_get(
        [[table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false), '\n')]],
        { name }
    )
end

--- Add an annotation to the store file the way another program does, so the
--- cached store does not know about it.
---@param body string
---@param line integer
local function write_outside(body, line)
    child.lua(
        [[
        local body, line = ...
        local path = require('iter.store').path(vim.fn.getcwd())
        local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
        local copy = vim.deepcopy(data.annotations[1])
        copy.id = 'outside-' .. body
        copy.body = body
        copy.scope = 'line'
        copy.anchor = { path = 'ch1.md', side = 'new', start_line = line, end_line = line, lines = { 'one line ' .. line } }
        table.insert(data.annotations, copy)
        vim.fn.writefile({ vim.json.encode(data) }, path)
    ]],
        { body, line }
    )
end

T['refresh']['a note added with annotate appears without a refresh'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_set_current_win(text_win)
    child.api.nvim_win_set_cursor(text_win, { 4, 0 })
    child.lua([[require('iter').annotate()]])
    helpers.wait_until(child, E .. '.is_shown()')
    child.type_keys('A fresh note', '<C-s>')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 6]]
    )
    helpers.wait_until(
        child,
        [[vim.fn.getbufline(vim.fn.bufnr('iter://annotate/1'), 1)[1]:find('(6)', 1, true)]]
    )

    eq(sidebar_lines()[6], '  4    A fresh note')
end

T['refresh']['a note written by another program appears within the poll interval'] = function()
    child.lua([[require('iter').setup({ refresh = { poll_ms = 100 } })]])
    open_beside_chapter()
    write_outside('From outside', 7)
    helpers.wait_until(
        child,
        [[vim.fn.getbufline(vim.fn.bufnr('iter://annotate/1'), 1)[1]:find('(6)', 1, true)]]
    )

    eq(sidebar_lines()[7], '  7    From outside')
end

T['refresh']['the cursor stays on its note when the list changes'] = function()
    child.lua([[require('iter').setup({ refresh = { poll_ms = 100 } })]])
    open_beside_chapter()
    goto_row('2–3  Tighten these')
    write_outside('Above', 1)
    helpers.wait_until(
        child,
        [[vim.fn.getbufline(vim.fn.bufnr('iter://annotate/1'), 1)[1]:find('(6)', 1, true)]]
    )

    eq(cursor_text(), '2–3  Tighten these')
end

T['refresh']['a sidebar in another tab follows a change made in this one'] = function()
    open_beside_chapter()
    child.cmd('tabnew')
    child.cmd('edit ch1.md')
    child.cmd('Iter annotate')
    child.lua([[
        local buf = vim.fn.bufnr('iter://annotate/2')
        for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            if vim.startswith(vim.trim(line), '3    he always is') then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            end
        end
    ]])
    child.type_keys('d')
    helpers.wait_until(
        child,
        [[vim.fn.getbufline(vim.fn.bufnr('iter://annotate/1'), 1)[1]:find('(4)', 1, true)]]
    )

    eq(text_of('iter://annotate/1'):find('he always is', 1, true), nil)
end

T['refresh']['closing the sidebar stops its watch'] = function()
    child.lua([[
        _G.watches = {}
        local watch = require('iter.watch')
        local start = watch.start
        watch.start = function(opts)
            local w = start(opts)
            table.insert(_G.watches, w)
            return w
        end
    ]])
    open_beside_chapter()

    eq(child.lua_get('_G.watches[1]:is_active()'), true)

    child.type_keys('q')

    eq(child.lua_get('_G.watches[1]:is_active()'), false)
end

T['refresh']['wiping the sidebar buffer stops its watch'] = function()
    child.lua([[
        _G.watches = {}
        local watch = require('iter.watch')
        local start = watch.start
        watch.start = function(opts)
            local w = start(opts)
            table.insert(_G.watches, w)
            return w
        end
    ]])
    open_beside_chapter()
    child.cmd('edit ch2.md')
    helpers.wait_until(child, '_G.watches[1]:is_active() == false')
end

T['window'] = new_set()

T['window']['a split copy does not outlive the closed original'] = function()
    open_beside_chapter()
    local original = sidebar_win()
    child.cmd('split')
    child.api.nvim_win_close(original, true)
    helpers.wait_until(child, [[vim.fn.bufnr('iter://annotate/1') < 0]])

    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 1)
    eq(child.v.errmsg, '')
end

T['window']['editing a file in the sidebar window restores its options'] = function()
    child.cmd('edit ch1.md')
    child.o.number = true
    open_sidebar()

    local win = sidebar_win()
    eq(child.lua_get('vim.wo[' .. win .. '].number'), false)
    eq(child.lua_get('vim.wo[' .. win .. '].winfixwidth'), true)

    child.cmd('edit ch2.md')

    eq(child.lua_get('vim.wo[' .. win .. '].number'), true)
    eq(child.lua_get('vim.wo[' .. win .. '].winfixwidth'), false)
    eq(child.lua_get('vim.wo[' .. win .. '].cursorline'), false)
end

T['refresh']['an unchanged store does not redraw even when the cache hands out copies'] = function()
    child.lua([[require('iter').setup({ refresh = { poll_ms = 50 } })]])
    open_beside_chapter()
    child.lua([[
        local store = require('iter.store')
        local cached = store.cached
        store.cached = function(root, fresh)
            return vim.deepcopy(cached(root, fresh))
        end
    ]])

    local tick = child.lua_get(
        [[vim.api.nvim_buf_get_changedtick(vim.fn.bufnr('iter://annotate/1'))]]
    )
    child.lua([[vim.wait(400)]])

    eq(
        child.lua_get(
            [[vim.api.nvim_buf_get_changedtick(vim.fn.bufnr('iter://annotate/1'))]]
        ),
        tick
    )
end

T['resize'] = new_set()

--- Lines in the sidebar's buffer and rows of its window.
---@return integer lines
---@return integer height
local function size()
    local lines, height = unpack(child.lua_get([[(function()
        local buf = vim.fn.bufnr('iter://annotate/1')
        local win = vim.fn.win_findbuf(buf)[1]
        return { vim.api.nvim_buf_line_count(buf), vim.api.nvim_win_get_height(win) }
    end)()]]))

    return lines, height
end

T['resize']['a window resize lays the hints out for the new height'] = function()
    open_beside_chapter()
    eq({ size() }, { 23, 23 })

    child.cmd('new')
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_line_count(vim.fn.bufnr('iter://annotate/1')) == 15]]
    )

    child.cmd('close')
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_line_count(vim.fn.bufnr('iter://annotate/1')) == 23]]
    )
end

T['resize']['a terminal resize lays the hints out for the new height'] = function()
    open_beside_chapter()
    child.o.lines = 40
    helpers.wait_until(
        child,
        [[vim.api.nvim_buf_line_count(vim.fn.bufnr('iter://annotate/1')) == 39]]
    )

    eq({ size() }, { 39, 39 })
end

T['jump'] = new_set()

T['jump']['<CR> on a note opens the line in the window it came from'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_set_current_win(text_win)
    child.cmd('edit ch2.md')
    child.api.nvim_set_current_win(sidebar_win())
    goto_row('3    he always is')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch1.md', line = 3, win = text_win })
    eq(sidebar_win() ~= nil, true)
    eq(child.v.errmsg, '')
end

T['jump']['<CR> on a passage note puts the cursor on its words'] = function()
    child.lua([[assert(require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'line',
        body = 'This word',
        anchor = {
            path = 'ch2.md',
            side = 'new',
            start_line = 6,
            end_line = 6,
            lines = { 'two line 6' },
            start_col = 4,
            end_col = 8,
            quote = 'line',
        },
    }))]])
    local text_win = open_beside_chapter()
    child.api.nvim_set_current_win(sidebar_win())
    goto_row('6:5')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch2.md', line = 6, win = text_win })
    eq(child.api.nvim_win_get_cursor(text_win), { 6, 4 })
end

T['open']['counts the column of a passage in characters'] = function()
    child.lua([[
        local lines = vim.fn.readfile('ch2.md')
        lines[6] = 'äöü line 6'
        vim.fn.writefile(lines, 'ch2.md')
        assert(require('iter.store').put_annotation(vim.fn.getcwd(), {
            scope = 'line',
            body = 'Umlaut',
            anchor = {
                path = 'ch2.md',
                side = 'new',
                start_line = 6,
                end_line = 6,
                lines = { 'äöü line 6' },
                start_col = 7,
                end_col = 11,
                quote = 'line',
            },
        }))
    ]])
    open_beside_chapter()

    local found = vim.tbl_filter(function(line)
        return line:find('Umlaut', 1, true) ~= nil
    end, sidebar_lines())

    eq(found[1]:find('6:5', 1, true) ~= nil, true)
end

T['jump']['<CR> on a range note opens its first line'] = function()
    local text_win = open_beside_chapter()
    goto_row('2–3  Tighten these')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch2.md', line = 2, win = text_win })
end

T['jump']['<CR> on a file header opens the file at line 1'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_win_set_cursor(text_win, { 8, 0 })
    goto_row('ch2.md')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch2.md', line = 1, win = text_win })
end

T['jump']['<CR> on a file note opens the file at line 1'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_win_set_cursor(text_win, { 8, 0 })
    child.api.nvim_set_current_win(sidebar_win())
    goto_row('file Middle')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch1.md', line = 1, win = text_win })
end

T['jump']['<CR> on an outdated note opens its last known line'] = function()
    local text_win = open_beside_chapter()
    goto_row('5    Stale remark')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch1.md', line = 5, win = text_win })
end

T['jump']['<CR> on a note follows its text to the line it moved to'] = function()
    helpers.write_file(
        vim.fs.joinpath(repo, 'ch1.md'),
        vim.list_extend(
            { 'inserted', 'inserted too' },
            numbered('one line ', 20)
        )
    )
    local text_win = open_beside_chapter()
    goto_row('5    he always is')
    child.type_keys('<CR>')

    eq(where(), { name = 'ch1.md', line = 5, win = text_win })
end

T['jump']['<CR> on a review note opens the editor'] = function()
    open_beside_chapter()
    goto_row('note Overall pacing is slow')
    child.type_keys('<CR>')
    helpers.wait_until(child, E .. '.is_shown()')

    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf('
                .. E
                .. '.win()), 0, -1, false)'
        ),
        { 'Overall pacing is slow' }
    )
end

T['jump']['<CR> opens a new window when the sidebar is the only one'] = function()
    local text_win = open_beside_chapter()
    child.api.nvim_win_close(text_win, true)
    goto_row('3    he always is')
    child.type_keys('<CR>')

    eq(where().name, 'ch1.md')
    eq(where().line, 3)
    eq(child.lua_get('#vim.api.nvim_tabpage_list_wins(0)'), 2)
    eq(sidebar_win() ~= nil, true)
end

T['jump']['<CR> on a file gone from the worktree warns'] = function()
    open_beside_chapter()
    os.remove(vim.fs.joinpath(repo, 'ch2.md'))
    goto_row('2–3  Tighten these')
    child.type_keys('<CR>')

    eq(notes(), { '[iter] Not in the worktree: ch2.md' })
    eq(where().name, '1')
end

T['jump']['<CR> keeps a window with unsaved changes when nothing may be hidden'] = function()
    local text_win = open_beside_chapter()
    child.o.hidden = false
    child.api.nvim_set_current_win(text_win)
    child.api.nvim_buf_set_lines(0, 0, 1, false, { 'edited' })
    child.api.nvim_set_current_win(sidebar_win())
    goto_row('2–3  Tighten these')
    child.type_keys('<CR>')

    eq(notes(), { '[iter] The pane has unsaved changes' })
    eq(where().name, '1')
end

T['yank'] = new_set()

T['yank']['y on a note copies it and clears it on y'] = function()
    open_beside_chapter()
    goto_row('3    he always is')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('he always is'), true)
    eq(copied('Stale remark'), false)

    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 4]]
    )

    eq(vim.tbl_contains(stored_bodies(), 'he always is'), false)
    eq(head(1), { 'Annotations (4) · 1 outdated' })
    eq(child.v.errmsg, '')
end

T['yank']['y on a note answered n keeps it'] = function()
    open_beside_chapter()
    goto_row('3    he always is')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')
    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])

    eq(#stored_bodies(), 5)
    eq(head(1), { 'Annotations (5) · 1 outdated' })
end

T['yank']['y on a file header copies the notes of that file'] = function()
    open_beside_chapter()
    goto_row('ch1.md')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 3 annotations. Clear them? [y/N]' }
    )
    eq(copied('Middle drags'), true)
    eq(copied('he always is'), true)
    eq(copied('Stale remark'), true)
    eq(copied('Tighten these'), false)

    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 2]]
    )

    eq(stored_bodies(), { 'Overall pacing is slow', 'Tighten these' })
    eq(head(1), { 'Annotations (2)' })
end

T['yank']['y on the review header copies the review notes'] = function()
    open_beside_chapter()
    goto_row('review')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(child.lua_get('_G.echoes'), { 'Copied 1 annotation. Clear it? [y/N]' })
    eq(copied('Overall pacing'), true)
    eq(copied('Tighten these'), false)
    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])
end

T['yank']['Y copies all notes in the sidebar order'] = function()
    open_beside_chapter()
    child.type_keys('Y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(
        child.lua_get('_G.echoes'),
        { 'Copied 5 annotations. Clear them? [y/N]' }
    )

    local text = child.fn.getreg('+')
    local first = text:find('Middle drags', 1, true)
    local last = text:find('Tighten these', 1, true)
    local review = text:find('Overall pacing', 1, true)

    eq(first < last and last < review, true)

    child.type_keys('y')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 0]]
    )

    eq(head(3), { 'Annotations (0)', '', 'No annotations' })
end

T['yank']['y on a blank line copies nothing'] = function()
    open_beside_chapter()
    child.api.nvim_win_set_cursor(0, { 2, 0 })
    child.type_keys('y')

    eq(child.lua_get('#_G.echoes'), 0)
    eq(notes(), {})
end

T['yank']['y uses the sidebar repository, not the working directory'] = function()
    local other = helpers.create_repo({ ['x.md'] = { 'x' } })
    open_beside_chapter()
    child.cmd('cd ' .. vim.fn.fnameescape(other))
    goto_row('3    he always is')
    child.type_keys('y')
    helpers.wait_until(child, '#_G.echoes == 1')

    eq(copied('he always is'), true)
    child.type_keys('n')
    helpers.wait_until(child, [[vim.fn.mode() == 'n']])

    helpers.cleanup(other)
end

T['delete'] = new_set()

T['delete']['d deletes the note after the confirm'] = function()
    open_beside_chapter()
    goto_row('3    he always is')
    child.type_keys('d')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 4]]
    )

    eq(child.lua_get('_G.confirms'), { 'Delete the annotation?\nhe always is' })
    eq(vim.tbl_contains(stored_bodies(), 'he always is'), false)
    eq(head(1), { 'Annotations (4) · 1 outdated' })
    eq(sidebar_lines()[5], '  5    Stale remark')
    eq(cursor_text(), '5    Stale remark')
end

T['delete']['d removes the note from the chapter buffer'] = function()
    local text_win = open_beside_chapter()
    local buf = child.lua_get('vim.api.nvim_win_get_buf(' .. text_win .. ')')
    local marks = [[(function()
        local ns = vim.api.nvim_get_namespaces()['iter.buffer.annotations']
        local texts = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(]] .. buf .. [[, ns, 0, -1, { details = true })) do
            for _, line in ipairs(mark[4].virt_lines or {}) do
                table.insert(texts, line[#line][1])
            end
        end
        return table.concat(texts, '\n')
    end)()]]

    helpers.wait_until(
        child,
        marks .. [[:find('he always is', 1, true) ~= nil]]
    )

    goto_row('3    he always is')
    child.type_keys('d')
    helpers.wait_until(
        child,
        marks .. [[:find('he always is', 1, true) == nil]]
    )

    eq(child.lua_get(marks .. [[:find('Stale remark', 1, true) ~= nil]]), true)
end

T['delete']['d declined keeps the note'] = function()
    open_beside_chapter()
    child.lua('_G.confirm_answer = 2')
    goto_row('3    he always is')
    child.type_keys('d')

    eq(#child.lua_get('_G.confirms'), 1)
    eq(#stored_bodies(), 5)
    eq(head(1), { 'Annotations (5) · 1 outdated' })
end

T['delete']['d on a file header does nothing'] = function()
    open_beside_chapter()
    goto_row('ch1.md')
    child.type_keys('d')

    eq(child.lua_get('_G.confirms'), {})
    eq(#stored_bodies(), 5)
end

T['edit'] = new_set()

T['edit']['e opens the editor on the note'] = function()
    open_beside_chapter()
    goto_row('3    he always is')
    child.type_keys('e')
    helpers.wait_until(child, E .. '.is_shown()')

    eq(
        child.lua_get(
            'vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf('
                .. E
                .. '.win()), 0, -1, false)'
        ),
        { 'he always is' }
    )
end

T['edit']['saving the edit shows the new text'] = function()
    open_beside_chapter()
    goto_row('3    he always is')
    child.type_keys('e')
    helpers.wait_until(child, E .. '.is_shown()')
    child.type_keys('<Esc>', 'A!', '<C-s>')
    helpers.wait_until(
        child,
        [[vim.tbl_contains(vim.tbl_map(function(a) return a.body end, require('iter.store').load(vim.fn.getcwd()).annotations), 'he always is!')]]
    )
    helpers.wait_until(
        child,
        [[table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr('iter://annotate/1'), 0, -1, false), '\n'):find('he always is!', 1, true) ~= nil]]
    )

    eq(sidebar_lines()[5], '  3    he always is!')
end

T['edit']['e on a header does nothing'] = function()
    open_beside_chapter()
    goto_row('ch1.md')
    child.type_keys('e')

    eq(child.lua_get(E .. '.is_shown()'), false)
end

T['help'] = new_set()

T['help']['? opens the keys and ? closes it'] = function()
    open_beside_chapter()
    child.type_keys('?')
    helpers.wait_until(child, [[vim.bo.filetype == 'iterhelp']])

    local lines = child.lua_get('vim.api.nvim_buf_get_lines(0, 0, -1, false)')

    eq(lines, {
        ' <CR>  Jump to the annotation ',
        ' y     Copy the annotation or file ',
        ' Y     Copy all annotations ',
        ' d     Delete the annotation ',
        ' e     Edit the annotation ',
        ' q     Close ',
        ' ?     Show the keys ',
    })

    child.type_keys('?')
    helpers.wait_until(child, [[vim.bo.filetype == 'iter']])
end

T['keys'] = new_set()

T['keys']['configured keys replace the defaults and the hints follow'] = function()
    child.lua([[require('iter').setup({
        keys = { annotate = { delete = 'x', close = 'Q', yank_all = false } },
    })]])
    open_beside_chapter()

    local lines = sidebar_lines()

    eq(lines[#lines - 1], '<CR> jump  y yank')
    eq(lines[#lines], 'x delete  e edit  ? help')

    goto_row('3    he always is')
    child.type_keys('x')
    helpers.wait_until(
        child,
        [[#require('iter.store').load(vim.fn.getcwd()).annotations == 4]]
    )
    child.type_keys('Q')

    eq(sidebar_win(), nil)
end

return T
