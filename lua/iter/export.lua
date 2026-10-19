--- The review as text for an agent: an intro, then a numbered list of the
--- comments with the code they sit on. `yank` copies it and offers to clear.

local anchor = require('iter.comments.anchor')
local picker = require('iter.comments.picker')
local store = require('iter.store')
local util = require('iter.util')

local M = {}

---@param text string
---@return string
local function strip_cr(text)
    return (text:gsub('\r$', ''))
end

--- `lines` with every non-empty line indented by `indent`.
---@param lines string[]
---@param indent string
---@return string[]
local function indented(lines, indent)
    return vim.tbl_map(function(line)
        return line == '' and '' or indent .. line
    end, lines)
end

--- A fence of backticks longer than any run in `lines`.
---@param lines string[]
---@return string
local function fence_for(lines)
    local longest = 2

    for _, line in ipairs(lines) do
        for run in line:gmatch('`+') do
            longest = math.max(longest, #run)
        end
    end

    return string.rep('`', longest + 1)
end

---@param comment IterComment
---@return boolean
local function has_code(comment)
    local a = comment.anchor

    return (comment.scope == 'line' or comment.scope == 'range')
        and a.lines ~= nil
        and #a.lines > 0
end

---@param item IterPickerItem
---@param lines_of fun(path: string): string[]?
---@return string
local function heading(item, lines_of)
    local comment = item.comment
    local a = comment.anchor

    if comment.scope == 'review' then
        return 'Review'
    elseif comment.scope == 'file' then
        return a.path .. ' (file)'
    end

    local first, last = a.start_line, a.end_line

    if a.side == 'new' and not item.outdated and has_code(comment) then
        local at = anchor.resolve(a, lines_of(a.path))

        if at ~= nil then
            first, last = at, at + (last - first)
        end
    end

    local loc = first == last and tostring(first) or (first .. '-' .. last)
    local marks = {}

    if a.side == 'old' then
        table.insert(marks, 'old side')
    end

    if item.outdated then
        table.insert(marks, 'outdated')
    end

    return a.path
        .. ':'
        .. loc
        .. (#marks > 0 and ' (' .. table.concat(marks, ', ') .. ')' or '')
end

--- The export text: `intro`, a blank line, then one numbered item per
--- comment. Files follow `order`, then name, with the review comments last.
---@param comments IterComment[]
---@param opts { intro: string, order?: string[], lines_of: fun(path: string): string[]? }
---@return string
function M.text(comments, opts)
    vim.validate('comments', comments, 'table')
    vim.validate('opts', opts, 'table')

    local out = { opts.intro, '' }
    local n = 0

    for _, group in ipairs(picker.groups(comments, opts.order, opts.lines_of)) do
        for _, item in ipairs(group.items) do
            n = n + 1

            local indent = string.rep(' ', #tostring(n) + 2)
            local comment = item.comment

            table.insert(out, n .. '. ' .. heading(item, opts.lines_of))

            if has_code(comment) then
                local code = vim.tbl_map(strip_cr, comment.anchor.lines)
                local fence = fence_for(code)
                local filetype =
                    vim.filetype.match({ filename = comment.anchor.path })

                table.insert(out, indent .. fence .. (filetype or ''))
                vim.list_extend(out, indented(code, indent))
                table.insert(out, indent .. fence)
            end

            local body = comment.body:gsub('\r\n?', '\n'):gsub('%s+$', '')

            vim.list_extend(out, indented(vim.split(body, '\n'), indent))
        end
    end

    return table.concat(out, '\n')
end

--- Put `text` in `"` and in `+` when a clipboard provider exists.
---@param text string
local function copy(text)
    vim.fn.setreg('"', text, 'l')
    pcall(vim.fn.setreg, '+', text, 'l')
end

--- Ask on the command line; only `y` answers yes.
---@param n integer
---@return boolean
local function ask_clear(n)
    vim.api.nvim_echo({
        {
            string.format(
                'Copied %d comment%s. Clear them? [y/N]',
                n,
                n == 1 and '' or 's'
            ),
        },
    }, false, {})
    vim.cmd.redraw()

    local ok, key = pcall(vim.fn.getcharstr)

    vim.cmd.echo('""')
    vim.cmd.redraw()

    return ok and (key == 'y' or key == 'Y')
end

---@class IterYankOptions
---@field root string
---@field config IterConfig
---@field order? string[] file paths in drawer order
---@field on_clear? fun() after the exported comments are removed

--- Copy the stored comments of `opts.root` and ask once whether to remove
--- them. Only the comments that were copied are removed.
---@param opts IterYankOptions
function M.yank(opts)
    vim.validate('opts', opts, 'table')

    local data, err = store.load(opts.root)

    if data == nil then
        util.warn('Cannot read the comments: ' .. tostring(err))
        return
    end

    if #data.comments == 0 then
        util.warn('No comments to copy')
        return
    end

    copy(M.text(data.comments, {
        intro = opts.config.options.export.intro,
        order = opts.order,
        lines_of = function(path)
            return picker.file_lines(opts.root, path)
        end,
    }))

    if not ask_clear(#data.comments) then
        return
    end

    local ids = vim.tbl_map(function(comment)
        return comment.id
    end, data.comments)
    local _, remove_err = store.remove_comments(opts.root, ids)

    if remove_err ~= nil then
        util.warn('Cannot clear the comments: ' .. remove_err)
        return
    end

    if opts.on_clear ~= nil then
        opts.on_clear()
    end
end

return M
