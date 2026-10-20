local git = require('iter.git')
local store = require('iter.store')
local util = require('iter.util')

---@alias IterReviewedState 'reviewed'|'changed'|'unreviewed'

---@class IterReviewedSummary
---@field reviewed integer
---@field changed integer
---@field total integer

---@class IterReviewedCacheEntry
---@field stat string worktree stat the hash was taken at
---@field hash? string

local M = {}

local DELETED = 'deleted'

-- Hashes by root and path. A file is hashed again only when its stat
-- (mtime, size) differs from the one its cached hash was taken at.
---@type table<string, table<string, IterReviewedCacheEntry>>
local cache = {}

--- `git hash-object` of one file, for the paths a batch can't carry or the
--- batch failed on.
---@param root string
---@param path string
---@return string?
local function hash_one(root, path)
    local out = git.run(
        { 'hash-object', '--', path },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil
    end

    return vim.trim(out.output)
end

--- `git hash-object --stdin-paths` of every path in one process. A path
--- with a newline can't go through stdin, and a batch where one file fails
--- gives no hashes; those are hashed one by one.
---@param root string
---@param paths string[]
---@return table<string, string>
local function hash_batch(root, paths)
    local hashes = {}
    local batch = {}

    for _, path in ipairs(paths) do
        if not path:find('\n', 1, true) then
            table.insert(batch, path)
        end
    end

    if #batch > 0 then
        local out = git.run({ 'hash-object', '--stdin-paths' }, {
            cwd = root,
            ignore_error = true,
            stdin = table.concat(batch, '\n') .. '\n',
        })
        local lines = vim.split(out.output, '\n', { trimempty = true })

        if out.exit_code == 0 and #lines == #batch then
            for i, path in ipairs(batch) do
                hashes[path] = lines[i]
            end
        end
    end

    for _, path in ipairs(paths) do
        if hashes[path] == nil then
            hashes[path] = hash_one(root, path)
        end
    end

    return hashes
end

--- The content hash of every path in the worktree of `root`: git's
--- `hash-object`, or `deleted` for a missing file. A path whose hash can't
--- be taken is left out.
---@param root string
---@param paths string[]
---@param fresh? boolean hash again whatever the cache holds
---@return table<string, string>
function M.hashes(root, paths, fresh)
    cache[root] = cache[root] or {}
    local entries = cache[root]
    local hashes, stale, stats = {}, {}, {}

    for _, path in ipairs(paths) do
        local stat = util.stat_key(vim.fs.joinpath(root, path))
        local entry = entries[path]

        if stat == nil then
            hashes[path] = DELETED
            entries[path] = { stat = '', hash = DELETED }
        elseif not fresh and entry ~= nil and entry.stat == stat then
            hashes[path] = entry.hash
        else
            table.insert(stale, path)
            stats[path] = stat
        end
    end

    if #stale > 0 then
        for path, hash in pairs(hash_batch(root, stale)) do
            hashes[path] = hash
            entries[path] = { stat = stats[path], hash = hash }
        end
    end

    return hashes
end

---@param record? IterReviewed
---@param hash? string
---@return IterReviewedState
local function state_of(record, hash)
    if record == nil then
        return 'unreviewed'
    end

    return record.hash == hash and 'reviewed' or 'changed'
end

--- The state of every path: reviewed when its record's hash is the worktree
--- hash, changed when it differs, unreviewed without a record. The cache
--- keeps only `paths` afterwards.
---@param root string
---@param paths string[]
---@param records table<string, IterReviewed>
---@return table<string, IterReviewedState>
function M.states(root, paths, records)
    local hashes = M.hashes(root, paths)
    local states, kept = {}, {}

    for _, path in ipairs(paths) do
        states[path] = state_of(records[path], hashes[path])
        kept[path] = cache[root][path]
    end

    cache[root] = kept

    return states
end

--- Mark `path` reviewed at its current content, or unreviewed when it is
--- reviewed already. The state is the one the file has now.
---@param root string
---@param path string
---@return IterReviewedState? state
---@return string? error
function M.toggle(root, path)
    local hash = M.hashes(root, { path }, true)[path]

    if hash == nil then
        return nil, 'Cannot hash ' .. path
    end

    local state

    local _, err = store.update(root, function(data)
        local record = data.reviewed[path]

        if record ~= nil and record.hash == hash then
            data.reviewed[path] = nil
            state = 'unreviewed'
        else
            data.reviewed[path] = { hash = hash, at = os.time() }
            state = 'reviewed'
        end
    end)

    if err ~= nil then
        return nil, err
    end

    return state
end

---@param states table<string, IterReviewedState>
---@return IterReviewedSummary
function M.summary(states)
    local summary = { reviewed = 0, changed = 0, total = 0 }

    for _, state in pairs(states) do
        summary.total = summary.total + 1

        if state == 'reviewed' then
            summary.reviewed = summary.reviewed + 1
        elseif state == 'changed' then
            summary.changed = summary.changed + 1
        end
    end

    return summary
end

return M
