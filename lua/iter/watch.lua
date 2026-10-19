local git = require('iter.git')

local M = {}

---@alias IterWatchReason 'git'|'focus'|'write'|'poll'

---@class IterWatchOpts
---@field root string worktree root
---@field poll_ms integer
---@field on_change fun(reason: IterWatchReason)

---@class IterWatchShared the watchers of one root, shared by its subscribers
---@field root string
---@field subs IterWatch[]
---@field events any[] libuv fs_event handles
---@field debounce any libuv timer
---@field poll any libuv timer
---@field group integer
local Shared = {}
Shared.__index = Shared

---@class IterWatch a subscription to the watchers of a root
---@field root string
---@field on_change fun(reason: IterWatchReason)
---@field shared IterWatchShared
---@field active boolean
local Watch = {}
Watch.__index = Watch

local DEBOUNCE_MS = 100
local next_id = 0

---@type table<string, IterWatchShared>
local shared_by_root = {}

-- git writes `index.lock` and renames it over `index` (likewise `HEAD`), so a
-- watcher on the file itself dies after the first change. The directories
-- are watched instead, filtered to these names.
local WATCHED = { index = true, HEAD = true }

---@param timer any libuv timer
local function close_timer(timer)
    timer:stop()

    if not timer:is_closing() then
        timer:close()
    end
end

---@param root string
---@param poll_ms integer
---@return IterWatchShared
local function new_shared(root, poll_ms)
    local self = setmetatable({
        root = root,
        subs = {},
        events = {},
        debounce = assert(vim.uv.new_timer()),
        poll = assert(vim.uv.new_timer()),
    }, Shared)

    local dirs = {}

    for _, path in ipairs(git.git_paths(root, { 'index', 'HEAD' }) or {}) do
        dirs[vim.fs.dirname(path)] = true
    end

    for dir in pairs(dirs) do
        local event = assert(vim.uv.new_fs_event())

        event:start(dir, {}, function(err, filename)
            if err == nil and (filename == nil or WATCHED[filename]) then
                self:schedule_git()
            end
        end)
        table.insert(self.events, event)
    end

    self.poll:start(
        poll_ms,
        poll_ms,
        vim.schedule_wrap(function()
            self:notify('poll')
        end)
    )

    next_id = next_id + 1
    self.group =
        vim.api.nvim_create_augroup('iter.watch.' .. next_id, { clear = true })
    vim.api.nvim_create_autocmd('FocusGained', {
        group = self.group,
        callback = function()
            self:notify('focus')
        end,
    })
    vim.api.nvim_create_autocmd('BufWritePost', {
        group = self.group,
        callback = function(args)
            local path = vim.fs.normalize(vim.fn.resolve(args.match))

            if vim.startswith(path, self.root .. '/') then
                self:notify('write')
            end
        end,
    })

    return self
end

--- Runs in the fs event callback, a fast context: only timer calls here.
function Shared:schedule_git()
    self.debounce:stop()
    self.debounce:start(
        DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
            self:notify('git')
        end)
    )
end

---@param reason IterWatchReason
function Shared:notify(reason)
    for _, sub in ipairs(vim.list_slice(self.subs)) do
        sub:notify(reason)
    end
end

--- Stop every watcher, timer and autocmd.
function Shared:close()
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    for _, event in ipairs(self.events) do
        event:stop()

        if not event:is_closing() then
            event:close()
        end
    end

    close_timer(self.debounce)
    close_timer(self.poll)
end

--- Call `opts.on_change` when the index or HEAD of `opts.root` changes, when
--- Neovim gains focus, when a file under the root is written, and every
--- `opts.poll_ms`. Git events are debounced. One set of watchers and one
--- poll timer serve every subscriber of a root, started by the first and
--- stopped with the last; the first subscriber's `poll_ms` applies.
---@param opts IterWatchOpts
---@return IterWatch
function M.start(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.root', opts.root, 'string')
    vim.validate('opts.poll_ms', opts.poll_ms, 'number')
    vim.validate('opts.on_change', opts.on_change, 'function')

    local shared = shared_by_root[opts.root]

    if shared == nil then
        shared = new_shared(opts.root, opts.poll_ms)
        shared_by_root[opts.root] = shared
    end

    local self = setmetatable({
        root = opts.root,
        on_change = opts.on_change,
        shared = shared,
        active = true,
    }, Watch)

    table.insert(shared.subs, self)

    return self
end

---@param reason IterWatchReason
function Watch:notify(reason)
    if self.active then
        self.on_change(reason)
    end
end

---@return boolean
function Watch:is_active()
    return self.active
end

--- Unsubscribe; the last subscriber of a root stops its watchers. Safe to
--- call twice.
function Watch:stop()
    if not self.active then
        return
    end

    self.active = false

    local shared = self.shared

    for i, sub in ipairs(shared.subs) do
        if sub == self then
            table.remove(shared.subs, i)
            break
        end
    end

    if #shared.subs == 0 then
        shared_by_root[self.root] = nil
        shared:close()
    end
end

return M
