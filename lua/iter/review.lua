local Drawer = require('iter.ui.drawer')
local git = require('iter.git')
local model = require('iter.diff.model')
local util = require('iter.util')

---@class IterReviewOpenOptions
---@field config IterConfig
---@field path? string absolute path of a file to select when it changed
---@field side? IterSide side to look for `path` on first
---@field on_close? fun(review: IterReview)

---@class IterReview
---@field tab integer
---@field origin_tab integer tab the review was opened from; `gf` opens files there
---@field origin_win? integer normal window of that tab
---@field diff_win integer
---@field spacer_win integer bottom split the drawer float covers
---@field buf integer empty buffer of the split and of the diff window without a diff
---@field drawer IterDrawer
---@field group integer
---@field closed boolean
---@field on_close? fun(review: IterReview)
local Review = {}
Review.__index = Review

-- The spacer only holds the place of the drawer float above it.
local SPACER_WINOPTS = {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    cursorline = false,
    cursorcolumn = false,
    colorcolumn = '',
    foldenable = false,
    list = false,
    spell = false,
    winfixheight = true,
}

---@param win integer?
---@return boolean
local function is_normal_win(win)
    return util.is_valid_win(win)
        and vim.api.nvim_win_get_config(win --[[@as integer]]).relative
            == ''
end

--- A normal window of `tab`: `preferred` when it is one there, else the
--- tab's current window, else its first normal one.
---@param tab integer
---@param preferred? integer
---@return integer?
local function normal_win(tab, preferred)
    if
        is_normal_win(preferred)
        and vim.api.nvim_win_get_tabpage(preferred --[[@as integer]]) == tab
    then
        return preferred
    end

    local current = vim.api.nvim_tabpage_get_win(tab)

    if is_normal_win(current) then
        return current
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if is_normal_win(win) then
            return win
        end
    end

    return nil
end

--- Open the review tab after the current one, with the diff window above
--- and the drawer over a split at the bottom. The drawer gets the focus.
---@param opts IterReviewOpenOptions
---@return IterReview?
function Review.open(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.path', opts.path, 'string', true)
    vim.validate('opts.side', opts.side, 'string', true)
    vim.validate('opts.on_close', opts.on_close, 'function', true)

    local origin_tab = vim.api.nvim_get_current_tabpage()
    local origin_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'hide'

    vim.cmd('tab sbuffer ' .. buf)

    local diff_win = vim.api.nvim_get_current_win()
    local spacer_win = vim.api.nvim_open_win(buf, false, {
        split = 'below',
        win = diff_win,
        height = 3,
    })

    for name, value in pairs(SPACER_WINOPTS) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { scope = 'local', win = spacer_win }
        )
    end

    local self = setmetatable({
        tab = vim.api.nvim_get_current_tabpage(),
        origin_tab = origin_tab,
        origin_win = normal_win(origin_tab, origin_win),
        diff_win = diff_win,
        spacer_win = spacer_win,
        buf = buf,
        closed = false,
        on_close = opts.on_close,
    }, Review)

    local drawer = Drawer.open({
        pane = spacer_win,
        view_win = diff_win,
        context = 'review',
        height = 1,
        config = opts.config,
        path = opts.path,
        side = opts.side,
        view_handlers = self:view_handlers(),
        on_close = function()
            self:close()
        end,
    })

    if drawer == nil then
        self.closed = true
        vim.cmd.tabclose({ bang = true })
        vim.api.nvim_buf_delete(buf, { force = true })
        return nil
    end

    self.drawer = drawer
    self:attach()

    return self
end

---@return table<string, fun()>
function Review:view_handlers()
    return {
        next_hunk = function()
            self.drawer.view:jump_hunk(1)
        end,
        prev_hunk = function()
            self.drawer.view:jump_hunk(-1)
        end,
        next_file = function()
            self.drawer:step_file(1)
        end,
        prev_file = function()
            self.drawer:step_file(-1)
        end,
        goto_file = function()
            self:goto_file()
        end,
        close = function()
            self:close()
        end,
    }
end

function Review:attach()
    self.group = vim.api.nvim_create_augroup(
        'iter.review.' .. self.buf,
        { clear = true }
    )

    vim.api.nvim_create_autocmd('WinClosed', {
        group = self.group,
        pattern = { tostring(self.diff_win), tostring(self.spacer_win) },
        callback = function()
            vim.schedule(function()
                self:close()
            end)
        end,
    })
    vim.api.nvim_create_autocmd('WinEnter', {
        group = self.group,
        callback = function()
            if
                vim.api.nvim_get_current_win() == self.spacer_win
                and util.is_valid_win(self.drawer.win)
            then
                vim.api.nvim_set_current_win(self.drawer.win)
            end
        end,
    })
end

---@return boolean
function Review:is_open()
    return not self.closed and vim.api.nvim_tabpage_is_valid(self.tab)
end

--- Switch to the tab and focus the drawer.
function Review:focus()
    vim.api.nvim_set_current_tabpage(self.tab)
    self.drawer:focus()
end

--- Close the tab and go back to the tab the review came from.
function Review:close()
    if self.closed then
        return
    end

    self.closed = true
    pcall(vim.api.nvim_del_augroup_by_id, self.group)

    local current = vim.api.nvim_get_current_tabpage() == self.tab

    if vim.api.nvim_tabpage_is_valid(self.tab) then
        if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd.tabnew()
        end

        vim.cmd.tabclose({
            vim.api.nvim_tabpage_get_number(self.tab),
            bang = true,
        })
    end

    -- With its windows gone, the view only wipes its buffer.
    self.drawer:close()

    if vim.api.nvim_buf_is_valid(self.buf) then
        vim.api.nvim_buf_delete(self.buf, { force = true })
    end

    if current and vim.api.nvim_tabpage_is_valid(self.origin_tab) then
        vim.api.nvim_set_current_tabpage(self.origin_tab)
    end

    if self.on_close ~= nil then
        self.on_close(self)
    end
end

--- `review · <file> · <i>/<n>` for windows of the tab, `''` elsewhere. The
--- position counts files in drawer order.
---@return string
function Review:statusline()
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()

    if
        not self:is_open()
        or not util.is_valid_win(win)
        or vim.api.nvim_win_get_tabpage(win) ~= self.tab
    then
        return ''
    end

    local view = self.drawer.view
    local file = view:is_shown() and view.files[1] or nil

    if file == nil then
        return 'review'
    end

    local files = self.drawer:files()

    for index, item in ipairs(files) do
        if item.side == file.side and item.path == file.path then
            return string.format(
                'review · %s · %d/%d',
                file.path,
                index,
                #files
            )
        end
    end

    return 'review · ' .. file.path
end

--- Line of the new version of `file` that row `lnum` stands for: its new
--- number, for a deleted line the line that took its place, for a gap its
--- first hidden line, for a hunk row its first row, for the header line 1.
---@param file IterFileDiff
---@param lnum integer
---@return integer
local function new_line(file, lnum)
    local row = file.rows[lnum]

    if row == nil or row.kind == 'header' then
        return 1
    elseif row.new ~= nil then
        return row.new
    elseif row.kind == 'del' then
        return model.old_line_to_new_line(file, row.old)
    elseif row.kind == 'gap' then
        return row.gap.new
    end

    return new_line(file, lnum + 1)
end

--- The worktree line for row `lnum` of `file`. A staged line goes through
--- the unstaged diff of the same path, when there is one.
---@param changes IterChanges
---@param file IterFileDiff
---@param lnum integer
---@return integer
local function worktree_line(changes, file, lnum)
    local line = new_line(file, lnum)

    if file.side ~= 'staged' then
        return line
    end

    for _, item in ipairs(changes.unstaged) do
        if item.path == file.path and not item.dir and item.code ~= '?' then
            local source = git.file_diff(changes.root, item)

            if source == nil then
                return line
            end

            return model.old_line_to_new_line(model.build(item, source), line)
        end
    end

    return line
end

--- Edit the file of the diff in the tab the review came from, at the
--- worktree line of the cursor row. The review stays open.
function Review:goto_file()
    local view = self.drawer.view
    local file = view.files[1]

    if file == nil or not view:is_shown() then
        return
    end

    local changes = self.drawer.changes
    local path = vim.fs.joinpath(changes.root, file.path)

    if vim.uv.fs_stat(path) == nil then
        util.warn(file.path .. ' is deleted')
        return
    end

    local line =
        worktree_line(changes, file, vim.api.nvim_win_get_cursor(view.win)[1])

    if not vim.api.nvim_tabpage_is_valid(self.origin_tab) then
        vim.cmd.tabnew({ range = { 0 } })
        self.origin_tab = vim.api.nvim_get_current_tabpage()
    end

    local win = normal_win(self.origin_tab, self.origin_win)

    if win == nil then
        return
    end

    self.origin_win = win

    -- With 'nohidden' a modified buffer can't leave its window (E37).
    local buf = vim.api.nvim_win_get_buf(win)

    if
        not vim.o.hidden
        and vim.bo[buf].modified
        and vim.api.nvim_buf_get_name(buf) ~= path
    then
        util.warn('The pane has unsaved changes')
        return
    end

    vim.api.nvim_set_current_tabpage(self.origin_tab)
    vim.api.nvim_set_current_win(win)

    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))

    if not ok then
        util.error(tostring(err), 'Cannot open ' .. file.path)
        return
    end

    vim.api.nvim_win_set_cursor(
        win,
        { math.min(line, vim.api.nvim_buf_line_count(0)), 0 }
    )
end

return Review
