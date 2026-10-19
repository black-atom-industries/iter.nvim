---@class IterKeymapEntry
---@field action string
---@field lhs string[]
---@field desc string
---@field modes string[]

local M = {}

-- Per view, every action in help order with its description and, optionally,
-- the modes it maps in (normal mode when omitted).
---@type table<IterView, { [1]: string, [2]: string, [3]: string[]? }[]>
local ACTIONS = {
    drawer = {
        { 'open', 'Open the file and close the drawer' },
        { 'stage', 'Stage or unstage the file' },
        { 'unstage', 'Unstage the file' },
        { 'discard', 'Discard changes in the file' },
        { 'ignore', 'Add the untracked file to .gitignore' },
        { 'review', 'Open the review tab' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
        { 'scroll_down', 'Scroll the diff down' },
        { 'scroll_up', 'Scroll the diff up' },
        { 'column_left', 'Select the column to the left' },
        { 'column_right', 'Select the column to the right' },
    },
    review_drawer = {
        { 'open', 'Open the diff, or jump to the annotation' },
        { 'stage', 'Stage or unstage the file' },
        { 'unstage', 'Unstage the file' },
        { 'discard', 'Discard changes in the file' },
        { 'ignore', 'Add the untracked file to .gitignore' },
        { 'viewed', 'Toggle viewed' },
        { 'mode', 'Toggle one file or all files' },
        { 'split', 'Show the diff side by side' },
        { 'unified', 'Show the diff unified' },
        { 'annotate_file', 'Annotate the file' },
        { 'edit', 'Edit the annotation' },
        { 'delete', 'Delete the annotation' },
        { 'yank', 'Copy the review' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
        { 'scroll_down', 'Scroll the diff down' },
        { 'scroll_up', 'Scroll the diff up' },
        { 'column_left', 'Select the column to the left' },
        { 'column_right', 'Select the column to the right' },
    },
    diff = {
        { 'next_hunk', 'Next hunk' },
        { 'prev_hunk', 'Previous hunk' },
        { 'next_annotation', 'Next annotation' },
        { 'prev_annotation', 'Previous annotation' },
        { 'next_file', 'Next file' },
        { 'prev_file', 'Previous file' },
        { 'stage', 'Stage the hunk or the selected lines', { 'n', 'x' } },
        { 'unstage', 'Unstage the hunk or the selected lines', { 'n', 'x' } },
        { 'annotate', 'Annotate the line or range', { 'n', 'x' } },
        { 'annotate_file', 'Annotate the file' },
        { 'edit', 'Edit the annotation' },
        { 'delete', 'Delete the annotation' },
        { 'expand', 'Expand the collapsed file or hidden context' },
        { 'goto_file', 'Go to the line in the file' },
        { 'viewed', 'Toggle viewed' },
        { 'mode', 'Toggle one file or all files' },
        { 'split', 'Show the diff side by side' },
        { 'unified', 'Show the diff unified' },
        { 'yank', 'Copy the review' },
        { 'focus_drawer', 'Focus the drawer' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
    },
    annotation = {
        { 'save', 'Save the annotation and close the float', { 'n', 'i' } },
        { 'toggle', 'Toggle the draft', { 'n', 'i' } },
        { 'cancel', 'Cancel', { 'n', 'i' } },
        { 'close', 'Close' },
    },
    help = {
        { 'close', 'Close' },
    },
}

--- Every action of `view`, in help order.
---@param view IterView
---@return string[]
function M.actions(view)
    return vim.tbl_map(function(spec)
        return spec[1]
    end, ACTIONS[view])
end

--- The actions of `view` that have a handler and at least one key, in help
--- order.
---@param view IterView
---@param keys table<string, string[]> resolved keys of the view
---@param handlers table<string, fun()>
---@return IterKeymapEntry[]
function M.list(view, keys, handlers)
    local entries = {}

    for _, spec in ipairs(ACTIONS[view]) do
        local action, desc = spec[1], spec[2]
        local lhs = keys[action] or {}

        if handlers[action] ~= nil and #lhs > 0 then
            table.insert(entries, {
                action = action,
                lhs = lhs,
                desc = desc,
                modes = spec[3] or { 'n' },
            })
        end
    end

    return entries
end

--- Map the keys of every handled action of `view` on `buf`.
---@param buf integer
---@param view IterView
---@param keys table<string, string[]> resolved keys of the view
---@param handlers table<string, fun()>
function M.attach(buf, view, keys, handlers)
    for _, entry in ipairs(M.list(view, keys, handlers)) do
        for _, lhs in ipairs(entry.lhs) do
            vim.keymap.set(entry.modes, lhs, handlers[entry.action], {
                buffer = buf,
                desc = entry.desc,
                silent = true,
                nowait = true,
            })
        end
    end
end

return M
