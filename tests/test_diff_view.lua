local helpers = dofile('tests/helpers.lua')

local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

local child = MiniTest.new_child_neovim()
---@type string
local repo

-- Two hunks with three-digit line numbers, 13 hidden lines between them and
-- hidden context before the first and after the last.
local function create_two_hunk_repo()
    local lines = {}

    for i = 1, 130 do
        table.insert(lines, 'line ' .. i)
    end

    repo = helpers.create_repo({ ['two.txt'] = lines })

    lines[100] = 'line one hundred'
    lines[120] = 'line one hundred twenty'
    helpers.write_file(vim.fs.joinpath(repo, 'two.txt'), lines)
end

--- Open an IterDiffView on two.txt in the child's current window as `_G.view`.
local function open_view()
    child.lua([[
        local git = require('iter.git')
        local model = require('iter.diff.model')
        local View = require('iter.diff.view')
        local change = { path = 'two.txt', side = 'unstaged', code = 'M' }
        local source = assert(git.file_diff(vim.fn.getcwd(), change))
        _G.view = View.new({ win = vim.api.nvim_get_current_win() })
        _G.view:show(model.build(change, source))
    ]])
end

---@return string[]
local function screen_lines()
    return vim.tbl_map(function(cells)
        return table.concat(cells)
    end, child.get_screenshot().text)
end

local T = new_set({
    hooks = {
        pre_case = function()
            create_two_hunk_repo()
            helpers.start_child(child, repo)
        end,
        post_case = function()
            child.stop()
            helpers.cleanup(repo)
        end,
    },
})

T['renders a two-hunk file with gaps'] = function()
    open_view()

    eq(child.api.nvim_get_current_buf(), child.lua_get('_G.view.buf'))
    eq(child.bo.buftype, 'nofile')
    eq(child.bo.modifiable, false)
    eq(child.api.nvim_buf_get_lines(0, 3, 6, false), {
        'line 97',
        'line 98',
        'line 99',
    })
    eq(child.v.errmsg, '')

    helpers.expect_screenshot(child, 'diff-view-two-hunks')
end

T['statuscolumn is blank on virtual lines'] = function()
    open_view()

    child.lua([[
        local ns = vim.api.nvim_create_namespace('iter.test')
        vim.api.nvim_buf_set_extmark(_G.view.buf, ns, 3, 0, {
            virt_lines = { { { 'VIRTUAL', 'Comment' } } },
        })
    ]])
    child.cmd('redraw')

    local lines = screen_lines()
    local virtual, code

    for _, line in ipairs(lines) do
        if line:find('VIRTUAL', 1, true) then
            virtual = line
        elseif line:find('line 97', 1, true) then
            code = line
        end
    end

    neq(virtual, nil)
    neq(code:match('^%s*97%s+97%s+line 97'), nil)

    local rail = virtual:sub(1, virtual:find('VIRTUAL', 1, true) - 1)
    eq(rail:match('^%s*$') ~= nil, true)
end

T['expand reveals a gap under the cursor'] = function()
    open_view()

    -- The gap between the hunks hides 104..116, fewer lines than one step.
    local gap_lnum = child.lua_get([[(function()
        for lnum, row in ipairs(_G.view.rows) do
            if row.kind == 'gap' and row.gap.new == 104 then
                return lnum
            end
        end
    end)()]])
    child.api.nvim_win_set_cursor(0, { gap_lnum, 0 })
    child.type_keys('<CR>')

    eq(child.api.nvim_win_get_cursor(0)[1], gap_lnum)
    eq(child.api.nvim_get_current_line(), 'line 104')
    eq(child.lua_get('_G.view.rows[' .. gap_lnum .. '].new'), 104)
    eq(child.api.nvim_buf_get_lines(0, gap_lnum + 11, gap_lnum + 13, false), {
        'line 116',
        '@@ -117,7 +117,7 @@ line 116',
    })
    eq(child.lua_get('_G.view:row(' .. gap_lnum .. ').kind'), 'context')
end

T['IterDiff groups follow the colorscheme'] = function()
    open_view()

    local function hl(name, link)
        return child.api.nvim_get_hl(0, { name = name, link = link })
    end

    local default_add = hl('IterDiffAdd', false).bg
    neq(default_add, nil)
    eq(hl('IterDiffGap', true).link, 'Folded')

    child.cmd('colorscheme habamax')
    neq(hl('IterDiffAdd', false).bg, nil)
    neq(hl('IterDiffAdd', false).bg, default_add)
    eq(hl('IterDiffGap', true).link, 'Folded')

    -- Blended 60 % towards Normal: 0x33 * 0.6 = 0x1e.
    child.lua([[
        vim.cmd('highlight clear')
        vim.api.nvim_set_hl(0, 'Normal', { fg = 0xffffff, bg = 0x000000 })
        vim.api.nvim_set_hl(0, 'DiffAdd', { bg = 0x003300 })
        vim.api.nvim_set_hl(0, 'DiffDelete', {})
        vim.api.nvim_exec_autocmds('ColorScheme', {})
    ]])
    eq(hl('IterDiffAdd', false).bg, 0x001e00)
    eq(hl('IterDiffAddText', false).bg, 0x003300)

    -- Without a DiffDelete background a fallback still gives one.
    neq(hl('IterDiffDelete', false).bg, nil)

    -- Transparent Normal: rows take DiffAdd whole, words mix in 40 % of the
    -- sign colour: 0xff * 0.4 + 0x33 * 0.6 = 0x84.
    child.lua([[
        vim.api.nvim_set_hl(0, 'Normal', { fg = 0xffffff })
        vim.api.nvim_set_hl(0, 'diffAdded', { fg = 0x00ff00 })
        vim.api.nvim_exec_autocmds('ColorScheme', {})
    ]])
    eq(hl('IterDiffAdd', false).bg, 0x003300)
    eq(hl('IterDiffAddNr', false).bg, 0x003300)
    eq(hl('IterDiffAddText', false).bg, 0x008400)
end

--- Every window-local option value of the current window.
local GET_WINOPTS = [[(function()
    local values = {}
    for name, info in pairs(vim.api.nvim_get_all_options_info()) do
        if info.scope == 'win' and name ~= 'scroll' then
            values[name] = vim.api.nvim_get_option_value(name, { win = 0 })
        end
    end
    return values
end)()]]

local function borrow_user_window()
    helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'other' })
    child.cmd('edit two.txt')
    child.lua([[
        vim.wo.number = true
        vim.wo.relativenumber = true
        vim.wo.signcolumn = 'yes'
        vim.wo.foldcolumn = '1'
        vim.wo.statuscolumn = '%l '
        vim.wo.wrap = false
        vim.wo.list = true
        vim.wo.spell = true
        vim.wo.cursorline = true
        vim.wo.colorcolumn = '80'
    ]])

    local original = child.lua_get(GET_WINOPTS)
    local user_buf = child.api.nvim_get_current_buf()

    open_view()

    eq(child.wo.number, false)
    eq(child.wo.signcolumn, 'no')
    neq(child.wo.statuscolumn, '%l ')

    return original, user_buf
end

T['borrowed window'] = new_set()

T['borrowed window']['gets its options back on close()'] = function()
    local original, user_buf = borrow_user_window()

    child.lua('_G.view:close()')

    eq(child.api.nvim_get_current_buf(), user_buf)
    eq(child.lua_get(GET_WINOPTS), original)

    child.cmd('enew')
    eq(child.lua_get(GET_WINOPTS), original)
end

T['borrowed window']['gets its options back on :edit'] = function()
    local original = borrow_user_window()

    child.cmd('edit other.txt')

    eq(child.lua_get(GET_WINOPTS), original)
end

T['borrowed window']['gets its options back on :bwipeout'] = function()
    local original, user_buf = borrow_user_window()

    child.cmd('bwipeout ' .. child.lua_get('_G.view.buf'))

    eq(child.api.nvim_get_current_buf(), user_buf)
    eq(child.lua_get(GET_WINOPTS), original)
end

T['borrowed window']['a split of the view drops them on another buffer'] = function()
    for _, command in ipairs({ 'edit other.txt', 'enew', 'buffer two.txt' }) do
        local original = borrow_user_window()

        child.cmd('split')
        eq(child.wo.signcolumn, 'no')
        child.cmd(command)
        eq(child.lua_get(GET_WINOPTS), original)

        child.cmd('only')
        child.lua('_G.view:close()')
    end
end

return T
