--- The statusline part outside the review tab: `<branch> · <n>`, n the
--- changed files, from a cache per repository root. Drawer refreshes fill
--- it; so do background reads on the first call for a root and, after
--- `setup()`, on writes, focus, directory changes and shell commands.
--- Reading the part never runs git.

local changes = require('iter.changes')
local git = require('iter.git')

local M = {}

-- Milliseconds an event waits, so a burst of events reads once.
local DEBOUNCE_MS = 100

-- Per resolved root: the part, or false while its first read runs.
---@type table<string, string|false>
local parts = {}
-- Per path a root lookup starts from: the resolved root, false outside one.
---@type table<string, string|false>
local roots = {}
-- Roots with a read running, and roots waiting out the debounce.
---@type table<string, true>
local reading, waiting = {}, {}

---@param path string
---@return string
local function resolve(path)
    return vim.uv.fs_realpath(path) or path
end

--- Cache the part of `result`'s root.
---@param result IterChanges
---@return boolean changed
function M.update(result)
    local branch = result.branch == 'HEAD' and '(detached)' or result.branch
    local root = resolve(result.root)
    local part = string.format('%s · %d', branch, #changes.paths(result))
    local changed = parts[root] ~= part

    parts[root] = part

    return changed
end

--- The worktree root of `buf`'s file, else of the current directory,
--- without running git; looked up once per path.
---@param buf integer
---@return string?
local function root_of(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local start = (vim.bo[buf].buftype == '' and name ~= '') and name
        or vim.fn.getcwd()

    if roots[start] == nil then
        local root = vim.fs.root(start, '.git')

        roots[start] = root and resolve(root) or false
    end

    return roots[start] or nil
end

--- Read the status of `root` in the background unless a read runs, then
--- cache it and redraw the statuslines when the part changed. A failed read
--- forgets the root, so the next call reads again.
---@param root string
local function read(root)
    if reading[root] then
        return
    end

    reading[root] = true
    git.status_async(root, function(snapshot)
        reading[root] = nil

        if snapshot.error ~= nil then
            if parts[root] == false then
                parts[root] = nil
            end

            return
        end

        if M.update(changes.build(snapshot)) then
            vim.cmd.redrawstatus({ bang = true })
        end
    end)
end

--- The cached part of the statusline window's repository, `''` outside a
--- repository or before the first read of its root completes.
---@return string
function M.get()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
        or vim.api.nvim_get_current_buf()
    local root = root_of(buf)

    if root == nil then
        return ''
    end

    local part = parts[root]

    if part == nil then
        parts[root] = false
        read(root)
    end

    return part or ''
end

--- Read the status of the current buffer's repository again on writes,
--- focus, directory changes and shell commands, a burst once.
function M.setup()
    local group = vim.api.nvim_create_augroup('iter.statusline', {})

    vim.api.nvim_create_autocmd({
        'BufWritePost',
        'FocusGained',
        'DirChanged',
        'ShellCmdPost',
        'TermClose',
    }, {
        group = group,
        callback = function(args)
            if args.event == 'DirChanged' or args.event == 'FocusGained' then
                roots = {}
            end

            local buf = vim.api.nvim_buf_is_valid(args.buf) and args.buf
                or vim.api.nvim_get_current_buf()
            local root = root_of(buf)

            if root == nil or waiting[root] then
                return
            end

            waiting[root] = true
            vim.defer_fn(function()
                waiting[root] = nil
                read(root)
            end, DEBOUNCE_MS)
        end,
    })
end

return M
