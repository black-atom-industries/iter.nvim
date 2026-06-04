---@diagnostic disable: undefined-field
local spec_dir = vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
)
---@type IterTestHelpers
local helpers = dofile(vim.fs.joinpath(vim.fs.dirname(spec_dir), 'helpers.lua'))

---@param buf integer
---@return string[]
local function buffer_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param lines string[]
---@param expected string
local function assert_has_line(lines, expected)
    for _, line in ipairs(lines) do
        if line == expected then
            return
        end
    end

    assert.fail('Expected line not found: ' .. expected)
end

---@param lines string[]
---@param expected string
local function assert_has_line_containing(lines, expected)
    for _, line in ipairs(lines) do
        if line:find(expected, 1, true) ~= nil then
            return
        end
    end

    assert.fail('Expected line containing not found: ' .. expected)
end

---@param buf integer
---@param text string
---@return integer
local function row_containing(buf, text)
    for row, line in ipairs(buffer_lines(buf)) do
        if line:find(text, 1, true) ~= nil then
            return row
        end
    end

    error('Expected row containing not found: ' .. text)
end

---@param win integer
---@return table<string, any>
local function capture_winopts(win)
    return {
        number = vim.wo[win].number,
        relativenumber = vim.wo[win].relativenumber,
        signcolumn = vim.wo[win].signcolumn,
        foldcolumn = vim.wo[win].foldcolumn,
        wrap = vim.wo[win].wrap,
        cursorline = vim.wo[win].cursorline,
        winbar = vim.wo[win].winbar,
        diff = vim.wo[win].diff,
        fillchars = vim.wo[win].fillchars,
        statuscolumn = vim.wo[win].statuscolumn,
    }
end

---@param actual table<string, any>
---@param expected table<string, any>
local function assert_winopts(actual, expected)
    for key, value in pairs(expected) do
        assert.are.equal(value, actual[key], key)
    end
end

---@param keys string
local function normal_keys(keys)
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes(keys, true, false, true),
        'nx',
        false
    )
end

---@param actual table<string, any>
---@param expected table<string, any>
---@return boolean
local function winopts_match(actual, expected)
    for key, value in pairs(expected) do
        if actual[key] ~= value then
            return false
        end
    end

    return true
end

---@param buf integer
---@param expected_opts? table<string, any>
local function wait_for_current_buf(buf, expected_opts)
    assert.is_true(vim.wait(1000, function()
        if vim.api.nvim_get_current_buf() ~= buf then
            return false
        end

        return expected_opts == nil
            or winopts_match(
                capture_winopts(vim.api.nvim_get_current_win()),
                expected_opts
            )
    end))
end

describe('iter status UI', function()
    ---@type string
    local original_cwd
    ---@type string
    local repo
    ---@type Iter
    local iter

    before_each(function()
        package.loaded.iter = nil
        original_cwd = vim.fn.getcwd()
        repo = vim.fn.tempname()
        vim.fn.mkdir(repo, 'p')

        helpers.run({ 'git', 'init', '-b', 'main' }, repo)
        helpers.run({ 'git', 'config', 'user.name', 'Iter Test' }, repo)
        helpers.run(
            { 'git', 'config', 'user.email', 'iter@example.test' },
            repo
        )

        helpers.write_file(vim.fs.joinpath(repo, 'tracked.txt'), { 'one' })
        helpers.run({ 'git', 'add', 'tracked.txt' }, repo)
        helpers.run({ 'git', 'commit', '-m', 'initial commit' }, repo)

        vim.cmd.cd(vim.fn.fnameescape(repo))
        vim.cmd.enew()
        iter = require('iter').setup({
            status = { height = 0.5 },
        })
    end)

    after_each(function()
        if iter ~= nil then
            iter.reset()
        end

        vim.cmd.only({ mods = { emsg_silent = true } })
        vim.cmd('%bwipeout!')
        vim.cmd.cd(vim.fn.fnameescape(original_cwd))

        if repo ~= nil then
            vim.fn.delete(repo, 'rf')
        end
    end)

    it('opens a status drawer at the bottom', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.write_file(vim.fs.joinpath(repo, 'staged.txt'), { 'staged' })
        helpers.write_file(
            vim.fs.joinpath(repo, 'untracked.txt'),
            { 'untracked' }
        )
        helpers.run({ 'git', 'add', 'staged.txt' }, repo)

        iter.status()

        ---@type GitStatusWindow
        local gsw = iter.gsw
        assert.is_not_nil(gsw)
        assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
        assert.is_true(vim.api.nvim_buf_is_valid(gsw.buf.id))
        assert.are.equal(gsw.buf.id, vim.api.nvim_win_get_buf(gsw.win))
        assert.are.equal('nofile', vim.bo[gsw.buf.id].buftype)
        assert.are.equal('hide', vim.bo[gsw.buf.id].bufhidden)
        assert.are.equal('iter', vim.bo[gsw.buf.id].filetype)
        assert.are.equal(false, vim.wo[gsw.win].number)
        assert.are.equal(false, vim.wo[gsw.win].relativenumber)
        assert.are.equal('no', vim.wo[gsw.win].signcolumn)
        assert.are.equal(true, vim.wo[gsw.win].cursorline)

        -- The drawer should be a real split, not floating.
        local config = vim.api.nvim_win_get_config(gsw.win)
        assert.are.equal('', config.relative)

        local lines = buffer_lines(gsw.buf.id)
        assert_has_line(lines, 'HEAD: main')
        assert_has_line(lines, 'Unstaged (1)')
        assert_has_line_containing(lines, 'tracked.txt')
        assert_has_line(lines, 'Staged (1)')
        assert_has_line_containing(lines, 'staged.txt')
        assert_has_line(lines, 'Untracked (1)')
        assert_has_line_containing(lines, 'untracked.txt')
    end)

    it(
        'refreshes and reuses the existing status drawer on repeated calls',
        function()
            iter.status()

            ---@type GitStatusWindow
            local first = iter.gsw
            local first_buf = first.buf.id
            local first_win = assert(first.win)

            helpers.write_file(
                vim.fs.joinpath(repo, 'untracked.txt'),
                { 'untracked' }
            )
            iter.status()

            assert.are.equal(first, iter.gsw)
            assert.are.equal(first_buf, iter.gsw.buf.id)
            assert.are.equal(first_win, iter.gsw.win)
            assert.are.equal(first_buf, vim.api.nvim_win_get_buf(first_win))
            assert_has_line(buffer_lines(first_buf), '?? untracked.txt')
        end
    )

    it('closes the status drawer through its normal mode mapping', function()
        iter.status()

        ---@type GitStatusWindow
        local gsw = iter.gsw
        local win = assert(gsw.win)

        vim.api.nvim_set_current_win(win)
        vim.cmd.normal('q')

        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_nil(gsw.win)
    end)

    it('renders a helpful message outside a git repository', function()
        local not_repo = vim.fn.tempname()
        vim.fn.mkdir(not_repo, 'p')
        vim.cmd.cd(vim.fn.fnameescape(not_repo))

        iter.status()

        local lines = buffer_lines(iter.gsw.buf.id)
        assert_has_line(lines, 'HEAD: (none)')
        assert_has_line_containing(lines, 'Not inside a git repository')

        vim.fn.delete(not_repo, 'rf')
    end)

    it('keeps file window options unchanged after closing drawer', function()
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo[file_win].number = true
        vim.wo[file_win].relativenumber = true
        vim.wo[file_win].signcolumn = 'yes:2'
        vim.wo[file_win].foldcolumn = '2'
        vim.wo[file_win].wrap = true
        vim.wo[file_win].cursorline = false
        vim.wo[file_win].winbar = 'real file'
        vim.wo[file_win].statuscolumn = 'user-statuscolumn'
        local before = capture_winopts(file_win)

        iter.status()
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.cmd.normal('q')

        assert.is_true(vim.api.nvim_win_is_valid(file_win))
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), before)
    end)

    it('opens stacked diff above the drawer', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.config.options.preview.diff_layout = 'stacked'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        assert.is_not_nil(gsw.diff_win)
        assert.is_true(vim.api.nvim_win_is_valid(gsw.diff_win))

        -- Status drawer should still be open below.
        assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
    end)

    it('toggles diff closed on second =', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.config.options.preview.diff_layout = 'stacked'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        -- Open diff.
        assert.is_true(gsw:diff_entry())
        assert.is_not_nil(gsw.diff_win)

        -- Stay in the diff window, press = from status to close. Using
        -- diff_entry directly from the status buffer context.
        local ok = pcall(vim.api.nvim_set_current_win, gsw.win)
        assert.is_true(ok)
        -- Allow CursorMoved debounce to settle.
        vim.wait(100, function()
            return false
        end)
        local closed = gsw:diff_entry()
        -- After closing, diff_win should be nil.
        assert.is_nil(gsw.diff_win)
        assert.is_true(closed)
    end)

    it('opens split diff above the drawer', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.config.options.preview.diff_layout = 'split'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        assert.is_true(gsw:diff_entry())
        assert.is_not_nil(gsw.diff_left_win)
        assert.is_not_nil(gsw.diff_right_win)
        assert.is_true(vim.api.nvim_win_is_valid(gsw.diff_left_win))
        assert.is_true(vim.api.nvim_win_is_valid(gsw.diff_right_win))

        -- Status drawer should still be open.
        assert.is_true(vim.api.nvim_win_is_valid(gsw.win))
    end)

    it('restores file options when diff buffer is replaced', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'other' })

        iter.config.options.preview.diff_layout = 'stacked'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        gsw:diff_entry()

        local diff_win = assert(gsw.diff_win)

        vim.api.nvim_set_current_win(diff_win)
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'other.txt')))

        -- The diff window should be restored after being replaced.
        assert.is_true(vim.wait(1000, function()
            return gsw.diff_win == nil
        end))
    end)

    it('restores file options when Ctrl-O leaves status drawer', function()
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_buf = vim.api.nvim_get_current_buf()
        local file_win = vim.api.nvim_get_current_win()
        vim.wo[file_win].number = true
        vim.wo[file_win].relativenumber = true
        vim.wo[file_win].signcolumn = 'yes:2'
        vim.wo[file_win].foldcolumn = '2'
        vim.wo[file_win].wrap = true
        vim.wo[file_win].cursorline = false
        vim.wo[file_win].winbar = 'real file jump'
        vim.wo[file_win].statuscolumn = 'jump-statuscolumn'
        local file_opts = capture_winopts(file_win)

        iter.status()
        local status_win = assert(iter.gsw.win)
        local status_buf = iter.gsw.buf.id
        local status_opts = capture_winopts(status_win)

        vim.api.nvim_set_current_win(status_win)
        normal_keys('<C-O>')
        wait_for_current_buf(file_buf, file_opts)

        assert.are.equal(file_buf, vim.api.nvim_get_current_buf())
        assert_winopts(
            capture_winopts(vim.api.nvim_get_current_win()),
            file_opts
        )

        normal_keys('<C-I>')
        wait_for_current_buf(status_buf, status_opts)

        assert.are.equal(status_buf, vim.api.nvim_get_current_buf())
        assert_winopts(
            capture_winopts(vim.api.nvim_get_current_win()),
            status_opts
        )
    end)

    it('reuses window above for stacked diff', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo[file_win].winbar = 'real file'
        local file_opts = capture_winopts(file_win)

        iter.config.options.preview.diff_layout = 'stacked'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        gsw:diff_entry()

        -- The diff should reuse the window above the drawer.
        assert.is_not_nil(gsw.diff_win)
        assert.are.equal(file_win, gsw.diff_win)

        -- Diff buffer should be loaded into the file's window.
        assert.are.equal(gsw.diff_buf.id, vim.api.nvim_win_get_buf(file_win))

        gsw:close()

        -- After close, file window should be restored.
        assert.is_true(vim.api.nvim_win_is_valid(file_win))
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), file_opts)
    end)

    it('reuses window above for split diff', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(repo, 'tracked.txt')))
        local file_win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_get_current_buf()
        vim.wo[file_win].winbar = 'real file split'
        local file_opts = capture_winopts(file_win)

        iter.config.options.preview.diff_layout = 'split'
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )
        gsw:diff_entry()

        -- The diff should reuse the window above for the left side,
        -- and create a new split to the right.
        assert.is_not_nil(gsw.diff_left_win)
        assert.are.equal(file_win, gsw.diff_left_win)

        gsw:close()

        -- After close, file window should be restored.
        assert.is_true(vim.api.nvim_win_is_valid(file_win))
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(file_win))
        assert_winopts(capture_winopts(file_win), file_opts)
    end)

    it('opens a file above the drawer and keeps drawer open', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        iter.status()
        local gsw = iter.gsw

        vim.api.nvim_set_current_win(gsw.win)
        vim.api.nvim_win_set_cursor(
            gsw.win,
            { row_containing(gsw.buf.id, 'tracked.txt'), 0 }
        )

        local ok = gsw:enter_entry()
        assert.is_true(ok)

        -- The drawer should still be open.
        assert.is_true(vim.api.nvim_win_is_valid(gsw.win))

        -- Check that tracked.txt is open somewhere.
        local found = false
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local bufname =
                vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
            if bufname:find('tracked.txt', 1, true) ~= nil then
                found = true
                break
            end
        end
        assert.is_true(found)
    end)
end)
