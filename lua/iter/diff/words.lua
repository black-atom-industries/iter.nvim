--- Word emphasis for changed lines: del and add rows of a change group are
--- paired by similarity, then each pair is diffed token by token.
---
--- Ranges are 0-based byte columns, end exclusive: `{ col, end_col }`.

local M = {}

-- Lines longer than this (bytes) get no emphasis.
local MAX_LINE = 500
-- Groups with more del and add lines than this get no pairing.
local MAX_GROUP = 60
-- Share of changed bytes above which a pair gets no emphasis.
local MAX_CHANGED = 0.6

---@class IterWordTokens
---@field texts string[]
---@field starts integer[] 0-based byte column of each token

--- Word runs (letters, digits, `_` and every byte of a multibyte character),
--- whitespace runs, and single punctuation characters.
---@param text string
---@return IterWordTokens
local function tokenize(text)
    local tokens = { texts = {}, starts = {} }
    local pos = 1

    while pos <= #text do
        local stop = text:match('^[%w_\128-\255]+()', pos)
            or text:match('^%s+()', pos)
            or pos + 1

        table.insert(tokens.texts, text:sub(pos, stop - 1))
        table.insert(tokens.starts, pos - 1)
        pos = stop
    end

    return tokens
end

---@param lines string[]
---@return string
local function as_text(lines)
    return #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
end

--- Byte ranges of tokens `first` to `first + count - 1`, merged with the
--- range before when only whitespace sits between them.
---@param ranges integer[][]
---@param text string
---@param tokens IterWordTokens
---@param first integer
---@param count integer
---@return integer changed bytes
local function push_range(ranges, text, tokens, first, count)
    if count == 0 then
        return 0
    end

    local col = tokens.starts[first]
    local last = first + count - 1
    local end_col = tokens.starts[last] + #tokens.texts[last]
    local prev = ranges[#ranges]

    if prev ~= nil and text:sub(prev[2] + 1, col):match('^%s*$') then
        prev[2] = end_col
    else
        table.insert(ranges, { col, end_col })
    end

    return end_col - col
end

--- Changed byte ranges of `old` and `new`, or nothing when a line is too
--- long or most of the pair changed.
---@param old string
---@param new string
---@return integer[][]? del ranges in `old`
---@return integer[][]? add ranges in `new`
function M.ranges(old, new)
    if #old > MAX_LINE or #new > MAX_LINE then
        return
    end

    local a, b = tokenize(old), tokenize(new)
    local hunks = vim.text.diff(as_text(a.texts), as_text(b.texts), {
        result_type = 'indices',
    }) --[[@as integer[][] ]]

    local del, add = {}, {}
    local changed = 0

    for _, hunk in ipairs(hunks) do
        changed = changed + push_range(del, old, a, hunk[1], hunk[2])
        changed = changed + push_range(add, new, b, hunk[3], hunk[4])
    end

    if changed > MAX_CHANGED * (#old + #new) then
        return
    end

    return del, add
end

--- Pair the del rows `dels` with the add rows `adds` that follow them.
---@param rows IterDiffRow[]
---@param dels integer[] row indexes
---@param adds integer[] row indexes
local function pair_group(rows, dels, adds)
    if #dels + #adds > MAX_GROUP then
        return
    end

    local function texts(indexes)
        return vim.tbl_map(function(index)
            return rows[index].text
        end, indexes)
    end

    local hunks = vim.text.diff(as_text(texts(dels)), as_text(texts(adds)), {
        result_type = 'indices',
        linematch = MAX_GROUP,
    }) --[[@as integer[][] ]]

    for _, hunk in ipairs(hunks) do
        for offset = 0, math.min(hunk[2], hunk[4]) - 1 do
            local d, a = dels[hunk[1] + offset], adds[hunk[3] + offset]
            local del, add = M.ranges(rows[d].text, rows[a].text)

            rows[d].pair, rows[a].pair = a, d

            if del ~= nil and #del > 0 then
                rows[d].words = del
            end

            if add ~= nil and #add > 0 then
                rows[a].words = add
            end
        end
    end
end

--- Set `pair` and `words` on the del and add rows of `rows`, dropping any
--- earlier values. A change group is a run of del rows and the add rows
--- right after it.
---@param rows IterDiffRow[]
function M.annotate(rows)
    for _, row in ipairs(rows) do
        row.pair, row.words = nil, nil
    end

    local index = 1

    while index <= #rows do
        local dels, adds = {}, {}

        while rows[index] ~= nil and rows[index].kind == 'del' do
            table.insert(dels, index)
            index = index + 1
        end

        while rows[index] ~= nil and rows[index].kind == 'add' do
            table.insert(adds, index)
            index = index + 1
        end

        if #dels > 0 and #adds > 0 then
            pair_group(rows, dels, adds)
        elseif #dels == 0 and #adds == 0 then
            index = index + 1
        end
    end
end

return M
