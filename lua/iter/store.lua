---@class IterViewed store.viewed[path]
---@field hash string git hash-object of the worktree file, 'deleted' when missing
---@field at integer

---@class IterStoreFile stdpath('data')/iter/<repo-id>/<branch>.json
---@field version 1
---@field annotations IterAnnotation[]
---@field viewed table<string, IterViewed>

local git = require('iter.git')
local util = require('iter.util')

local M = {}

local VERSION = 1

local id_count = 0

---@type table<string, true>
local newer_warned = {}

---@return IterStoreFile
local function empty()
    return { version = VERSION, annotations = {}, viewed = {} }
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

    if type(data.viewed) ~= 'table' then
        return false
    end

    for path, viewed in pairs(data.viewed) do
        if type(path) ~= 'string' or type(viewed) ~= 'table' then
            return false
        end
    end

    return true
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

--- Write through a temp file in the same directory, renamed into place.
---@param path string
---@param data IterStoreFile
---@return boolean? ok
---@return string? error
local function write(path, data)
    local dir = vim.fs.dirname(path)
    local made, mkdir_err = pcall(vim.fn.mkdir, dir, 'p')

    if not made or vim.fn.isdirectory(dir) == 0 then
        return nil,
            string.format(
                'Cannot create the annotation store directory %s: %s',
                dir,
                made and 'not a directory' or tostring(mkdir_err)
            )
    end

    local encoded = vim.json.encode({
        version = data.version,
        annotations = data.annotations,
        viewed = next(data.viewed) == nil and vim.empty_dict() or data.viewed,
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

--- The stored annotations and viewed records. A missing file reads as empty; a
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

--- Re-read the store from disk, let `fn` change it in place, and write it
--- back. Every write goes through here, so changes apply by annotation id and
--- path to what other instances wrote in the meantime. When `fn` returns
--- false, nothing is written.
---@param root string
---@param fn fun(data: IterStoreFile): boolean?
---@return IterStoreFile?
---@return string? error
function M.update(root, fn)
    local path, path_err = M.path(root)

    if path == nil then
        return nil, path_err
    end

    local data, read_err = read(path)

    if data == nil then
        return nil, read_err
    end

    if fn(data) == false then
        return data
    end

    local ok, write_err = write(path, data)

    if not ok then
        return nil, write_err
    end

    return data
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

--- Store the viewed record of `path`, or drop it when `viewed` is nil.
---@param root string
---@param path string
---@param viewed IterViewed?
---@return IterStoreFile?
---@return string? error
function M.set_viewed(root, path, viewed)
    return M.update(root, function(data)
        data.viewed[path] = viewed
    end)
end

return M
