---@class IterAnchor
---@field path? string           nil for scope 'review'
---@field side 'old'|'new'
---@field base? 'HEAD'|'index'   old side: version the deleted line came from
---@field start_line? integer
---@field end_line? integer
---@field lines? string[]        anchored text, for re-anchoring and export

---@class IterComment
---@field id string
---@field scope 'line'|'range'|'file'|'review'
---@field anchor IterAnchor
---@field body string
---@field outdated boolean
---@field created_at integer
---@field updated_at integer

---@alias IterAnchorVersion 'worktree'|'HEAD'|'index'

local M = {}

---@param line string
---@return string
local function strip_cr(line)
    return (line:gsub('\r$', ''))
end

---@param lines string[]
---@param at integer
---@param block string[]
---@return boolean
local function matches_at(lines, at, block)
    for i, line in ipairs(block) do
        local other = lines[at + i - 1]

        if other == nil or strip_cr(other) ~= strip_cr(line) then
            return false
        end
    end

    return true
end

--- An anchor on `lines`, the version the anchor follows: the worktree file
--- for the new side, `base` for the old side. Without `start_line` it is a
--- file or review anchor and carries no text.
---@param opts { path?: string, side: 'old'|'new', base?: 'HEAD'|'index', start_line?: integer, end_line?: integer }
---@param lines? string[]
---@return IterAnchor
function M.create(opts, lines)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.side', opts.side, function(side)
        return side == 'old' or side == 'new'
    end, "'old' or 'new'")

    if opts.side == 'old' then
        vim.validate('opts.base', opts.base, function(base)
            return base == 'HEAD' or base == 'index'
        end, "'HEAD' or 'index'")
    end

    ---@type IterAnchor
    local a = { path = opts.path, side = opts.side, base = opts.base }

    if opts.start_line == nil then
        return a
    end

    vim.validate('lines', lines, 'table')

    local start = opts.start_line
    local stop = opts.end_line or start
    a.start_line = start
    a.end_line = stop
    a.lines = vim.list_slice(lines, start, stop)

    return a
end

--- The version whose lines an anchor follows when it is persisted.
---@param a IterAnchor
---@return IterAnchorVersion
function M.version(a)
    if a.side == 'old' then
        return a.base or 'HEAD'
    end

    return 'worktree'
end

--- Where the anchored text sits in `lines`: at the stored position when it is
--- still there, else at the match nearest to it, the upper one on a tie.
--- Nil when the text is gone or the anchor has none.
---@param a IterAnchor
---@param lines? string[]
---@return integer? start
---@return integer? end
function M.resolve(a, lines)
    local block = a.lines

    if lines == nil or block == nil or #block == 0 then
        return nil
    end

    local stored = a.start_line or 1
    local count = #block

    if matches_at(lines, stored, block) then
        return stored, stored + count - 1
    end

    local best

    for at = 1, #lines - count + 1 do
        if
            matches_at(lines, at, block)
            and (best == nil or math.abs(at - stored) < math.abs(best - stored))
        then
            best = at
        end
    end

    if best == nil then
        return nil
    end

    return best, best + count - 1
end

--- The comment with its anchor moved to where `lines` has the text, or marked
--- outdated at its old position when the text is gone. File and review
--- comments have no text to lose. `comment` itself is left untouched.
---@param comment IterComment
---@param lines? string[]
---@return IterComment
---@return boolean changed
function M.follow(comment, lines)
    if comment.scope == 'file' or comment.scope == 'review' then
        return comment, false
    end

    local a = comment.anchor
    local start, stop = M.resolve(a, lines)

    if start == nil then
        if comment.outdated then
            return comment, false
        end

        local result = vim.deepcopy(comment)
        result.outdated = true
        return result, true
    end

    if
        not comment.outdated
        and start == a.start_line
        and stop == a.end_line
    then
        return comment, false
    end

    local result = vim.deepcopy(comment)
    result.outdated = false
    result.anchor.start_line = start
    result.anchor.end_line = stop
    return result, true
end

return M
