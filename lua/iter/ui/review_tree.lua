--- A file tree page of the panel, the review's or a commit's: a header,
--- the changed files as a directory tree, an optional footer, and two lines
--- of key hints at the bottom.

local keymap = require('iter.keymap')
local layout = require('iter.ui.layout')
local render = require('iter.ui.render')
local tree = require('iter.ui.tree')

local M = {}

---@class IterReviewTreeOptions
---@field view IterView the keys view the page maps
---@field keys table<string, string[]> resolved keys of `view`
---@field handlers table<string, fun()> tree actions by name
---@field header fun(width: integer): IterRenderLine[] the lines above the rows
---@field decorate fun(file: IterTreeFile): IterTreeDecor
---@field hints fun(): [string, string][][] action and label, one list per hint line
---@field footer? fun(width: integer): IterRenderLine[], table<integer, any> lines above the hints and the item of each of its lines that has one
---@field on_select fun(node?: IterTreeDir|IterTreeFile, extra?: any) after the cursor moved onto another row: a tree row's node, or a footer line's item

---@class IterReviewTree: IterPanelPage
---@field buf integer
---@field root IterTreeDir
---@field collapsed table<string, true> directory paths the user closed
---@field rows IterTreeRow[] the visible rows of the last render
---@field items table<integer, IterTreeRow> buffer line → row
---@field extras table<integer, any> buffer line → footer item
---@field lnum integer the cursor line the page saw last
---@field opts IterReviewTreeOptions
local Tree = {}
Tree.__index = Tree

--- The page with an empty tree; `root` takes the files.
---@param opts IterReviewTreeOptions
---@return IterReviewTree
function M.new(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.view', opts.view, 'string')
    vim.validate('opts.keys', opts.keys, 'table')
    vim.validate('opts.handlers', opts.handlers, 'table')
    vim.validate('opts.header', opts.header, 'function')
    vim.validate('opts.decorate', opts.decorate, 'function')
    vim.validate('opts.hints', opts.hints, 'function')
    vim.validate('opts.on_select', opts.on_select, 'function')
    vim.validate('opts.footer', opts.footer, 'function', true)

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'iter'
    keymap.attach(buf, opts.view, opts.keys, opts.handlers)

    return setmetatable({
        buf = buf,
        root = tree.build({}),
        collapsed = {},
        rows = {},
        items = {},
        extras = {},
        lnum = 1,
        opts = opts,
    }, Tree)
end

--- The hint chunks of each line for `width` cells, one cell in.
---@param self IterReviewTree
---@param width integer
---@return [string, string][][]
local function hint_chunks(self, width)
    local bound =
        keymap.list(self.opts.view, self.opts.keys, self.opts.handlers)

    return vim.tbl_map(function(actions)
        return layout.hints(bound, actions, width - 1)
    end, self.opts.hints())
end

---@param width integer
---@param height integer
function Tree:render(width, height)
    local lines = self.opts.header(width)

    table.insert(lines, render.line(''))

    self.rows = tree.rows(self.root, self.collapsed)
    self.items = {}

    if #self.rows == 0 then
        local clean = render.line(' Working tree clean')

        render.add_highlight(clean, 'IterDrawerHint', 0, #clean.text)
        table.insert(lines, clean)
    end

    local first = #lines

    for index, line in
        ipairs(tree.lines(self.rows, width, self.collapsed, self.opts.decorate))
    do
        table.insert(lines, line)
        self.items[first + index] = self.rows[index]
    end

    local hints = hint_chunks(self, width)
    local bottom = height

    self.extras = {}

    if self.opts.footer ~= nil then
        local footer, extras = self.opts.footer(width)

        if #footer > 0 then
            local gap = height - #lines - #footer - #hints

            for _ = 1, math.max(gap, 1) do
                table.insert(lines, render.line(''))
            end

            for index, item in pairs(extras) do
                self.extras[#lines + index] = item
            end

            vim.list_extend(lines, footer)
            bottom = #lines + #hints
        end
    end

    layout.bottom_hints(lines, hints, bottom)

    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, render.text_lines(lines))
    vim.bo[self.buf].modifiable = false
    render.apply(self.buf, lines)
end

--- The line of a row or footer item nearest to `lnum`, looking in
--- direction `dir` first; nil without either.
---@param lnum integer
---@param dir 1|-1
---@return integer?
function Tree:nearest(lnum, dir)
    local last = vim.api.nvim_buf_line_count(self.buf)

    for _, step in ipairs({ dir, -dir }) do
        local l = lnum

        while l >= 1 and l <= last do
            if self.items[l] ~= nil or self.extras[l] ~= nil then
                return l
            end

            l = l + step
        end
    end

    return nil
end

--- Snap the cursor to a row or footer item and tell the page's owner what
--- it is on.
---@param lnum integer
---@param prev integer
function Tree:on_cursor(lnum, prev)
    local target = self:nearest(lnum, lnum < prev and -1 or 1)

    if target ~= nil and target ~= lnum then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end

    self.lnum = target or lnum

    local row = self.items[self.lnum]

    if row ~= nil then
        self.opts.on_select(row.node)
    elseif self.extras[self.lnum] ~= nil then
        self.opts.on_select(nil, self.extras[self.lnum])
    end
end

--- Whether line `lnum` holds a row or a footer item.
---@param lnum integer
---@return boolean
function Tree:has_item(lnum)
    return self.items[lnum] ~= nil or self.extras[lnum] ~= nil
end

--- The footer item under the cursor.
---@return any
function Tree:extra()
    return self.extras[self.lnum]
end

--- The node under the cursor.
---@return (IterTreeDir|IterTreeFile)?
function Tree:node()
    local row = self.items[self.lnum]

    return row and row.node
end

--- The file under the cursor; nil on a directory.
---@return IterTreeFile?
function Tree:file()
    local node = self:node()

    return node ~= nil and node.kind == 'file' and node or nil
end

--- The line of the row of `path`, a file or directory path, nil while it is
--- not visible.
---@param path string
---@return integer?
function Tree:line_of(path)
    for lnum, row in pairs(self.items) do
        if row.node.path == path then
            return lnum
        end
    end

    return nil
end

--- Open the directories that hold `path`, so its row shows at the next
--- render.
---@param path string
function Tree:open_to(path)
    for _, dir in ipairs(tree.ancestors(path)) do
        self.collapsed[dir] = nil
    end
end

--- Close directory `dir`, or open it when it is closed.
---@param dir IterTreeDir
function Tree:toggle(dir)
    local closed = false

    for _, span in ipairs(dir.spans) do
        closed = closed or self.collapsed[span] == true
    end

    if closed then
        for _, span in ipairs(dir.spans) do
            self.collapsed[span] = nil
        end
    else
        self.collapsed[dir.path] = true
    end
end

--- Fold the directory under the cursor: `toggle` closes or opens it,
--- `collapse` closes it, `expand` opens it. On a file `collapse` closes the
--- file's directory. Returns the directory, whose row the cursor belongs
--- on, or nil when nothing applies.
---@param action 'toggle'|'collapse'|'expand'
---@return IterTreeDir?
function Tree:fold(action)
    local node = self:node()

    if node == nil then
        return nil
    end

    if node.kind == 'file' then
        local parent = action == 'collapse' and self:parent(node)

        if not parent then
            return nil
        end

        node = parent
    end

    ---@cast node IterTreeDir
    local closed = false

    for _, span in ipairs(node.spans) do
        closed = closed or self.collapsed[span] == true
    end

    if action == 'toggle' or (action == 'collapse') ~= closed then
        self:toggle(node)
    end

    return node
end

--- The directory that holds `node`, nil at the top level. Nodes match by
--- path, so a node of an earlier read finds its place in the current tree.
---@param node IterTreeDir|IterTreeFile
---@return IterTreeDir?
function Tree:parent(node)
    local found

    local function walk(dir)
        for _, child in ipairs(dir.children) do
            if child.kind == node.kind and child.path == node.path then
                found = dir
                return
            elseif child.kind == 'dir' then
                walk(child)
            end
        end
    end

    walk(self.root)

    return found ~= self.root and found or nil
end

--- Wipe the page's buffer.
function Tree:close()
    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end
end

return M
