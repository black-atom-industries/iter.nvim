---@class IterReviewed store.reviewed[path], store.reviewed_by_base[key][path]
---@field hash string git hash-object of the worktree file, 'deleted' when missing
---@field at integer

---@class IterStoreFile stdpath('data')/iter/<repo-id>/<branch>.json
---@field version 2
---@field annotations IterAnnotation[]
---@field reviewed table<string, IterReviewed>
---@field base? IterBaseSpec what the review compares with; absent for working changes
---@field reviewed_by_base? table<string, table<string, IterReviewed>> reviewed records by base key (`branch:<ref>`, `commit:<sha>`); working changes keep theirs in `reviewed`

local git = require('iter.git')
local util = require('iter.util')

local M = {}

local VERSION = 2

local id_count = 0

---@type table<string, true>
local newer_warned = {}

---@class IterStoreCache
---@field head_path? string
---@field head? string contents of `head_path` when `path` was resolved
---@field path? string
---@field stat? string stat of `path` when `data` was read, `''` when missing
---@field data IterStoreFile

---@type table<string, IterStoreCache>
local caches = {}

---@alias IterStoreChange fun(data: IterStoreFile): boolean?

-- A lock file older than this was left by an instance that died holding it.
local LOCK_STALE_MS = 10000
-- How long a write waits for another instance's lock before it queues.
local LOCK_WAIT_MS = 500

--- Changes a write couldn't make while another instance held the lock, by
--- store path, in order. The next write of that path makes them first.
---@type table<string, IterStoreChange[]>
local pending = {}

---@type table<string, true>
local lock_warned = {}

---@return IterStoreFile
local function empty()
    return { version = VERSION, annotations = {}, reviewed = {} }
end

---@param branch string
---@return string
local function encode_branch(branch)
    local encoded = branch:gsub('%%', '%%25')
    encoded = encoded:gsub('/', '%%2F')
    return encoded
end

---@param data any
---@return boolean
local function is_valid(data)
    if type(data) ~= 'table' or data.version ~= VERSION then
        return false
    end

    if
        type(data.annotations) ~= 'table' or not vim.islist(data.annotations)
    then
        return false
    end

    for _, annotation in ipairs(data.annotations) do
        if type(annotation) ~= 'table' or type(annotation.id) ~= 'string' then
            return false
        end
    end

    if type(data.reviewed) ~= 'table' then
        return false
    end

    for path, reviewed in pairs(data.reviewed) do
        if type(path) ~= 'string' or type(reviewed) ~= 'table' then
            return false
        end
    end

    return true
end

--- `base` when it is a base spec this iter reads, else nil.
---@param base any
---@return IterBaseSpec?
local function valid_base(base)
    if type(base) ~= 'table' then
        return nil
    elseif
        base.kind == 'branch'
        and type(base.ref) == 'string'
        and base.ref ~= ''
    then
        return { kind = 'branch', ref = base.ref }
    elseif
        base.kind == 'commit'
        and type(base.sha) == 'string'
        and base.sha:match('^%x+$') ~= nil
    then
        return { kind = 'commit', sha = base.sha }
    elseif
        base.kind == 'rev'
        and type(base.ref) == 'string'
        and base.ref ~= ''
        and type(base.sha) == 'string'
        and base.sha:match('^%x+$') ~= nil
    then
        return { kind = 'rev', ref = base.ref, sha = base.sha }
    end

    return nil
end

--- The reviewed records by base key in `by_base` this iter reads, nil
--- when none are left.
---@param by_base any
---@return table<string, table<string, IterReviewed>>?
local function valid_by_base(by_base)
    if type(by_base) ~= 'table' then
        return nil
    end

    local kept = {}

    for key, records in pairs(by_base) do
        if type(key) == 'string' and type(records) == 'table' then
            local valid = {}

            for path, record in pairs(records) do
                if type(path) == 'string' and type(record) == 'table' then
                    valid[path] = record
                end
            end

            if next(valid) ~= nil then
                kept[key] = valid
            end
        end
    end

    return next(kept) ~= nil and kept or nil
end

--- Rename a corrupt store file to `<name>.corrupt-<timestamp>`, with a
--- counter when that name is taken, so no earlier copy is overwritten.
---@param path string
---@return boolean? missing true when another instance moved it first
---@return string? error
local function set_aside(path)
    local base = path .. '.corrupt-' .. os.date('%Y%m%dT%H%M%S')
    local target = base
    local n = 1

    while vim.uv.fs_stat(target) ~= nil do
        n = n + 1
        target = base .. '-' .. n
    end

    local ok, err, name = vim.uv.fs_rename(path, target)

    if not ok then
        if name == 'ENOENT' then
            return true
        end

        return nil, err
    end

    util.warn(
        string.format(
            'The annotation store %s was corrupt and is kept as %s; starting empty',
            path,
            vim.fs.basename(target)
        )
    )

    return false
end

---@param path string
---@return IterStoreFile?
---@return string? error
local function read(path)
    local file, open_err = io.open(path, 'rb')

    if file == nil then
        if vim.uv.fs_stat(path) == nil then
            return empty()
        end

        return nil, open_err
    end

    local text = file:read('*a')
    file:close()

    local ok, data = pcall(
        vim.json.decode,
        text,
        { luanil = { object = true, array = true } }
    )

    if ok and is_valid(data) then
        -- A base this iter can't read means working changes; the
        -- annotations stay.
        data.base = valid_base(data.base)
        data.reviewed_by_base = valid_by_base(data.reviewed_by_base)
        return data
    end

    if
        ok
        and type(data) == 'table'
        and type(data.version) == 'number'
        and data.version > VERSION
    then
        if not newer_warned[path] then
            newer_warned[path] = true
            util.warn(
                string.format(
                    'The annotation store %s was written by a newer iter; leaving it untouched',
                    path
                )
            )
        end

        return nil, 'store written by a newer iter'
    end

    local _, err = set_aside(path)

    if err ~= nil then
        return nil, err
    end

    return empty()
end

--- Make the directory of the store file `path`.
---@param path string
---@return boolean? ok
---@return string? error
local function make_dir(path)
    local dir = vim.fs.dirname(path)
    local made, mkdir_err

    -- Another instance making a parent at the same time fails `mkdir()`
    -- there (E739) before it makes the rest; the next try goes on from it.
    for _ = 1, 3 do
        made, mkdir_err = pcall(vim.fn.mkdir, dir, 'p')

        if vim.fn.isdirectory(dir) == 1 then
            return true
        end
    end

    return nil,
        string.format(
            'Cannot create the annotation store directory %s: %s',
            dir,
            made and 'not a directory' or tostring(mkdir_err)
        )
end

--- Write through a temp file in the same directory, renamed into place.
---@param path string
---@param data IterStoreFile
---@return boolean? ok
---@return string? error
local function write(path, data)
    local encoded = vim.json.encode({
        version = data.version,
        annotations = data.annotations,
        reviewed = next(data.reviewed) == nil and vim.empty_dict()
            or data.reviewed,
        base = data.base,
        reviewed_by_base = data.reviewed_by_base,
    })

    local tmp =
        string.format('%s.tmp-%d-%d', path, vim.uv.os_getpid(), vim.uv.hrtime())

    local fd, err = vim.uv.fs_open(tmp, 'w', 420)

    if fd == nil then
        return nil, err
    end

    local written, write_err = vim.uv.fs_write(fd, encoded)
    vim.uv.fs_close(fd)

    if written == nil then
        vim.uv.fs_unlink(tmp)
        return nil, write_err
    end

    local ok, rename_err = vim.uv.fs_rename(tmp, path)

    if not ok then
        vim.uv.fs_unlink(tmp)
        return nil, rename_err
    end

    return true
end

--- Milliseconds since `stat`'s file was last modified.
---@param stat uv.fs_stat.result
---@return number
local function age_ms(stat)
    local now = vim.uv.clock_gettime('realtime')
    ---@cast now -nil

    return (now.sec - stat.mtime.sec) * 1000
        + (now.nsec - stat.mtime.nsec) / 1e6
end

--- Move a stale lock out of the way. The rename lets one instance take a
--- given lock file; one that turns out fresh, made by another instance
--- after the stat, goes back.
---@param lock_path string
---@param token string
local function take_stale(lock_path, token)
    local aside = lock_path .. '.stale-' .. token

    if not vim.uv.fs_rename(lock_path, aside) then
        return
    end

    local stat = vim.uv.fs_stat(aside)

    if stat ~= nil and age_ms(stat) < LOCK_STALE_MS then
        vim.uv.fs_link(aside, lock_path)
    end

    vim.uv.fs_unlink(aside)
end

--- Take the lock of the store file `path`: `<path>.lock`, created
--- exclusively and holding a token of this instance. A held lock is waited
--- for with backoff up to `wait_ms`; one older than `LOCK_STALE_MS` is taken
--- over, once per call.
---@param path string
---@param wait_ms integer
---@return string? token nil when another instance holds the lock or it can't be made
---@return string? error
---@return boolean? busy another instance holds the lock
local function lock(path, wait_ms)
    local lock_path = path .. '.lock'
    local token = string.format('%d-%d', vim.uv.os_getpid(), vim.uv.hrtime())
    local waited, delay = 0, 2
    local took_stale = false

    local made, dir_err = make_dir(path)

    if not made then
        return nil, dir_err
    end

    while true do
        local fd, err, name = vim.uv.fs_open(lock_path, 'wx', 420)

        if fd ~= nil then
            vim.uv.fs_write(fd, token)
            vim.uv.fs_close(fd)

            return token
        end

        if name ~= 'EEXIST' then
            return nil, err
        end

        local stat = vim.uv.fs_stat(lock_path)

        -- One takeover per call: a stale lock that can't be moved is waited
        -- for like a held one.
        if not took_stale and stat ~= nil and age_ms(stat) >= LOCK_STALE_MS then
            took_stale = true
            take_stale(lock_path, token)
        elseif waited >= wait_ms then
            return nil, 'held by another instance', true
        else
            vim.uv.sleep(delay)
            waited = waited + delay
            delay = math.min(delay * 2, 50)
        end
    end
end

--- Release the lock of `path` when it is still the one `token` took.
---@param path string
---@param token string
local function unlock(path, token)
    local lock_path = path .. '.lock'
    local file = io.open(lock_path, 'rb')

    if file == nil then
        return
    end

    local held = file:read('*a')
    file:close()

    if held == token then
        vim.uv.fs_unlink(lock_path)
    end
end

local flush_registered = false

--- Under the lock of `path`: read the file, make the pending changes and
--- `change`, and write it back when one of them changed it. Without the
--- lock `change` joins the pending ones and the result has them made in
--- memory. A failed read or write leaves `change` out of the pending ones,
--- since the caller sees the error.
---@param path string
---@param change? IterStoreChange
---@param wait_ms? integer how long a held lock is waited for, `LOCK_WAIT_MS` by default
---@return IterStoreFile?
---@return string? error
local function commit(path, change, wait_ms)
    local changes = vim.list_extend({}, pending[path] or {})

    if change ~= nil then
        table.insert(changes, change)
    end

    local token, lock_err, busy = lock(path, wait_ms or LOCK_WAIT_MS)
    local ok, data, err

    if token == nil and not busy then
        return nil, lock_err
    elseif token == nil then
        ok, data, err = pcall(read, path)

        if ok and data ~= nil then
            for _, fn in ipairs(changes) do
                fn(data)
            end

            pending[path] = changes

            if not lock_warned[path] then
                lock_warned[path] = true
                util.warn(
                    string.format(
                        'Cannot lock the annotation store (%s); the change is kept and saved with the next one',
                        lock_err
                    )
                )
            end

            if not flush_registered then
                flush_registered = true
                vim.api.nvim_create_autocmd('VimLeavePre', {
                    group = vim.api.nvim_create_augroup(
                        'iter.store',
                        { clear = true }
                    ),
                    callback = function()
                        if next(pending) == nil then
                            return
                        end

                        vim.api.nvim_echo({
                            {
                                'iter: waiting for the annotation store lock…',
                            },
                        }, false, {})
                        vim.cmd.redraw()

                        -- One deadline for every store: long enough for the
                        -- other instance's lock to go stale, so only a lock
                        -- still held then loses the changes.
                        local deadline = vim.uv.now()
                            + LOCK_STALE_MS
                            + LOCK_WAIT_MS

                        for queued in pairs(pending) do
                            vim.uv.update_time()
                            commit(
                                queued,
                                nil,
                                math.max(0, deadline - vim.uv.now())
                            )

                            if pending[queued] ~= nil then
                                util.error(
                                    string.format(
                                        'Lost %d annotation change(s): %s stayed locked',
                                        #pending[queued],
                                        queued
                                    )
                                )
                            end
                        end
                    end,
                })
            end
        end
    else
        ok, data, err = pcall(function()
            local current, read_err = read(path)

            if current == nil then
                return nil, read_err
            end

            local changed = false

            for _, fn in ipairs(changes) do
                if fn(current) ~= false then
                    changed = true
                end
            end

            if changed then
                local written, write_err = write(path, current)

                if not written then
                    return nil, write_err
                end
            end

            return current
        end)

        unlock(path, token)

        if ok and data ~= nil then
            pending[path] = nil
            lock_warned[path] = nil
        end
    end

    if not ok then
        error(data, 0)
    end

    return data, err
end

---@return string
local function new_id()
    id_count = id_count + 1

    return string.format(
        '%x-%x-%x',
        vim.uv.os_getpid(),
        vim.uv.hrtime(),
        id_count
    )
end

--- The store file of the repository and branch `root` is on now. Linked
--- worktrees share the directory; a detached HEAD uses `HEAD.json`.
---@param root string
---@return string? path
---@return string? error
function M.path(root)
    local id, err = git.repo_id(root)

    if id == nil then
        return nil, err ~= '' and err or 'Not inside a git repository'
    end

    local branch = git.head_branch(root)
    local name = branch ~= nil and encode_branch(branch) .. '.json'
        or 'HEAD.json'

    return vim.fs.joinpath(vim.fn.stdpath('data'), 'iter', id, name)
end

--- The stored annotations and reviewed records. A missing file reads as empty; a
--- corrupt one is renamed aside with a warning and reads as empty.
---@param root string
---@return IterStoreFile?
---@return string? error
function M.load(root)
    local path, err = M.path(root)

    if path == nil then
        return nil, err
    end

    return read(path)
end

--- `load` for a store file whose path the caller already resolved.
---@param path string
---@return IterStoreFile?
---@return string? error
function M.read(path)
    return read(path)
end

---@param path string
---@return string?
local function read_line(path)
    local file = io.open(path, 'r')

    if file == nil then
        return nil
    end

    local line = file:read('*l')
    file:close()

    return line
end

--- The HEAD file of the worktree at `root`, found without spawning git: in
--- `.git/`, or in the directory a `.git` file points to.
---@param root string
---@return string?
local function head_path(root)
    local dotgit = vim.fs.joinpath(root, '.git')
    local stat = vim.uv.fs_stat(dotgit)

    if stat == nil then
        return nil
    end

    if stat.type == 'directory' then
        return vim.fs.joinpath(dotgit, 'HEAD')
    end

    local gitdir = (read_line(dotgit) or ''):match('^gitdir: (.+)$')

    if gitdir == nil then
        return nil
    end

    if not vim.startswith(gitdir, '/') then
        gitdir = vim.fs.joinpath(root, gitdir)
    end

    return vim.fs.joinpath(gitdir, 'HEAD')
end

--- `load` through one cache per root, shared by every reader in this
--- instance. The store path is resolved again only when HEAD changed (on
--- every call without a `.git` at `root`), starting empty when it differs;
--- the file is read again only when its stat changed, or with `fresh`. A
--- failed read keeps what the cache holds. The result is shared: callers
--- never change it.
---@param root string
---@param fresh? boolean read the file whatever its stat says
---@return IterStoreFile
function M.cached(root, fresh)
    local cache = caches[root]

    if cache == nil then
        cache = { head_path = head_path(root), data = empty() }
        caches[root] = cache
    end

    local head = cache.head_path and read_line(cache.head_path)

    if cache.path == nil or cache.head_path == nil or head ~= cache.head then
        local path = M.path(root)

        if path ~= cache.path then
            cache.data = empty()
        end

        cache.path = path
        cache.head = head
        cache.stat = nil
    end

    if cache.path == nil then
        return cache.data
    end

    local stat = util.stat_key(cache.path) or ''

    if fresh or stat ~= cache.stat then
        local data = M.read(cache.path)

        if data ~= nil then
            cache.data = data
            cache.stat = stat
        end
    end

    local changes = pending[cache.path]

    if changes == nil then
        return cache.data
    end

    local copy = vim.deepcopy(cache.data)

    for _, fn in ipairs(changes) do
        fn(copy)
    end

    return copy
end

--- Re-read the store from disk, let `fn` change it in place, and write it
--- back, all under the store's lock file. Every write goes through here, so
--- changes apply by annotation id and path to what other instances wrote in
--- the meantime. When `fn` returns false, nothing is written. While another
--- instance holds the lock past a short wait, the change is kept in this
--- instance (`cached` shows it), a warning says so, and the next update of
--- the same file writes it first; the result is the store with the change
--- made, as if written.
---@param root string
---@param fn IterStoreChange
---@return IterStoreFile?
---@return string? error
function M.update(root, fn)
    local path, path_err = M.path(root)

    if path == nil then
        return nil, path_err
    end

    return commit(path, fn)
end

--- Add an annotation, or replace the stored one with the same id. A new annotation
--- gets its id and `created_at`; `updated_at` is set on every put.
---@param root string
---@param annotation IterAnnotation|{ id?: string, created_at?: integer, updated_at?: integer }
---@return IterAnnotation?
---@return string? error
function M.put_annotation(root, annotation)
    vim.validate('annotation', annotation, 'table')

    local saved = vim.deepcopy(annotation)
    local now = os.time()
    saved.id = saved.id or new_id()
    saved.created_at = saved.created_at or now
    saved.updated_at = now

    local _, err = M.update(root, function(data)
        for i, stored in ipairs(data.annotations) do
            if stored.id == saved.id then
                data.annotations[i] = saved
                return
            end
        end

        table.insert(data.annotations, saved)
    end)

    if err ~= nil then
        return nil, err
    end

    return saved
end

--- Replace the stored annotation with the same id, and only that: when another
--- instance deleted it meanwhile, nothing is written back.
---@param root string
---@param annotation IterAnnotation
---@return IterAnnotation? saved nil when the annotation no longer exists
---@return string? error
function M.edit_annotation(root, annotation)
    vim.validate('annotation', annotation, 'table')
    vim.validate('annotation.id', annotation.id, 'string')

    local saved = vim.deepcopy(annotation)
    saved.updated_at = os.time()
    local found = false

    local _, err = M.update(root, function(data)
        for i, stored in ipairs(data.annotations) do
            if stored.id == saved.id then
                saved.created_at = stored.created_at
                data.annotations[i] = saved
                found = true
                return true
            end
        end

        return false
    end)

    if err ~= nil then
        return nil, err
    end

    if not found then
        return nil, 'The annotation no longer exists'
    end

    return saved
end

---@param root string
---@param ids string[]
---@return IterStoreFile?
---@return string? error
function M.remove_annotations(root, ids)
    local remove = {}

    for _, id in ipairs(ids) do
        remove[id] = true
    end

    return M.update(root, function(data)
        data.annotations = vim.tbl_filter(function(annotation)
            return not remove[annotation.id]
        end, data.annotations)
    end)
end

--- Store the reviewed record of `path`, or drop it when `reviewed` is nil.
---@param root string
---@param path string
---@param reviewed IterReviewed?
---@return IterStoreFile?
---@return string? error
function M.set_reviewed(root, path, reviewed)
    return M.update(root, function(data)
        data.reviewed[path] = reviewed
    end)
end

--- Remember `base` as what the review compares with, nil for working
--- changes.
---@param root string
---@param base? IterBaseSpec
---@return IterStoreFile?
---@return string? error
function M.set_base(root, base)
    vim.validate('base', base, 'table', true)

    return M.update(root, function(data)
        if vim.deep_equal(data.base, base) then
            return false
        end

        data.base = base
    end)
end

return M
