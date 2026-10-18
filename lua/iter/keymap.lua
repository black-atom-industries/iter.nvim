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
        { 'open', 'Open the file and close the status window' },
        { 'preview', 'Toggle the diff preview' },
        { 'stage', 'Stage or unstage the file' },
        { 'unstage', 'Unstage the file' },
        { 'discard', 'Discard changes in the file' },
        { 'expand', 'Expand or collapse the directory' },
        { 'review', 'Open the review tab' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
        { 'column_left', 'Select the Unstaged column' },
        { 'column_right', 'Select the Staged column' },
    },
    review_drawer = {
        { 'open', 'Open the file' },
        { 'stage', 'Stage or unstage the file' },
        { 'unstage', 'Unstage the file' },
        { 'discard', 'Discard changes in the file' },
        { 'expand', 'Expand or collapse the directory' },
        { 'viewed', 'Toggle viewed' },
        { 'mode', 'Toggle one file or all files' },
        { 'comment_file', 'Comment on the file' },
        { 'picker', 'List comments' },
        { 'yank', 'Copy the review' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
        { 'column_left', 'Select the Unstaged column' },
        { 'column_right', 'Select the Staged column' },
    },
    diff = {
        { 'next_hunk', 'Next hunk' },
        { 'prev_hunk', 'Previous hunk' },
        { 'next_comment', 'Next comment' },
        { 'prev_comment', 'Previous comment' },
        { 'next_file', 'Next file' },
        { 'prev_file', 'Previous file' },
        { 'stage', 'Stage the hunk' },
        { 'unstage', 'Unstage the hunk' },
        { 'discard', 'Discard the hunk' },
        { 'comment', 'Comment on the line or range' },
        { 'comment_file', 'Comment on the file' },
        { 'edit', 'Edit the comment' },
        { 'delete', 'Delete the comment' },
        { 'expand', 'Expand hidden context' },
        { 'goto_file', 'Go to the line in the file' },
        { 'viewed', 'Toggle viewed' },
        { 'mode', 'Toggle one file or all files' },
        { 'picker', 'List comments' },
        { 'yank', 'Copy the review' },
        { 'close', 'Close' },
        { 'help', 'Show the keys' },
    },
    comment = {
        { 'save', 'Save the comment', { 'n', 'i' } },
        { 'toggle', 'Toggle the draft', { 'n', 'i' } },
        { 'cancel', 'Cancel', { 'n', 'i' } },
        { 'close', 'Close' },
    },
    picker = {
        { 'next', 'Next comment' },
        { 'prev', 'Previous comment' },
        { 'jump', 'Jump to the comment' },
        { 'edit', 'Edit the comment' },
        { 'delete', 'Delete the comment' },
        { 'close', 'Close' },
    },
    help = {
        { 'close', 'Close' },
    },
}

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
