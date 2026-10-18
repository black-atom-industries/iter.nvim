local git = require('iter.git')

local M = {}

---@class IterChange: IterDiffChange one drawer item
---@field dir? boolean untracked directory, path ends with `/`
---@field expanded? boolean
---@field children? IterChange[]

---@class IterChanges
---@field root string
---@field branch string 'HEAD' when detached
---@field ahead? integer
---@field unstaged IterChange[] untracked last
---@field staged IterChange[]

local conflicts = {
    AA = true,
    AU = true,
    DD = true,
    DU = true,
    UA = true,
    UD = true,
    UU = true,
}

---@param code string
---@return boolean
local function is_rename_or_copy(code)
    return code == 'R' or code == 'C'
end

---@param path string
---@param side IterSide
---@param code string
---@param orig_path? string
---@return IterChange
local function change(path, side, code, orig_path)
    ---@type IterChange
    local item = { path = path, side = side, code = code }

    if orig_path ~= nil and is_rename_or_copy(code) then
        item.orig_path = orig_path
    end

    if code == '?' and vim.endswith(path, '/') then
        item.dir = true
    end

    return item
end

--- Unstaged and Staged lists from a status snapshot. A partly staged file is
--- on both sides, a conflict once under Unstaged with code `U`, and untracked
--- paths come last. Untracked directories stay collapsed.
---@param snapshot GitStatusSnapshot
---@return IterChanges
function M.build(snapshot)
    local tracked, untracked, staged = {}, {}, {}

    for _, entry in ipairs(snapshot.entries) do
        local x, y = entry.staged, entry.unstaged

        if conflicts[x .. y] then
            table.insert(
                tracked,
                change(entry.path, 'unstaged', 'U', entry.orig_path)
            )
        elseif x == '?' then
            table.insert(untracked, change(entry.path, 'unstaged', '?'))
        elseif x ~= '!' then
            if x ~= ' ' then
                table.insert(
                    staged,
                    change(entry.path, 'staged', x, entry.orig_path)
                )
            end

            if y ~= ' ' then
                table.insert(
                    tracked,
                    change(entry.path, 'unstaged', y, entry.orig_path)
                )
            end
        end
    end

    vim.list_extend(tracked, untracked)

    return {
        root = snapshot.root,
        branch = snapshot.detached and 'HEAD' or snapshot.branch,
        ahead = snapshot.ahead,
        unstaged = tracked,
        staged = staged,
    }
end

--- Fill an untracked directory with its untracked files; ignored files are
--- never listed.
---@param root string
---@param item IterChange
---@return boolean expanded false when `item` is not an untracked directory
function M.expand(root, item)
    if not item.dir then
        return false
    end

    local files = git.untracked_files(root, item.path) or {}
    item.children = vim.tbl_map(function(path)
        return change(path, 'unstaged', '?')
    end, files)
    item.expanded = true

    return true
end

---@param item IterChange
function M.collapse(item)
    item.expanded = false
end

--- The exact paths an action on `item` touches. An untracked directory is
--- listed afresh, so stale children never widen or narrow a stage or discard.
---@param root string
---@param item IterChange
---@return string[]
function M.files(root, item)
    if not item.dir then
        return { item.path }
    end

    return git.untracked_files(root, item.path) or {}
end

--- Cut `path` from the left to at most `width` display cells, marking the cut
--- with `…`.
---@param path string
---@param width integer
---@return string
function M.truncate(path, width)
    if vim.fn.strdisplaywidth(path) <= width then
        return path
    end

    if width <= 0 then
        return ''
    end

    local starts = vim.str_utf_pos(path)
    local used = 1
    local from = #path + 1

    for i = #starts, 1, -1 do
        local char = path:sub(starts[i], from - 1)
        local w = vim.fn.strdisplaywidth(char)

        if used + w > width then
            break
        end

        used = used + w
        from = starts[i]
    end

    return '…' .. path:sub(from)
end

return M
