local document = require('iter.diff.document')
local git = require('iter.git')
local model = require('iter.diff.model')
local util = require('iter.util')
local View = require('iter.diff.view')

---@class IterPreviewSource what the preview shows, read on every use
---@field changes fun(): IterChanges
---@field files fun(): IterChange[] every file in all-files order
---@field collapsed? fun(item: IterChange): boolean? in all-files mode, whether the file shows its header row alone
---@field shown fun() after the view showed something

---@class IterPreviewOptions
---@field win integer window the view borrows
---@field config IterConfig
---@field handlers table<string, fun()> diff view actions
---@field bufhidden? string 'bufhidden' of the view's buffer
---@field source IterPreviewSource
---@field on_cursor? fun() after the cursor moved in the view
---@field on_layout? fun() after the view's layout changed

---@class IterPreview the diff of the changes' files in a window
---@field view IterDiffView
---@field config IterConfig
---@field source IterPreviewSource
---@field previewed? string key of the item the view shows, or of the item that showed it
---@field previewed_stat? string worktree stat of that item when it was read, of every file in all-files mode
---@field all_files boolean the view shows every file
---@field all_shown boolean the view's document is the all-files one
---@field diff_ids? table<string, string> per file key, the blob ids and worktree stat its shown diff was read with
---@field auto? IterDocLayout the layout 'auto' picked for the last width, nil under any other `diff.layout`
local Preview = {}
Preview.__index = Preview

-- The diff layout chosen last in any preview; a new preview starts in it, so
-- the choice holds for the Neovim session. Before any choice, a preview
-- starts in `diff.layout`. Under 'auto' a resize that crosses
-- `diff.split_breakpoint` drops the choice.
---@type IterDocLayout?
local diff_layout = nil
-- Whether diffs wrap, chosen last in any preview and held for the session
-- like the layout. Before any choice, a preview starts with `diff.wrap`.
---@type boolean?
local diff_wrap = nil

--- The layout `diff.layout` 'auto' picks for `width` columns of diff, nil
--- under any other `diff.layout`.
---@param diff { layout: IterLayoutOption, split_breakpoint: integer }
---@param width integer
---@return IterDocLayout?
local function auto_layout(diff, width)
    if diff.layout ~= 'auto' then
        return nil
    end

    return width >= diff.split_breakpoint and 'split' or 'unified'
end

---@param item IterChange|IterFileDiff
---@return string
function Preview.key(item)
    return item.side .. '\0' .. item.path
end

local key = Preview.key

---@param opts IterPreviewOptions
---@return IterPreview
function Preview.new(opts)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.win', opts.win, 'number')
    vim.validate('opts.config', opts.config, 'table')
    vim.validate('opts.handlers', opts.handlers, 'table')
    vim.validate('opts.bufhidden', opts.bufhidden, 'string', true)
    vim.validate('opts.source', opts.source, 'table')
    vim.validate('opts.on_cursor', opts.on_cursor, 'function', true)
    vim.validate('opts.on_layout', opts.on_layout, 'function', true)

    local diff = opts.config.options.diff
    local auto = auto_layout(diff, vim.api.nvim_win_get_width(opts.win))
    local wrap = diff_wrap

    if wrap == nil then
        wrap = diff.wrap
    end

    return setmetatable({
        auto = auto,
        config = opts.config,
        source = opts.source,
        all_files = false,
        all_shown = false,
        view = View.new({
            win = opts.win,
            keys = opts.config.keys.diff,
            expand_step = diff.expand_step,
            syntax_max_lines = diff.syntax_max_lines,
            word_diff = diff.word_diff,
            icon = opts.config.options.icons.annotation,
            handlers = opts.handlers,
            bufhidden = opts.bufhidden,
            -- Under 'auto' `auto` is set, so the option is a layout here.
            layout = diff_layout or auto or diff.layout --[[@as IterDocLayout]],
            wrap = wrap,
            on_cursor = opts.on_cursor,
            on_layout = opts.on_layout,
        }),
    }, Preview)
end

--- Show the diff of `item`, a file of the changes, in the view.
---@param item IterChange
---@param force boolean also when the view already shows the item
function Preview:show(item, force)
    if item.dir then
        return
    end

    if not force and key(item) == self.previewed then
        return
    end

    if self.all_files then
        self:show_all(item, force)
        return
    end

    local stat = self:stat(item)
    local source, err = git.file_diff(
        self.source.changes().root,
        item,
        self.config.options.diff.args
    )

    if source == nil then
        util.error(err, 'Cannot read the diff of ' .. item.path)
        return
    end

    self.previewed_stat = stat
    self.all_shown = false
    self.view:set_new_follows(self:new_follows(item))

    -- The same diff again keeps the view as it is, expanded gaps included.
    local shown = #self.view.files == 1 and self.view.files[1] or nil

    if
        self.view:is_shown()
        and shown ~= nil
        and shown.side == item.side
        and shown.path == item.path
        and shown.code == item.code
        and shown.base == item.base
        and vim.deep_equal(shown.raw, source.raw)
    then
        self.previewed = key(item)
        self.source.shown()
        return
    end

    self.previewed = key(item)
    self.view:show(model.build(item, source))
    self.source.shown()
end

--- The worktree stat of `item`, of every file in all-files mode, to tell a
--- write from outside.
---@param item IterChange
---@return string
function Preview:stat(item)
    local items = self.all_files and self.source.files() or { item }
    local root = self.source.changes().root

    return table.concat(
        vim.tbl_map(function(file)
            return util.stat_key(vim.fs.joinpath(root, file.path)) or ''
        end, items),
        '\0'
    )
end

--- Read the diff of every file and show them in the source's order, a file
--- the source collapses as its header row alone. A file whose blob ids and
--- worktree stat are the ones read before keeps its rows without a read, as
--- does one whose diff text is the one shown, expanded gaps included; when
--- every file does, the view stays as it is.
function Preview:load_all()
    local view = self.view
    local root = self.source.changes().root
    local files = self.source.files()
    local before = {}

    if self.all_shown then
        for _, section in ipairs(view.document.sections) do
            before[section.key] = section
        end
    end

    self.previewed_stat = self:stat(files[1])

    local since = self.source.changes().since
    local ids = git.diff_ids(root, since and since.sha) or {}
    local known = self.diff_ids or {}

    self.diff_ids = {}

    ---@type IterDocEntry[]
    local entries = {}
    local same = self.all_shown
        and view:is_shown()
        and #files == #view.document.sections

    for _, item in ipairs(files) do
        local k = key(item)
        local shown = before[k]
        local id = (ids[k] or '')
            .. '\0'
            .. (
                item.side ~= 'staged'
                    and util.stat_key(vim.fs.joinpath(root, item.path))
                or ''
            )
        ---@type IterFileDiff?
        local file = shown ~= nil
                and shown.file.code == item.code
                and shown.file.base == item.base
                and known[k] == id
                and shown.file
            or nil

        if not file then
            local source, err =
                git.file_diff(root, item, self.config.options.diff.args)

            if source == nil then
                util.error(err, 'Cannot read the diff of ' .. item.path)
            else
                file = shown ~= nil
                        and shown.file.code == item.code
                        and shown.file.base == item.base
                        and vim.deep_equal(shown.file.raw, source.raw)
                        and shown.file
                    or model.build(item, source)
            end
        end

        if file then
            local new_follows = self:new_follows(item)
            local collapsed = self.source.collapsed ~= nil
                    and self.source.collapsed(item)
                or nil
            local section = view.document.sections[#entries + 1]

            same = same
                and section ~= nil
                and section.file == file
                and section.new_follows == new_follows
                and section.collapsed == collapsed
            self.diff_ids[k] = id
            table.insert(entries, {
                file = file,
                new_follows = new_follows,
                collapsed = collapsed,
            })
        else
            same = false
        end
    end

    self.all_shown = true

    if #entries == 0 then
        view:hide()
    elseif not same then
        view:show_all(entries)
    end
end

--- In all-files mode: show every file, read again with `force` or when the
--- view shows something else, then put `item`'s header at the top of the
--- window, unless a forced read finds the cursor in `item` already.
---@param item IterChange
---@param force boolean
function Preview:show_all(item, force)
    local view = self.view

    if force or not self.all_shown then
        self:load_all()
    elseif not view:is_shown() and #view.document.sections > 0 then
        view:show_document(view.document)
    end

    self.previewed = key(item)

    local index = document.find(view.document, key(item))
    local _, _, at = view:at()

    if index ~= nil and (not force or at ~= index) then
        view:reveal(view.document.sections[index].first, 'top')
    end

    self.source.shown()
end

--- Show every file in one buffer (`on`), or `target` alone. Without a
--- `target` file, the file the view shows stays shown, near its row.
---@param on boolean
---@param target? IterChange
function Preview:set_all_files(on, target)
    if on == self.all_files then
        return
    end

    local shown = self.view:is_shown() and self.view:file() or nil

    if (target == nil or target.dir) and shown ~= nil then
        target = nil

        for _, item in ipairs(self.source.files()) do
            if key(item) == key(shown) then
                target = item
            end
        end
    end

    self.all_files = on
    self.all_shown = false

    if target ~= nil then
        self:show(target, true)
    elseif on then
        self:load_all()
        self.source.shown()
    end
end

--- Columns of the diff: the view's window, and in the split layout the old
--- side's window and the separator between them.
---@return integer
function Preview:diff_width()
    local width = vim.api.nvim_win_get_width(self.view.win)
    local old = self.view.old

    if old ~= nil and util.is_valid_win(old.win) then
        width = width + vim.api.nvim_win_get_width(old.win) + 1
    end

    return width
end

--- Show diffs in `doc_layout`, here and in every preview opened after.
---@param doc_layout IterDocLayout
function Preview:set_layout(doc_layout)
    diff_layout = doc_layout
    self.view:set_layout(doc_layout)
end

--- Wrap long lines of the diff, or stop, here and in every preview opened
--- after. The split layout shows them unwrapped either way.
function Preview:toggle_wrap()
    diff_wrap = not self.view.wrap
    self.view:set_wrap(diff_wrap)

    if diff_wrap and self.view.layout == 'split' then
        util.warn('Wrap shows in the unified layout')
    end
end

--- Under 'auto', switch to the layout the diff's width now picks when it
--- differs from the last one, dropping the session's choice.
---@return boolean switched
function Preview:resized()
    local auto = auto_layout(self.config.options.diff, self:diff_width())

    if auto == nil or auto == self.auto then
        return false
    end

    self.auto = auto
    diff_layout = nil
    self.view:set_layout(auto)

    return true
end

--- Whether the new side of `item`'s diff shows the worktree's content: a
--- change against a base, else a staged file without unstaged changes.
---@param item IterChange
---@return boolean
function Preview:new_follows(item)
    if item.side == 'base' then
        return true
    end

    if item.side ~= 'staged' then
        return false
    end

    for _, unstaged in ipairs(self.source.changes().unstaged) do
        if unstaged.path == item.path then
            return false
        end
    end

    return true
end

--- The worktree line for model row `row` of `file`, a diff of the changes.
--- A staged line goes through the unstaged diff of the same path, when
--- there is one.
---@param file IterFileDiff
---@param row integer
---@return integer
function Preview:worktree_line(file, row)
    local line = model.new_line(file, row)

    if file.side ~= 'staged' then
        return line
    end

    local changes = self.source.changes()

    for _, item in ipairs(changes.unstaged) do
        if item.path == file.path and not item.dir and item.code ~= '?' then
            local source =
                git.file_diff(changes.root, item, self.config.options.diff.args)

            if source == nil then
                return line
            end

            return model.old_line_to_new_line(model.build(item, source), line)
        end
    end

    return line
end

--- Close the view and give its window back its buffer and options.
function Preview:close()
    self.view:close()
end

return Preview
