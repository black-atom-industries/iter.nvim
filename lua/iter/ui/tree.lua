--- Changed files as a directory tree: the tree, its visible rows and their
--- render lines. Pure: it builds tables and touches no window or buffer.

local highlight = require('iter.highlight')
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
---@field mark? [string, string] glyph and group before the icon
---@field icon? [string, string] glyph and group before the letter
---@field right? [string, string][] chunks at the right edge, one cell in

local M = {}

-- Glyph and group per staging state.
local STAGE_ICONS = {
    staged = { '●', 'IterStage' },
    partly = { '◐', 'IterUnstage' },
    unstaged = { '○', 'IterDrawerHint' },
}

local GUTTER = '   '
local INDENT = '  '
local ARROW = ' ← '

local FADE_GROUPS =
    { 'IterTreeFade1', 'IterTreeFade2', 'IterTreeFade3', 'IterTreeFade4' }

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

---@param chunks [string, string][]
---@return integer
local function chunks_width(chunks)
    local width = 0

    for _, chunk in ipairs(chunks) do
        width = width + vim.fn.strdisplaywidth(chunk[1])
    end

    return width
end

--- The start of `text` that fits in `width` cells.
---@param text string
---@param width integer
---@return string
local function head(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end

    local kept = ''

    for i = 0, vim.fn.strchars(text) - 1 do
        local next = kept .. vim.fn.strcharpart(text, i, 1)

        if vim.fn.strdisplaywidth(next) > width then
            break
        end

        kept = next
    end

    return kept
end

--- The chunks of a name cut short, its last cells fading out.
---@param name string
---@return [string, string?][]
local function faded(name)
    local count = vim.fn.strchars(name)
    local steps = math.min(#FADE_GROUPS, count)
    local chunks = { { vim.fn.strcharpart(name, 0, count - steps) } }

    for step = 1, steps do
        table.insert(chunks, {
            vim.fn.strcharpart(name, count - steps + step - 1, 1),
            FADE_GROUPS[#FADE_GROUPS - steps + step],
        })
    end

    return chunks
end

--- `line` cut to `width` cells, its highlights cut with it.
---@param line IterRenderLine
---@param width integer
---@return IterRenderLine
local function clip(line, width)
    if vim.fn.strdisplaywidth(line.text) <= width then
        return line
    end

    local kept = head(line.text, width)

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
---@param collapsed table<string, true>
---@return IterRenderLine
local function dir_line(row, collapsed)
    local dir = row.node
    ---@cast dir IterTreeDir
    local lead = GUTTER .. INDENT:rep(row.depth)
    local glyph = is_collapsed(dir, collapsed) and '▸ ' or '▾ '

    return render.chunks_line({
        { lead },
        { glyph .. dir.name, 'IterDrawerHint' },
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

    if decor.mark then
        table.insert(chunks, decor.mark)
        table.insert(chunks, { ' ' })
    end

    if decor.icon then
        table.insert(chunks, decor.icon)
        table.insert(chunks, { ' ' })
    end

    table.insert(chunks, { code, highlight.code_group(code) })
    table.insert(chunks, { ' ' })

    local right = decor.right or {}
    local right_width = chunks_width(right)
    local full_lead = vim.fn.strdisplaywidth(GUTTER .. INDENT:rep(row.depth))
    local lead_width = full_lead
    local room = width
        - full_lead
        - chunks_width(chunks)
        - (right_width > 0 and right_width + 2 or 0)

    -- The indent gives way before the name's first cell does.
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
        local name = head(file.name, room)

        if name == file.name then
            table.insert(chunks, { name })
        else
            vim.list_extend(chunks, faded(name))
        end
    end

    if right_width > 0 then
        local gap = width - 1 - right_width - chunks_width(chunks)

        table.insert(chunks, { string.rep(' ', math.max(gap, 1)) })
        vim.list_extend(chunks, right)
    end

    return render.chunks_line(chunks)
end

--- The icon of a file's staging state, nil for a file without one.
---@param stage? 'staged'|'partly'|'unstaged'
---@return [string, string]?
function M.stage_icon(stage)
    return STAGE_ICONS[stage]
end

--- The cells `lines` needs to show every name of the tree whole, closed
--- directories included, with one cell left at the edge. A rename's
--- `← orig_path` doesn't count.
---@param root IterTreeDir
---@param decorate fun(file: IterTreeFile): IterTreeDecor
---@return integer
function M.width(root, decorate)
    vim.validate('root', root, 'table')
    vim.validate('decorate', decorate, 'function')

    local widest = 0

    for _, row in ipairs(M.rows(root, {})) do
        local node = row.node
        local used = vim.fn.strdisplaywidth(GUTTER .. INDENT:rep(row.depth))
            + vim.fn.strdisplaywidth(node.name)

        if node.kind == 'dir' then
            used = used + vim.fn.strdisplaywidth('▾ ')
        else
            ---@cast node IterTreeFile
            local decor = decorate(node)
            local right = chunks_width(decor.right or {})

            used = used
                + (decor.mark and chunks_width({ decor.mark }) + 1 or 0)
                + (decor.icon and chunks_width({ decor.icon }) + 1 or 0)
                + vim.fn.strdisplaywidth(node.code .. ' ')
                + (right > 0 and right + 1 or 0)
        end

        widest = math.max(widest, used + 1)
    end

    return widest
end

--- The render lines of `rows`, each at most `width` cells: a 3-cell gutter,
--- 2 cells per depth, then a directory as `▾ name` (`▸` when collapsed) or a
--- file as `[mark ][icon ]letter name`. A rename adds `← orig_path`, dropped
--- before the name stops short; the decor's right chunks end one cell before
--- the edge. A name is never shortened: what doesn't fit stops at the right
--- chunks or the edge.
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
        local line = row.node.kind == 'dir' and dir_line(row, collapsed)
            or file_line(row, width, decorate(row.node))

        return clip(line, width)
    end, rows)
end

return M
