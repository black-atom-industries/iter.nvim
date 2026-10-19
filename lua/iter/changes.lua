local M = {}

---@class IterChange: IterDiffChange one drawer item
---@field dir? boolean nested repository, path ends with `/`

---@class IterChanges
---@field root string
---@field branch string 'HEAD' when detached
---@field ahead? integer
---@field unstaged IterChange[] sorted by path, untracked included
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
--- files sit among the other unstaged paths.
---@param snapshot GitStatusSnapshot
---@return IterChanges
function M.build(snapshot)
    local unstaged, staged = {}, {}

    for _, entry in ipairs(snapshot.entries) do
        local x, y = entry.staged, entry.unstaged

        if conflicts[x .. y] then
            table.insert(
                unstaged,
                change(entry.path, 'unstaged', 'U', entry.orig_path)
            )
        elseif x == '?' then
            table.insert(unstaged, change(entry.path, 'unstaged', '?'))
        elseif x ~= '!' then
            if x ~= ' ' then
                table.insert(
                    staged,
                    change(entry.path, 'staged', x, entry.orig_path)
                )
            end

            if y ~= ' ' then
                table.insert(
                    unstaged,
                    change(entry.path, 'unstaged', y, entry.orig_path)
                )
            end
        end
    end

    table.sort(unstaged, function(a, b)
        return a.path < b.path
    end)

    return {
        root = snapshot.root,
        branch = snapshot.detached and 'HEAD' or snapshot.branch,
        ahead = snapshot.ahead,
        unstaged = unstaged,
        staged = staged,
    }
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
