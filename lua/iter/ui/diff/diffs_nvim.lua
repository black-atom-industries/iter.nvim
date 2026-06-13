--- Adapter for the diffs.nvim dependency. The only module that touches
--- require('diffs'). Integration follows the documented host-plugin recipe
--- (:h diffs.nvim-plugin-authors): iter owns the buffer and windows, writes
--- raw unified diff lines, and hands highlighting to diffs.nvim.

local git = require('iter.git')

local M = {}

M.error_msg = 'iter.nvim requires diffs.nvim for diff previews. '
    .. "Install it alongside iter, e.g. vim.pack.add({ 'https://github.com/barrettruth/diffs.nvim' }) "
    .. "or lazy.nvim dependencies = { 'barrettruth/diffs.nvim' }"

---@return boolean
function M.is_available()
    return pcall(require, 'diffs')
end

--- Attach diffs.nvim highlighting to a buffer that already contains raw
--- unified diff lines. Idempotent — diffs.nvim ignores already-attached
--- buffers, so callers must use M.refresh() after regenerating content.
---@param bufnr integer
function M.attach(bufnr)
    local root = git.root()

    if root ~= '' then
        vim.b[bufnr].diffs_repo_root = root
    end

    vim.bo[bufnr].filetype = 'iter-diff'

    require('diffs').attach(bufnr)
end

--- Invalidate diffs.nvim's cache after the buffer content was regenerated.
---@param bufnr integer
function M.refresh(bufnr)
    require('diffs').refresh(bufnr)
end

return M
