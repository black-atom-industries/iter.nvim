local log = require('flux.log')
local git = require('flux.git')
local common = require('flux.ui.status.common')

local M = {}

---@class GitStatusWindowOptions
---@field number boolean
---@field relativenumber boolean
---@field signcolumn string
---@field foldcolumn string
---@field wrap boolean
---@field cursorline boolean
---@field winbar string
---@field diff boolean
---@field fillchars string
---@field statuscolumn string
---@field winfixheight boolean

---@param opts FluxStatusOptions
---@return integer
function M.status_win_height(opts)
    return math.max(math.floor(vim.o.lines * opts.height), 1)
end

---@param entry GitStatusEntry
---@return string
local function entry_path(entry)
    local root = git.root()

    if root == '' then
        return vim.fn.fnamemodify(entry.path, ':p')
    end

    return vim.fs.normalize(vim.fs.joinpath(root, entry.path))
end

---@param win number
function M.configure_status_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixheight = true
end

---@param buf Buffer
---@param opts FluxStatusOptions
---@return number, GitStatusWindowOptions
function M.create_status_win(buf, opts)
    local height = M.status_win_height(opts)

    vim.cmd('botright ' .. height .. 'split')

    local win = vim.api.nvim_get_current_win()
    local prev_winopts = M.capture_winopts(win)

    vim.api.nvim_win_set_buf(win, buf.id)
    vim.api.nvim_set_current_win(win)
    M.configure_status_win(win)

    log.info(string.format('created status window win=%d buf=%d', win, buf.id))

    return win, prev_winopts
end

---@param status_win number?
---@return number?
function M.find_window_above(status_win)
    -- Find the window immediately above the status drawer, if any.
    if status_win == nil or not common.is_valid_win(status_win) then
        return nil
    end

    -- Navigate up from the status window.
    local current = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(status_win)
    pcall(vim.cmd, 'wincmd k')
    local above = vim.api.nvim_get_current_win()

    if above ~= status_win then
        return above
    end

    -- Restore focus if we didn't move.
    if common.is_valid_win(current) then
        pcall(vim.api.nvim_set_current_win, current)
    end

    return nil
end

---@param entry GitStatusEntry
---@param status_win number?
---@return boolean
function M.open_entry(entry, status_win)
    local path = entry_path(entry)

    if vim.uv.fs_stat(path) == nil then
        log.error('Cannot open missing worktree path: ' .. path)
        vim.notify(
            '[flux] Cannot open missing worktree path: ' .. entry.path,
            vim.log.levels.WARN
        )
        return false
    end

    -- Find or create a window above the status drawer.
    local target = M.find_window_above(status_win)

    if target == nil then
        vim.cmd('aboveleft split')
        target = vim.api.nvim_get_current_win()
    else
        vim.api.nvim_set_current_win(target)
    end

    local current_path = vim.fs.normalize(
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target))
    )

    if current_path ~= path then
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
    end

    return true
end

---@param win number
function M.configure_diff_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
end

---@param win number
function M.configure_split_diff_win(win)
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'yes:1'
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].statuscolumn = '%l %s '
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.api.nvim_win_call(win, function()
        local fc = vim.opt_local.fillchars:get()
        fc.diff = ' '
        vim.opt_local.fillchars = fc
    end)
end

---@param win number
---@return GitStatusWindowOptions
function M.capture_winopts(win)
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
        winfixheight = vim.wo[win].winfixheight,
    }
end

---@param win number
---@param opts GitStatusWindowOptions?
function M.restore_winopts(win, opts)
    if opts == nil or not common.is_valid_win(win) then
        return
    end

    vim.wo[win].number = opts.number
    vim.wo[win].relativenumber = opts.relativenumber
    vim.wo[win].signcolumn = opts.signcolumn
    vim.wo[win].foldcolumn = opts.foldcolumn
    vim.wo[win].wrap = opts.wrap
    vim.wo[win].cursorline = opts.cursorline
    vim.wo[win].winbar = opts.winbar
    vim.wo[win].diff = opts.diff
    vim.wo[win].fillchars = opts.fillchars
    vim.wo[win].statuscolumn = opts.statuscolumn
    vim.wo[win].winfixheight = opts.winfixheight
end

return M
