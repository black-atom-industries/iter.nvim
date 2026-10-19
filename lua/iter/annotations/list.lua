--- The stored annotations in review order, grouped by file, each with its
--- outdated state against the worktree. The export and the review drawer's
--- Annotations column list them this way.

local anchor = require('iter.annotations.anchor')

---@class IterAnnotationItem
---@field annotation IterAnnotation
---@field index integer position in the store
---@field outdated boolean
---@field start? integer line the annotation starts on in the worktree, when its text was found there

---@class IterAnnotationGroup
---@field path? string nil for the review group
---@field items IterAnnotationItem[]

local M = {}

--- Lines of `path`: the loaded buffer's when there is one, else the file's.
---@param root string
---@param path string
---@return string[]?
function M.file_lines(root, path)
    local full = vim.fs.joinpath(root, path)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)

        if
            vim.api.nvim_buf_is_loaded(buf)
            and name ~= ''
            and vim.bo[buf].buftype == ''
            and vim.fs.normalize(vim.fn.resolve(name)) == full
        then
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
    end

    local ok, lines = pcall(vim.fn.readfile, full)

    return ok and lines or nil
end

---@param annotation IterAnnotation
---@return boolean
local function follows_worktree(annotation)
    return (annotation.scope == 'line' or annotation.scope == 'range')
        and annotation.anchor.side == 'new'
        and annotation.anchor.lines ~= nil
        and #annotation.anchor.lines > 0
end

--- Annotations in groups: the files of `order` first, in that order, then the
--- other files by name, the review last. In a group the file annotation comes
--- first, then the annotations by line. An annotation that follows the
--- worktree is outdated when its text isn't in `lines_of(path)`; the others
--- keep their stored state.
---@param annotations IterAnnotation[]
---@param order? string[]
---@param lines_of fun(path: string): string[]?
---@return IterAnnotationGroup[]
function M.groups(annotations, order, lines_of)
    local rank = {}

    for i, path in ipairs(order or {}) do
        rank[path] = rank[path] or i
    end

    ---@type table<string, IterAnnotationGroup>
    local by_key = {}
    ---@type IterAnnotationGroup[]
    local groups = {}

    for index, annotation in ipairs(annotations) do
        local path = annotation.scope ~= 'review' and annotation.anchor.path
            or nil
        local key = path or ''
        local group = by_key[key]

        if group == nil then
            group = { path = path, items = {} }
            by_key[key] = group
            table.insert(groups, group)
        end

        local outdated = annotation.outdated == true
        local start

        if follows_worktree(annotation) then
            start = anchor.resolve(
                annotation.anchor,
                lines_of(path --[[@as string]])
            )
            outdated = start == nil
        end

        table.insert(group.items, {
            annotation = annotation,
            index = index,
            outdated = outdated,
            start = start,
        })
    end

    for _, group in ipairs(groups) do
        table.sort(group.items, function(a, b)
            local sa = a.annotation.anchor.start_line or 0
            local sb = b.annotation.anchor.start_line or 0

            if a.annotation.scope == 'file' then
                sa = 0
            end

            if b.annotation.scope == 'file' then
                sb = 0
            end

            if sa ~= sb then
                return sa < sb
            end

            return a.index < b.index
        end)
    end

    table.sort(groups, function(a, b)
        if (a.path == nil) ~= (b.path == nil) then
            return a.path ~= nil
        end

        local ra, rb = rank[a.path or ''], rank[b.path or '']

        if ra ~= rb and (ra ~= nil or rb ~= nil) then
            return ra ~= nil and (rb == nil or ra < rb)
        end

        return (a.path or '') < (b.path or '')
    end)

    return groups
end

return M
