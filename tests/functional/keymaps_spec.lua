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

---@param buf integer
---@param lhs string
---@return boolean
local function has_keymap(buf, lhs)
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    for _, map in ipairs(maps) do
        if map.lhs == lhs then
            return true
        end
    end
    return false
end

---@param buf integer
---@param lhs string
---@return boolean
local function keymap_has_nowait(buf, lhs)
    local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
    for _, map in ipairs(maps) do
        if map.lhs == lhs then
            return map.nowait == 1
        end
    end
    return false
end

describe('iter keymaps', function()
    local original_cwd
    local repo
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
            status = { width = 0.5, min_width = 20 },
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

    it('status buffer has expected keymaps after open', function()
        iter.status()

        local buf = iter.gsw.buf.id
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
        assert.is_true(has_keymap(buf, '='))
        assert.is_true(has_keymap(buf, 'q'))
        assert.is_true(has_keymap(buf, 's'))
        assert.is_true(has_keymap(buf, 'u'))
        assert.is_true(has_keymap(buf, '<CR>'))
        assert.is_true(has_keymap(buf, 'r'))
    end)

    it('status keymaps survive close and reopen', function()
        iter.status()
        local buf = iter.gsw.buf.id

        -- Close via q mapping
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.cmd.normal('q')

        -- Reopen
        iter.status()
        local new_buf = iter.gsw.buf.id
        assert.are.equal(buf, new_buf)
        assert.is_true(has_keymap(new_buf, '='))
        assert.is_true(has_keymap(new_buf, 'q'))
        assert.is_true(has_keymap(new_buf, 's'))
    end)

    it('status keymaps survive open diff then close diff', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.status()
        local status_buf = iter.gsw.buf.id

        -- Open diff via = mapping
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        -- Diff buffer should exist and have keymaps
        assert.is_not_nil(iter.gsw.diff_buf)
        local diff_buf = iter.gsw.diff_buf.id
        assert.is_true(vim.api.nvim_buf_is_valid(diff_buf))
        assert.is_true(has_keymap(diff_buf, 'q'))
        assert.is_true(has_keymap(diff_buf, 's'))
        assert.is_true(has_keymap(diff_buf, 'u'))

        -- Close diff via q mapping
        vim.api.nvim_set_current_win(iter.gsw.diff_win)
        vim.cmd.normal('q')

        -- Status keymaps still present
        assert.is_true(has_keymap(status_buf, '='))
        assert.is_true(has_keymap(status_buf, 'q'))

        -- Re-open diff on same entry
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        -- Diff should be open again with keymaps
        assert.is_not_nil(iter.gsw.diff_buf)
        assert.is_true(vim.api.nvim_buf_is_valid(iter.gsw.diff_buf.id))
        assert.is_true(has_keymap(iter.gsw.diff_buf.id, 'q'))
    end)

    it('status keymaps survive opening a file from status', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.status()
        local status_buf = iter.gsw.buf.id
        local status_win = iter.gsw.win

        -- Open entry via API
        iter.gsw:enter_entry()

        -- We should now be in the tracked.txt file buffer
        local file_buf = vim.api.nvim_get_current_buf()
        local expected_path =
            vim.fn.resolve(vim.fs.joinpath(repo, 'tracked.txt'))
        local actual_path = vim.fn.resolve(vim.api.nvim_buf_get_name(file_buf))
        assert.are.equal(expected_path, actual_path)

        -- Switch back to status window
        vim.api.nvim_set_current_win(status_win)

        -- Status keymaps still present
        assert.is_true(has_keymap(status_buf, '='))
        assert.is_true(has_keymap(status_buf, 'q'))

        -- Can open diff
        vim.api.nvim_win_set_cursor(
            status_win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        -- Verify diff opened
        assert.is_not_nil(iter.gsw.diff_buf)
        assert.is_true(vim.api.nvim_buf_is_valid(iter.gsw.diff_buf.id))
    end)

    it('status keymaps survive open/close toggle', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.status()
        local status_buf = iter.gsw.buf.id

        -- First press: open diff
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        assert.is_not_nil(iter.gsw.diff_win)
        assert.is_true(vim.api.nvim_win_is_valid(iter.gsw.diff_win))

        -- Second press: close diff (toggle)
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.cmd.normal('=')

        -- Status keymaps intact
        assert.is_true(has_keymap(status_buf, '='))
        assert.is_true(has_keymap(status_buf, 'q'))

        -- Third press: re-open diff
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        assert.is_not_nil(iter.gsw.diff_win)
        assert.is_true(vim.api.nvim_win_is_valid(iter.gsw.diff_win))
    end)

    it('help buffer opens with q and closes', function()
        iter.status()

        -- Open help via ?
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.cmd.normal('?')

        assert.is_not_nil(iter.gsw.help_win)
        assert.is_true(vim.api.nvim_win_is_valid(iter.gsw.help_win))
        assert.is_true(has_keymap(iter.gsw.help_buf.id, 'q'))

        -- Close help via q
        vim.api.nvim_set_current_win(iter.gsw.help_win)
        vim.cmd.normal('q')

        -- Status window should be back in focus with keymaps
        assert.is_not_nil(iter.gsw.win)
        assert.is_true(vim.api.nvim_win_is_valid(iter.gsw.win))
        assert.is_true(has_keymap(iter.gsw.buf.id, '?'))
    end)

    it('diff keymaps survive switching windows and coming back', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )
        helpers.write_file(vim.fs.joinpath(repo, 'other.txt'), { 'other' })
        helpers.run({ 'git', 'add', 'other.txt' }, repo)

        iter.status()
        local status_buf = iter.gsw.buf.id

        -- Open diff
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        local diff_win = iter.gsw.diff_win
        local diff_buf = iter.gsw.diff_buf.id
        assert.is_true(has_keymap(diff_buf, 'q'))
        assert.is_true(has_keymap(diff_buf, 's'))

        -- Switch back to status window
        vim.api.nvim_set_current_win(iter.gsw.win)

        -- Switch back to diff window
        vim.api.nvim_set_current_win(diff_win)

        -- Keymaps should still be on diff buffer
        assert.is_true(has_keymap(diff_buf, 'q'))
        assert.is_true(has_keymap(diff_buf, 's'))

        -- Close diff from diff buffer
        vim.cmd.normal('q')

        -- Status should be focused with keymaps
        assert.is_true(has_keymap(status_buf, '='))
    end)

    it(
        'status keymaps are restored via WinEnter after being cleared',
        function()
            iter.status()
            local status_buf = iter.gsw.buf.id

            -- Verify keymaps exist
            assert.is_true(has_keymap(status_buf, '='))
            assert.is_true(has_keymap(status_buf, '<C-]>'))

            -- Simulate keymaps being lost (e.g. by another plugin clearing them)
            pcall(vim.keymap.del, 'n', '=', { buffer = status_buf })
            pcall(vim.keymap.del, 'n', '<C-]>', { buffer = status_buf })
            assert.is_false(has_keymap(status_buf, '='))
            assert.is_false(has_keymap(status_buf, '<C-]>'))

            -- Navigate away and back to trigger WinEnter re-attachment
            vim.cmd.wincmd('w')
            vim.api.nvim_set_current_win(iter.gsw.win)

            -- Keymaps should be restored
            assert.is_true(has_keymap(status_buf, '='))
            assert.is_true(has_keymap(status_buf, '<C-]>'))
        end
    )

    it('status keymaps have nowait = true', function()
        iter.status()
        local status_buf = iter.gsw.buf.id

        assert.is_true(has_keymap(status_buf, '='))
        assert.is_true(keymap_has_nowait(status_buf, '='))
        assert.is_true(keymap_has_nowait(status_buf, '<C-]>'))
        assert.is_true(keymap_has_nowait(status_buf, 'q'))
        assert.is_true(keymap_has_nowait(status_buf, 's'))
    end)

    it(
        'status keymaps are re-attached after close_diff returns focus',
        function()
            helpers.write_file(
                vim.fs.joinpath(repo, 'tracked.txt'),
                { 'one', 'two' }
            )

            iter.status()
            local status_buf = iter.gsw.buf.id

            -- Open diff
            vim.api.nvim_set_current_win(iter.gsw.win)
            vim.api.nvim_win_set_cursor(
                iter.gsw.win,
                { row_containing(status_buf, 'tracked.txt'), 0 }
            )
            vim.cmd.normal('=')

            assert.is_not_nil(iter.gsw.diff_buf)
            local diff_buf = iter.gsw.diff_buf.id
            assert.is_true(vim.api.nvim_buf_is_valid(diff_buf))

            -- Clear status keymaps to simulate loss during diff operations
            pcall(vim.keymap.del, 'n', '=', { buffer = status_buf })
            pcall(vim.keymap.del, 'n', '<C-]>', { buffer = status_buf })
            assert.is_false(has_keymap(status_buf, '='))
            assert.is_false(has_keymap(status_buf, '<C-]>'))

            -- Close diff via q; close_diff should re-attach keymaps
            vim.api.nvim_set_current_win(iter.gsw.diff_win)
            vim.cmd.normal('q')

            -- Status keymaps should be restored after close_diff
            assert.is_true(has_keymap(status_buf, '='))
            assert.is_true(has_keymap(status_buf, '<C-]>'))
        end
    )

    it('diff keymaps have nowait = true', function()
        helpers.write_file(
            vim.fs.joinpath(repo, 'tracked.txt'),
            { 'one', 'two' }
        )

        iter.status()
        local status_buf = iter.gsw.buf.id

        -- Open diff
        vim.api.nvim_set_current_win(iter.gsw.win)
        vim.api.nvim_win_set_cursor(
            iter.gsw.win,
            { row_containing(status_buf, 'tracked.txt'), 0 }
        )
        vim.cmd.normal('=')

        assert.is_not_nil(iter.gsw.diff_buf)
        local diff_buf = iter.gsw.diff_buf.id
        assert.is_true(keymap_has_nowait(diff_buf, 'q'))
        assert.is_true(keymap_has_nowait(diff_buf, 's'))
        assert.is_true(keymap_has_nowait(diff_buf, 'u'))
    end)
end)
