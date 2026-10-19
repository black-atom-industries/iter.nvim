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

    -- The old version keeps lines 8 and 9 inside the long string opened on
    -- line 3, which the gap above the hunk hides; the new version closes it
    -- on line 8. The blank added line shows the add background on an empty
    -- row.
    local code_old = {
        'local M = {}',
        '',
        'local doc = [[',
        'one',
        'two',
        'three',
        'four',
        'five',
        ']]',
        '',
        'function M.total(items)',
        '  local count = 0',
        '  for _, item in ipairs(items) do',
        '    count = count + item.size',
        '  end',
        '  return count',
        'end',
        '',
        'return M',
    }

    repo = helpers.create_repo({ ['two.txt'] = lines, ['code.lua'] = code_old })

    lines[100] = 'line one hundred'
    lines[120] = 'line one hundred twenty'
    helpers.write_file(vim.fs.joinpath(repo, 'two.txt'), lines)

    local code_new = vim.list_slice(code_old, 1, 7)
    vim.list_extend(code_new, {
        'five]]',
        "local fresh = 'new line'",
        '',
        'function M.total(items)',
        "  local count = 'one'",
        '  for _, item in ipairs(items) do',
        '    count = count + item.weight',
        '  end',
        '',
        '  return count',
        'end',
        '',
        'return M',
    })
    helpers.write_file(vim.fs.joinpath(repo, 'code.lua'), code_new)
end

-- Lua source of the view options the default config gives.
local VIEW_OPTIONS = [[(function()
    local config = require('iter.config').resolve({})
    local diff = config.options.diff
    return {
        keys = config.keys.diff,
        expand_step = diff.expand_step,
        syntax_max_lines = diff.syntax_max_lines,
        word_diff = diff.word_diff,
        icon = config.options.icons.annotation,
    }
end)()]]

--- Open an IterDiffView on `path` (two.txt by default) in the child's
--- current window as `_G.view`, with `opts` (Lua table source) merged into
--- the view options.
---@param path? string
---@param opts? string
local function open_view(path, opts)
    child.lua([[
        local path, opts = ...
        local git = require('iter.git')
        local model = require('iter.diff.model')
        local View = require('iter.diff.view')
        local change = { path = path, side = 'unstaged', code = 'M' }
        local source = assert(git.file_diff(vim.fn.getcwd(), change, {}))
        _G.view = View.new(vim.tbl_extend('force', {
            win = vim.api.nvim_get_current_win(),
        }, ]] .. VIEW_OPTIONS .. [[, loadstring('return ' .. opts)()))
        _G.view:show(model.build(change, source))
    ]], { path or 'two.txt', opts or '{}' })
end

--- Wait until the view's syntax for its last render is applied.
local function wait_decorated()
    helpers.wait_until(child, '_G.view.decorated == _G.view.generation')
end

--- Extmarks of namespace `name` in the view buffer by buffer line (string
--- key): `{ text, hl_group }` with the text each mark covers.
---@param name string
---@return table<string, string[][]>
local function marks(name)
    return child.lua_get(
        [[(function(name)
        local ns = vim.api.nvim_create_namespace(name)
        local buf = _G.view.buf
        local result = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
            buf, ns, 0, -1, { details = true }
        )) do
            local row, col, details = mark[2], mark[3], mark[4]
            local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, true)[1]
            local key = tostring(row + 1)
            result[key] = result[key] or {}
            table.insert(result[key], {
                line:sub(col + 1, details.end_col),
                details.hl_group,
            })
        end
        return result
    end)(...)]],
        { name }
    )
end

--- The buffer line (string key) of the row of `kind` showing `text`.
---@param text string
---@param kind string
---@return string
local function lnum_of(text, kind)
    return tostring(child.lua_get(
        [[(function(text, kind)
        for lnum, row in ipairs(_G.view.rows) do
            if row.text == text and row.kind == kind then
                return lnum
            end
        end
    end)(...)]],
        { text, kind }
    ))
end

--- Sorted groups of the marks in `list` that cover exactly `text`.
---@param list? string[][]
---@param text string
---@return string[]
local function groups_on(list, text)
    local groups = {}

    for _, mark in ipairs(list or {}) do
        if mark[1] == text then
            table.insert(groups, mark[2])
        end
    end

    table.sort(groups)
    return groups
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

--- Text of the header row's right-aligned marks.
---@return string
local function header_text()
    return child.lua_get([[(function()
        local ns = vim.api.nvim_create_namespace('iter.diff')
        local parts = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(_G.view.buf, ns, 0, 0, { details = true })) do
            if mark[4].virt_text_pos == 'right_align' then
                for _, chunk in ipairs(mark[4].virt_text) do
                    table.insert(parts, chunk[1])
                end
            end
        end
        return table.concat(parts)
    end)()]])
end

T['the header shows a mode change'] = function()
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'code.lua'), tonumber('755', 8))
    helpers.git(repo, { 'checkout', '--', 'code.lua' })
    vim.uv.fs_chmod(vim.fs.joinpath(repo, 'code.lua'), tonumber('755', 8))
    open_view('code.lua')

    eq(header_text(), 'mode 100644 → 100755  +0 −0 ')

    open_view()
    eq(header_text(), '+2 −2 ')
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

T['syntax and words'] = new_set()

T['syntax and words']['del rows read the old version, the rest the new'] = function()
    open_view('code.lua')
    wait_decorated()

    local syn = marks('iter.diff.syntax')

    -- Inside the string the old version still holds open.
    eq(groups_on(syn[lnum_of('five', 'del')], 'five'), { '@string.lua' })
    eq(groups_on(syn[lnum_of(']]', 'del')], ']]'), { '@string.lua' })

    -- The same line numbers in the new version are code.
    local fresh = syn[lnum_of("local fresh = 'new line'", 'add')]
    eq(groups_on(fresh, 'local'), { '@keyword.lua' })
    eq(groups_on(fresh, "'new line'"), { '@string.lua' })

    -- Context from the new version, inside the string opened in the gap.
    eq(groups_on(syn[lnum_of('two', 'context')], 'two'), { '@string.lua' })

    local added = syn[lnum_of("  local count = 'one'", 'add')]
    eq(groups_on(added, "'one'"), { '@string.lua' })
    eq(groups_on(added, 'local'), { '@keyword.lua' })
end

T['syntax and words']['changed words carry the emphasis'] = function()
    open_view('code.lua')
    wait_decorated()

    local w = marks('iter.diff.words')

    eq(w[lnum_of('  local count = 0', 'del')], {
        { '0', 'IterDiffDeleteText' },
    })
    eq(w[lnum_of("  local count = 'one'", 'add')], {
        { "'one'", 'IterDiffAddText' },
    })
    eq(w[lnum_of('    count = count + item.weight', 'add')], {
        { 'weight', 'IterDiffAddText' },
    })
    eq(w[lnum_of('five]]', 'add')], { { ']]', 'IterDiffAddText' } })
    eq(w[lnum_of('five', 'del')], nil)

    -- The word groups set only a background, so syntax colours stay.
    local text = child.api.nvim_get_hl(0, { name = 'IterDiffAddText' })
    eq(text.fg, nil)
    neq(text.bg, nil)
end

T['syntax and words']['shows syntax and word emphasis'] = function()
    open_view('code.lua')
    wait_decorated()

    helpers.expect_screenshot(child, 'diff-view-lua-syntax')
end

T['syntax and words']['a version above the size cap gets no syntax'] = function()
    -- The old version has 19 lines, the new one 20.
    open_view('code.lua', '{ syntax_max_lines = 19 }')
    wait_decorated()

    local syn = marks('iter.diff.syntax')
    eq(groups_on(syn[lnum_of(']]', 'del')], ']]'), { '@string.lua' })
    eq(syn[lnum_of('two', 'context')], nil)
    eq(syn[lnum_of("  local count = 'one'", 'add')], nil)

    open_view('code.lua', '{ syntax_max_lines = 18 }')
    wait_decorated()
    eq(marks('iter.diff.syntax'), {})
    neq(marks('iter.diff.words'), {})
end

T['syntax and words']['word_diff = false shows no emphasis'] = function()
    open_view('code.lua', '{ word_diff = false }')
    wait_decorated()

    eq(marks('iter.diff.words'), {})
    neq(marks('iter.diff.syntax'), {})
end

T['syntax and words']['a stale render generation is ignored'] = function()
    child.lua([[
        _G.requests = {}
        require('iter.diff.syntax').request = function(_, _, lnums, callback)
            table.insert(_G.requests, { lnums = lnums, callback = callback })
        end
        _G.answer = function(from, to)
            for i = from, to do
                local request = _G.requests[i]
                local spans = {}
                for _, lnum in ipairs(request.lnums) do
                    spans[lnum] = {
                        { col = 0, end_col = 1, hl = 1, priority = 100 },
                    }
                end
                request.callback(spans)
            end
        end
    ]])
    open_view('code.lua')
    eq(child.lua_get('#_G.requests'), 2)

    -- Render again, then answer the first render's requests.
    child.lua('_G.view:render()')
    eq(child.lua_get('#_G.requests'), 4)
    child.lua('_G.answer(1, 2)')

    eq(marks('iter.diff.syntax'), {})
    neq(child.lua_get('_G.view.decorated'), child.lua_get('_G.view.generation'))

    child.lua('_G.answer(3, 4)')

    neq(marks('iter.diff.syntax'), {})
    eq(child.lua_get('_G.view.decorated'), child.lua_get('_G.view.generation'))
end

T['syntax and words']['emphasis follows its rows when a gap expands'] = function()
    open_view()

    local function expected()
        return child.lua_get([[(function()
            local result = {}
            for lnum, row in ipairs(_G.view.rows) do
                if row.words ~= nil then
                    table.insert(result, lnum)
                end
            end
            return result
        end)()]])
    end

    local function actual()
        local result = {}

        for key in pairs(marks('iter.diff.words')) do
            table.insert(result, tonumber(key))
        end

        table.sort(result)
        return result
    end

    local before = expected()
    eq(#before > 0, true)
    eq(actual(), before)

    -- Reveal 20 lines of the gap above the first hunk.
    child.lua('_G.view:expand(2)')

    local after = expected()
    eq(
        after,
        vim.tbl_map(function(lnum)
            return lnum + 20
        end, before)
    )
    eq(actual(), after)
    eq(
        child.lua_get(
            '_G.view.rows[_G.view.rows[' .. after[1] .. '].pair].text'
        ),
        'line one hundred'
    )
end

--- Open a view on `change` as `_G.view`. `source_patch` (Lua source of a
--- function taking the source) may change the git source before the model.
---@param change table
---@param source_patch? string
local function open_change(change, source_patch)
    child.lua([[
        local change, patch = ...
        local git = require('iter.git')
        local model = require('iter.diff.model')
        local View = require('iter.diff.view')
        local source = assert(git.file_diff(vim.fn.getcwd(), change, {}))
        if patch ~= '' then
            loadstring('return ' .. patch)()(source)
        end
        _G.view = View.new(vim.tbl_extend('force', {
            win = vim.api.nvim_get_current_win(),
        }, ]] .. VIEW_OPTIONS .. [[))
        _G.view:show(model.build(change, source))
    ]], { change, source_patch or '' })
end

--- Replace `syntax.request` so the test answers each request itself.
local function capture_requests()
    child.lua([[
        _G.requests = {}
        require('iter.diff.syntax').request = function(_, _, lnums, callback)
            table.insert(_G.requests, { lnums = lnums, callback = callback })
        end
    ]])
end

T['syntax and words']['a closed view ignores a parse that finishes later'] = function()
    capture_requests()
    open_view('code.lua')
    eq(child.lua_get('#_G.requests'), 2)

    child.lua('_G.view:close()')
    child.cmd('enew')
    child.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c' })
    child.lua([[
        for _, request in ipairs(_G.requests) do
            local spans = {}
            for _, lnum in ipairs(request.lnums) do
                spans[lnum] = {
                    { col = 0, end_col = 1, hl = 1, priority = 100 },
                }
            end
            request.callback(spans)
        end
    ]])

    eq(child.v.errmsg, '')
    eq(child.lua_get([[#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {})]]), 0)
end

T['syntax and words']['a parse timeout renders without syntax'] = function()
    child.lua([[
        require('iter.diff.syntax').request = function(_, _, _, callback)
            callback(nil)
        end
    ]])
    open_view('code.lua')

    eq(child.lua_get('_G.view.decorated'), child.lua_get('_G.view.generation'))
    eq(marks('iter.diff.syntax'), {})
    neq(marks('iter.diff.words'), {})
    eq(child.v.errmsg, '')
end

T['syntax and words']['a renamed file reads old-side syntax from orig_path'] = function()
    helpers.git(repo, { 'mv', 'code.lua', 'code.txt' })
    helpers.git(repo, { 'add', 'code.txt' })

    open_change({
        path = 'code.txt',
        orig_path = 'code.lua',
        side = 'staged',
        code = 'R',
    })
    wait_decorated()

    local syn = marks('iter.diff.syntax')
    eq(groups_on(syn[lnum_of(']]', 'del')], ']]'), { '@string.lua' })
    eq(syn[lnum_of("  local count = 'one'", 'add')], nil)
    eq(syn[lnum_of('two', 'context')], nil)
end

T['syntax and words']['a hunk-only file renders without syntax'] = function()
    open_change(
        { path = 'code.lua', side = 'unstaged', code = 'M' },
        'function(source) source.new_lines = { "mismatch" } end'
    )
    wait_decorated()

    eq(child.lua_get('_G.view.files[1].new_lines'), vim.NIL)
    eq(marks('iter.diff.syntax'), {})
    neq(marks('iter.diff.words'), {})
    eq(child.v.errmsg, '')
end

T['syntax and words']['injected languages get their own captures'] = function()
    if not child.lua_get('vim.treesitter.language.add("vim") == true') then
        MiniTest.skip('No bundled vim parser')
    end

    helpers.write_file(vim.fs.joinpath(repo, 'inj.lua'), {
        'local x = 1',
        'vim.cmd("set number")',
    })
    open_change({ path = 'inj.lua', side = 'unstaged', code = '?' })
    wait_decorated()

    local groups = vim.tbl_map(function(mark)
        return mark[2]
    end, marks('iter.diff.syntax')[lnum_of('vim.cmd("set number")', 'add')])

    eq(vim.tbl_contains(groups, '@string.lua'), true)
    eq(#vim.tbl_filter(function(group)
        return vim.endswith(group, '.vim')
    end, groups) > 0, true)
end

return T
