--- Treesitter highlights for one version of a file, injections included.
--- Each version is parsed once as a string and its captures are collected
--- only for the lines asked for.

local M = {}

---@class IterSyntaxSpan
---@field col integer 0-based byte column
---@field end_col integer exclusive
---@field hl integer highlight group id
---@field priority integer

---@class IterSyntaxEntry
---@field lang string
---@field source string
---@field parser table treesitter LanguageTree
---@field parsed boolean
---@field spans table<integer, IterSyntaxSpan[]> per line, filled on demand

-- Keyed by the lines table of a version, so a version that is no longer
-- referenced drops its parse. Entries must not hold that table themselves.
---@type table<string[], IterSyntaxEntry>
local cache = setmetatable({}, { __mode = 'k' })

---@type table<string, table<integer, integer|false>>
local hl_ids = {}

--- The highlight group id of `capture` in `query`, false for captures that
--- carry no highlight.
---@param query table treesitter query
---@param lang string
---@param capture integer
---@return integer|false
local function hl_id(query, lang, capture)
    local ids = hl_ids[lang]

    if ids == nil then
        ids = {}
        hl_ids[lang] = ids
    end

    if ids[capture] == nil then
        local name = query.captures[capture]
        local plain = vim.startswith(name, '_')
            or name == 'spell'
            or name == 'nospell'
        ids[capture] = not plain
                and vim.api.nvim_get_hl_id_by_name('@' .. name .. '.' .. lang)
            or false
    end

    return ids[capture]
end

--- The treesitter language for `path`, when its parser and highlight query
--- are installed.
---@param path string
---@return string?
function M.lang(path)
    local filetype = vim.filetype.match({ filename = path })

    if filetype == nil then
        return nil
    end

    local lang = vim.treesitter.language.get_lang(filetype) or filetype
    local ok, added = pcall(vim.treesitter.language.add, lang)

    if not ok or not added then
        return nil
    end

    local has_query, query = pcall(vim.treesitter.query.get, lang, 'highlights')

    return has_query and query ~= nil and lang or nil
end

--- Collect the spans of lines `first` to `last` (1-based) from every tree.
---@param entry IterSyntaxEntry
---@param lines string[]
---@param first integer
---@param last integer
local function collect(entry, lines, first, last)
    for lnum = first, last do
        entry.spans[lnum] = {}
    end

    entry.parser:for_each_tree(function(tree, ltree)
        local lang = ltree:lang()
        local query = vim.treesitter.query.get(lang, 'highlights')

        if query == nil then
            return
        end

        for capture, node, metadata in
            query:iter_captures(tree:root(), entry.source, first - 1, last)
        do
            local id = hl_id(query, lang, capture)

            if id then
                local range = vim.treesitter.get_range(
                    node,
                    entry.source,
                    metadata[capture]
                )
                local priority = tonumber(
                    metadata.priority
                        or metadata[capture] and metadata[capture].priority
                ) or vim.hl.priorities.treesitter

                for row = math.max(range[1], first - 1), math.min(range[4], last - 1) do
                    local line = lines[row + 1]
                    local col = row == range[1] and range[2] or 0
                    local end_col = row == range[4] and range[5] or #line

                    if end_col > col then
                        table.insert(entry.spans[row + 1], {
                            col = col,
                            end_col = math.min(end_col, #line),
                            hl = id,
                            priority = priority,
                        })
                    end
                end
            end
        end
    end)
end

--- Spans of `lnums`, collecting the lines not seen yet in runs.
---@param entry IterSyntaxEntry
---@param lines string[]
---@param lnums integer[]
---@return table<integer, IterSyntaxSpan[]>
local function spans_for(entry, lines, lnums)
    local missing = vim.tbl_filter(function(lnum)
        return entry.spans[lnum] == nil and lines[lnum] ~= nil
    end, lnums)
    table.sort(missing)

    local index = 1

    while index <= #missing do
        local first, last = missing[index], missing[index]

        while missing[index + 1] ~= nil and missing[index + 1] <= last + 1 do
            index = index + 1
            last = missing[index]
        end

        collect(entry, lines, first, last)
        index = index + 1
    end

    local result = {}

    for _, lnum in ipairs(lnums) do
        result[lnum] = entry.spans[lnum]
    end

    return result
end

--- Highlight spans for lines `lnums` of the version `lines` in `lang`.
--- `callback` gets them once the version is parsed, right away when it was
--- parsed before, and nil when parsing timed out.
---@param lines string[]
---@param lang string
---@param lnums integer[]
---@param callback fun(spans: table<integer, IterSyntaxSpan[]>?)
function M.request(lines, lang, lnums, callback)
    local entry = cache[lines]

    if entry == nil or entry.lang ~= lang then
        local source = table.concat(lines, '\n')
        entry = {
            lang = lang,
            source = source,
            parser = vim.treesitter.get_string_parser(source, lang),
            parsed = false,
            spans = {},
        }
        cache[lines] = entry
    end

    if entry.parsed then
        callback(spans_for(entry, lines, lnums))
        return
    end

    entry.parser:parse(true, function(err)
        if err ~= nil then
            callback(nil)
            return
        end

        entry.parsed = true
        callback(spans_for(entry, lines, lnums))
    end)
end

return M
