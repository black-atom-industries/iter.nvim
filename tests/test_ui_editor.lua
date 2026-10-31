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

--- `m.txt` (l1..l20) has l3 changed and l8 deleted in the worktree.
---@return string
local function create_editor_repo()
    local path = helpers.create_repo({ ['m.txt'] = numbered('l', 1, 20) })

    local m = numbered('l', 1, 20)
    m[3] = 'l3 new'
    table.remove(m, 8)
    helpers.write_file(vim.fs.joinpath(path, 'm.txt'), m)

    return path
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

--- Open the review tab and wait until the diff pane shows `m.txt`.
local function open_review()
    H.open(child)
    helpers.wait_until(
        child,
        R
            .. [[.view.files[1].path == 'm.txt' and ]]
            .. R
            .. [[.view:is_shown()]]
    )
end

--- Move into the diff pane onto the row whose text is `text`.
---@param text string
---@param kind? string row kind, any by default
local function diff_cursor(text, kind)
    child.lua(
        [[
        local text, kind = ...
        local review = require('iter').current_review
        local view = review.view
        vim.api.nvim_set_current_win(review.diff_win)
        for lnum, row in ipairs(view.rows) do
            if row.text == text and (kind == nil or row.kind == kind) then
                vim.api.nvim_win_set_cursor(review.diff_win, { lnum, 0 })
                return
            end
        end
        error('no row ' .. text)
    ]],
        { text, kind }
    )
end

---@return boolean
local function editor_shown()
    return child.lua_get(E .. [[.is_shown()]])
end

local function wait_editor()
    helpers.wait_until(
        child,
        E
            .. [[.is_shown() and vim.api.nvim_get_current_win() == ]]
            .. E
            .. [[.win()]]
    )
end

---@return string
local function mode()
    return child.api.nvim_get_mode().mode
end

---@return integer
local function iter_ctrl_t_maps()
    return child.lua_get([[#vim.tbl_filter(function(m)
        return m.desc == 'Show the draft annotation'
    end, vim.api.nvim_get_keymap('n'))]])
end

---@return string?
local function global_ctrl_t_desc()
    return child.lua_get([[(function()
        for _, m in ipairs(vim.api.nvim_get_keymap('n')) do
            if vim.fn.keytrans(m.lhsraw) == '<C-T>' then
                return m.desc or m.rhs
            end
        end
        return vim.NIL
    end)()]])
end

---@return integer
local function annotation_buffers()
    return child.lua_get([[#vim.tbl_filter(function(b)
        return vim.api.nvim_buf_get_name(b):match('^iter://annotation$') ~= nil
    end, vim.api.nvim_list_bufs())]])
end

---@return boolean
local function editor_augroup()
    return child.lua_get(
        [[pcall(vim.api.nvim_get_autocmds, { group = 'iter.annotation' })]]
    )
end

--- Start a line annotation on `l3 new` and type `text` in insert mode.
---@param text string
local function start_annotation(text)
    open_review()
    diff_cursor('l3 new')
    child.type_keys('a')
    wait_editor()
    child.type_keys(text)
end

local T = new_set({
    hooks = {
        pre_case = function()
            repo = create_editor_repo()
            helpers.start_child(child, repo, { lines = 36 })
            child.lua([[require('iter').setup()]])
            stub_ui()
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['float'] = new_set()

T['float']['opens in insert mode over the diff with the key hint'] = function()
    start_annotation('')

    eq(mode(), 'i')

    local config =
        child.lua_get([[vim.api.nvim_win_get_config(]] .. E .. [[.win())]])
    eq(config.zindex, 60)
    eq(config.relative, 'editor')
    eq(config.footer, {
        { ' <C-s> save & close · <C-t> toggle · <C-c> cancel ' },
    })
    eq(config.title, { { ' m.txt:3 ' } })
    eq(child.lua_get([[vim.bo.filetype]]), 'markdown')
    eq(iter_ctrl_t_maps(), 1)
end

T['float']['follows the pane when the editor is resized'] = function()
    child.o.columns = 120
    start_annotation('')

    local config = [[(function()
        local c = vim.api.nvim_win_get_config(]] .. E .. [[.win())
        local pane = vim.api.nvim_win_get_width(]] .. R .. [[.diff_win)
        return { c.width, pane }
    end)()]]
    local before = child.lua_get(config)
    eq(before[1], before[2] - 2)

    child.o.columns = child.o.columns - 30
    child.lua('vim.wait(20)')

    local after = child.lua_get(config)
    eq(after[1], after[2] - 2)
    eq(after[1] < before[1], true)
end

T['float']['<C-s> saves in insert mode and closes the float'] = function()
    start_annotation('first')
    child.type_keys('<C-s>')

    eq(editor_shown(), false)
    eq(mode(), 'n')

    local annotations = stored()
    eq(#annotations, 1)
    eq(annotations[1].body, 'first')
    eq(annotations[1].scope, 'line')
    eq(annotations[1].anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 3,
        end_line = 3,
        lines = { 'l3 new' },
    })
    eq(annotation_buffers(), 0)
    eq(iter_ctrl_t_maps(), 0)
    eq(editor_augroup(), false)
end

T['float']['<C-s> saves in normal mode and closes the float'] = function()
    start_annotation('multi')
    child.type_keys('<CR>', 'line', '<Esc>', '<C-s>')

    eq(stored()[1].body, 'multi\nline')
    eq(editor_shown(), false)
    eq(annotation_buffers(), 0)
end

T['float'][':w saves and :wq saves and closes'] = function()
    start_annotation('by write')
    child.type_keys('<Esc>')
    child.cmd('write')

    eq(stored()[1].body, 'by write')
    eq(editor_shown(), true)

    child.type_keys('A', ' and quit', '<Esc>')
    child.cmd('wq')

    eq(stored()[1].body, 'by write and quit')
    eq(#stored(), 1)
    eq(editor_shown(), false)
    eq(annotation_buffers(), 0)
    eq(iter_ctrl_t_maps(), 0)
    eq(editor_augroup(), false)
end

T['float']['the diff pane shows the saved annotation'] = function()
    start_annotation('shown')
    child.type_keys('<C-s>')

    helpers.wait_until(child, [[#]] .. R .. [[.view.marks == 1]])
    eq(child.lua_get(R .. [[.view.marks[1].annotation.body]]), 'shown')
end

T['float']['an empty annotation is not saved'] = function()
    start_annotation('  ')
    child.type_keys('<C-s>')

    eq(#stored(), 0)
    eq(notes(), { '[iter] The annotation is empty' })
end

T['toggle'] = new_set()

T['toggle']['<C-t> hides the float and shows it in the same place'] = function()
    start_annotation('draft')
    local before =
        child.lua_get([[vim.api.nvim_win_get_config(]] .. E .. [[.win())]])
    child.type_keys('<C-t>')

    eq(editor_shown(), false)
    eq(mode(), 'n')
    eq(annotation_buffers(), 1)
    eq(iter_ctrl_t_maps(), 1)
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · m.txt · 1/1 · draft annotation'
    )

    child.cmd('tabnew')
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'main · 1 · draft annotation'
    )
    child.cmd('tabprevious')
    child.type_keys('<C-t>')
    wait_editor()

    local after =
        child.lua_get([[vim.api.nvim_win_get_config(]] .. E .. [[.win())]])
    eq({ after.row, after.col, after.width, after.height }, {
        before.row,
        before.col,
        before.width,
        before.height,
    })
    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'draft',
    })
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · m.txt · 1/1'
    )
end

T['toggle']['<C-t> hides from normal mode too'] = function()
    start_annotation('draft')
    child.type_keys('<Esc>', '<C-t>')

    eq(editor_shown(), false)
    eq(annotation_buffers(), 1)
end

T['toggle']['<C-t> shows the draft from another tab'] = function()
    start_annotation('draft')
    child.type_keys('<C-t>')
    child.cmd('tabnew')
    child.type_keys('<C-t>')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'draft',
    })
end

T['toggle']['a user <C-t> map comes back after save'] = function()
    child.lua(
        [[vim.keymap.set('n', '<C-t>', function() _G.user_ctrl_t = true end, { desc = 'user ctrl-t' })]]
    )
    start_annotation('draft')

    eq(global_ctrl_t_desc(), 'Show the draft annotation')

    child.type_keys('<C-s>')

    eq(global_ctrl_t_desc(), 'user ctrl-t')
    eq(iter_ctrl_t_maps(), 0)

    child.type_keys('<C-c>')
    child.type_keys('<C-t>')
    eq(child.lua_get('_G.user_ctrl_t'), true)
end

T['toggle']['a user <C-t> map comes back after cancel'] = function()
    child.cmd('nnoremap <C-t> :let g:user_ctrl_t = 1<CR>')
    start_annotation('draft')
    child.type_keys('<C-t>')
    child.type_keys('<C-t>')
    wait_editor()
    child.type_keys('<C-c>')

    eq(global_ctrl_t_desc(), ':let g:user_ctrl_t = 1<CR>')
    eq(iter_ctrl_t_maps(), 0)
    eq(child.lua_get([[vim.fn.maparg('<C-t>', 'n', false, true).noremap]]), 1)
end

T['toggle']['no <C-t> map is left after save and after cancel'] = function()
    start_annotation('saved')
    child.type_keys('<C-s>')

    eq(iter_ctrl_t_maps(), 0)
    eq(global_ctrl_t_desc(), vim.NIL)

    child.type_keys('<C-c>')
    diff_cursor('l3 new')
    child.type_keys('a')
    wait_editor()
    eq(iter_ctrl_t_maps(), 1)
    child.type_keys('dropped', '<C-c>')

    eq(iter_ctrl_t_maps(), 0)
    eq(global_ctrl_t_desc(), vim.NIL)
    eq(editor_shown(), false)
    eq(annotation_buffers(), 0)
    eq(editor_augroup(), false)
    eq(mode(), 'n')
end

T['toggle']['a disabled toggle key maps nothing globally'] = function()
    child.lua(
        [[require('iter').setup({ keys = { annotation = { toggle = false } } })]]
    )
    start_annotation('draft')

    eq(global_ctrl_t_desc(), vim.NIL)
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).footer[1][1] ]]
        ),
        ' <C-s> save & close · <C-c> cancel '
    )
end

T['lifecycle'] = new_set()

T['lifecycle']['<C-c> drops the draft'] = function()
    start_annotation('dropped')
    child.type_keys('<C-c>')

    eq(#stored(), 0)
    eq(editor_shown(), false)
    eq(annotation_buffers(), 0)
    eq(mode(), 'n')
    eq(
        child.lua_get([[vim.api.nvim_get_current_win()]]),
        child.lua_get(R .. '.diff_win')
    )
end

T['lifecycle']['q closes only when the annotation is saved'] = function()
    start_annotation('unsaved')
    child.type_keys('<Esc>', 'q')

    eq(editor_shown(), true)
    eq(notes(), {
        '[iter] The annotation has unsaved changes; save or cancel it',
    })

    child.type_keys('<C-s>', 'q')

    eq(editor_shown(), false)
    eq(annotation_buffers(), 0)
    eq(stored()[1].body, 'unsaved')
end

T['lifecycle'][':q on an unsaved annotation keeps it as a hidden draft'] = function()
    start_annotation('kept')
    child.type_keys('<Esc>')
    child.cmd('quit')

    eq(editor_shown(), false)
    eq(annotation_buffers(), 1)
    eq(iter_ctrl_t_maps(), 1)
    eq(
        child
            .lua_get([[require('iter').statusline()]])
            :match('draft annotation$'),
        'draft annotation'
    )

    child.type_keys('<C-t>')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'kept',
    })
    eq(mode(), 'i')
end

for _, command in ipairs({ 'bunload!', 'bdelete!', 'bwipeout!' }) do
    for _, state in ipairs({ 'hidden', 'shown' }) do
        T['lifecycle'][':' .. command .. ' on the ' .. state .. ' draft keeps its text'] = function()
            start_annotation('kept text')

            if state == 'hidden' then
                child.type_keys('<C-t>')
            else
                child.type_keys('<Esc>')
                child.lua(
                    [[vim.api.nvim_set_current_win(]] .. R .. [[.diff_win)]]
                )
            end

            child.cmd(command .. ' ' .. child.lua_get([[(function()
                        for _, b in ipairs(vim.api.nvim_list_bufs()) do
                            if vim.api.nvim_buf_get_name(b):match('^iter://annotation$') then
                                return b
                            end
                        end
                    end)()]]))

            eq(editor_shown(), false)
            eq(iter_ctrl_t_maps(), 1)
            eq(
                child
                    .lua_get([[require('iter').statusline()]])
                    :match('draft annotation$'),
                'draft annotation'
            )

            child.type_keys('<C-t>')
            wait_editor()

            eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
                'kept text',
            })
            eq(child.lua_get('vim.bo.buftype'), 'acwrite')
            eq(annotation_buffers(), 1)

            child.type_keys('<Esc>')
            child.cmd('write')

            eq(stored()[1].body, 'kept text')
            eq(vim.fn.glob(vim.fs.joinpath(repo, 'iter:*')), '')
            eq(vim.fn.isdirectory(vim.fs.joinpath(repo, 'iter:')), 0)
            eq(child.v.errmsg, '')

            child.type_keys('q')
            eq(iter_ctrl_t_maps(), 0)
            eq(annotation_buffers(), 0)
        end
    end
end

T['lifecycle']['hide and show keep one WinClosed autocmd'] = function()
    start_annotation('cycles')

    local counts = {}

    for _ = 1, 3 do
        child.type_keys('<C-t>')
        child.type_keys('<C-t>')
        wait_editor()
        table.insert(
            counts,
            child.lua_get(
                [[#vim.api.nvim_get_autocmds({ group = 'iter.annotation', event = 'WinClosed' })]]
            )
        )
    end

    eq(counts, { 1, 1, 1 })
end

T['toggle']['a <C-t> map set while the draft exists stays'] = function()
    child.lua(
        [[vim.keymap.set('n', '<C-t>', function() end, { desc = 'first user map' })]]
    )
    start_annotation('draft')
    child.type_keys('<C-t>')
    child.lua(
        [[vim.keymap.set('n', '<C-t>', function() _G.newer = true end, { desc = 'newer user map' })]]
    )
    child.lua(E .. '.show()')
    wait_editor()
    child.type_keys('<C-c>')

    eq(global_ctrl_t_desc(), 'newer user map')
end

T['lifecycle']['a second a shows the open draft'] = function()
    start_annotation('first draft')
    child.type_keys('<C-t>')
    diff_cursor('l4')
    child.type_keys('a')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'first draft',
    })
    eq(annotation_buffers(), 1)
    eq(notes(), { '[iter] Finish the open annotation first' })
end

T['lifecycle']['a saved annotation gives way to the next one'] = function()
    start_annotation('first')
    child.type_keys('<C-s>')
    diff_cursor('l4')
    child.type_keys('a')
    wait_editor()
    child.type_keys('second', '<C-s>')

    eq(annotation_buffers(), 0)
    eq(
        vim.tbl_map(function(c)
            return c.body
        end, stored()),
        { 'first', 'second' }
    )
end

T['anchors'] = new_set()

T['anchors']['a visual range anchors its lines'] = function()
    open_review()
    diff_cursor('l4')
    child.type_keys('Vj', 'a')
    wait_editor()
    child.type_keys('range')
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).title[1][1] ]]
        ),
        ' m.txt:4-5 '
    )
    child.type_keys('<C-s>')

    local annotation = stored()[1]
    eq(annotation.scope, 'range')
    eq(annotation.anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 4,
        end_line = 5,
        lines = { 'l4', 'l5' },
    })
end

T['anchors']['v anchors the selected words of the new side'] = function()
    open_review()
    diff_cursor('l3 new')
    child.type_keys('l', 'v', '2l', 'a')
    wait_editor()
    child.type_keys('passage', '<C-s>')

    local annotation = stored()[1]
    eq(annotation.scope, 'line')
    local before, after = annotation.anchor.before, annotation.anchor.after
    annotation.anchor.before, annotation.anchor.after = nil, nil
    eq(annotation.anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 3,
        end_line = 3,
        lines = { 'l3 new' },
        start_col = 1,
        end_col = 4,
        quote = '3 n',
    })
    eq(before, 'l1\nl2\nl')
    eq(vim.startswith(after, 'ew\nl4\nl5'), true)
end

T['anchors']['V in the diff pane still anchors whole lines'] = function()
    open_review()
    diff_cursor('l3 new')
    child.type_keys('l', 'V', 'a')
    wait_editor()
    child.type_keys('line', '<C-s>')

    eq(stored()[1].anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 3,
        end_line = 3,
        lines = { 'l3 new' },
    })
end

T['anchors']['v on a deleted line keeps a line note'] = function()
    open_review()
    diff_cursor('l8', 'del')
    child.type_keys('v', 'a')
    wait_editor()
    child.type_keys('old', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.side, 'old')
    eq(anchor.quote, nil)
end

T['anchors']['a deleted line anchors on the old side'] = function()
    open_review()
    diff_cursor('l8', 'del')
    child.type_keys('a')
    wait_editor()
    child.type_keys('old', '<C-s>')

    eq(stored()[1].anchor, {
        path = 'm.txt',
        side = 'old',
        base = 'index',
        start_line = 8,
        end_line = 8,
        lines = { 'l8' },
    })
end

T['anchors']['a range over deleted and added rows takes the new side'] = function()
    open_review()
    diff_cursor('l3', 'del')
    child.type_keys('Vj', 'a')
    wait_editor()
    child.type_keys('mixed', '<C-s>')

    eq(stored()[1].anchor.side, 'new')
    eq(stored()[1].anchor.start_line, 3)
    eq(stored()[1].anchor.end_line, 3)
end

T['anchors']['a staged line anchors on the worktree line'] = function()
    helpers.git(repo, { 'add', 'm.txt' })
    local m = numbered('l', 1, 20)
    m[3] = 'l3 new'
    table.remove(m, 8)
    table.insert(m, 1, 'l0')
    helpers.write_file(vim.fs.joinpath(repo, 'm.txt'), m)

    child.cmd('Iter review')
    helpers.wait_until(child, R .. [[ ~= nil and ]] .. R .. [[.panel ~= nil]])
    H.select(child, 'staged', 'm.txt')
    helpers.wait_until(
        child,
        R
            .. [[.view.files[2] ~= nil and ]]
            .. R
            .. [[.view.files[2].side == 'staged']]
    )
    -- The added row of the Staged section.
    diff_cursor('l3 new', 'add')
    child.type_keys('a')
    wait_editor()
    child.type_keys('staged', '<C-s>')

    eq(stored()[1].anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 4,
        end_line = 4,
        lines = { 'l3 new' },
    })
end

T['anchors']['a hunk row takes no line annotation'] = function()
    open_review()
    child.lua([[
        local review = require('iter').current_review
        vim.api.nvim_set_current_win(review.diff_win)
        for lnum, row in ipairs(review.view.rows) do
            if row.kind == 'hunk' then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
                break
            end
        end
    ]])
    child.type_keys('a')

    eq(editor_shown(), false)
    eq(notes(), { '[iter] No line under the cursor' })
end

T['anchors']['A annotates the file from the diff pane and the tree'] = function()
    open_review()
    diff_cursor('l4')
    child.type_keys('A')
    wait_editor()
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).title[1][1] ]]
        ),
        ' m.txt (file) '
    )
    child.type_keys('from diff', '<C-s>', '<C-c>')

    H.focus_list(child)
    child.type_keys('A')
    wait_editor()
    child.type_keys('from tree', '<C-s>', '<C-c>')

    local annotations = stored()
    eq(#annotations, 2)
    eq(annotations[1].scope, 'file')
    eq(annotations[1].anchor, { path = 'm.txt', side = 'new' })
    eq(annotations[2].body, 'from tree')
    eq(annotations[2].anchor, { path = 'm.txt', side = 'new' })
end

T['edit and delete'] = new_set()

---@return string id
local function seed_line_annotation()
    return child.lua_get(
        [[require('iter.store').put_annotation(vim.fn.getcwd(), {
        scope = 'line',
        body = 'old body',
        outdated = false,
        anchor = { path = 'm.txt', side = 'new', start_line = 4, end_line = 4, lines = { 'l4' } },
    }).id]]
    )
end

T['edit and delete']['e edits the annotation under the cursor'] = function()
    local id = seed_line_annotation()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'old body',
    })
    eq(mode(), 'i')

    child.type_keys(' edited', '<C-s>')

    local annotations = stored()
    eq(#annotations, 1)
    eq(annotations[1].id, id)
    eq(annotations[1].body, 'old body edited')
end

T['edit and delete']['saving an edit of an annotation deleted elsewhere warns'] = function()
    local id = seed_line_annotation()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()
    child.lua(
        [[require('iter.store').remove_annotations(vim.fn.getcwd(), { ... })]],
        { id }
    )
    child.type_keys('!', '<C-s>')

    eq(#stored(), 0)
    eq(notes(), { '[iter] The annotation no longer exists' })
    eq(editor_shown(), true)
end

T['edit and delete']['e without an annotation warns'] = function()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')

    eq(editor_shown(), false)
    eq(notes(), { '[iter] No annotation on this line' })
end

T['edit and delete']['d deletes after the confirm'] = function()
    seed_line_annotation()
    open_review()
    diff_cursor('l4')

    child.lua('_G.confirm_answer = 2')
    child.type_keys('d')
    eq(#stored(), 1)
    eq(child.lua_get('_G.confirms'), { 'Delete the annotation?\nold body' })

    child.lua('_G.confirm_answer = 1')
    child.type_keys('d')
    eq(#stored(), 0)
    helpers.wait_until(child, [[#]] .. R .. [[.view.marks == 0]])
end

--- Text of the annotation lines in the buffer of `m.txt`.
---@return string[]
local function buffer_mark_texts()
    return child.lua_get([[(function()
        local buf = vim.fn.bufnr('m.txt')
        local ns = vim.api.nvim_get_namespaces()['iter.buffer.annotations']
        local texts = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true, type = 'virt_lines' })) do
            for _, line in ipairs(mark[4].virt_lines) do
                local parts = {}
                for _, chunk in ipairs(line) do
                    table.insert(parts, chunk[1])
                end
                table.insert(texts, vim.trim(table.concat(parts)))
            end
        end
        return texts
    end)()]])
end

T['edit and delete']['e in the review redraws the file buffer'] = function()
    seed_line_annotation()
    child.cmd('edit m.txt')
    eq(buffer_mark_texts(), { '▍ 󰆉 old body' })

    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()
    -- The same length, so only the content of the store file changes.
    child.type_keys('<C-u>', 'new body', '<C-s>')

    eq(stored()[1].body, 'new body')
    eq(buffer_mark_texts(), { '▍ 󰆉 new body' })
end

T['edit and delete']['d in the review clears the mark of the file buffer'] = function()
    seed_line_annotation()
    child.cmd('edit m.txt')
    eq(buffer_mark_texts(), { '▍ 󰆉 old body' })

    open_review()
    diff_cursor('l4')
    child.type_keys('d')

    eq(#stored(), 0)
    eq(buffer_mark_texts(), {})
end

T['api'] = new_set()

T['api']['annotate() annotates a line of a normal buffer'] = function()
    child.cmd('edit m.txt')
    child.api.nvim_win_set_cursor(0, { 2, 0 })
    child.lua([[require('iter').annotate()]])
    wait_editor()
    child.type_keys('buffer', '<C-s>', '<C-c>')

    eq(stored()[1].anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 2,
        end_line = 2,
        lines = { 'l2' },
    })
    eq(
        child.lua_get(
            [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['iter.buffer.annotations'], 0, -1, { type = 'virt_lines' })]]
        ),
        1
    )
end

T['api']['annotate() takes a visual range'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 5, 0 })
    child.type_keys('Vk', '<Space>c')
    wait_editor()
    child.type_keys('range', '<C-s>')

    eq(stored()[1].scope, 'range')
    eq(stored()[1].anchor.start_line, 4)
    eq(stored()[1].anchor.end_line, 5)
end

T['api']['annotate() takes the words of a v selection'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 1 })
    child.type_keys('v', '2l', '<Space>c')
    wait_editor()
    child.type_keys('passage', '<C-s>')

    local annotation = stored()[1]
    eq(annotation.scope, 'line')
    eq(annotation.anchor.lines, { 'l3 new' })
    eq({ annotation.anchor.start_col, annotation.anchor.end_col }, { 1, 4 })
    eq(annotation.anchor.quote, '3 n')
end

T['api']['annotate() takes a backwards v selection across lines'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 5, 1 })
    child.type_keys('v', 'k', '<Space>c')
    wait_editor()
    child.type_keys('passage', '<C-s>')

    local annotation = stored()[1]
    eq(annotation.scope, 'range')
    eq(annotation.anchor.lines, { 'l4', 'l5' })
    eq({ annotation.anchor.start_col, annotation.anchor.end_col }, { 1, 2 })
    eq(annotation.anchor.quote, '4\nl5')
end

T['api']['annotate() keeps V and blockwise selections as line notes'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 1 })
    child.type_keys('V', '<Space>c')
    wait_editor()
    child.type_keys('one', '<C-s>')

    child.api.nvim_win_set_cursor(0, { 5, 0 })
    child.type_keys('<C-v>', 'jl', '<Space>c')
    wait_editor()
    child.type_keys('two', '<C-s>')

    local saved = stored()
    eq(#saved, 2)

    for _, annotation in ipairs(saved) do
        eq(annotation.anchor.quote, nil)
        eq(annotation.anchor.start_col, nil)
    end
end

T['api']['annotate() takes a whole multibyte character at the end of v'] = function()
    child.cmd('edit m.txt')
    child.api.nvim_buf_set_lines(0, 2, 3, false, { 'äöü xyz' })
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 0 })
    child.type_keys('v', 'l', '<Space>c')
    wait_editor()
    child.type_keys('mb', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, 'äö')
    eq({ anchor.start_col, anchor.end_col }, { 0, 4 })
end

T['api']['annotate() clamps v$ to the line without its newline'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 1 })
    child.type_keys('v', '$', '<Space>c')
    wait_editor()
    child.type_keys('eol', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, '3 new')
    eq({ anchor.start_col, anchor.end_col }, { 1, 6 })
end

T['api']['annotate() orders a reversed v selection'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 4 })
    child.type_keys('v', '2h', '<Space>c')
    wait_editor()
    child.type_keys('rev', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, ' ne')
    eq({ anchor.start_col, anchor.end_col }, { 2, 5 })
end

T['anchors']['v starting on a deleted row falls back to a line note'] = function()
    open_review()
    diff_cursor('l3 new')
    child.type_keys('l', 'v', 'k', 'a')
    wait_editor()
    child.type_keys('fallback', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, nil)
    eq({ anchor.start_line, anchor.end_line }, { 3, 3 })
end

T['anchors']['v ending on a deleted row falls back to a line note'] = function()
    open_review()
    diff_cursor('l2')
    child.type_keys('l', 'v', 'j', 'a')
    wait_editor()
    child.type_keys('fallback', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, nil)
    eq({ anchor.start_line, anchor.end_line }, { 2, 2 })
end

T['api']["annotate() ends an exclusive 'selection' before the last character"] = function()
    child.cmd('edit m.txt')
    child.o.selection = 'exclusive'
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').annotate() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 3, 1 })
    child.type_keys('v', '2l', '<Space>c')
    wait_editor()
    child.type_keys('excl', '<C-s>')

    local anchor = stored()[1].anchor
    eq(anchor.quote, '3 ')
    eq({ anchor.start_col, anchor.end_col }, { 1, 3 })
end

T['api']["annotate({ scope = 'file' }) annotates the buffer's file"] = function()
    child.cmd('edit m.txt')
    child.lua([[require('iter').annotate({ scope = 'file' })]])
    wait_editor()
    child.type_keys('whole file', '<C-s>')

    eq(stored()[1].scope, 'file')
    eq(stored()[1].anchor, { path = 'm.txt', side = 'new' })
    eq(stored()[1].body, 'whole file')
end

T['api']["annotate({ scope = 'file' }) outside a repo file warns"] = function()
    child.cmd('enew')
    child.lua([[require('iter').annotate({ scope = 'file' })]])

    eq(editor_shown(), false)
    eq(notes(), { '[iter] Not a file in a git repository' })
end

T['api']['annotate() outside a repo file warns'] = function()
    child.cmd('enew')
    child.lua([[require('iter').annotate()]])

    eq(editor_shown(), false)
    eq(notes(), { '[iter] Not a file in a git repository' })
end

T['api']["annotation({ scope = 'review' }) adds a review annotation"] = function()
    child.lua([[require('iter').annotate({ scope = 'review' })]])
    wait_editor()
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).title[1][1] ]]
        ),
        ' Review '
    )
    child.type_keys('overall', '<C-s>')

    eq(stored()[1].scope, 'review')
    eq(stored()[1].anchor, { side = 'new' })
    eq(stored()[1].body, 'overall')
end

return T
