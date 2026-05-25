---@class FluxConfig
---@field options FluxOptions
---@field keymaps_status FluxKeymapEntry[]
---@field keymaps_diff_stacked FluxKeymapEntry[]
---@field keymaps_diff_split FluxKeymapEntry[]
---@field keymaps_help FluxKeymapEntry[]
---@field highlight_specs table<string, FluxHighlightSpec>
---@field spinner_frames string[]
---@field owned_buffer_fields string[]
---@field highlight_namespace string
---@field diff_header_hl_name string
---@field diff_hunk_header_hl_name string
---@field debug boolean Whether to write debug-level logs to the flux log file

local defaults = require('flux.config.defaults')

local M = {}

---@param opts FluxOptions?
---@return string?
local function validate(opts)
    vim.validate('opts', opts, 'table', true, '`opts` should be a table')

    opts = opts or {}
    vim.validate('opts.preview', opts.preview, 'table', true)
    vim.validate('opts.status', opts.status, 'table', true)
    vim.validate('opts.keymaps', opts.keymaps, 'table', true)

    if opts.preview ~= nil then
        vim.validate('opts.preview.wrap', opts.preview.wrap, 'boolean', true)
        vim.validate(
            'opts.preview.show_line_numbers',
            opts.preview.show_line_numbers,
            'boolean',
            true
        )
        vim.validate(
            'opts.preview.show_metadata',
            opts.preview.show_metadata,
            'boolean',
            true
        )
        vim.validate(
            'opts.preview.diff_layout',
            opts.preview.diff_layout,
            'string',
            true
        )
        vim.validate(
            'opts.preview.diff_auto_threshold',
            opts.preview.diff_auto_threshold,
            'number',
            true
        )

        if
            opts.preview.diff_layout ~= nil
            and opts.preview.diff_layout ~= 'stacked'
            and opts.preview.diff_layout ~= 'split'
            and opts.preview.diff_layout ~= 'auto'
        then
            return "opts.preview.diff_layout must be 'stacked', 'split', or 'auto'"
        end

        if
            opts.preview.diff_auto_threshold ~= nil
            and opts.preview.diff_auto_threshold < 1
        then
            return 'opts.preview.diff_auto_threshold must be >= 1'
        end
    end

    if opts.status ~= nil then
        vim.validate('opts.status.width', opts.status.width, 'number', true)
        vim.validate(
            'opts.status.min_width',
            opts.status.min_width,
            'number',
            true
        )

        if opts.status.width ~= nil then
            if opts.status.width <= 0 or opts.status.width > 1 then
                return 'opts.status.width must be a number between 0 and 1'
            end
        end

        if opts.status.min_width ~= nil then
            if opts.status.min_width < 1 then
                return 'opts.status.min_width must be >= 1'
            end
        end

        if opts.status.layout ~= nil then
            vim.validate(
                'opts.status.layout',
                opts.status.layout,
                'string',
                true
            )

            if
                opts.status.layout ~= 'topleft'
                and opts.status.layout ~= 'replace'
            then
                return "opts.status.layout must be 'topleft' or 'replace'"
            end
        end
    end

    -- Validate keymap overrides via opts.keymaps.<area>
    if opts.keymaps ~= nil then
        if type(opts.keymaps) ~= 'table' then
            return 'opts.keymaps must be a table'
        end

        local valid_areas = {
            'status',
            'diff_stacked',
            'diff_split',
            'help',
        }

        for area, _ in pairs(opts.keymaps) do
            local found = false
            for _, v in ipairs(valid_areas) do
                if area == v then
                    found = true
                    break
                end
            end

            if not found then
                return 'opts.keymaps.'
                    .. area
                    .. ' is not a valid area (use: status, diff_stacked, diff_split, help)'
            end
        end

        for _, area_key in ipairs(valid_areas) do
            local raw = opts.keymaps[area_key]
            if raw ~= nil then
                if type(raw) ~= 'table' then
                    return 'opts.keymaps.' .. area_key .. ' must be a table'
                end

                local keys_seen = {}

                for i, entry in ipairs(raw) do
                    if type(entry) ~= 'table' then
                        return 'opts.keymaps.'
                            .. area_key
                            .. '['
                            .. i
                            .. '] must be a table'
                    end

                    if entry.key == nil or type(entry.key) ~= 'string' then
                        return 'opts.keymaps.'
                            .. area_key
                            .. '['
                            .. i
                            .. '].key must be a string'
                    end

                    if keys_seen[entry.key] then
                        return 'opts.keymaps.'
                            .. area_key
                            .. ' contains duplicate key: '
                            .. entry.key
                    end

                    keys_seen[entry.key] = true
                end
            end
        end
    end

    return nil
end

---@param user_opts FluxOptions?
---@return FluxConfig
function M.resolve(user_opts)
    user_opts = user_opts or {}

    local err = validate(user_opts)
    if err ~= nil then
        error(err)
    end

    local merged =
        vim.tbl_deep_extend('force', vim.deepcopy(defaults.options), user_opts)

    -- Keymaps: replace whole table when user provides overrides, otherwise
    -- use the defaults as-is. This keeps customisation simple: users can
    -- selectively override individual entries by providing an array of
    -- { key = '...', modes = {...}, desc = '...' } tables.
    local function resolve_keymaps(user_raw, default_list)
        if user_raw == nil then
            return vim.deepcopy(default_list)
        end

        -- User provided a table — deep-merge at the entry level so they can
        -- override desc/modes/action while keeping defaults for other entries.
        -- If an entry only has 'key' and 'desc', match by key to the default.
        local merged_list = {}

        for _, default_entry in ipairs(default_list) do
            local matched = nil
            for _, user_entry in ipairs(user_raw) do
                if
                    type(user_entry) == 'table'
                    and user_entry.key == default_entry.key
                then
                    matched = user_entry
                    break
                end
            end

            if matched then
                merged_list[#merged_list + 1] = vim.tbl_deep_extend(
                    'force',
                    vim.deepcopy(default_entry),
                    matched
                )
            else
                merged_list[#merged_list + 1] = vim.deepcopy(default_entry)
            end
        end

        return merged_list
    end

    local keymap_overrides = user_opts.keymaps or {}

    return {
        options = merged,
        keymaps_status = resolve_keymaps(
            keymap_overrides.status,
            defaults.keymaps_status
        ),
        keymaps_diff_stacked = resolve_keymaps(
            keymap_overrides.diff_stacked,
            defaults.keymaps_diff_stacked
        ),
        keymaps_diff_split = resolve_keymaps(
            keymap_overrides.diff_split,
            defaults.keymaps_diff_split
        ),
        keymaps_help = resolve_keymaps(
            keymap_overrides.help,
            defaults.keymaps_help
        ),
        highlight_specs = defaults.highlight_specs,
        spinner_frames = defaults.spinner_frames,
        owned_buffer_fields = defaults.owned_buffer_fields,
        highlight_namespace = defaults.highlight_namespace,
        diff_header_hl_name = defaults.diff_header_hl_name,
        diff_hunk_header_hl_name = defaults.diff_hunk_header_hl_name,
        debug = merged.debug,
    }
end

return M
