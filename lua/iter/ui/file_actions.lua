local git = require('iter.git')
local util = require('iter.util')

--- Stage, unstage, discard and ignore files of the changes. Each action
--- returns what it did, or nil when it did nothing: refused with a warning,
--- or declined at the confirm.
local M = {}

---@class IterFileActionContext
---@field changes IterChanges
---@field config IterConfig

---@class IterFileActionResult
---@field ok boolean
---@field err? string
---@field fallback string message when `ok` is false
---@field action? 'stage'|'unstage'|'discard' nil for ignore, which fires no IterStage
---@field paths string[]

--- Whether one of `items` is a change against a base, where `action`
--- doesn't apply; says so when it is.
---@param items IterChange[]
---@param action string
---@return boolean
local function against_base(items, action)
    for _, item in ipairs(items) do
        if item.side == 'base' then
            util.warn(action .. ' does not apply against a base')
            return true
        end
    end

    return false
end

--- The files an action on `item` touches. A nested repository is left out.
---@param item IterChange
---@return string[]
local function paths_of(item)
    if item.dir then
        util.warn('Skipped the nested repository ' .. item.path)
        return {}
    end

    return { item.path }
end

--- `path` of the only item, else the number of items.
---@param items IterChange[]
---@return string
local function name(items)
    return #items == 1 and items[1].path or (#items .. ' files')
end

---@param ctx IterFileActionContext
local function validate(ctx)
    vim.validate('ctx', ctx, 'table')
    vim.validate('ctx.changes', ctx.changes, 'table')
    vim.validate('ctx.config', ctx.config, 'table')
end

--- Stage the unstaged and untracked items; when every item is staged,
--- unstage them instead.
---@param ctx IterFileActionContext
---@param items IterChange[]
---@return IterFileActionResult?
function M.stage(ctx, items)
    validate(ctx)
    vim.validate('items', items, 'table')

    if #items == 0 or against_base(items, 'Staging') then
        return nil
    end

    local unstaged = vim.tbl_filter(function(item)
        return item.side ~= 'staged'
    end, items)

    if #unstaged == 0 then
        return M.unstage(ctx, items)
    end

    local paths = {}

    for _, item in ipairs(unstaged) do
        vim.list_extend(paths, paths_of(item))
    end

    if #paths == 0 then
        return nil
    end

    local ok, err = git.stage(ctx.changes.root, paths)

    return {
        ok = ok,
        err = err,
        fallback = 'Cannot stage ' .. name(unstaged),
        action = 'stage',
        paths = paths,
    }
end

--- Unstage the staged changes of the items' paths, a rename with its
--- original path.
---@param ctx IterFileActionContext
---@param items IterChange[]
---@return IterFileActionResult?
function M.unstage(ctx, items)
    validate(ctx)
    vim.validate('items', items, 'table')

    if #items == 0 or against_base(items, 'Unstaging') then
        return nil
    end

    local paths = {}

    for _, item in ipairs(items) do
        local target = item.side == 'staged' and item or nil

        if target == nil then
            for _, staged in ipairs(ctx.changes.staged) do
                if staged.path == item.path then
                    target = staged
                end
            end
        end

        if target ~= nil then
            if target.orig_path ~= nil then
                table.insert(paths, target.orig_path)
            end

            table.insert(paths, target.path)
        end
    end

    if #paths == 0 then
        util.warn('Nothing to unstage')
        return nil
    end

    local ok, err = git.unstage(ctx.changes.root, paths)

    return {
        ok = ok,
        err = err,
        fallback = 'Cannot unstage ' .. name(items),
        action = 'unstage',
        paths = paths,
    }
end

--- Discard the unstaged changes of `item` after a confirm that names every
--- path: a tracked file goes back to its index version, untracked files are
--- deleted.
---@param ctx IterFileActionContext
---@param item IterChange
---@return IterFileActionResult?
function M.discard(ctx, item)
    validate(ctx)
    vim.validate('item', item, 'table')

    if against_base({ item }, 'Discard') then
        return nil
    end

    if item.side == 'staged' then
        util.warn('Unstage first')
        return nil
    end

    local untracked = item.code == '?'
    local paths = untracked and paths_of(item) or { item.path }

    if #paths == 0 then
        return nil
    end

    local message = (
        untracked and 'Delete untracked files:\n'
        or 'Discard unstaged changes in:\n'
    ) .. table.concat(paths, '\n')

    if
        ctx.config.options.confirm.discard
        and vim.fn.confirm(message, '&Discard\n&No', 2) ~= 1
    then
        return nil
    end

    local root = ctx.changes.root
    local ok, err

    if untracked then
        ok, err = git.delete_untracked(root, paths)
    else
        ok, err = git.discard(root, paths)
    end

    return {
        ok = ok,
        err = err,
        fallback = 'Cannot discard ' .. item.path,
        action = 'discard',
        paths = paths,
    }
end

--- Append the path of `item`, an untracked file, to the `.gitignore` at the
--- root, anchored to the root, after a confirm.
---@param ctx IterFileActionContext
---@param item IterChange
---@return IterFileActionResult?
function M.ignore(ctx, item)
    validate(ctx)
    vim.validate('item', item, 'table')

    if against_base({ item }, 'Ignoring') then
        return nil
    end

    if item.code ~= '?' then
        util.warn('Only untracked files can be ignored')
        return nil
    end

    if
        ctx.config.options.confirm.ignore
        and vim.fn.confirm(
                'Append ' .. item.path .. ' to .gitignore?',
                '&Yes\n&No',
                2
            )
            ~= 1
    then
        return nil
    end

    local ok, err = git.ignore(ctx.changes.root, item.path)

    return {
        ok = ok,
        err = err,
        fallback = 'Cannot write .gitignore',
        paths = { item.path },
    }
end

return M
