local defaults = require('iter.config.defaults')

local M = {}

---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number' and value == math.floor(value)
end

-- Option name -> type for leaves, or a nested schema for tables.
local SCHEMA = {
    debug = 'boolean',
    drawer = {
        height = 'number',
        zindex = 'integer',
        breakpoint = 'integer',
        commits = 'integer',
    },
    diff = {
        expand_step = 'integer',
        syntax_max_lines = 'integer',
        word_diff = 'boolean',
        args = 'table',
    },
    export = { intro = 'string' },
    refresh = { poll_ms = 'integer' },
    confirm = { discard = 'boolean', ignore = 'boolean' },
    icons = { annotation = 'string' },
}

---@param tbl table
---@return string
local function sorted_names(tbl)
    local names = vim.tbl_keys(tbl)
    table.sort(names)

    return table.concat(names, ', ')
end

---@param opts table
---@param schema table
---@param prefix string
local function validate_options(opts, schema, prefix)
    for name, value in pairs(opts) do
        local path = prefix .. '.' .. name
        local expected = schema[name]

        if expected == nil then
            error(path .. ' is not an option', 0)
        end

        if type(expected) == 'table' then
            vim.validate(path, value, 'table')
            validate_options(value, expected, path)
        elseif expected == 'integer' then
            vim.validate(path, value, is_integer, false, 'integer')
        else
            vim.validate(path, value, expected)
        end
    end
end

---@param value any
---@return boolean
local function is_key_value(value)
    if value == false then
        return true
    end

    if type(value) == 'string' then
        return value ~= ''
    end

    if type(value) ~= 'table' or #value == 0 then
        return false
    end

    for _, lhs in ipairs(value) do
        if type(lhs) ~= 'string' or lhs == '' then
            return false
        end
    end

    return #value == vim.tbl_count(value)
end

---@param keys table
local function validate_keys(keys)
    vim.validate('opts.keys', keys, 'table')

    for view, actions in pairs(keys) do
        local path = 'opts.keys.' .. tostring(view)
        local known = defaults.keys[view]

        if known == nil then
            error(
                path
                    .. ' is not a view (use: '
                    .. sorted_names(defaults.keys)
                    .. ')',
                0
            )
        end

        vim.validate(path, actions, 'table')

        for action, value in pairs(actions) do
            local action_path = path .. '.' .. tostring(action)

            if known[action] == nil then
                error(
                    string.format(
                        '%s is not an action of %s (use: %s)',
                        action_path,
                        view,
                        sorted_names(known)
                    ),
                    0
                )
            end

            if not is_key_value(value) then
                error(
                    action_path .. ' must be a key, a list of keys, or false',
                    0
                )
            end
        end
    end
end

local DIFF_ARGS_ALLOWED = '--diff-algorithm=<myers|minimal|patience|histogram>, '
    .. '--patience, --histogram, --minimal, --indent-heuristic, '
    .. '--no-indent-heuristic, --inter-hunk-context=<n>, -U<n> or '
    .. '--unified=<n> with n >= 1'

local DIFF_ALGORITHMS = {
    myers = true,
    minimal = true,
    patience = true,
    histogram = true,
}

local DIFF_FLAGS = {
    ['--patience'] = true,
    ['--histogram'] = true,
    ['--minimal'] = true,
    ['--indent-heuristic'] = true,
    ['--no-indent-heuristic'] = true,
}

---@param arg any
---@return boolean
local function is_diff_arg(arg)
    if type(arg) ~= 'string' then
        return false
    end

    if DIFF_FLAGS[arg] then
        return true
    end

    local algorithm = arg:match('^%-%-diff%-algorithm=(.*)$')

    if algorithm ~= nil then
        return DIFF_ALGORITHMS[algorithm] == true
    end

    if arg:match('^%-%-inter%-hunk%-context=%d+$') then
        return true
    end

    local lines = arg:match('^%-U(%d+)$') or arg:match('^%-%-unified=(%d+)$')

    return lines ~= nil and tonumber(lines) >= 1
end

---@param args any
local function validate_diff_args(args)
    if not vim.islist(args) then
        error('opts.diff.args must be a list of strings', 0)
    end

    for index, arg in ipairs(args) do
        if not is_diff_arg(arg) then
            error(
                string.format(
                    'opts.diff.args[%d] = %s is not allowed (use: %s)',
                    index,
                    vim.inspect(arg),
                    DIFF_ARGS_ALLOWED
                ),
                0
            )
        end
    end
end

---@param opts IterOptions
local function validate(opts)
    local keys = opts.keys
    local options = vim.deepcopy(opts)
    options.keys = nil

    validate_options(options, SCHEMA, 'opts')

    local height = opts.drawer and opts.drawer.height

    if height ~= nil and (height <= 0 or height > 1) then
        error('opts.drawer.height must be a number between 0 and 1', 0)
    end

    local commits = opts.drawer and opts.drawer.commits

    if commits ~= nil and commits < 0 then
        error('opts.drawer.commits must be 0 or more', 0)
    end

    if opts.diff and opts.diff.args ~= nil then
        validate_diff_args(opts.diff.args)
    end

    if keys ~= nil then
        validate_keys(keys)
    end
end

---@param value IterKeyValue
---@return string[]
local function normalize_lhs(value)
    if value == false then
        return {}
    end

    if type(value) == 'string' then
        return { value }
    end

    return vim.deepcopy(value)
end

---@param user_keys table<IterView, table<string, IterKeyValue>>?
---@return table<IterView, table<string, string[]>>
local function resolve_keys(user_keys)
    user_keys = user_keys or {}
    local resolved = {}

    for view, actions in pairs(defaults.keys) do
        local overrides = user_keys[view] or {}
        resolved[view] = {}

        for action, value in pairs(actions) do
            local override = overrides[action]

            if override == nil then
                override = value
            end

            resolved[view][action] = normalize_lhs(override)
        end
    end

    return resolved
end

---@param user_opts IterOptions?
---@return IterConfig
function M.resolve(user_opts)
    vim.validate('opts', user_opts, 'table', true)
    user_opts = user_opts or {}

    validate(user_opts)

    local options = vim.deepcopy(user_opts)
    options.keys = nil

    local merged =
        vim.tbl_deep_extend('force', vim.deepcopy(defaults.options), options)

    return {
        options = merged,
        keys = resolve_keys(user_opts.keys),
        debug = merged.debug,
    }
end

return M
