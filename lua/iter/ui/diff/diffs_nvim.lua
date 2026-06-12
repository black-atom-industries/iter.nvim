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

-- Native diff groups are direction-less: `DiffAdd`/`DiffChange` mean "this
-- window differs", so the old side would paint removed lines green. Remap
-- per side to diffs.nvim's documented groups (:h diffs.nvim-highlights),
-- mirroring its own split view: red family on the old pane, green on the new.
local SIDE_WINHIGHLIGHT = {
    old = table.concat({
        'DiffAdd:DiffsDelete',
        'DiffChange:DiffsDelete',
        'DiffText:DiffsDeleteText',
        'DiffDelete:DiffsDiffDelete',
    }, ','),
    new = table.concat({
        'DiffAdd:DiffsAdd',
        'DiffChange:DiffsAdd',
        'DiffText:DiffsAddText',
        'DiffDelete:DiffsDiffDelete',
    }, ','),
}

--- Remap native diff-mode groups to diffs.nvim's replacements. diffs.nvim
--- applies a generic remap itself on `OptionSet diff`, but that event does
--- not fire for :diffthis, so iter sets it on its own split diff windows —
--- and per side, which the generic remap cannot know about.
---@param win integer
---@param side 'old'|'new'
function M.apply_diff_winhighlight(win, side)
    if not M.is_available() then
        return
    end

    -- The groups are defined on diffs.nvim's first initialization; force it
    -- through the public API if split mode is used before any attach.
    if vim.fn.hlexists('DiffsDiffAdd') == 0 then
        local scratch = vim.api.nvim_create_buf(false, true)
        require('diffs').attach(scratch)
        vim.api.nvim_buf_delete(scratch, { force = true })
    end

    if vim.fn.hlexists('DiffsDiffAdd') == 0 then
        return
    end

    vim.wo[win].winhighlight = SIDE_WINHIGHLIGHT[side]
end

return M
