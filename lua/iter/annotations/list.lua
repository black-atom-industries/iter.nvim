--- Queries over the stored annotations: the lines of the version an
--- annotation follows, where its text sits there and whether it is outdated,
--- and the annotations in review order, grouped by file. The export, the
--- review drawer's Annotations column and the annotation marks of diff views
--- and buffers all decide outdated through `line_of`.

local anchor = require('iter.annotations.anchor')

---@class IterAnnotationItem
---@field annotation IterAnnotation
---@field index integer position in the store
---@field outdated boolean
---@field start? integer line the annotation starts on in the version it follows, when its text was found there

---@class IterAnnotationGroup
---@field path? string nil for the review group
---@field items IterAnnotationItem[]

local M = {}

---@alias IterLinesOf fun(path: string, version: IterAnchorVersion): string[]?

--- Lines of `path` at `version`: for the worktree the loaded buffer's when
--- there is one, else the file's; for `HEAD` and `index` the blob's. A path
--- missing from the version reads as no lines; nil means the version can't
--- be read (an unreadable file, an unborn HEAD, git failing).
---@param root string
---@param path string
---@param version? IterAnchorVersion `worktree` by default
---@return string[]?
function M.file_lines(root, path, version)
    if version == 'HEAD' or version == 'index' then
        local git = require('iter.git')
        local lines =
            git.blob_lines(root, (version == 'HEAD' and 'HEAD:' or ':') .. path)

        if lines ~= nil then
            return lines
        end

        -- With git working and the version there, the path isn't in it.
        local there = git.run(
            version == 'HEAD'
                    and { 'rev-parse', '--verify', '--quiet', 'HEAD^{tree}' }
                or { 'rev-parse', '--git-dir' },
            { cwd = root, ignore_error = true }
        )

        return there.exit_code == 0 and {} or nil
    end

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

    if vim.uv.fs_stat(full) == nil then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, full)

    return ok and lines or nil
end

--- `M.file_lines` of `root`, each path and version read once.
---@param root string
---@return IterLinesOf
function M.reader(root)
    local cache = {}

    return function(path, version)
        local key = version .. '\0' .. path

        if cache[key] == nil then
            cache[key] = M.file_lines(root, path, version) or false
        end

        return cache[key] or nil
    end
end

--- Whether `annotation` anchors to text: a line or range annotation with
--- its lines stored.
---@param annotation IterAnnotation
---@return boolean
function M.has_text(annotation)
    local lines = annotation.anchor.lines

    return (annotation.scope == 'line' or annotation.scope == 'range')
        and lines ~= nil
        and #lines > 0
end

--- Where the text of `annotation` sits in `lines`, the content of the
--- version it follows (`anchor.version`), and whether it is outdated: an
--- annotation with text is outdated when `lines` lacks it. Without `lines`
--- or without text the stored `outdated` flag answers, a cache that
--- `anchor.follow` updates when a written buffer moves the text.
---@param annotation IterAnnotation
---@param lines? string[]
---@return integer? start
---@return integer? stop
---@return boolean outdated
function M.line_of(annotation, lines)
    if lines == nil or not M.has_text(annotation) then
        return nil, nil, annotation.outdated == true
    end

    local start, stop = anchor.resolve(annotation.anchor, lines)

    return start, stop, start == nil
end

--- `line_of` against the version the annotation follows, read through
--- `lines_of`.
---@param annotation IterAnnotation
---@param lines_of IterLinesOf
---@return integer? start
---@return integer? stop
---@return boolean outdated
function M.resolve(annotation, lines_of)
    local a = annotation.anchor
    local lines = M.has_text(annotation)
            and lines_of(a.path --[[@as string]], anchor.version(a))
        or nil

    return M.line_of(annotation, lines)
end

--- Annotations in groups: the files of `order` first, in that order, then the
--- other files by name, the review last. In a group the file annotation comes
--- first, then the annotations by line. Each is resolved with `resolve`.
---@param annotations IterAnnotation[]
---@param order? string[]
---@param lines_of IterLinesOf
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

        local start, _, outdated = M.resolve(annotation, lines_of)

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
