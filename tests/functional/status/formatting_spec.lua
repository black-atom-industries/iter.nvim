---@diagnostic disable: undefined-field
local formatting = require('iter.ui.status.formatting')
local render = require('iter.ui.render')

---@type table<string, string>
local groups = {
    staged = 'IterStage',
    unstaged = 'IterUnstage',
    untracked = 'IterUntracked',
    conflict = 'IterConflict',
    head = 'IterHead',
    ignored = 'IterIgnored',
    unpushed = 'IterUnpushed',
    loading = 'IterLoading',
}

---@param snapshot GitStatusSnapshot
---@return string[]
local function rendered_text(snapshot, opts)
    local lines = formatting.render(snapshot, groups, opts or {})
    return render.text_lines(lines)
end

---@param text_lines string[]
---@param needle string
---@return boolean
local function has_line(text_lines, needle)
    for _, line in ipairs(text_lines) do
        if line:find(needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

describe('iter.status.formatting', function()
    describe('render', function()
        it('renders head line with branch', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'HEAD: main'))
        end)

        it('renders head line with (none) for empty branch', function()
            local snapshot = {
                branch = '',
                entries = {},
                unpushed_commits = {},
                root = '',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'HEAD: (none)'))
        end)

        it('renders clean tree message', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'Working tree clean'))
        end)

        it('renders error message when present', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {},
                root = '',
                error = 'Not inside a git repository',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'Not inside a git repository'))
            -- Should NOT show clean message when there's an error
            assert.is_false(has_line(text, 'Working tree clean'))
        end)

        it('groups staged, unstaged, untracked entries', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    { staged = 'M', unstaged = ' ', path = 'staged.txt' },
                    { staged = ' ', unstaged = 'M', path = 'modified.txt' },
                    { staged = '?', unstaged = '?', path = 'untracked.txt' },
                    {
                        staged = 'A',
                        unstaged = ' ',
                        path = 'added.txt',
                    },
                },
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)

            assert.is_true(has_line(text, 'Staged (2)'))
            assert.is_true(has_line(text, 'M  staged.txt'))
            assert.is_true(has_line(text, 'A  added.txt'))

            assert.is_true(has_line(text, 'Unstaged (1)'))
            assert.is_true(has_line(text, ' M modified.txt'))

            assert.is_true(has_line(text, 'Untracked (1)'))
            assert.is_true(has_line(text, '?? untracked.txt'))
        end)

        it('groups conflict entries separately', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    { staged = 'U', unstaged = 'U', path = 'conflict.txt' },
                    { staged = 'A', unstaged = 'A', path = 'both_added.txt' },
                },
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)

            assert.is_true(has_line(text, 'Conflicts (2)'))
            assert.is_true(has_line(text, 'UU conflict.txt'))
            assert.is_true(has_line(text, 'AA both_added.txt'))
        end)

        it('renders renames with old -> new format', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    {
                        staged = 'R',
                        unstaged = ' ',
                        path = 'new.txt',
                        orig_path = 'old.txt',
                    },
                },
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'R  old.txt -> new.txt'))
        end)

        it('filters entries by text query', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    { staged = 'M', unstaged = ' ', path = 'foo.lua' },
                    { staged = ' ', unstaged = 'M', path = 'bar.lua' },
                },
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot, { filter = 'foo' })

            assert.is_true(has_line(text, 'foo.lua'))
            assert.is_false(has_line(text, 'bar.lua'))
            assert.is_true(has_line(text, 'filter=foo'))
        end)

        it('shows no-match message when filter excludes everything', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    { staged = 'M', unstaged = ' ', path = 'foo.lua' },
                },
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot, { filter = 'xyz' })
            assert.is_true(has_line(text, 'No entries match filter'))
        end)

        it('renders unpushed commits', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {
                    {
                        hash = 'abc1234567890',
                        short_hash = 'abc1234',
                        message = 'feat: add cool thing',
                    },
                },
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'Unpushed (1)'))
            assert.is_true(has_line(text, 'abc1234 feat: add cool thing'))
        end)

        it('shows loading message when provided', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot, {
                loading_message = 'Refreshing...',
                loading_frame = '-',
            })

            assert.is_true(has_line(text, '- Refreshing...'))
        end)

        it('hides unpushed section when filter is active', function()
            local snapshot = {
                branch = 'main',
                entries = {
                    { staged = 'M', unstaged = ' ', path = 'foo.lua' },
                },
                unpushed_commits = {
                    {
                        hash = 'abc',
                        short_hash = 'abc',
                        message = 'test',
                    },
                },
                root = '/tmp/repo',
            }

            local text = rendered_text(snapshot, { filter = 'foo' })
            assert.is_false(has_line(text, 'Unpushed'))
        end)

        it('handles empty entries', function()
            local snapshot = {
                branch = 'main',
                entries = {},
                unpushed_commits = {},
                root = '/tmp/repo',
            }

            -- Empty entries + empty unpushed = clean
            local text = rendered_text(snapshot)
            assert.is_true(has_line(text, 'Working tree clean'))
        end)
    end)

    describe('entry_line', function()
        it('renders staged entry with stage highlight on first char', function()
            local line = formatting.entry_line(
                { staged = 'M', unstaged = ' ', path = 'file.txt' },
                groups,
                'staged'
            )

            assert.are.equal('M  file.txt', line.text)
            assert.are.equal(1, #line.highlights)
            assert.are.equal('IterStage', line.highlights[1].group)
            assert.are.equal(0, line.highlights[1].start_col)
        end)

        it(
            'renders unstaged entry with unstage highlight on second char',
            function()
                local line = formatting.entry_line(
                    { staged = ' ', unstaged = 'M', path = 'file.txt' },
                    groups,
                    'unstaged'
                )

                assert.are.equal(' M file.txt', line.text)
                -- Should have highlight on second char (index 1)
                local has_unstaged_hl = false
                for _, hl in ipairs(line.highlights) do
                    if hl.group == 'IterUnstage' and hl.start_col == 1 then
                        has_unstaged_hl = true
                    end
                end
                assert.is_true(has_unstaged_hl)
            end
        )

        it('attaches entry data for selection', function()
            local entry = {
                staged = 'M',
                unstaged = ' ',
                path = 'file.txt',
            }
            local line = formatting.entry_line(entry, groups, 'staged')

            assert.is_not_nil(line.data)
            assert.are.equal(entry, line.data.entry)
            assert.are.equal('staged', line.data.section)
        end)
    end)

    describe('commit_line', function()
        it('renders commit with short hash and message', function()
            local commit = {
                hash = 'abc1234567890',
                short_hash = 'abc1234',
                message = 'feat: add feature',
            }

            local line = formatting.commit_line(commit, groups)
            assert.are.equal('abc1234 feat: add feature', line.text)
            -- Should have unpushed highlight on the hash part
            assert.is_true(#line.highlights > 0)
            assert.are.equal('IterUnpushed', line.highlights[1].group)
        end)
    end)

    describe('head_line', function()
        it('renders HEAD: prefix with branch', function()
            local line = formatting.head_line('main', groups)
            assert.are.equal('HEAD: main', line.text)
            assert.are.equal(2, #line.highlights)
        end)

        it('renders (none) for empty branch', function()
            local line = formatting.head_line('', groups)
            assert.are.equal('HEAD: (none)', line.text)
        end)
    end)
end)
