local M = {}

---@class IterChange: IterDiffChange one drawer item
---@field dir? boolean nested repository, path ends with `/`

---@class IterChanges
---@field root string
---@field branch string 'HEAD' when detached
---@field unstaged IterChange[] sorted by path, untracked included
---@field staged IterChange[]
---@field base? IterChange[] the changes since `since`, sorted by path, in a review against a base
---@field since? IterChangesBase

---@class IterChangesBase what a review against a base compares with
---@field kind 'branch'|'commit'|'rev' a branch's merge-base, a picked commit's parent, or a typed ref's commit
---@field sha string the resolved base commit or tree
---@field label string the branch, the ref as typed, or the short sha of a picked commit or a typed sha

--- The name of the base `spec`: the branch, the ref as typed, or the short
--- sha of a picked commit or of a typed sha.
---@param spec IterBaseSpec
---@return string
function M.base_label(spec)
    if spec.kind ~= 'branch' and vim.startswith(spec.sha, spec.ref or '') then
        return spec.sha:sub(1, 7)
    end

    return spec.ref
end

--- How the review names `since`: `since main (a1b2c3d)` for a branch with
--- its merge-base, `since v1.0 (a1b2c3d)` for a typed ref with its commit,
--- and `from a1b2c3d` for a picked commit, which the review includes.
---@param since IterChangesBase
---@return string
function M.base_text(since)
    if since.kind == 'commit' then
        return 'from ' .. since.label
    elseif since.kind == 'rev' and vim.startswith(since.sha, since.label) then
        return 'since ' .. since.label
    end

    return string.format('since %s (%s)', since.label, since.sha:sub(1, 7))
end

--- The title of the column of the changes since `since`: `Since main`,
--- `Since v1.0` or `From a1b2c3d`.
---@param since IterChangesBase
---@return string
function M.base_title(since)
    return (since.kind == 'commit' and 'From ' or 'Since ') .. since.label
end

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
        unstaged = unstaged,
        staged = staged,
    }
end

--- The items of `git diff -M --name-status -z` output, of `side`, in the
--- order git lists them, each recorded in `listed` by path.
---@param output string
---@param side IterSide
---@param listed table<string, boolean>
---@return IterChange[]
local function name_status(output, side, listed)
    local items = {}
    local fields = vim.split(output, '\0', { plain = true })
    local index = 1

    while fields[index] ~= nil and fields[index] ~= '' do
        local code = fields[index]:sub(1, 1)
        local orig_path

        if is_rename_or_copy(code) then
            orig_path = fields[index + 1]
            index = index + 1
        end

        local path = fields[index + 1]

        index = index + 2

        if path ~= nil then
            listed[path] = true
            table.insert(items, change(path, side, code, orig_path))
        end
    end

    return items
end

---@param a IterChange
---@param b IterChange
---@return boolean
local function by_path(a, b)
    return a.path < b.path
end

--- The changes since `base` from `git diff -M --name-status -z <base>`
--- and the untracked entries of `entries`, sorted by path. A path the diff
--- lists keeps its diff entry over an untracked one.
---@param output string
---@param base string resolved base sha
---@param entries GitStatusEntry[]
---@return IterChange[]
function M.since(output, base, entries)
    local listed = {}
    local items = name_status(output, 'base', listed)

    for _, entry in ipairs(entries) do
        if entry.staged == '?' and not listed[entry.path] then
            table.insert(items, change(entry.path, 'base', '?'))
        end
    end

    for _, item in ipairs(items) do
        item.base = base
    end

    table.sort(items, by_path)

    return items
end

--- The changes from `base` to `head` from
--- `git diff -M --name-status -z <base> <head>`, sorted by path.
---@param output string
---@param base string commit or tree
---@param head string commit
---@return IterChange[]
function M.between(output, base, head)
    local items = name_status(output, 'commit', {})

    for _, item in ipairs(items) do
        item.base = base
        item.head = head
    end

    table.sort(items, by_path)

    return items
end

--- The changed paths, Unstaged then Staged, then those since the base, a
--- path on several sides once.
---@param result IterChanges
---@return string[]
function M.paths(result)
    local paths, seen = {}, {}

    for _, list in ipairs({ result.unstaged, result.staged, result.base or {} }) do
        for _, item in ipairs(list) do
            if not seen[item.path] then
                seen[item.path] = true
                table.insert(paths, item.path)
            end
        end
    end

    return paths
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
