--- Word emphasis for changed lines: del and add rows of a change group are
--- paired by similarity, then each pair is diffed token by token.
---
--- Ranges are 0-based byte columns, end exclusive: `{ col, end_col }`.

local model = require('iter.diff.model')

local M = {}

-- Lines longer than this (bytes) get no emphasis.
local MAX_LINE = 500
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

--- Byte ranges of tokens `first` to `first + count - 1`, merged with the
--- range before when only whitespace sits between them. Whitespace at either
--- end of the run is left out, so a change in indentation alone marks nothing.
---@param ranges integer[][]
---@param text string
---@param tokens IterWordTokens
---@param first integer
---@param count integer
---@return integer changed bytes, whitespace included
local function push_range(ranges, text, tokens, first, count)
    if count == 0 then
        return 0
    end

    local last = first + count - 1
    local changed = tokens.starts[last]
        + #tokens.texts[last]
        - tokens.starts[first]

    while first <= last and tokens.texts[first]:match('^%s+$') do
        first = first + 1
    end

    while last >= first and tokens.texts[last]:match('^%s+$') do
        last = last - 1
    end

    if first > last then
        return changed
    end

    local col = tokens.starts[first]
    local end_col = tokens.starts[last] + #tokens.texts[last]
    local prev = ranges[#ranges]

    if prev ~= nil and text:sub(prev[2] + 1, col):match('^%s*$') then
        prev[2] = end_col
    else
        table.insert(ranges, { col, end_col })
    end

    return changed
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
    local hunks =
        vim.text.diff(model.as_text(a.texts), model.as_text(b.texts), {
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

--- Set `pair` and `words` on the del and add rows of `rows` that pair by
--- similarity (`model.pairs`), dropping any earlier values.
---@param rows IterDiffRow[]
function M.annotate(rows)
    for _, row in ipairs(rows) do
        row.pair, row.words = nil, nil
    end

    for _, pair in ipairs(model.pairs(rows)) do
        if pair.similar then
            local d, a = pair.del, pair.add
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

return M
