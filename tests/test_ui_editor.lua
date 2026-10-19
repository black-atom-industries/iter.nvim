local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

local R = [[require('iter').current_review]]
local E = [[require('iter.comments.editor')]]

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
        [[require('iter.store').load(vim.fn.getcwd()).comments]]
    )
end

--- Open the review tab and wait until the diff pane shows `m.txt`.
local function open_review()
    child.cmd('Iter review')
    helpers.wait_until(
        child,
        string.format(
            [[(function()
                local r = %s
                local f = r and r.drawer.win and r.drawer.view.files[1]
                return f ~= nil and f.path == 'm.txt' and r.drawer.view:is_shown()
            end)()]],
            R
        )
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
        local view = review.drawer.view
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
        return m.desc == 'Show the draft comment'
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
local function comment_buffers()
    return child.lua_get([[#vim.tbl_filter(function(b)
        return vim.api.nvim_buf_get_name(b):match('^iter://comment/') ~= nil
    end, vim.api.nvim_list_bufs())]])
end

---@return boolean
local function editor_augroup()
    return child.lua_get(
        [[pcall(vim.api.nvim_get_autocmds, { group = 'iter.comment' })]]
    )
end

--- Start a line comment on `l3 new` and type `text` in insert mode.
---@param text string
local function start_comment(text)
    open_review()
    diff_cursor('l3 new')
    child.type_keys('c')
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

T['float']['opens in insert mode above the drawer with the key hint'] = function()
    start_comment('')

    eq(mode(), 'i')

    local config =
        child.lua_get([[vim.api.nvim_win_get_config(]] .. E .. [[.win())]])
    eq(config.zindex, 60)
    eq(config.relative, 'editor')
    eq(config.footer, {
        { ' <C-s> save · <C-t> toggle · <C-c> cancel ' },
    })
    eq(config.title, { { ' m.txt:3 ' } })
    eq(child.lua_get([[vim.bo.filetype]]), 'markdown')
    eq(iter_ctrl_t_maps(), 1)
end

T['float']['<C-s> saves in insert mode and keeps the float'] = function()
    start_comment('first')
    child.type_keys('<C-s>')

    eq(editor_shown(), true)
    eq(mode(), 'i')

    local comments = stored()
    eq(#comments, 1)
    eq(comments[1].body, 'first')
    eq(comments[1].scope, 'line')
    eq(comments[1].anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 3,
        end_line = 3,
        lines = { 'l3 new' },
    })
    eq(iter_ctrl_t_maps(), 0)

    child.type_keys(' second', '<C-s>')

    comments = stored()
    eq(#comments, 1)
    eq(comments[1].body, 'first second')
end

T['float']['<C-s> saves in normal mode'] = function()
    start_comment('multi')
    child.type_keys('<CR>', 'line', '<Esc>', '<C-s>')

    eq(stored()[1].body, 'multi\nline')
    eq(editor_shown(), true)
end

T['float'][':w saves and :wq saves and closes'] = function()
    start_comment('by write')
    child.type_keys('<Esc>')
    child.cmd('write')

    eq(stored()[1].body, 'by write')
    eq(editor_shown(), true)

    child.type_keys('A', ' and quit', '<Esc>')
    child.cmd('wq')

    eq(stored()[1].body, 'by write and quit')
    eq(#stored(), 1)
    eq(editor_shown(), false)
    eq(comment_buffers(), 0)
    eq(iter_ctrl_t_maps(), 0)
    eq(editor_augroup(), false)
end

T['float']['the diff pane shows the saved comment'] = function()
    start_comment('shown')
    child.type_keys('<C-s>', '<C-c>')

    helpers.wait_until(child, [[#]] .. R .. [[.drawer.view.marks == 1]])
    eq(child.lua_get(R .. [[.drawer.view.marks[1].comment.body]]), 'shown')
end

T['float']['an empty comment is not saved'] = function()
    start_comment('  ')
    child.type_keys('<C-s>')

    eq(#stored(), 0)
    eq(notes(), { '[iter] The comment is empty' })
end

T['toggle'] = new_set()

T['toggle']['<C-t> hides the float and shows it in the same place'] = function()
    start_comment('draft')
    local before =
        child.lua_get([[vim.api.nvim_win_get_config(]] .. E .. [[.win())]])
    child.type_keys('<C-t>')

    eq(editor_shown(), false)
    eq(mode(), 'n')
    eq(comment_buffers(), 1)
    eq(iter_ctrl_t_maps(), 1)
    eq(
        child.lua_get([[require('iter').statusline()]]),
        'review · m.txt · 1/1 · draft comment'
    )

    child.cmd('tabnew')
    eq(child.lua_get([[require('iter').statusline()]]), 'draft comment')
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
    start_comment('draft')
    child.type_keys('<Esc>', '<C-t>')

    eq(editor_shown(), false)
    eq(comment_buffers(), 1)
end

T['toggle']['<C-t> shows the draft from another tab'] = function()
    start_comment('draft')
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
    start_comment('draft')

    eq(global_ctrl_t_desc(), 'Show the draft comment')

    child.type_keys('<C-s>')

    eq(global_ctrl_t_desc(), 'user ctrl-t')
    eq(iter_ctrl_t_maps(), 0)

    child.type_keys('<C-c>')
    child.type_keys('<C-t>')
    eq(child.lua_get('_G.user_ctrl_t'), true)
end

T['toggle']['a user <C-t> map comes back after cancel'] = function()
    child.cmd('nnoremap <C-t> :let g:user_ctrl_t = 1<CR>')
    start_comment('draft')
    child.type_keys('<C-t>')
    child.type_keys('<C-t>')
    wait_editor()
    child.type_keys('<C-c>')

    eq(global_ctrl_t_desc(), ':let g:user_ctrl_t = 1<CR>')
    eq(iter_ctrl_t_maps(), 0)
    eq(child.lua_get([[vim.fn.maparg('<C-t>', 'n', false, true).noremap]]), 1)
end

T['toggle']['no <C-t> map is left after save and after cancel'] = function()
    start_comment('saved')
    child.type_keys('<C-s>')

    eq(iter_ctrl_t_maps(), 0)
    eq(global_ctrl_t_desc(), vim.NIL)

    child.type_keys('<C-c>')
    diff_cursor('l3 new')
    child.type_keys('c')
    wait_editor()
    eq(iter_ctrl_t_maps(), 1)
    child.type_keys('dropped', '<C-c>')

    eq(iter_ctrl_t_maps(), 0)
    eq(global_ctrl_t_desc(), vim.NIL)
    eq(editor_shown(), false)
    eq(comment_buffers(), 0)
    eq(editor_augroup(), false)
    eq(mode(), 'n')
end

T['toggle']['a disabled toggle key maps nothing globally'] = function()
    child.lua(
        [[require('iter').setup({ keys = { comment = { toggle = false } } })]]
    )
    start_comment('draft')

    eq(global_ctrl_t_desc(), vim.NIL)
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).footer[1][1] ]]
        ),
        ' <C-s> save · <C-c> cancel '
    )
end

T['lifecycle'] = new_set()

T['lifecycle']['<C-c> drops the draft'] = function()
    start_comment('dropped')
    child.type_keys('<C-c>')

    eq(#stored(), 0)
    eq(editor_shown(), false)
    eq(comment_buffers(), 0)
    eq(mode(), 'n')
    eq(
        child.lua_get([[vim.api.nvim_get_current_win()]]),
        child.lua_get(R .. '.diff_win')
    )
end

T['lifecycle']['q closes only when the comment is saved'] = function()
    start_comment('unsaved')
    child.type_keys('<Esc>', 'q')

    eq(editor_shown(), true)
    eq(notes(), {
        '[iter] The comment has unsaved changes; save or cancel it',
    })

    child.type_keys('<C-s>', 'q')

    eq(editor_shown(), false)
    eq(comment_buffers(), 0)
    eq(stored()[1].body, 'unsaved')
end

T['lifecycle'][':q on an unsaved comment keeps it as a hidden draft'] = function()
    start_comment('kept')
    child.type_keys('<Esc>')
    child.cmd('quit')

    eq(editor_shown(), false)
    eq(comment_buffers(), 1)
    eq(iter_ctrl_t_maps(), 1)
    eq(
        child.lua_get([[require('iter').statusline()]]):match('draft comment$'),
        'draft comment'
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
            start_comment('kept text')

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
                            if vim.api.nvim_buf_get_name(b):match('^iter://comment/') then
                                return b
                            end
                        end
                    end)()]]))

            eq(editor_shown(), false)
            eq(iter_ctrl_t_maps(), 1)
            eq(
                child
                    .lua_get([[require('iter').statusline()]])
                    :match('draft comment$'),
                'draft comment'
            )

            child.type_keys('<C-t>')
            wait_editor()

            eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
                'kept text',
            })
            eq(child.lua_get('vim.bo.buftype'), 'acwrite')
            eq(comment_buffers(), 1)

            child.type_keys('<Esc>')
            child.cmd('write')

            eq(stored()[1].body, 'kept text')
            eq(vim.fn.glob(vim.fs.joinpath(repo, 'iter:*')), '')
            eq(vim.fn.isdirectory(vim.fs.joinpath(repo, 'iter:')), 0)
            eq(child.v.errmsg, '')

            child.type_keys('q')
            eq(iter_ctrl_t_maps(), 0)
            eq(comment_buffers(), 0)
        end
    end
end

T['lifecycle']['hide and show keep one WinClosed autocmd'] = function()
    start_comment('cycles')

    local counts = {}

    for _ = 1, 3 do
        child.type_keys('<C-t>')
        child.type_keys('<C-t>')
        wait_editor()
        table.insert(
            counts,
            child.lua_get(
                [[#vim.api.nvim_get_autocmds({ group = 'iter.comment', event = 'WinClosed' })]]
            )
        )
    end

    eq(counts, { 1, 1, 1 })
end

T['toggle']['a <C-t> map set while the draft exists stays'] = function()
    child.lua(
        [[vim.keymap.set('n', '<C-t>', function() end, { desc = 'first user map' })]]
    )
    start_comment('draft')
    child.type_keys('<C-t>')
    child.lua(
        [[vim.keymap.set('n', '<C-t>', function() _G.newer = true end, { desc = 'newer user map' })]]
    )
    child.lua(E .. '.show()')
    wait_editor()
    child.type_keys('<C-c>')

    eq(global_ctrl_t_desc(), 'newer user map')
end

T['lifecycle']['a second c shows the open draft'] = function()
    start_comment('first draft')
    child.type_keys('<C-t>')
    diff_cursor('l4')
    child.type_keys('c')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'first draft',
    })
    eq(comment_buffers(), 1)
    eq(notes(), { '[iter] Finish the open comment first' })
end

T['lifecycle']['a saved comment gives way to the next one'] = function()
    start_comment('first')
    child.type_keys('<C-s>', '<Esc>')
    diff_cursor('l4')
    child.type_keys('c')
    wait_editor()
    child.type_keys('second', '<C-s>')

    eq(comment_buffers(), 1)
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
    child.type_keys('Vj', 'c')
    wait_editor()
    child.type_keys('range', '<C-s>')

    local comment = stored()[1]
    eq(comment.scope, 'range')
    eq(comment.anchor, {
        path = 'm.txt',
        side = 'new',
        start_line = 4,
        end_line = 5,
        lines = { 'l4', 'l5' },
    })
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).title[1][1] ]]
        ),
        ' m.txt:4-5 '
    )
end

T['anchors']['a deleted line anchors on the old side'] = function()
    open_review()
    diff_cursor('l8', 'del')
    child.type_keys('c')
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
    child.type_keys('Vj', 'c')
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
    helpers.wait_until(
        child,
        R .. [[ ~= nil and ]] .. R .. [[.drawer.win ~= nil]]
    )
    child.lua(R .. [[.drawer:switch('staged')]])
    child.lua(R .. [[.drawer:preview(true)]])
    helpers.wait_until(
        child,
        R
            .. [[.drawer.view.files[1] ~= nil and ]]
            .. R
            .. [[.drawer.view.files[1].side == 'staged']]
    )
    diff_cursor('l3 new')
    child.type_keys('c')
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

T['anchors']['a hunk row takes no line comment'] = function()
    open_review()
    child.lua([[
        local review = require('iter').current_review
        vim.api.nvim_set_current_win(review.diff_win)
        for lnum, row in ipairs(review.drawer.view.rows) do
            if row.kind == 'hunk' then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
                break
            end
        end
    ]])
    child.type_keys('c')

    eq(editor_shown(), false)
    eq(notes(), { '[iter] No line under the cursor' })
end

T['anchors']['C comments on the file from the diff pane and the drawer'] = function()
    open_review()
    diff_cursor('l4')
    child.type_keys('C')
    wait_editor()
    eq(
        child.lua_get(
            [[vim.api.nvim_win_get_config(]] .. E .. [[.win()).title[1][1] ]]
        ),
        ' m.txt (file) '
    )
    child.type_keys('from diff', '<C-s>', '<C-c>')

    child.lua([[vim.api.nvim_set_current_win(]] .. R .. [[.drawer.win)]])
    child.type_keys('C')
    wait_editor()
    child.type_keys('from drawer', '<C-s>', '<C-c>')

    local comments = stored()
    eq(#comments, 2)
    eq(comments[1].scope, 'file')
    eq(comments[1].anchor, { path = 'm.txt', side = 'new' })
    eq(comments[2].body, 'from drawer')
    eq(comments[2].anchor, { path = 'm.txt', side = 'new' })
end

T['edit and delete'] = new_set()

---@return string id
local function seed_line_comment()
    return child.lua_get([[require('iter.store').put_comment(vim.fn.getcwd(), {
        scope = 'line',
        body = 'old body',
        outdated = false,
        anchor = { path = 'm.txt', side = 'new', start_line = 4, end_line = 4, lines = { 'l4' } },
    }).id]])
end

T['edit and delete']['e edits the comment under the cursor'] = function()
    local id = seed_line_comment()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()

    eq(child.lua_get([[vim.api.nvim_buf_get_lines(0, 0, -1, false)]]), {
        'old body',
    })
    eq(mode(), 'i')

    child.type_keys(' edited', '<C-s>')

    local comments = stored()
    eq(#comments, 1)
    eq(comments[1].id, id)
    eq(comments[1].body, 'old body edited')
end

T['edit and delete']['saving an edit of a comment deleted elsewhere warns'] = function()
    local id = seed_line_comment()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()
    child.lua(
        [[require('iter.store').remove_comments(vim.fn.getcwd(), { ... })]],
        { id }
    )
    child.type_keys('!', '<C-s>')

    eq(#stored(), 0)
    eq(notes(), { '[iter] The comment no longer exists' })
    eq(editor_shown(), true)
end

T['edit and delete']['e without a comment warns'] = function()
    open_review()
    diff_cursor('l4')
    child.type_keys('e')

    eq(editor_shown(), false)
    eq(notes(), { '[iter] No comment on this line' })
end

T['edit and delete']['x deletes after the confirm'] = function()
    seed_line_comment()
    open_review()
    diff_cursor('l4')

    child.lua('_G.confirm_answer = 2')
    child.type_keys('x')
    eq(#stored(), 1)
    eq(child.lua_get('_G.confirms'), { 'Delete the comment?\nold body' })

    child.lua('_G.confirm_answer = 1')
    child.type_keys('x')
    eq(#stored(), 0)
    helpers.wait_until(child, [[#]] .. R .. [[.drawer.view.marks == 0]])
end

--- Text of the comment lines in the buffer of `m.txt`.
---@return string[]
local function buffer_mark_texts()
    return child.lua_get([[(function()
        local buf = vim.fn.bufnr('m.txt')
        local ns = vim.api.nvim_get_namespaces()['iter.buffer.comments']
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
    seed_line_comment()
    child.cmd('edit m.txt')
    eq(buffer_mark_texts(), { '▎ old body' })

    open_review()
    diff_cursor('l4')
    child.type_keys('e')
    wait_editor()
    -- The same length, so only the content of the store file changes.
    child.type_keys('<C-u>', 'new body', '<C-s>')

    eq(stored()[1].body, 'new body')
    eq(buffer_mark_texts(), { '▎ new body' })
end

T['edit and delete']['x in the review clears the mark of the file buffer'] = function()
    seed_line_comment()
    child.cmd('edit m.txt')
    eq(buffer_mark_texts(), { '▎ old body' })

    open_review()
    diff_cursor('l4')
    child.type_keys('x')

    eq(#stored(), 0)
    eq(buffer_mark_texts(), {})
end

T['api'] = new_set()

T['api']['comment() comments on a line of a normal buffer'] = function()
    child.cmd('edit m.txt')
    child.api.nvim_win_set_cursor(0, { 2, 0 })
    child.lua([[require('iter').comment()]])
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
            [[#vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces()['iter.buffer.comments'], 0, -1, { type = 'virt_lines' })]]
        ),
        1
    )
end

T['api']['comment() takes a visual range'] = function()
    child.cmd('edit m.txt')
    child.lua(
        [[vim.keymap.set('x', '<Space>c', function() require('iter').comment() end)]]
    )
    child.api.nvim_win_set_cursor(0, { 5, 0 })
    child.type_keys('Vk', '<Space>c')
    wait_editor()
    child.type_keys('range', '<C-s>')

    eq(stored()[1].scope, 'range')
    eq(stored()[1].anchor.start_line, 4)
    eq(stored()[1].anchor.end_line, 5)
end

T['api']['comment() outside a repo file warns'] = function()
    child.cmd('enew')
    child.lua([[require('iter').comment()]])

    eq(editor_shown(), false)
    eq(notes(), { '[iter] Not a file in a git repository' })
end

T['api']["comment({ scope = 'review' }) adds a review comment"] = function()
    child.lua([[require('iter').comment({ scope = 'review' })]])
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
