---@class IterAnchor
---@field path? string           nil for scope 'review'
---@field side 'old'|'new'
---@field base? IterAnchorBase   old side: version the deleted line came from
---@field start_line? integer
---@field end_line? integer
---@field lines? string[]        anchored text, for re-anchoring and export
---@field start_col? integer     passage: 0-based byte column on `start_line`
---@field end_col? integer       passage: exclusive byte column on `end_line`
---@field quote? string          passage: the selected text, lines joined by "\n"
---@field before? string         passage: the text before the quote, to tell repeats apart
---@field after? string          passage: the text after the quote

---@class IterAnnotation
---@field id string
---@field scope 'line'|'range'|'file'|'review'
---@field anchor IterAnchor
---@field body string
---@field outdated boolean
---@field created_at integer
---@field updated_at integer

--- `HEAD`, `index`, or the full sha of the commit or tree a review against
--- a base compared with.
---@alias IterAnchorBase 'HEAD'|'index'|string

---@alias IterAnchorVersion 'worktree'|IterAnchorBase

---@param base any
---@return boolean
local function is_base(base)
    return base == 'HEAD'
        or base == 'index'
        or type(base) == 'string'
            and (#base == 40 or #base == 64)
            and base:match('^%x+$') ~= nil
end

local M = {}

--- The version the deleted rows of each working-changes side come from, as
--- an old-side anchor's `base`.
---@type table<IterSide, IterAnchorBase>
M.OLD_BASE = { unstaged = 'index', staged = 'HEAD' }

--- The version the deleted rows of `file` come from, as an old-side
--- anchor's `base`: the base sha against a base, else `OLD_BASE`.
---@param file { side: IterSide, base?: string }
---@return IterAnchorBase?
function M.old_base(file)
    if file.side == 'base' then
        return file.base
    end

    return M.OLD_BASE[file.side]
end

--- The short sha an old-side anchor `a` follows, when its base is a commit
--- or tree, nil for `HEAD`, `index` and the new side.
---@param a IterAnchor
---@return string?
function M.short_base(a)
    local base = a.side == 'old' and a.base or nil

    if base == nil or base == 'HEAD' or base == 'index' then
        return nil
    end

    return base:sub(1, 7)
end

---@param line string
---@return string
local function strip_cr(line)
    return (line:gsub('\r$', ''))
end

---@param lines string[]
---@param at integer
---@param block string[]
---@return boolean
local function matches_at(lines, at, block)
    for i, line in ipairs(block) do
        local other = lines[at + i - 1]

        if other == nil or strip_cr(other) ~= strip_cr(line) then
            return false
        end
    end

    return true
end

---@param lines string[]
---@param start_col integer
---@param end_col integer
---@return string
local function quote_of(lines, start_col, end_col)
    lines = vim.tbl_map(strip_cr, lines)
    local count = #lines

    if count == 1 then
        return lines[1]:sub(start_col + 1, end_col)
    end

    local parts = { lines[1]:sub(start_col + 1) }
    vim.list_extend(parts, lines, 2, count - 1)
    table.insert(parts, lines[count]:sub(1, end_col))

    return table.concat(parts, '\n')
end

-- Bytes of text kept on each side of a passage to tell repeats apart.
local CONTEXT = 40

--- `lines` joined by "\n", and the index of the start of each line in it.
---@param lines string[]
---@return string text
---@return integer[] offsets
local function join(lines)
    local offsets, parts, at = {}, {}, 1

    for i, line in ipairs(lines) do
        line = strip_cr(line)
        offsets[i] = at
        parts[i] = line
        at = at + #line + 1
    end

    return table.concat(parts, '\n'), offsets
end

---@param byte integer
---@return boolean
local function is_continuation(byte)
    return byte >= 0x80 and byte < 0xC0
end

--- The text before and after the `length` bytes at `pos` of `text`, cut to
--- whole characters.
---@param text string
---@param pos integer
---@param length integer
---@return string before
---@return string after
local function context_of(text, pos, length)
    local before = text:sub(math.max(1, pos - CONTEXT), pos - 1)

    while #before > 0 and is_continuation(before:byte(1)) do
        before = before:sub(2)
    end

    local stop = pos + length
    local after = text:sub(stop, stop + CONTEXT - 1)
    local n = #after

    if n > 0 then
        local i = n

        while i > 1 and is_continuation(after:byte(i)) do
            i = i - 1
        end

        local lead = after:byte(i)
        local size = lead >= 0xF0 and 4
            or lead >= 0xE0 and 3
            or lead >= 0xC0 and 2
            or 1

        if i + size - 1 > n then
            after = after:sub(1, i - 1)
        end
    end

    return before, after
end

--- The context of the quote that starts at byte `col` of line `line` of
--- `lines`.
---@param lines string[]
---@param line integer
---@param col integer
---@param length integer
---@return string before
---@return string after
local function context_at(lines, line, col, length)
    local text, offsets = join(lines)

    return context_of(text, offsets[line] + col, length)
end

--- An anchor on `lines`, the version the anchor follows: the worktree file
--- for the new side, `base` for the old side. Without `start_line` it is a
--- file or review anchor and carries no text. With `start_col` and `end_col`
--- (0-based bytes, the end exclusive) it is a passage anchor that also keeps
--- the selected text; an empty selection makes a line anchor.
---@param opts { path?: string, side: 'old'|'new', base?: IterAnchorBase, start_line?: integer, end_line?: integer, start_col?: integer, end_col?: integer }
---@param lines? string[]
---@return IterAnchor
function M.create(opts, lines)
    vim.validate('opts', opts, 'table')
    vim.validate('opts.side', opts.side, function(side)
        return side == 'old' or side == 'new'
    end, "'old' or 'new'")

    if opts.side == 'old' then
        vim.validate(
            'opts.base',
            opts.base,
            is_base,
            "'HEAD', 'index' or a sha"
        )
    end

    ---@type IterAnchor
    local a = { path = opts.path, side = opts.side, base = opts.base }

    if opts.start_line == nil then
        return a
    end

    vim.validate('lines', lines, 'table')
    ---@cast lines string[]

    local start = opts.start_line
    local stop = opts.end_line or start
    a.start_line = start
    a.end_line = stop
    a.lines = vim.list_slice(lines, start, stop)

    if opts.start_col ~= nil and opts.end_col ~= nil then
        local quote = quote_of(a.lines, opts.start_col, opts.end_col)

        if quote ~= '' then
            a.start_col = opts.start_col
            a.end_col = math.min(opts.end_col, #strip_cr(a.lines[#a.lines]))
            a.quote = quote
            a.before, a.after = context_at(
                lines,
                start --[[@as integer]],
                opts.start_col --[[@as integer]],
                #quote
            )
        end
    end

    return a
end

--- The version whose lines an anchor follows when it is persisted.
---@param a IterAnchor
---@return IterAnchorVersion
function M.version(a)
    if a.side == 'old' then
        return a.base or 'HEAD'
    end

    return 'worktree'
end

--- The end column of a passage `quote` that starts at `col`, `breaks` lines
--- below its start line.
---@param quote string
---@param col integer
---@param breaks integer
---@return integer
local function end_col_of(quote, col, breaks)
    if breaks == 0 then
        return col + #quote
    end

    return #quote:match('^.*\n(.*)$')
end

---@param str string a character or more
---@return boolean
local function is_word(str)
    return str ~= '' and vim.fn.charclass(str) >= 2
end

--- The character that ends `str`, empty for an empty string.
---@param str string
---@return string
local function last_char(str)
    if str == '' then
        return ''
    end

    return str:sub(#str + vim.str_utf_start(str, #str))
end

--- Which edges of `a.quote` sat on a word edge when it was stored: a
--- word character at an edge of the quote with no word character beside it.
--- A passage that cut into a word may do so again.
---@param a IterAnchor
---@return { start: boolean, stop: boolean }
local function word_edges(a)
    local quote = a.quote --[[@as string]]
    local first, last = a.lines[1], a.lines[#a.lines]
    local head = (first or ''):sub(1, a.start_col or 0)
    local tail = (last or ''):sub((a.end_col or 0) + 1)

    return {
        start = is_word(quote) and not is_word(last_char(head)),
        stop = is_word(last_char(quote)) and not is_word(tail),
    }
end

--- Whether the `quote` at `pos` of `text` sits on the word edges `edges`
--- asks for, so that "old" doesn't match inside "cold".
---@param text string
---@param pos integer
---@param quote string
---@param edges { start: boolean, stop: boolean }
---@return boolean
local function at_word_edges(text, pos, quote, edges)
    if
        edges.start
        and is_word(last_char(text:sub(math.max(1, pos - 4), pos - 1)))
    then
        return false
    end

    return not (
        edges.stop and is_word(text:sub(pos + #quote, pos + #quote + 3))
    )
end

---@param a string
---@param b string
---@return integer
local function common_prefix(a, b)
    local n = 0

    while n < #a and n < #b and a:byte(n + 1) == b:byte(n + 1) do
        n = n + 1
    end

    return n
end

---@param a string
---@param b string
---@return integer
local function common_suffix(a, b)
    local n = 0

    while n < #a and n < #b and a:byte(#a - n) == b:byte(#b - n) do
        n = n + 1
    end

    return n
end

--- The line holding byte `pos` of the joined text and its 0-based column.
---@param offsets integer[]
---@param pos integer
---@return integer line
---@return integer col
local function locate(offsets, pos)
    local low, high = 1, #offsets

    while low < high do
        local mid = math.ceil((low + high) / 2)

        if offsets[mid] <= pos then
            low = mid
        else
            high = mid - 1
        end
    end

    return low, pos - offsets[low]
end

--- Where the passage of `a` sits in `lines`, at the whole words of its
--- quote. Context stored with the anchor tells repeats apart: the stored
--- position wins when the context there is intact, else the occurrence whose
--- surroundings match best, and the text is lost when two match equally
--- well or, with several occurrences, none matches at all. An anchor
--- without context takes the stored position, else the occurrence nearest
--- to it (line, then column), the upper one on a tie.
---@param a IterAnchor
---@param lines string[]
---@return integer? start
---@return integer? end
---@return integer? start_col
---@return integer? end_col
local function resolve_passage(a, lines)
    local quote = a.quote --[[@as string]]
    local stored = a.start_line or 1
    local _, breaks = quote:gsub('\n', '')
    local text, offsets = join(lines)
    local edges = word_edges(a)
    local before, after = a.before or '', a.after or ''
    local with_context = (a.before ~= nil or a.after ~= nil)
        and #before + #after > 0

    ---@param pos integer
    ---@return integer
    local function score(pos)
        return common_suffix(
            before,
            text:sub(math.max(1, pos - #before), pos - 1)
        ) + common_prefix(
            after,
            text:sub(pos + #quote, pos + #quote + #after - 1)
        )
    end

    local function found(pos)
        local line, col = locate(offsets, pos)

        return line, line + breaks, col, end_col_of(quote, col, breaks)
    end

    if a.start_col ~= nil and offsets[stored] ~= nil then
        local pos = offsets[stored] + a.start_col

        if
            text:sub(pos, pos + #quote - 1) == quote
            and at_word_edges(text, pos, quote, edges)
            and (
                not (a.before ~= nil or a.after ~= nil)
                or (with_context and score(pos) == #before + #after)
            )
        then
            return found(pos)
        end
    end

    ---@type { pos: integer, line: integer, col: integer, score: integer }[]
    local candidates = {}
    local init = 1

    while true do
        local pos = text:find(quote, init, true)

        if pos == nil then
            break
        end

        if at_word_edges(text, pos, quote, edges) then
            local line, col = locate(offsets, pos)
            table.insert(
                candidates,
                { pos = pos, line = line, col = col, score = score(pos) }
            )
        end

        init = pos + 1
    end

    if #candidates == 0 then
        return nil
    end

    local best

    if a.before == nil and a.after == nil then
        for _, c in ipairs(candidates) do
            if
                best == nil
                or math.abs(c.line - stored) < math.abs(best.line - stored)
                or (
                    c.line == best.line
                    and math.abs(c.col - (a.start_col or 0))
                        < math.abs(best.col - (a.start_col or 0))
                )
            then
                best = c
            end
        end
    elseif #candidates == 1 then
        best = candidates[1]
    else
        local tied = false

        for _, c in ipairs(candidates) do
            if best == nil or c.score > best.score then
                best, tied = c, false
            elseif c.score == best.score then
                tied = true
            end
        end

        if tied or best.score == 0 then
            return nil
        end
    end

    return found(best.pos)
end

--- Where the anchored text sits in `lines`: at the stored position when it is
--- still there, else at the match nearest to it, the upper one on a tie.
--- A passage anchor (one with a `quote`) also returns the columns of its
--- start and end (0-based bytes, the end exclusive). Nil when the text is
--- gone or the anchor has none.
---@param a IterAnchor
---@param lines? string[]
---@return integer? start
---@return integer? end
---@return integer? start_col
---@return integer? end_col
function M.resolve(a, lines)
    local block = a.lines

    if lines == nil or block == nil or #block == 0 then
        return nil
    end

    if a.quote ~= nil and a.quote ~= '' then
        return resolve_passage(a, lines)
    end

    local stored = a.start_line or 1
    local count = #block

    if matches_at(lines, stored, block) then
        return stored, stored + count - 1
    end

    local best

    for at = 1, #lines - count + 1 do
        if
            matches_at(lines, at, block)
            and (best == nil or math.abs(at - stored) < math.abs(best - stored))
        then
            best = at
        end
    end

    if best == nil then
        return nil
    end

    return best, best + count - 1
end

--- The annotation with its anchor moved to where `lines` has the text, or marked
--- outdated at its old position when the text is gone. File and review
--- annotations have no text to lose. `annotation` itself is left untouched.
---@param annotation IterAnnotation
---@param lines? string[]
---@return IterAnnotation
---@return boolean changed
function M.follow(annotation, lines)
    if annotation.scope == 'file' or annotation.scope == 'review' then
        return annotation, false
    end

    local a = annotation.anchor
    local start, stop, start_col, end_col = M.resolve(a, lines)

    if start == nil then
        if annotation.outdated then
            return annotation, false
        end

        local result = vim.deepcopy(annotation)
        result.outdated = true
        return result, true
    end

    local before, after

    if start_col ~= nil and (a.before ~= nil or a.after ~= nil) then
        before, after = context_at(
            lines --[[@as string[] ]],
            start --[[@as integer]],
            start_col,
            #a.quote
        )
    end

    if
        not annotation.outdated
        and start == a.start_line
        and stop == a.end_line
        and start_col == a.start_col
        and end_col == a.end_col
        and before == a.before
        and after == a.after
        and (
            start_col == nil
            or vim.deep_equal(
                a.lines,
                vim.list_slice(lines --[[@as string[] ]], start, stop)
            )
        )
    then
        return annotation, false
    end

    local result = vim.deepcopy(annotation)
    result.outdated = false
    result.anchor.start_line = start
    result.anchor.end_line = stop

    if start_col ~= nil then
        result.anchor.start_col = start_col
        result.anchor.end_col = end_col
        result.anchor.before = before
        result.anchor.after = after
        result.anchor.lines =
            vim.list_slice(lines --[[@as string[] ]], start, stop)
    end

    return result, true
end

return M
