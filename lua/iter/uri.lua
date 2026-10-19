--- `iter://` buffer names as addresses. `:edit` of one opens or focuses what
--- it names, and the buffer `:edit` made for it is wiped. iter's own buffers
--- carry the same names: one shown in a window iter doesn't own goes back to
--- that window's previous buffer and opens what it names; `:edit` in its own
--- window fills it again.

local util = require('iter.util')

local M = {}

---@class IterUriTarget
---@field kind 'status'|'review'|'annotation'
---@field path? string repository-relative path, for `status` too
---@field line? integer new-side line, from `#L<n>`
---@field view? 'all'|'annotations' the review's view, from `#all` or `#annotations`

---@class IterUriOwner
---@field owns fun(win: integer): boolean the windows iter shows the buffer in
---@field reload fun() fill the buffer again after `:edit` emptied it
---@field prev? fun(): integer? the buffer the window showed before iter's

---@type table<integer, IterUriOwner>
local owners = {}

--- Per window, the buffer it showed before the owned buffer that left it
--- last: a buffer with 'bufhidden' `wipe` is gone, and no longer the
--- window's alternate, by the time `:edit` reads.
---@type table<integer, integer>
local left = {}

-- The group `plugin/iter.lua` creates for `BufReadCmd`.
local GROUP = vim.api.nvim_create_augroup('iter.uri', { clear = false })

--- `iter://<kind>`, with `/<path>` and `#L<line>` when given.
---@param kind string
---@param path? string
---@param line? integer
---@return string
function M.of(kind, path, line)
    local name = 'iter://' .. kind

    if path ~= nil then
        name = name .. '/' .. path
    end

    if line ~= nil then
        name = name .. '#L' .. line
    end

    return name
end

local FRAGMENTS = { L = true, all = true, annotations = true, old = true }

--- What `name` addresses, nil when it isn't an iter URI. Known fragments
--- come off the end: `#L<n>` gives the line, `#all` and `#annotations` the
--- view, `#old` nothing; any other `#` belongs to the path.
---@param name string
---@return IterUriTarget?
function M.parse(name)
    local rest = name:match('^iter://(.*)$')

    if rest == nil then
        return nil
    end

    local line, view

    while true do
        local base, fragment = rest:match('^(.-)#([^#/]*)$')

        if base == nil or not FRAGMENTS[fragment:gsub('^L%d+$', 'L')] then
            break
        end

        rest = base
        line = line or tonumber(fragment:match('^L(%d+)$'))

        if fragment == 'all' or fragment == 'annotations' then
            view = view or fragment
        end
    end

    local kind, path = rest:match('^(%a+)/(.+)$')
    kind = kind or rest

    if kind == 'status' then
        return { kind = 'status', path = path }
    elseif kind == 'annotation' and path == nil then
        return { kind = 'annotation' }
    elseif kind == 'review' then
        return {
            kind = 'review',
            path = path,
            line = path and line,
            view = view,
        }
    end

    return nil
end

--- True, with a warning, when the open drawer or review of `kind` belongs
--- to another repository than the current directory's.
---@param kind 'status'|'review'
---@return boolean
local function elsewhere(kind)
    local iter = require('iter')
    local review = iter.current_review
    local open = kind == 'review'
            and review ~= nil
            and review:is_open()
            and review.drawer
        or kind == 'status' and iter.drawer ~= nil and iter.drawer:is_open() and iter.drawer
        or nil
    local root = require('iter.git').root()

    if open == nil or root == '' or open.changes.root == root then
        return false
    end

    util.warn(
        string.format(
            'The open %s is of %s, not of %s',
            kind == 'review' and 'review' or 'drawer',
            open.changes.root,
            root
        )
    )
    return true
end

--- Open or focus what `target` addresses, in the current directory's
--- repository.
---@param target? IterUriTarget
---@param name string the URI, for the warning
local function route(target, name)
    local iter = require('iter')

    if target == nil then
        util.warn('Unknown address ' .. name)
    elseif
        target.kind ~= 'annotation'
        and elsewhere(target.kind --[[@as 'status'|'review']])
    then
        return
    elseif target.kind == 'status' then
        iter.status()

        local drawer = iter.drawer

        if target.path ~= nil and drawer ~= nil and drawer:is_open() then
            drawer:reveal(target.path)
        end
    elseif target.kind == 'annotation' then
        require('iter.annotations.editor').show()
    else
        iter.review()

        local review = iter.current_review

        if review == nil or not review:is_open() then
            return
        end

        if target.path ~= nil then
            review:reveal(target.path, target.line)
        elseif target.view == 'annotations' then
            review:focus_annotations()
        elseif target.view == 'all' and not review.drawer.all_files then
            review:toggle_mode()
        end
    end
end

--- Open or focus what the iter URI `name` addresses, as `:edit` of it does,
--- without escaping it first.
---@param name string
function M.open(name)
    vim.validate('name', name, 'string')
    route(M.parse(name), name)
end

--- The buffer to give a window back: `alt`, else the one the window showed
--- before iter's (`prev`), else an empty scratch buffer that is wiped once
--- it leaves the window.
---@param alt integer
---@param prev? integer
---@return integer
local function back_buf(alt, prev)
    -- Never one of iter's own: two of them would hand the window back and
    -- forth.
    for _, buf in ipairs({ alt, prev or -1 }) do
        if
            buf > 0
            and vim.api.nvim_buf_is_valid(buf)
            and owners[buf] == nil
        then
            return buf
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'

    return buf
end

--- The buffer the current window showed before iter's: what `alt`'s owner
--- says, else what the last owned buffer leaving the window said.
---@param alt integer
---@return integer?
local function prev_of(alt)
    local owner = owners[alt]

    if owner ~= nil and owner.prev ~= nil then
        return owner.prev()
    end

    return left[vim.api.nvim_get_current_win()]
end

--- `BufReadCmd` of `iter://*`: fill an owned buffer again, else route.
---@param buf integer
function M.read(buf)
    local owner = owners[buf]

    if owner ~= nil then
        owner.reload()
        -- `:edit` lists the buffer.
        vim.bo[buf].buflisted = false
        return
    end

    local name = vim.api.nvim_buf_get_name(buf)
    local win = vim.api.nvim_get_current_win()
    local alt = vim.fn.bufnr('#')
    local prev = prev_of(alt)

    -- Not a file: the review takes back its panes from a nofile buffer
    -- without opening it as one.
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false

    -- Routing reads the current buffer's name and names buffers like this
    -- one, so it waits until the window has its buffer back.
    vim.schedule(function()
        if
            util.is_valid_win(win)
            and vim.api.nvim_win_get_buf(win) == buf
            and alt ~= buf
        then
            vim.api.nvim_win_set_buf(win, back_buf(alt, prev))
        end

        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end

        route(M.parse(name), name)
    end)
end

--- Whether `buf` is one of iter's own buffers.
---@param buf integer
---@return boolean
function M.owned(buf)
    return owners[buf] ~= nil
end

--- Wipe the `iter://` buffers that aren't iter's own, such as those a
--- session restores, closing the windows that show them unless one is the
--- last window.
function M.clean()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if
            owners[buf] == nil
            and vim.startswith(vim.api.nvim_buf_get_name(buf), 'iter://')
        then
            for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                if #vim.api.nvim_list_wins() > 1 then
                    pcall(vim.api.nvim_win_close, win, true)
                end
            end

            if vim.api.nvim_buf_is_valid(buf) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
        end
    end
end

--- Mark `buf`, named with an iter URI, as iter's own until it is wiped.
---@param buf integer
---@param owner IterUriOwner
function M.own(buf, owner)
    owners[buf] = owner

    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = GROUP,
        buffer = buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            local alt = vim.fn.bufnr('#')
            local prev = prev_of(alt)
            local name = vim.api.nvim_buf_get_name(buf)

            -- `:edit`, `:tabedit` and `:buffer` of its name list it.
            vim.bo[buf].buflisted = false

            if owner.owns(win) then
                return
            end

            -- iter assigns the windows it opens after opening them. A
            -- buffer wiped meanwhile, as the status drawer's are when it
            -- closes, still routes.
            vim.schedule(function()
                local current = owners[buf]

                if
                    not util.is_valid_win(win)
                    or (current ~= nil and current.owns(win))
                then
                    return
                end

                if
                    vim.api.nvim_buf_is_valid(buf)
                    and vim.api.nvim_win_get_buf(win) == buf
                    and alt ~= buf
                then
                    vim.api.nvim_win_set_buf(win, back_buf(alt, prev))
                end

                if vim.api.nvim_buf_is_valid(buf) then
                    vim.bo[buf].buflisted = false
                end

                route(M.parse(name), name)
            end)
        end,
    })
    if owner.prev ~= nil then
        vim.api.nvim_create_autocmd('BufWinLeave', {
            group = GROUP,
            buffer = buf,
            callback = function()
                left[vim.api.nvim_get_current_win()] = owner.prev()
            end,
        })
    end

    vim.api.nvim_create_autocmd('BufWipeout', {
        group = GROUP,
        buffer = buf,
        once = true,
        callback = function()
            owners[buf] = nil
        end,
    })
end

return M
