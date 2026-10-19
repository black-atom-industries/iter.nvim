---@class IterAnchor
---@field path? string           nil for scope 'review'
---@field side 'old'|'new'
---@field base? IterAnchorBase   old side: version the deleted line came from
---@field start_line? integer
---@field end_line? integer
---@field lines? string[]        anchored text, for re-anchoring and export

---@class IterAnnotation
---@field id string
---@field scope 'line'|'range'|'file'|'review'
---@field anchor IterAnchor
---@field body string
---@field outdated boolean
---@field created_at integer
---@field updated_at integer

--- `merge-base` is the merge-base of the review's base branch and HEAD,
--- resolved when the anchor is placed, so it follows the current base.
---@alias IterAnchorBase 'HEAD'|'index'|'merge-base'

---@alias IterAnchorVersion 'worktree'|IterAnchorBase

-- Valid values of an old-side anchor's `base`.
local BASES = { HEAD = true, index = true, ['merge-base'] = true }

local M = {}

--- The version the deleted rows of each diff side come from, as an
--- old-side anchor's `base`.
---@type table<IterSide, IterAnchorBase>
M.OLD_BASE = { unstaged = 'index', staged = 'HEAD', branch = 'merge-base' }

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
---@param opts { path?: string, side: 'old'|'new', base?: IterAnchorBase, start_line?: integer, end_line?: integer }
---@param lines? string[]
---@return IterAnchor
function M.create(opts, lines)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.side', opts.side, function(side)
        return side == 'old' or side == 'new'
    end, "'old' or 'new'")

    if opts.side == 'old' then
        vim.validate('opts.base', opts.base, function(base)
            return BASES[base] == true
        end, "'HEAD', 'index' or 'merge-base'")
    end

    ---@type IterAnchor
    local a = { path = opts.path, side = opts.side, base = opts.base }

    if opts.start_line == nil then
        return a
    end

    vim.validate('lines', lines, 'table')
    ---@cast lines string[]

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

--- The annotation with its anchor moved to where `lines` has the text, or marked
--- outdated at its old position when the text is gone. File and review
--- annotations have no text to lose. `annotation` itself is left untouched.
---@param annotation IterAnnotation
---@param lines? string[]
---@return IterAnnotation
---@return boolean changed
function M.follow(annotation, lines)
    if annotation.scope == 'file' or annotation.scope == 'review' then
        return annotation, false
    end

    local a = annotation.anchor
    local start, stop = M.resolve(a, lines)

    if start == nil then
        if annotation.outdated then
            return annotation, false
        end

        local result = vim.deepcopy(annotation)
        result.outdated = true
        return result, true
    end

    if
        not annotation.outdated
        and start == a.start_line
        and stop == a.end_line
    then
        return annotation, false
    end

    local result = vim.deepcopy(annotation)
    result.outdated = false
    result.anchor.start_line = start
    result.anchor.end_line = stop
    return result, true
end

return M
