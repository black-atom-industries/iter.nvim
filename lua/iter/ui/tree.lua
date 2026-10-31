--- Changed files as a directory tree: the tree, its visible rows and their
--- render lines. Pure: it builds tables and touches no window or buffer.

local changes = require('iter.changes')
local render = require('iter.ui.render')

---@class IterTreeFile one row per path
---@field kind 'file'
---@field path string relative; a nested repository keeps its trailing '/'
---@field name string last segment, 'sub/' for a nested repository
---@field items IterChange[] the path's changes in input order
---@field code string the first item's code
---@field stage? 'staged'|'partly'|'unstaged' from the sides present; nil for base and commit sides

---@class IterTreeDir
---@field kind 'dir'
---@field path string ends with '/', '' for the root
---@field name string the compacted chain below its parent, 'lua/iter/'
---@field spans string[] the path of every directory the chain covers, outermost first
---@field children (IterTreeDir|IterTreeFile)[] directories first, then files, each by name (byte order)

---@class IterTreeRow
---@field node IterTreeDir|IterTreeFile
---@field depth integer

---@class IterTreeDecor
---@field icon? [string, string] glyph and group before the letter
---@field right? [string, string][] chunks at the right edge, one cell in

local M = {}

local GUTTER = '  '
local INDENT = '  '
local ARROW = ' ← '

---@param items IterChange[]
---@return 'staged'|'partly'|'unstaged'|nil
local function stage_of(items)
    local staged, unstaged = false, false

    for _, item in ipairs(items) do
        if item.side == 'staged' then
            staged = true
        elseif item.side == 'unstaged' then
            unstaged = true
        else
            return nil
        end
    end

    if staged and unstaged then
        return 'partly'
    end

    return staged and 'staged' or 'unstaged'
end

---@param path string
---@return string
local function trim_slash(path)
    return (path:gsub('/$', ''))
end

---@param path string
---@return IterTreeDir
local function new_dir(path)
    return {
        kind = 'dir',
        path = path,
        name = '',
        children = {},
        spans = { path },
    }
end

--- Whether `collapsed` names `dir` or any directory of its chain, so a
--- collapse survives the chain growing or shrinking.
---@param dir IterTreeDir
---@param collapsed table<string, true>
---@return boolean
local function is_collapsed(dir, collapsed)
    for _, path in ipairs(dir.spans) do
        if collapsed[path] then
            return true
        end
    end

    return false
end

---@param a IterTreeDir|IterTreeFile
---@param b IterTreeDir|IterTreeFile
---@return boolean
local function before(a, b)
    if a.kind ~= b.kind then
        return a.kind == 'dir'
    end

    return a.name < b.name
end

--- Sort every directory's children, then merge each chain of directories
--- that hold one directory and nothing else into its first directory.
---@param dir IterTreeDir
local function finish(dir)
    table.sort(dir.children, before)

    for _, child in ipairs(dir.children) do
        if child.kind == 'dir' then
            ---@cast child IterTreeDir
            finish(child)

            local only = child.children[1]

            while #child.children == 1 and only.kind == 'dir' do
                ---@cast only IterTreeDir
                child.name = child.name .. only.name
                child.path = only.path
                child.children = only.children
                vim.list_extend(child.spans, only.spans)
                only = child.children[1]
            end
        end
    end
end

--- The tree of `items`: one file per path, a rename under its new path, a
--- nested repository a file of its own.
---@param items IterChange[]
---@return IterTreeDir
function M.build(items)
    vim.validate('items', items, 'table')

    local root = new_dir('')
    ---@type table<string, IterTreeDir>
    local dirs = { [''] = root }
    ---@type table<string, IterTreeFile>
    local files = {}

    for _, item in ipairs(items) do
        local file = files[item.path]

        if file == nil then
            local segments = vim.split(trim_slash(item.path), '/')
            local parent = root

            for i = 1, #segments - 1 do
                local path = parent.path .. segments[i] .. '/'
                local dir = dirs[path]

                if dir == nil then
                    dir = new_dir(path)
                    dir.name = segments[i] .. '/'
                    dirs[path] = dir
                    table.insert(parent.children, dir)
                end

                parent = dir
            end

            file = {
                kind = 'file',
                path = item.path,
                name = segments[#segments] .. (item.dir and '/' or ''),
                items = {},
                code = item.code,
            }
            files[item.path] = file
            table.insert(parent.children, file)
        end

        table.insert(file.items, item)
    end

    for _, file in pairs(files) do
        file.stage = stage_of(file.items)
    end

    finish(root)

    return root
end

--- Every file of the tree in tree order, depth first, collapsed or not.
---@param root IterTreeDir
---@return IterTreeFile[]
function M.files(root)
    vim.validate('root', root, 'table')

    local result = {}

    local function walk(dir)
        for _, child in ipairs(dir.children) do
            if child.kind == 'dir' then
                walk(child)
            else
                table.insert(result, child)
            end
        end
    end

    walk(root)

    return result
end

--- The visible rows of the tree: a collapsed directory shows, its contents
--- don't. A key of `collapsed` collapses the directory whose chain covers it. The root is not a row; its children have depth 0.
---@param root IterTreeDir
---@param collapsed table<string, true> directory paths
---@return IterTreeRow[]
function M.rows(root, collapsed)
    vim.validate('root', root, 'table')
    vim.validate('collapsed', collapsed, 'table')

    local result = {}

    local function walk(dir, depth)
        for _, child in ipairs(dir.children) do
            table.insert(result, { node = child, depth = depth })

            if child.kind == 'dir' and not is_collapsed(child, collapsed) then
                walk(child, depth + 1)
            end
        end
    end

    walk(root, 0)

    return result
end

--- The directory paths that hold `path`, outermost first, without the root.
---@param path string
---@return string[]
function M.ancestors(path)
    vim.validate('path', path, 'string')

    local result = {}
    local segments = vim.split(trim_slash(path), '/')
    local prefix = ''

    for i = 1, #segments - 1 do
        prefix = prefix .. segments[i] .. '/'
        table.insert(result, prefix)
    end

    return result
end

---@param code string
---@return string
local function code_group(code)
    if code == '?' then
        return 'IterUntracked'
    elseif code == 'U' then
        return 'IterConflict'
    end

    return 'IterDiffHeaderRule'
end

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

--- `line` cut to `width` cells, its highlights cut with it.
---@param line IterRenderLine
---@param width integer
---@return IterRenderLine
local function clip(line, width)
    if vim.fn.strdisplaywidth(line.text) <= width then
        return line
    end

    local kept = ''

    for i = 0, vim.fn.strchars(line.text) - 1 do
        local next = kept .. vim.fn.strcharpart(line.text, i, 1)

        if vim.fn.strdisplaywidth(next) > width then
            break
        end

        kept = next
    end

    local highlights = {}

    for _, span in ipairs(line.highlights) do
        if span.start_col < #kept then
            span.end_col = math.min(span.end_col, #kept)
            table.insert(highlights, span)
        end
    end

    line.text, line.highlights = kept, highlights

    return line
end

---@param row IterTreeRow
---@param width integer
---@param collapsed table<string, true>
---@return IterRenderLine
local function dir_line(row, width, collapsed)
    local dir = row.node
    ---@cast dir IterTreeDir
    local lead = GUTTER .. INDENT:rep(row.depth)
    local glyph = is_collapsed(dir, collapsed) and '▸ ' or '▾ '
    local room = width
        - vim.fn.strdisplaywidth(lead)
        - vim.fn.strdisplaywidth(glyph)

    return render.chunks_line({
        { lead },
        { glyph .. changes.truncate(dir.name, room), 'IterDrawerHint' },
    })
end

---@param row IterTreeRow
---@param width integer
---@param decor IterTreeDecor
---@return IterRenderLine
local function file_line(row, width, decor)
    local file = row.node
    ---@cast file IterTreeFile
    local renamed = vim.iter(file.items):find(function(item)
        return item.orig_path ~= nil
    end)
    local code = renamed and renamed.code or file.code
    local chunks = {}

    if decor.icon then
        table.insert(chunks, decor.icon)
        table.insert(chunks, { ' ' })
    end

    table.insert(chunks, { code, code_group(code) })
    table.insert(chunks, { ' ' })

    local right = decor.right or {}
    local right_width = chunks_width(right)
    local full_lead = vim.fn.strdisplaywidth(GUTTER .. INDENT:rep(row.depth))
    local lead_width = full_lead
    local room = width
        - full_lead
        - chunks_width(chunks)
        - (right_width > 0 and right_width + 2 or 0)

    -- The indent gives way before the name shrinks below `…`.
    if room < 1 then
        lead_width = math.max(0, full_lead - (1 - room))
        room = room + full_lead - lead_width
    end

    table.insert(chunks, 1, { string.rep(' ', lead_width) })

    if
        renamed ~= nil
        and vim.fn.strdisplaywidth(file.name .. ARROW .. renamed.orig_path)
            <= room
    then
        table.insert(chunks, { file.name })
        table.insert(chunks, { ARROW .. renamed.orig_path, 'IterDrawerHint' })
    else
        table.insert(chunks, { changes.truncate(file.name, room) })
    end

    if right_width > 0 then
        local gap = width - 1 - right_width - chunks_width(chunks)

        table.insert(chunks, { string.rep(' ', math.max(gap, 1)) })
        vim.list_extend(chunks, right)
    end

    return render.chunks_line(chunks)
end

--- The render lines of `rows`, each at most `width` cells: a 2-cell gutter,
--- 2 cells per depth, then a directory as `▾ name` (`▸` when collapsed) or a
--- file as `[icon ]letter name`. A rename adds `← orig_path`, dropped
--- before the name is cut; the decor's right chunks end one cell before the
--- edge.
---@param rows IterTreeRow[]
---@param width integer
---@param collapsed table<string, true> directory paths
---@param decorate fun(file: IterTreeFile): IterTreeDecor
---@return IterRenderLine[]
function M.lines(rows, width, collapsed, decorate)
    vim.validate('rows', rows, 'table')
    vim.validate('width', width, 'number')
    vim.validate('collapsed', collapsed, 'table')
    vim.validate('decorate', decorate, 'function')

    return vim.tbl_map(function(row)
        local line = row.node.kind == 'dir' and dir_line(row, width, collapsed)
            or file_line(row, width, decorate(row.node))

        return clip(line, width)
    end, rows)
end

return M
