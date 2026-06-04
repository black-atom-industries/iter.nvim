---@class Iter
---@field gsw GitStatusWindow?
---@field did_setup boolean
---@field config IterConfig
local M = {
    gsw = nil,
    did_setup = false,
    config = require('iter.config').resolve(),
}

local log = require('iter.log')

---@param gsw GitStatusWindow?
---@return boolean
local function has_valid_status_buffer(gsw)
    if gsw == nil or gsw.buf == nil or gsw.buf.id == nil then
        return false
    end

    local bufnr = gsw.buf.id

    return vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.bo[bufnr].buftype == 'nofile'
        and vim.bo[bufnr].filetype == 'iter'
end

function M.reset()
    if M.gsw == nil then
        return
    end

    ---@type GitStatusWindow
    local gsw = M.gsw
    local ok, destroyed = pcall(function()
        return gsw:destroy()
    end)

    if ok and destroyed then
        M.gsw = nil
    end
end

---@param gsw GitStatusWindow
local function attach_status_buffer_autocmd(gsw)
    vim.api.nvim_create_autocmd({ 'BufDelete', 'BufUnload', 'BufWipeout' }, {
        group = gsw.autocmd_group,
        buffer = gsw.buf.id,
        once = true,
        callback = function()
            if M.gsw ~= gsw then
                return
            end

            vim.schedule(function()
                if M.gsw == gsw then
                    M.reset()
                end
            end)
        end,
    })
end

---@param path string?
---@return GitFileChangeCounts
---@return string?
function M.file_change_counts(path)
    return require('iter.git').file_change_counts(path)
end

---@return GitFileChangeCounts
---@return string?
function M.current_file_change_counts()
    return require('iter.git').current_file_change_counts()
end

function M.status()
    log.info('status command called')

    if M.gsw ~= nil and not has_valid_status_buffer(M.gsw) then
        M.reset()
    end

    if M.gsw then
        M.gsw:refresh()
        M.gsw:show()
    else
        local GitStatusWindow = require('iter.ui.status')
        local gsw = GitStatusWindow.new(M.config)
        attach_status_buffer_autocmd(gsw)
        M.gsw = gsw
    end

    log.info(
        string.format('Window opened win=%d buf=%d', M.gsw.win, M.gsw.buf.id)
    )
end

---@param opts IterOptions?
function M.setup(opts)
    local config = require('iter.config')
    M.config = config.resolve(opts)
    M.did_setup = true

    return M
end

return M
