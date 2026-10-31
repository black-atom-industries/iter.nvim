---@class GitStatusEntry
---@field staged string
---@field unstaged string
---@field path string
---@field orig_path string?

---@class GitStatusSnapshot
---@field branch string
---@field entries GitStatusEntry[]
---@field detached boolean? HEAD is not on a branch
---@field root string
---@field error string?

local git = {}

local changes = require('iter.changes')
local log = require('iter.log')
local patch = require('iter.diff.patch')
local util = require('iter.util')

---@param output string
---@param start integer
---@return string?, integer?
local function read_nul_field(output, start)
    local stop = output:find('\0', start, true)

    if stop == nil then
        return nil, nil
    end

    return output:sub(start, stop - 1), stop + 1
end

---@param staged string
---@param unstaged string
---@return boolean
local function is_rename_or_copy(staged, unstaged)
    return staged == 'R' or staged == 'C' or unstaged == 'R' or unstaged == 'C'
end

---@param output string
---@return GitStatusEntry[]
local function parse_status(output)
    local entries = {}
    local index
    index = 1

    while index <= #output do
        local record
        record, index = read_nul_field(output, index)

        if record == nil or index == nil then
            break
        end

        if record ~= '' then
            local staged = record:sub(1, 1)
            local unstaged = record:sub(2, 2)

            ---@type GitStatusEntry
            local entry = {
                staged = staged,
                unstaged = unstaged,
                path = record:sub(4),
            }

            if is_rename_or_copy(staged, unstaged) then
                entry.orig_path, index = read_nul_field(output, index)
            end

            table.insert(entries, entry)
        end
    end

    return entries
end

---@type boolean?
local has_git

--- Whether `git` is executable, checked once; the first miss tells the user.
---@return boolean
local function ensure_git()
    if has_git == nil then
        has_git = vim.fn.executable('git') == 1

        if not has_git then
            util.error('`git` is not executable')
        end
    end

    return has_git
end

---@alias GitResult {
---output: string,
---exit_code: number,
---stderr: string,
---}

local return_result

---Executes a git command and returns the result
---@param args string[] List of git arguments (e.g., {"status", "--porcelain"})
---@param opts? table Options { cwd = string?, ignore_error = boolean?, stdin = string?, bytes = boolean? }; `bytes` keeps carriage returns in the output
---@return GitResult
function git.run(args, opts)
    opts = opts or {}

    if not ensure_git() then
        return {
            output = '',
            exit_code = 127,
            stderr = '`git` is not executable',
        }
    end

    -- --no-optional-locks keeps read-only commands (status, diff) from
    -- opportunistically rewriting .git/index, which would re-trigger the
    -- fs-event watchers and loop the auto-refresh.
    local cmd = { 'git', '--no-optional-locks' }
    vim.list_extend(cmd, args)

    local cwd = opts.cwd or vim.fn.getcwd()

    local job = vim.system(
        cmd,
        { text = not opts.bytes, cwd = cwd, stdin = opts.stdin }
    )
    local result = job:wait()

    local output = result.stdout or ''
    local stderr = result.stderr or ''
    local exit_code = result.code or 1

    if exit_code ~= 0 and not opts.ignore_error then
        log.error(
            string.format(
                'git command failed (%d): %s\n%s',
                exit_code,
                table.concat(cmd, ' '),
                stderr
            )
        )
    end

    log.debug(string.format('%s (%d)', table.concat(cmd, ' '), exit_code))

    return {
        output = output,
        exit_code = exit_code,
        stderr = stderr,
    }
end

---@param res GitResult
---@return string
function return_result(res)
    local value = res.exit_code == 0 and res.output or res.stderr

    -- Preserve meaningful leading spaces in outputs like `git status --short`.
    local v, _ = value:gsub('[\r\n]+$', '')
    return v
end

---@return string
function git.root()
    local out = git.run(
        { 'rev-parse', '--show-toplevel' },
        { ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return ''
    end

    return return_result(out)
end

---@param root? string worktree root, the one of the cwd when nil
---@return GitStatusSnapshot
function git.status_snapshot(root)
    if not ensure_git() then
        return {
            branch = '',
            entries = {},
            root = '',
            error = '`git` is not executable',
        }
    end

    root = root or git.root()

    if root == '' then
        return {
            branch = '',
            entries = {},
            root = '',
            error = 'Not inside a git repository',
        }
    end

    local branch_out = git.run(
        { 'branch', '--show-current' },
        { cwd = root, ignore_error = true }
    )
    local branch = return_result(branch_out)
    local detached = branch == ''

    if branch == '' then
        local head_out = git.run(
            { 'rev-parse', '--short', 'HEAD' },
            { cwd = root, ignore_error = true }
        )

        branch = head_out.exit_code == 0 and return_result(head_out)
            or '(unknown)'
    end

    local status_out = git.run(
        { 'status', '--porcelain=v1', '-z', '--untracked-files=all' },
        { cwd = root }
    )

    if status_out.exit_code ~= 0 then
        return {
            branch = branch,
            entries = {},
            root = root,
            error = return_result(status_out),
        }
    end

    return {
        branch = branch,
        entries = parse_status(status_out.output),
        detached = detached,
        root = root,
    }
end

--- `git.status_snapshot` without waiting: the branch and the entries of
--- `root`, read in the background, then `on_done` on the main loop.
---@param root string
---@param on_done fun(snapshot: GitStatusSnapshot)
function git.status_async(root, on_done)
    local done = vim.schedule_wrap(on_done)

    if vim.fn.executable('git') == 0 then
        done({
            branch = '',
            entries = {},
            root = root,
            error = '`git` is not executable',
        })
        return
    end

    -- A spawn that fails, such as on a root removed meanwhile, reads as a
    -- failed command.
    local function run(args, on_exit)
        local cmd = vim.list_extend({ 'git', '--no-optional-locks' }, args)
        local ok, err =
            pcall(vim.system, cmd, { text = true, cwd = root }, on_exit)

        if not ok then
            on_exit({ code = -1, stdout = '', stderr = tostring(err) })
        end
    end

    run({ 'branch', '--show-current' }, function(branch_out)
        run(
            { 'status', '--porcelain=v1', '-z', '--untracked-files=all' },
            function(status_out)
                local branch = vim.trim(branch_out.stdout or '')
                local failed = branch_out.code ~= 0 and branch_out
                    or status_out.code ~= 0 and status_out
                    or nil

                if failed ~= nil then
                    done({
                        branch = branch,
                        entries = {},
                        root = root,
                        error = vim.trim(failed.stderr or ''),
                    })
                    return
                end

                done({
                    branch = branch,
                    entries = parse_status(status_out.stdout or ''),
                    detached = branch == '',
                    root = root,
                })
            end
        )
    end)
end

---Absolute paths of files in the git dir, e.g. `index` and `HEAD`. In a
---linked worktree they live under the common dir's `worktrees/<name>/`.
---@param root string
---@param names string[]
---@return string[]? paths nil outside a repository
function git.git_paths(root, names)
    local args = { 'rev-parse', '--path-format=absolute' }

    for _, name in ipairs(names) do
        vim.list_extend(args, { '--git-path', name })
    end

    local out = git.run(args, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil
    end

    return vim.split(return_result(out), '\n', { plain = true })
end

---The identity of the repository `root` belongs to, the same for all of its
---linked worktrees: `<name>-<sha8>`, where name is the main worktree's
---directory and sha8 the first 8 hex of the sha256 of the resolved common
---git dir.
---@param root string
---@return string? id nil outside a repository
---@return string? error
function git.repo_id(root)
    local out = git.run(
        { 'rev-parse', '--path-format=absolute', '--git-common-dir' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local common = return_result(out)
    common = vim.uv.fs_realpath(common) or common

    local name = vim.fs.basename(common)

    if name == '.git' then
        name = vim.fs.basename(vim.fs.dirname(common))
    else
        name = name:gsub('%.git$', '')
    end

    return name .. '-' .. vim.fn.sha256(common):sub(1, 8)
end

---The branch HEAD of `root` is on, also when it has no commit yet.
---@param root string
---@return string? branch nil when HEAD is detached or outside a repository
function git.head_branch(root)
    local out = git.run(
        { 'symbolic-ref', '--quiet', 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil
    end

    local ref = return_result(out)

    if not vim.startswith(ref, 'refs/heads/') then
        return nil
    end

    return ref:sub(#'refs/heads/' + 1)
end

--- Run `args -- <paths>` in `root`, every path a literal pathspec so glob
--- characters in file names never widen the action.
---@param root string
---@param args string[]
---@param paths string[]
---@return boolean
---@return string?
local function run_on_paths(root, args, paths)
    if #paths == 0 then
        return true
    end

    local cmd = vim.list_extend(vim.deepcopy(args), { '--' })

    for _, path in ipairs(paths) do
        table.insert(cmd, ':(literal)' .. path)
    end

    local out = git.run(cmd, { cwd = root, ignore_error = true })

    return out.exit_code == 0, return_result(out)
end

---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.stage(root, paths)
    return run_on_paths(root, { 'add' }, paths)
end

--- On an unborn HEAD, `rm --cached` takes the paths out of the index and
--- leaves the worktree files; `--force` lets it drop staged content that
--- differs from the worktree too.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.unstage(root, paths)
    local head = git.run(
        { 'rev-parse', '--verify', '--quiet', 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if head.exit_code ~= 0 then
        return run_on_paths(
            root,
            { 'rm', '--cached', '--force', '--quiet' },
            paths
        )
    end

    return run_on_paths(root, { 'restore', '--staged' }, paths)
end

--- Restore the worktree from the index; staged changes stay.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.discard(root, paths)
    return run_on_paths(root, { 'restore', '--worktree' }, paths)
end

--- Delete untracked files. Tracked and ignored paths are left alone, and
--- directories are not recursed into.
---@param root string
---@param paths string[]
---@return boolean
---@return string?
function git.delete_untracked(root, paths)
    return run_on_paths(root, { 'clean', '--force' }, paths)
end

--- Append `path`, a path of `root`, to the `.gitignore` at `root` as a
--- pattern anchored to the root: `/path`, or `/dir/` for a directory given
--- as `dir/`. Glob characters and trailing spaces are escaped, so the
--- pattern matches the path alone. The file is created when missing; a last
--- line without a newline gets one first. No other file is touched.
---@param root string
---@param path string
---@return boolean
---@return string? error
function git.ignore(root, path)
    local file = vim.fs.joinpath(root, '.gitignore')
    local pattern = path:gsub('[\\*?%[]', '\\%0')
    local body, spaces = pattern:match('^(.-)( *)$')
    pattern = '/' .. body .. spaces:gsub(' ', '\\ ')

    local content = ''
    local reader = io.open(file, 'rb')

    if reader ~= nil then
        content = reader:read('*a') or ''
        reader:close()
    end

    local writer, err = io.open(file, 'ab')

    if writer == nil then
        return false, err
    end

    local lead = (content ~= '' and content:sub(-1) ~= '\n') and '\n' or ''
    local ok, write_err = writer:write(lead .. pattern .. '\n')

    writer:close()

    if not ok then
        return false, write_err
    end

    return true
end

--- Apply the patch `lines` (carriage returns kept) to the index for
--- `stage`, reversed for `unstage`. With `opts.check` git only checks that it
--- applies. The whitespace flags pin what lands to the patch text, whatever
--- the config.
---@param root string
---@param lines string[]
---@param kind 'stage'|'unstage'
---@param opts? { check?: boolean }
---@return boolean
---@return string
function git.apply_patch(root, lines, kind, opts)
    if #lines == 0 then
        return false, 'No patch to apply'
    end

    if kind ~= 'stage' and kind ~= 'unstage' then
        return false, 'Unknown hunk action: ' .. kind
    end

    local args = {
        'apply',
        '--cached',
        '--whitespace=nowarn',
        '--no-ignore-whitespace',
    }

    if kind == 'unstage' then
        table.insert(args, '--reverse')
    end

    if opts ~= nil and opts.check then
        table.insert(args, '--check')
    end

    table.insert(args, '-')

    local out = git.run(args, {
        cwd = root,
        ignore_error = true,
        stdin = table.concat(lines, '\n') .. '\n',
    })

    return out.exit_code == 0, return_result(out)
end

---@param path string
---@param root string?
---@return string[]
---@return string?
local function read_worktree_lines(path, root)
    root = root or git.root()

    local full_path = root ~= '' and vim.fs.joinpath(root, path) or path
    local stat = vim.uv.fs_stat(full_path)

    if stat == nil then
        return {}, 'Cannot stat file: ' .. full_path
    end

    if stat.type == 'directory' then
        return {}, 'Diff preview is not available for directories'
    end

    local ok, lines = pcall(vim.fn.readfile, full_path)

    if not ok then
        return {}, 'Cannot read file: ' .. tostring(lines)
    end

    return lines, nil
end

---@class IterFileSource
---@field raw string[] git diff text
---@field old_lines? string[] nil for binary files
---@field new_lines? string[] nil for binary files
---@field binary boolean

-- Flags that keep the diff text parseable, and applicable with `-p1`,
-- whatever the user's git config.
local DIFF_FLAGS = {
    '--no-color',
    '--no-ext-diff',
    '--no-textconv',
    '--src-prefix=a/',
    '--dst-prefix=b/',
}

---@param output string
---@return string[]
local function split_output(output)
    if output == '' then
        return {}
    end

    local lines = vim.split(output, '\n', { plain = true })

    if lines[#lines] == '' then
        table.remove(lines)
    end

    return lines
end

--- The lines of a blob, nil when it doesn't exist.
---@param root string
---@param spec string blob spec such as `:path` or `HEAD:path`
---@return string[]?
function git.blob_lines(root, spec)
    local out = git.run({ 'show', spec }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil
    end

    return split_output(out.output)
end

---@param raw string[]
---@return boolean
local function is_binary_diff(raw)
    for _, line in ipairs(raw) do
        if
            vim.startswith(line, 'Binary files ')
            or line == 'GIT binary patch'
        then
            return true
        end
    end

    return false
end

--- The diff text of one file, see `git.file_diff`. With `bytes` the lines
--- keep their carriage returns.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, base?: string, head?: string, code: string }
---@param args string[] extra flags for `git diff`, the `diff.args` option
---@param bytes boolean
---@return string[]?
---@return string? error
local function diff_text(root, change, args, bytes)
    vim.validate('args', args, 'table')

    local untracked = change.code == '?'
    local cmd

    if change.side == 'base' and type(change.base) ~= 'string' then
        return nil, 'No base for ' .. change.path
    end

    if
        change.side == 'commit'
        and (type(change.base) ~= 'string' or type(change.head) ~= 'string')
    then
        return nil, 'No commits for ' .. change.path
    end

    if untracked then
        cmd = { 'diff', '--no-index' }
    elseif change.side == 'base' or change.side == 'commit' then
        cmd = { 'diff', '-M' }
    elseif change.side == 'staged' then
        cmd = { 'diff', '--cached', '-M' }
    else
        cmd = { 'diff' }
    end

    vim.list_extend(cmd, args)
    vim.list_extend(cmd, DIFF_FLAGS)

    if change.side == 'base' and not untracked then
        table.insert(cmd, change.base)
    elseif change.side == 'commit' then
        vim.list_extend(cmd, { change.base, change.head })
    end

    table.insert(cmd, '--')

    if untracked then
        vim.list_extend(cmd, { '/dev/null', change.path })
    else
        if change.orig_path ~= nil then
            table.insert(cmd, change.orig_path)
        end
        table.insert(cmd, change.path)
    end

    local out = git.run(cmd, { cwd = root, ignore_error = true, bytes = bytes })

    -- `--no-index` exits 1 when the files differ.
    if out.exit_code > 1 or (out.exit_code == 1 and not untracked) then
        return nil, return_result(out)
    end

    return split_output(out.output)
end

--- The diff text of `git.file_diff` byte for byte: lines of a CRLF file
--- keep their carriage returns, as a patch for `git apply` needs them.
---@param root string
---@param change { path: string, orig_path?: string, side: IterSide, base?: string, head?: string, code: string }
---@param args string[] extra flags for `git diff`, the same as for `git.file_diff`
---@return string[]?
---@return string? error
function git.file_diff_bytes(root, change, args)
    return diff_text(root, change, args, true)
end

--- Diff text and both full versions of one file. Unstaged compares the index
--- with the worktree, staged compares HEAD with the index, base compares
--- `change.base` with the worktree, commit compares `change.base` with
--- `change.head`. Untracked and added files have an empty old side, deleted
--- files an empty new side.
---@param root string
---@param change IterDiffChange
---@param args string[] extra flags for `git diff`, the `diff.args` option
---@return IterFileSource?
---@return string? error
function git.file_diff(root, change, args)
    -- Read as bytes and normalized here: text mode drops CRs per output
    -- chunk, so a CRLF split across two chunks would keep its CR.
    local bytes, err = diff_text(root, change, args, true)

    if bytes == nil then
        return nil, err
    end

    local raw = patch.text(bytes)

    local untracked = change.code == '?'

    if is_binary_diff(raw) then
        return { raw = raw, binary = true }
    end

    local old_path = change.orig_path or change.path
    local old_lines, new_lines

    if untracked or change.code == 'A' then
        old_lines = {}
    elseif change.side == 'base' or change.side == 'commit' then
        old_lines = git.blob_lines(root, change.base .. ':' .. old_path)
    elseif change.side == 'staged' then
        old_lines = git.blob_lines(root, 'HEAD:' .. old_path)
    else
        old_lines = git.blob_lines(root, ':' .. old_path)
    end

    if change.code == 'D' then
        new_lines = {}
    elseif change.side == 'commit' then
        new_lines = git.blob_lines(root, change.head .. ':' .. change.path)
    elseif change.side == 'base' then
        new_lines = read_worktree_lines(change.path, root)
    elseif change.side == 'staged' then
        new_lines = git.blob_lines(root, ':' .. change.path)
    else
        new_lines = read_worktree_lines(change.path, root)
    end

    return {
        raw = raw,
        old_lines = old_lines,
        new_lines = new_lines,
        binary = false,
    }
end

--- The modes and blob ids each changed file's diff compares, by
--- `side \0 path`: the index against the worktree for unstaged files (the
--- worktree's id stays zero), HEAD against the index for staged ones. With
--- `base` only the base side is read: the base against the worktree, whose
--- id stays zero too. Two reads with the same entry, and for a file whose
--- new side is the worktree the same worktree stat, give the same diff text.
--- Untracked files are left out.
---@param root string
---@param base? string resolved base sha
---@return table<string, string>?
function git.diff_ids(root, base)
    local ids = {}
    local reads = base ~= nil and { base = { 'diff', '-M' } }
        or {
            unstaged = { 'diff', '--no-renames' },
            staged = { 'diff', '--cached', '-M' },
        }

    for side, args in pairs(reads) do
        vim.list_extend(args, { '--raw', '-z', '--no-abbrev', '--no-color' })

        if side == 'base' then
            table.insert(args, base)
        end

        local out = git.run(args, { cwd = root, ignore_error = true })

        if out.exit_code ~= 0 then
            return nil
        end

        local fields = vim.split(out.output, '\0', { plain = true })
        local index = 1

        while fields[index] ~= nil and fields[index] ~= '' do
            local info, path = fields[index], fields[index + 1]
            local status = info:match('(%a)%d*$')

            index = index + 2

            if status == 'R' or status == 'C' then
                info = info .. '\0' .. path
                path = fields[index]
                index = index + 1
            end

            if path ~= nil then
                ids[side .. '\0' .. path] = info
            end
        end
    end

    return ids
end

---@class GitCommit
---@field sha string abbreviated
---@field full_sha string
---@field subject string
---@field time integer committer date, seconds since the epoch
---@field author string the author's name
---@field body string the message after the subject, its whitespace runs joined by one space
---@field unpushed boolean not on the upstream

---@class GitRecent where HEAD stands against its upstream
---@field key string HEAD, the upstream and the count it was read for
---@field upstream? string short name such as `origin/main`, nil without one
---@field ahead integer commits on HEAD and not on the upstream
---@field behind integer commits on the upstream and not on HEAD
---@field commits GitCommit[] newest first

local SEP = '\31'

---@param line string?
---@return boolean
local function is_sha(line)
    return line ~= nil
        and (#line == 40 or #line == 64)
        and line:match('^%x+$') ~= nil
end

--- The last `count` commits of HEAD and how far it is ahead of and behind
--- its upstream, as last fetched. One `rev-parse` reads HEAD and the
--- upstream; when they and `count` match `prev`, `prev` comes back as it is
--- and nothing else runs. A detached HEAD has no upstream.
---@param root string
---@param count integer
---@param prev? GitRecent
---@return GitRecent? recent nil when HEAD has no commit
function git.recent(root, count, prev)
    local out = git.run({
        'rev-parse',
        'HEAD',
        '@{upstream}',
        '--abbrev-ref',
        '@{upstream}',
    }, { cwd = root, ignore_error = true })
    local lines = split_output(out.output)
    local head = lines[1]

    if not is_sha(head) then
        return nil
    end

    local upstream_sha, upstream

    if out.exit_code == 0 and is_sha(lines[2]) and lines[3] ~= nil then
        upstream_sha, upstream = lines[2], lines[3]
    end

    local key = table.concat(
        { tostring(count), head, upstream_sha or '', upstream or '' },
        SEP
    )

    if prev ~= nil and prev.key == key then
        return prev
    end

    ---@type GitRecent
    local recent = {
        key = key,
        upstream = upstream,
        ahead = 0,
        behind = 0,
        commits = {},
    }
    local unpushed = {}

    if upstream_sha ~= nil then
        local sides = git.run(
            { 'rev-list', '--left-right', head .. '...' .. upstream_sha },
            { cwd = root, ignore_error = true }
        )

        for _, line in ipairs(split_output(sides.output)) do
            if vim.startswith(line, '<') then
                recent.ahead = recent.ahead + 1
                unpushed[line:sub(2)] = true
            elseif vim.startswith(line, '>') then
                recent.behind = recent.behind + 1
            end
        end
    end

    if count == 0 then
        return recent
    end

    local commits = git.run({
        'log',
        '--no-color',
        '--no-show-signature',
        '--max-count=' .. count,
        '-z',
        '--format=%H%x1f%h%x1f%ct%x1f%an%x1f%s%x1f%b',
        head,
        '--',
    }, { cwd = root, ignore_error = true })

    -- With `-z` a NUL ends each commit, so a body may span lines.
    for _, record in ipairs(vim.split(commits.output, '\0', { plain = true })) do
        local fields = vim.split(record, SEP, { plain = true })

        if #fields >= 6 then
            table.insert(recent.commits, {
                sha = fields[2],
                full_sha = fields[1],
                subject = fields[5],
                body = vim.trim(
                    (table.concat(fields, ' ', 6):gsub('%s+', ' '))
                ),
                time = tonumber(fields[3]) or 0,
                author = fields[4],
                unpushed = unpushed[fields[1]] == true,
            })
        end
    end

    return recent
end

--- The files changed since `base`, committed or not, untracked ones
--- included from the status `entries`: changes of side `base`, sorted by
--- path.
---@param root string
---@param base string resolved base sha
---@param entries GitStatusEntry[] the status the untracked files come from
---@return IterChange[]?
---@return string? error
function git.base_changes(root, base, entries)
    vim.validate('base', base, 'string')
    vim.validate('entries', entries, 'table')

    local diff = git.run({
        'diff',
        '-M',
        '--name-status',
        '-z',
        '--no-color',
        base,
        '--',
    }, { cwd = root, ignore_error = true })

    if diff.exit_code ~= 0 then
        return nil, return_result(diff)
    end

    return changes.since(diff.output, base, entries)
end

--- The files changed from `base` to `head`: changes of side `commit`,
--- sorted by path.
---@param root string
---@param base string commit or tree
---@param head string commit
---@return IterChange[]?
---@return string? error
function git.commit_changes(root, base, head)
    vim.validate('base', base, 'string')
    vim.validate('head', head, 'string')

    local diff = git.run({
        'diff',
        '-M',
        '--name-status',
        '-z',
        '--no-color',
        base,
        head,
        '--',
    }, { cwd = root, ignore_error = true })

    if diff.exit_code ~= 0 then
        return nil, return_result(diff)
    end

    return changes.between(diff.output, base, head)
end

---@class GitMessage a commit and its whole message
---@field sha string abbreviated
---@field time integer committer date, seconds since the epoch
---@field author string the author's name
---@field message string[] the message's lines, the subject first, trailing blank lines dropped

-- The `log` format `parse_messages` reads.
local MESSAGE_FORMAT = '--format=%h%x1f%ct%x1f%an%x1f%B'

--- The commits of a `git log -z` in `MESSAGE_FORMAT`.
---@param output string
---@return GitMessage[]
local function parse_messages(output)
    ---@type GitMessage[]
    local messages = {}

    for _, record in ipairs(vim.split(output, '\0', { plain = true })) do
        local fields = vim.split(record, SEP, { plain = true })

        if #fields >= 4 then
            local lines =
                vim.split(table.concat(fields, SEP, 4), '\n', { plain = true })

            while #lines > 0 and vim.trim(lines[#lines]) == '' do
                table.remove(lines)
            end

            table.insert(messages, {
                sha = vim.trim(fields[1]),
                time = tonumber(fields[2]) or 0,
                author = fields[3],
                message = lines,
            })
        end
    end

    return messages
end

--- The commits from `oldest` to `newest`, newest first, with their whole
--- messages: `newest` and its ancestors that `oldest`'s parents don't
--- reach, so a root `oldest` takes every ancestor.
---@param root string
---@param oldest string commit
---@param newest string commit
---@return GitMessage[]?
---@return string? error
function git.messages(root, oldest, newest)
    vim.validate('oldest', oldest, 'string')
    vim.validate('newest', newest, 'string')

    local out = git.run({
        'log',
        '--no-color',
        '--no-show-signature',
        '-z',
        MESSAGE_FORMAT,
        newest,
        '--not',
        oldest .. '^@',
        '--',
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    return parse_messages(out.output)
end

--- The commits on `head` since `base`, `base..head`, newest first with
--- their whole messages, at most `limit`, and how many more there are.
---@param root string
---@param base string commit
---@param head string commit
---@param limit integer
---@return GitMessage[]?
---@return string? error
---@return integer more the commits past `limit`
function git.messages_since(root, base, head, limit)
    vim.validate('base', base, 'string')
    vim.validate('head', head, 'string')
    vim.validate('limit', limit, 'number')

    local range = base .. '..' .. head
    local out = git.run({
        'log',
        '--no-color',
        '--no-show-signature',
        '-z',
        '--max-count=' .. limit,
        MESSAGE_FORMAT,
        '--end-of-options',
        range,
        '--',
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out), 0
    end

    local messages = parse_messages(out.output)

    if #messages < limit then
        return messages, nil, 0
    end

    local count = git.run(
        { 'rev-list', '--count', '--end-of-options', range, '--' },
        { cwd = root, ignore_error = true }
    )

    return messages,
        nil,
        math.max(0, (tonumber(return_result(count)) or #messages) - #messages)
end

---@class GitStat the lines a diff adds and deletes in one file
---@field path string
---@field orig_path? string the old path of a rename
---@field added? integer nil for a binary file
---@field deleted? integer nil for a binary file

--- The lines added and deleted per file from `base` to `head`, or to the
--- worktree's tracked files without `head`, in git's order.
---@param root string
---@param base string commit or tree
---@param head? string commit
---@return GitStat[]?
---@return string? error
function git.stats(root, base, head)
    vim.validate('base', base, 'string')
    vim.validate('head', head, 'string', true)

    local args = { 'diff', '-M', '--numstat', '-z', '--no-color', base }

    if head ~= nil then
        table.insert(args, head)
    end

    table.insert(args, '--')

    local out = git.run(args, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    ---@type GitStat[]
    local stats = {}
    local tokens = vim.split(out.output, '\0', { plain = true })
    local i = 1

    -- A rename's entry has an empty path and its two paths as the next
    -- tokens.
    while i <= #tokens do
        local added, deleted, path =
            tokens[i]:match('^([%d-]+)\t([%d-]+)\t(.*)$')

        if added ~= nil then
            local stat = {
                path = path,
                added = tonumber(added),
                deleted = tonumber(deleted),
            }

            if path == '' then
                stat.orig_path, stat.path = tokens[i + 1], tokens[i + 2]
                i = i + 2
            end

            table.insert(stats, stat)
        end

        i = i + 1
    end

    return stats
end

--- The empty tree's id in the repository's hash.
---@param root string
---@return string? sha
---@return string? error
function git.empty_tree(root)
    local empty = git.run(
        { 'hash-object', '-t', 'tree', '--stdin' },
        { cwd = root, ignore_error = true, stdin = '' }
    )

    if empty.exit_code ~= 0 then
        return nil, return_result(empty)
    end

    return return_result(empty)
end

--- The full sha of `sha`'s first parent, or the empty tree for a root
--- commit.
---@param root string
---@param sha string
---@return string? sha
---@return string? error
function git.parent_of(root, sha)
    vim.validate('sha', sha, 'string')

    local out = git.run({
        'rev-list',
        '--parents',
        '--max-count=1',
        '--end-of-options',
        sha .. '^{commit}',
        '--',
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local parent = vim.split(return_result(out), ' ', { plain = true })[2]

    if parent ~= nil then
        return parent
    end

    return git.empty_tree(root)
end

---@class IterBaseSpec what a review compares the worktree with
---@field kind 'branch'|'commit'|'rev'
---@field ref? string the branch, for `branch`; the ref as typed, for `rev`
---@field sha? string the commit, for `commit` and `rev`

--- The commit or tree a review against `spec` starts from: a branch's
--- merge-base with HEAD; a picked commit's first parent, so the commit is
--- part of the review, and the empty tree for a root commit; a typed ref's
--- commit itself. A commit or ref that is no longer an ancestor of HEAD,
--- such as after a rebase, doesn't resolve.
---@param root string
---@param spec IterBaseSpec
---@return string? sha
---@return string? error
function git.resolve_base(root, spec)
    vim.validate('spec', spec, 'table')

    if spec.kind == 'branch' then
        vim.validate('spec.ref', spec.ref, 'string')

        local out = git.run(
            { 'merge-base', '--end-of-options', 'HEAD', spec.ref },
            { cwd = root, ignore_error = true }
        )

        if out.exit_code ~= 0 then
            return nil,
                out.stderr ~= '' and return_result(out)
                    or 'No common commit with ' .. spec.ref
        end

        return return_result(out)
    end

    if spec.kind ~= 'commit' and spec.kind ~= 'rev' then
        return nil, 'Unknown base kind: ' .. tostring(spec.kind)
    end

    vim.validate('spec.sha', spec.sha, 'string')

    local out = git.run({
        'rev-list',
        '--parents',
        '--max-count=1',
        '--end-of-options',
        spec.sha .. '^{commit}',
        '--',
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local ancestor = git.run(
        { 'merge-base', '--is-ancestor', '--end-of-options', spec.sha, 'HEAD' },
        { cwd = root, ignore_error = true }
    )

    if ancestor.exit_code ~= 0 then
        return nil,
            ancestor.stderr ~= '' and return_result(ancestor)
                or 'Not in the history of HEAD'
    end

    local commit, parent =
        unpack(vim.split(return_result(out), ' ', { plain = true }))

    if spec.kind == 'rev' then
        return commit
    elseif parent ~= nil then
        return parent
    end

    return git.empty_tree(root)
end

--- Each ref in `refs` with the count of commits on HEAD and not on it, the
--- distance from their merge-base to HEAD; 0 when it contains HEAD.
---@param root string
---@param patterns string[] `for-each-ref` patterns
---@return { ref: string, behind: integer }[]?
local function behind_head(root, patterns)
    local out = git.run(
        vim.list_extend(
            { 'for-each-ref', '--format=%(refname)%00%(ahead-behind:HEAD)' },
            patterns
        ),
        { cwd = root, ignore_error = true }
    )
    local refs = {}

    if out.exit_code == 0 then
        for _, line in ipairs(split_output(out.output)) do
            local ref, counts = unpack(vim.split(line, '\0', { plain = true }))
            local behind = tonumber((counts or ''):match('^%d+ (%d+)$'))

            if behind ~= nil then
                table.insert(refs, { ref = ref, behind = behind })
            end
        end

        return refs
    end

    -- `%(ahead-behind)` needs git 2.41; older ones count each ref alone.
    out = git.run(
        vim.list_extend({ 'for-each-ref', '--format=%(refname)' }, patterns),
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 then
        return nil
    end

    for _, ref in ipairs(split_output(out.output)) do
        local count = git.run(
            { 'rev-list', '--count', ref .. '..HEAD', '--' },
            { cwd = root, ignore_error = true }
        )
        local behind = tonumber(return_result(count))

        if count.exit_code == 0 and behind ~= nil then
            table.insert(refs, { ref = ref, behind = behind })
        end
    end

    return refs
end

---@param ref string full ref name
---@return string
local function short_ref(ref)
    if vim.startswith(ref, 'refs/heads/') then
        return ref:sub(#'refs/heads/' + 1)
    end

    return (ref:gsub('^refs/remotes/', ''))
end

--- The branch HEAD was created from. First the creation line of the
--- branch's reflog, when it names a branch that still exists; otherwise
--- the local branch or remote default branch whose merge-base with HEAD is
--- the fewest commits back, branches that contain HEAD left out and ties
--- going to the default branch. The default branch is `origin/HEAD`'s
--- target, else a local `main`, else a local `master`.
---@param root string
---@return string? branch short name such as `main` or `origin/main`; nil on the default branch and when nothing qualifies
function git.parent_branch(root)
    local branch = git.head_branch(root)
    local origin = git.run(
        { 'symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD' },
        { cwd = root, ignore_error = true }
    )
    local remote = origin.exit_code == 0 and return_result(origin) or nil
    local patterns = { 'refs/heads' }

    if remote ~= nil then
        table.insert(patterns, remote)
    end

    local refs = behind_head(root, patterns) or {}
    local default = 'refs/heads/master'

    if remote ~= nil then
        default = 'refs/heads/' .. remote:gsub('^refs/remotes/[^/]+/', '')
    else
        for _, entry in ipairs(refs) do
            if entry.ref == 'refs/heads/main' then
                default = entry.ref
            end
        end
    end

    if branch ~= nil and 'refs/heads/' .. branch == default then
        return nil
    end

    if branch ~= nil then
        local reflog = git.run(
            { 'reflog', 'show', '--format=%gs', 'refs/heads/' .. branch, '--' },
            { cwd = root, ignore_error = true }
        )
        local lines = split_output(reflog.output)
        local from = (lines[#lines] or ''):match('^branch: Created from (.+)$')

        if from ~= nil and from ~= 'HEAD' then
            local exists = git.run({
                'for-each-ref',
                '--format=%(refname)',
                'refs/heads/' .. from,
                'refs/remotes/' .. from,
            }, { cwd = root, ignore_error = true })

            for _, ref in ipairs(split_output(exists.output)) do
                if short_ref(ref) == from then
                    return from
                end
            end
        end
    end

    local function rank(entry)
        return entry.ref == default or entry.ref == remote
    end

    local best

    for _, entry in ipairs(refs) do
        if
            entry.behind > 0
            and (branch == nil or entry.ref ~= 'refs/heads/' .. branch)
            and (
                best == nil
                or entry.behind < best.behind
                or entry.behind == best.behind
                    and rank(entry)
                    and not rank(best)
            )
        then
            best = entry
        end
    end

    return best ~= nil and short_ref(best.ref) or nil
end

--- The local branches, then the remote-tracking ones, by short name such
--- as `main` or `origin/main`; symbolic refs such as `origin/HEAD` left out.
---@param root string
---@return string[]? branches
---@return string? error
function git.branches(root)
    local out = git.run({
        'for-each-ref',
        '--format=%(refname)%00%(symref)',
        'refs/heads',
        'refs/remotes',
    }, { cwd = root, ignore_error = true })

    if out.exit_code ~= 0 then
        return nil, return_result(out)
    end

    local branches = {}

    for _, line in ipairs(split_output(out.output)) do
        local ref, symref = unpack(vim.split(line, '\0', { plain = true }))

        if symref == nil or symref == '' then
            table.insert(branches, short_ref(ref))
        end
    end

    return branches
end

--- The full sha of the commit `ref` names.
---@param root string
---@param ref string
---@return string? sha
---@return string? error
function git.commit_sha(root, ref)
    vim.validate('ref', ref, 'string')

    if ref == '' or vim.startswith(ref, '-') then
        return nil, 'Unknown ref ' .. ref
    end

    local out = git.run(
        { 'rev-parse', '--verify', '--quiet', ref .. '^{commit}' },
        { cwd = root, ignore_error = true }
    )

    if out.exit_code ~= 0 or not is_sha(return_result(out)) then
        return nil, 'Unknown ref ' .. ref
    end

    return return_result(out)
end

--- The base a typed `ref` names: a branch spec when it is a local or
--- remote-tracking branch, else a rev spec with the full sha it resolves
--- to, which the review starts after.
---@param root string
---@param ref string
---@return IterBaseSpec?
---@return string? error
function git.base_spec(root, ref)
    vim.validate('ref', ref, 'string')

    for _, branch in ipairs(git.branches(root) or {}) do
        if branch == ref then
            return { kind = 'branch', ref = ref }
        end
    end

    local sha, err = git.commit_sha(root, ref)

    if sha == nil then
        return nil, err
    end

    return { kind = 'rev', ref = ref, sha = sha }
end

return git
