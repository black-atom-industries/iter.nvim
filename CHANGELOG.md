# Changelog

## [0.7.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.6.0...v0.7.0) (2026-10-30)


### Features

* **review:** the annotation sidebar beside the diff on wide screens ([b24bd9c](https://github.com/black-atom-industries/iter.nvim/commit/b24bd9c1c8ecdd29094dce21338223d0cbc42d68)), closes [#37](https://github.com/black-atom-industries/iter.nvim/issues/37)

## [0.6.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.5.0...v0.6.0) (2026-10-30)

### Highlights

#### Review a branch or a pull request

The review can now compare the files on disk with a base instead of the index, so work that is already committed shows up
too. Check out the branch of a pull request and press `b` in the review drawer: the first row is the merge base with the
branch it was created from, which is what the pull request shows. Working changes, the other branches and the last 20
commits follow, each commit with its date, author and message. `:Iter review main` opens against a ref directly.

Against a base the drawer has one column, `Since main`, and staging doesn't apply. Reviewed marks belong to the base they
were made against, annotations are shared, the copied prompt names the base, and iter remembers the base per branch. The
picker opens over the drawer whichever picker plugin you use.

![b in the review drawer opens the base picker with the merge base with main first, then branches and commits; picking the merge base switches the drawer to Since main](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.6.0/docs/assets/changelog/0.6.0-base-picker.webp)

#### Browse commits with `:Iter commits`

`:Iter commits` lists the branch's last 100 commits. Moving through them shows a summary above: the message, author, date
and the changed files with their counts. `<CR>` opens the files of a commit, or of a range selected with `V`, one diff at
a time. `q` goes back to the list, and `r` starts a review from the oldest selected commit.

![:Iter commits shows a summary of each commit above the list; V selects two commits, Enter lists their files one diff at a time, q goes back and r opens the review](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.6.0/docs/assets/changelog/0.6.0-commits.webp)

#### Annotate the exact words

A charwise `v` selection annotates just the selected words. The annotation follows them when the text around them changes
and turns outdated when they are gone. Annotated text is tinted in buffers and in the diff (`IterAnnotationText`), and the
export names a passage as `file:line:col` with only its words quoted.

![In the review diff, v selects hear when it is ready, a annotates it, and the words stay tinted in the diff and in the README buffer](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.6.0/docs/assets/changelog/0.6.0-passages.webp)

#### Every annotation in a sidebar

`:Iter annotate` toggles a sidebar at the edge of the tab with every annotation of the repository, grouped by file, whether
the file has changes or not. `<CR>` jumps to the annotation, and `y`, `Y`, `d` and `e` work as in the review.
`require('iter').clear()` drops every annotation at once.

![:Iter annotate opens the sidebar with three annotations in two files; Enter on the teas.lua annotation jumps to its line](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.6.0/docs/assets/changelog/0.6.0-sidebar.webp)

#### Copy one annotation or all of them

`y` in the review drawer and the diff pane copies the annotation under the cursor, or a file's annotations on a file row.
`Y` copies all of them. iter then asks about clearing only what was copied.

#### Wrap long lines

`gw` toggles wrapping in the unified diff, and `diff.wrap` sets how a session starts.

#### Important fixes

- The drawer stays opaque under a global `winblend` and under a colorscheme with a transparent `Normal`.
- Side-by-side panes stay aligned under `scrolloff`.
- Word emphasis leaves the whitespace at the edges of a change unmarked, so a changed indent alone marks nothing.

#### Upgrading from 0.5

`mode` moves to `=`, so `m` is free again:

```diff
- m   toggle one file or all files
+ =   toggle one file or all files
```

Deleting an annotation moves from `x` to `d`, and `y` copies the annotation under the cursor instead of all of them:

```diff
- x   delete the annotation
+ d   delete the annotation
- y   copy all annotations
+ y   copy the annotation or file under the cursor
+ Y   copy all annotations
```

To keep the old keys, set them in `keys`, as in `keys.drawer.mode = 'm'`.



### ⚠ BREAKING CHANGES

* **review:** `y` in the review drawer and the diff pane copies the annotation or file under the cursor; `Y` copies all. Deleting an annotation moves from `x` to `d`.
* the default key of `mode` is `=`, it was `m`. Set `keys.drawer.mode`, `keys.review_drawer.mode` and `keys.diff.mode` to 'm' to keep it.

### Features

* = toggles one file or all files ([cecdcd6](https://github.com/black-atom-industries/iter.nvim/commit/cecdcd6c6b834dd43b2572a4b3d6627dc978cb3e))
* **annotations:** annotate passages and tint annotated text ([dc23283](https://github.com/black-atom-industries/iter.nvim/commit/dc23283d40ccf04b1b902a41f946abdcdceda4d5)), closes [#35](https://github.com/black-atom-industries/iter.nvim/issues/35)
* **annotations:** clear every annotation with iter.clear() ([f3ab205](https://github.com/black-atom-industries/iter.nvim/commit/f3ab205e9b7b0181fa389891ef71f67f039ac7f8))
* **annotations:** list every annotation in a sidebar with :Iter annotate ([502e25c](https://github.com/black-atom-industries/iter.nvim/commit/502e25ce387492cdea05c50801d34828b5aba57c)), closes [#35](https://github.com/black-atom-industries/iter.nvim/issues/35)
* **commits:** browse commits with :Iter commits ([5725be8](https://github.com/black-atom-industries/iter.nvim/commit/5725be88491800372b13ce4b86117c5d55233a68))
* **diff:** gw wraps long lines in the unified layout ([2afa271](https://github.com/black-atom-industries/iter.nvim/commit/2afa271a159c46126368ec44c46111cd86b9117d))
* **review:** colour the commit rows of the base picker ([a81bde4](https://github.com/black-atom-industries/iter.nvim/commit/a81bde4982b9bf3eacda9ac63f23c00ae537cfe3))
* **review:** pick the base in a list over the drawer ([1b42f32](https://github.com/black-atom-industries/iter.nvim/commit/1b42f32e18a58cd7da0724ed35ccd0cfff2ba09b))
* **review:** review committed work against a picked base ([8bd7aa8](https://github.com/black-atom-industries/iter.nvim/commit/8bd7aa8bbb76f27ed7dadb3b241daac2440c9cbf))
* **review:** y copies one annotation or a file's, Y copies all ([85c5172](https://github.com/black-atom-industries/iter.nvim/commit/85c5172f2a7a2430f224c445f00c3ac339bcfa39)), closes [#35](https://github.com/black-atom-industries/iter.nvim/issues/35)


### Bug Fixes

* **diff:** leave whitespace at the edges out of word emphasis ([bc92256](https://github.com/black-atom-industries/iter.nvim/commit/bc922565a5d93fb973a0de9a919dc10715e94dae))
* **diff:** side-by-side panes stay aligned under scrolloff ([7f4abe9](https://github.com/black-atom-industries/iter.nvim/commit/7f4abe902e56e3dee6b604d22999cac0e8dfe289))
* **drawer:** keep the drawer opaque under a global winblend ([ebc8878](https://github.com/black-atom-industries/iter.nvim/commit/ebc88786ed7a25c90fe34a94e5d12a647df14473))
* **highlight:** keep the drawer opaque under a transparent Normal ([bda719d](https://github.com/black-atom-industries/iter.nvim/commit/bda719d0a5a4b843b8b2ff9e3305f3a4a95698ee))


### Documentation

* give launching from the shell its own section ([01942df](https://github.com/black-atom-industries/iter.nvim/commit/01942df4b90fb556580b2380bc68c4fb9caf6f3c))
* link mini.git in the README ([1c55c76](https://github.com/black-atom-industries/iter.nvim/commit/1c55c767e070d3adc2928eb3b87f72486e599246))
* note that launching from the shell needs iter loaded at startup ([4cd64c0](https://github.com/black-atom-industries/iter.nvim/commit/4cd64c0d53badb2b779775d6c7906e0fbaa25abc))
* open the review straight from the shell ([e6c669f](https://github.com/black-atom-industries/iter.nvim/commit/e6c669f4f3ab7b998406117249a469252c846107))

## [0.5.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.4.0...v0.5.0) (2026-10-21)

### Highlights

#### A clear edge between the diff and the drawer

The status drawer starts with a rule in the `Title` colour and puts its header row on a tinted band, so it no longer
blends into the diff above it. The separators of a side-by-side diff now end on that rule. The drawer keeps its height and
shows one file row less.

In the review tab the drawer has a split of its own, and Neovim already draws a line above it, so the review drawer shows
the band without the rule. The band is a new group, `IterDrawerHeader`, derived from `Title`.

![The status drawer under a rule in the Title colour, its HEAD row on the tinted header band](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.5.0/docs/assets/changelog/0.5.0-drawer-header.webp)



### Features

* **drawer:** header on a band under a rule, like a file header ([dbdf14e](https://github.com/black-atom-industries/iter.nvim/commit/dbdf14e800bfd71c588ed3fb8c5cd1a433fcfab5))


### Documentation

* README clips at a 240-column viewport ([fdf6578](https://github.com/black-atom-industries/iter.nvim/commit/fdf6578ec7c9cc3166aa8e60b7b7162a673e974e))

## [0.4.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.3.0...v0.4.0) (2026-10-21)

### Highlights

#### The diff layout follows the window width

With `diff.layout = 'auto'` the diff shows side by side once the window is `diff.split_breakpoint` columns wide, and
unified below that. It switches as the window resizes. `|` and `-` still pick a layout by hand, and that pick holds until a
resize crosses the breakpoint. `'unified'` and `'split'` set the layout every session starts in.

```lua
require('iter').setup({
    diff = {
        layout = 'auto',        -- 'unified', 'split' or 'auto'
        split_breakpoint = 120, -- diff width from which 'auto' shows side by side
    },
})
```

![In a full-width window the status drawer opens side by side; after :vsplit it opens unified in the half-width window and leaves the other one alone; after :only it opens side by side again](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.4.0/docs/assets/changelog/0.4.0-auto-layout.webp)

#### Side by side stays in its window

The old version opens inside the window the diff was in, so the windows next to it keep their width, also under `CTRL-W =`
or an autocmd that equalizes windows. The status drawer covers both panes from the moment it opens, and its divider between
Unstaged and Staged sits on the separator between the panes.

#### The progress bar fills the Annotations column

The bar next to `reviewed` takes the width the word and the counts leave, with at least 8 cells, and draws in `▰` and `▱`.

#### Important fixes

- The Annotations window no longer picks up a global `winborder`, which pushed it a row below the drawer's headers.



### Features

* **config:** diff.layout picks unified, split or auto by width ([4cd3344](https://github.com/black-atom-industries/iter.nvim/commit/4cd3344f2fac94cbb71c7ed009862c3c8b9ea3cf))
* **review:** progress bar spans the Annotations column ([2eb35bf](https://github.com/black-atom-industries/iter.nvim/commit/2eb35bfbd0e01211d26867d803ad1268c7e45969))


### Bug Fixes

* **diff:** side by side splits only the window it opens in ([6c1a5e1](https://github.com/black-atom-industries/iter.nvim/commit/6c1a5e10e969ada120b534aebf5373d67ebe6e84))
* **diff:** side-by-side panes line up with the drawer columns ([6a119f8](https://github.com/black-atom-industries/iter.nvim/commit/6a119f8ff3dc08d2849f2d5e2b3be669d645228c))
* **drawer:** Annotations window ignores a global winborder ([8a07da7](https://github.com/black-atom-industries/iter.nvim/commit/8a07da7f662fd78eb54f82591e9c4d6fd5f1a47c))
* **drawer:** status drawer spans both panes when it opens side by side ([7406d61](https://github.com/black-atom-industries/iter.nvim/commit/7406d61e75764ff9f671e4db66ed4114e0c06711))


### Documentation

* README as lists for processes and reference details ([f473c3d](https://github.com/black-atom-industries/iter.nvim/commit/f473c3d1e0b4a7aa847e1be0e55bb1dfd27bf76d))
* yank in the annotation mapping recipe ([0bf4bb3](https://github.com/black-atom-industries/iter.nvim/commit/0bf4bb38c9e67c3da19726ac35139770d2386f7e))

## [0.3.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.2.0...v0.3.0) (2026-10-20)

### Highlights

#### Wide review drawers

From 160 columns on, the review drawer puts Unstaged and Staged side by side with the Annotations column to their right,
and `h` and `l` step through all three. Between 80 and 160 columns Unstaged stays above Staged. The drawer switches as the
terminal resizes, and both widths are options:

```lua
require('iter').setup({
    drawer = {
        breakpoint = 80,       -- drawer width below which the columns stack
        wide_breakpoint = 160, -- review drawer width from which Unstaged and Staged sit side by side
    },
})
```

![The status drawer switches to side by side, the review opens wide in the same layout, r marks and moves on, r on a reviewed file moves on, R removes the mark, l steps to Staged and Annotations](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.3.0/docs/assets/changelog/0.3.0-wide-review.webp)

#### `r` moves on, `R` removes the mark

`r` marks the file reviewed and moves to the next file you haven't reviewed. On a reviewed file it keeps the mark and moves
on, so going back with `k` to look at a file and pressing `r` again keeps your review. `R` removes the mark and leaves the
selection where it is.

#### The diff layout holds for the session

Side by side (`|`) or unified (`-`), picked in the status drawer, carries over into the review tab and back until Neovim
quits.

#### Upgrading from 0.2

To remove a reviewed mark, press `R`. `r` on a reviewed file moves on and keeps the mark.


### Features

* keep the diff layout across the status drawer and the review ([6120a09](https://github.com/black-atom-industries/iter.nvim/commit/6120a092a7d213fc2d977567f234aecdf15d723a))
* **review:** r marks and moves on, R removes the reviewed mark ([31ad184](https://github.com/black-atom-industries/iter.nvim/commit/31ad1846e120848bccac660d5b9c9b4722bf9ea0))
* **review:** Unstaged and Staged side by side in wide drawers ([530ca24](https://github.com/black-atom-industries/iter.nvim/commit/530ca24a2e0c219e252ff06a08f6de437d406c18))


### Documentation

* README banner for light and dark themes ([e621acf](https://github.com/black-atom-industries/iter.nvim/commit/e621acfbd1d5acf1d31a2192f3da90dbfbf070fc))
* README contents as a nested list ([2f3e983](https://github.com/black-atom-industries/iter.nvim/commit/2f3e9830f65e1227a36426fb1022faadd553c7a8))
* README contents, annotations outside iter in their own section ([7c1d3f4](https://github.com/black-atom-industries/iter.nvim/commit/7c1d3f425c18a5d8934a14820620fdba2b81b3d1))

## [0.2.0](https://github.com/black-atom-industries/iter.nvim/compare/v0.1.0...v0.2.0) (2026-10-20)

### Highlights

#### Annotate a file from any buffer

`annotate({ scope = 'file' })` annotates the current buffer's file, the same annotation `A` makes in the review. iter
still maps nothing outside its own buffers, so the README's
[Annotations outside iter](https://github.com/black-atom-industries/iter.nvim#annotations-outside-iter) has a recipe:

```lua
local iter = require('iter')

vim.keymap.set({ 'n', 'x' }, '<leader>aa', function()
    iter.annotate()
end, { desc = 'Annotate the line or selection' })

vim.keymap.set('n', '<leader>af', function()
    iter.annotate({ scope = 'file' })
end, { desc = 'Annotate the file' })

vim.keymap.set('n', '<leader>ar', function()
    iter.annotate({ scope = 'review' })
end, { desc = 'Annotate the review' })

vim.keymap.set('n', '<leader>al', iter.annotations, { desc = 'List the annotations' })
```

#### Fixes

Switching between unified and side by side, or from all files back to one, keeps the file header where it was. Before,
it could end up one line above the window.

### Features

* **annotations:** annotate a file from any buffer, mapping recipe ([9446b17](https://github.com/black-atom-industries/iter.nvim/commit/9446b17963a5dc1e6508152a49733408639e8db3)), closes [#28](https://github.com/black-atom-industries/iter.nvim/issues/28)


### Bug Fixes

* **diff:** keep the file header in view across layout changes ([6b68b8d](https://github.com/black-atom-industries/iter.nvim/commit/6b68b8d5ce146ffe85b42d28b13219aa2fac4c29)), closes [#27](https://github.com/black-atom-industries/iter.nvim/issues/27)

## 0.1.0 (2026-10-20)

### Highlights

iter is a review loop for Neovim. You or an agent change code, you review it in iter, annotate what needs work, and hand
the annotations back as a prompt. 0.1.0 is the first release of the renovated plugin.

#### Review tab

`:Iter review`, or `r` in the status drawer, opens a tab for the whole review. iter draws the diff itself, with treesitter
syntax, the changed words emphasized and context that expands on `<CR>`. `m` shows every file in one scroll, `|` puts old
and new side by side, and `s` and `u` stage hunks or only the selected lines.

`r` marks a file reviewed and moves on to the next one, its header at the top and the cursor on its first change. A
reviewed file that changes again turns `↻`.

![The review tab: a annotates a line, r marks the file reviewed and moves on, the Annotations column lists the annotation](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.1.0/docs/assets/changelog/0.1.0-review.webp)

![All files: m shows every file, r collapses each reviewed file and moves to the next, | shows the diff side by side](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.1.0/docs/assets/changelog/0.1.0-layouts.webp)

#### Annotations and the agent prompt

`a` annotates a line or a range and `A` a file. Annotations also show in normal file buffers, follow their code when it
moves and turn outdated when it is gone. The Annotations column of the review drawer lists them all, and `y` copies the
review as a prompt: an intro, then every annotation with its `file:line` and the code it is on.

```lua
vim.keymap.set({ 'n', 'x' }, '<leader>a', function()
    require('iter').annotate()
end, { desc = 'Annotate' })
```

#### Status drawer

`:Iter` opens a drawer at the bottom of the window with Unstaged and Staged side by side and the diff of the selection
above. The header shows the branch and how far it is ahead and behind its upstream, and the recent commits sit under the
files. `s`, `u`, `d` and `I` stage, unstage, discard and ignore whole files.

![The status drawer: moving through the files previews each diff, s stages a file, ? lists the keys](https://raw.githubusercontent.com/black-atom-industries/iter.nvim/v0.1.0/docs/assets/changelog/0.1.0-drawer.webp)

#### Fits into your setup

Every view has an `iter://` address, `statusline()` and `tabline()` label the review, and `IterRefresh` and `IterStage`
events fire after reads and stage actions. Keys are remappable per view, `diff.args` passes flags to `git diff`, and the
`Iter*` highlight groups derive from your colorscheme unless it defines them.

### Features

* **annotations:** &lt;C-s&gt; saves and closes the float ([9e15625](https://github.com/black-atom-industries/iter.nvim/commit/9e15625d30d5582b91a5c8699835b45625f478cc)), closes [#17](https://github.com/black-atom-industries/iter.nvim/issues/17)
* **annotations:** an icon in front of each annotation ([95c226f](https://github.com/black-atom-industries/iter.nvim/commit/95c226fdcada2a6058483fbf23d06e63b45a9177)), closes [#20](https://github.com/black-atom-industries/iter.nvim/issues/20)
* **changes:** list untracked files one by one, fix drawer height ([e8c12ce](https://github.com/black-atom-industries/iter.nvim/commit/e8c12ceeabe7c9705d09d2428baca4add17b4c58)), closes [#1](https://github.com/black-atom-industries/iter.nvim/issues/1)
* **comments:** add the comment float editor ([9b13e1f](https://github.com/black-atom-industries/iter.nvim/commit/9b13e1f0614e1ff63ccda36798be67b6a186fae9))
* **comments:** add the comment picker ([c5d8b9e](https://github.com/black-atom-industries/iter.nvim/commit/c5d8b9e0920fa416acd3f9fff017780dd5517ccf))
* **comments:** add the comment store and line anchors ([87f4075](https://github.com/black-atom-industries/iter.nvim/commit/87f407598b54a566487b886485f23016a95fcfbe))
* **comments:** show comments in normal file buffers ([6ef44bf](https://github.com/black-atom-industries/iter.nvim/commit/6ef44bfbae111de2559dd2179cec9b419dbc17c4))
* **comments:** show comments in the review diff views ([1f59a94](https://github.com/black-atom-industries/iter.nvim/commit/1f59a94f41906715e0bc3efce7d9bc4df05cc41f))
* **config:** add the keymap layer, key config and :Iter subcommands ([2262c43](https://github.com/black-atom-industries/iter.nvim/commit/2262c4313df03f826242d04dc8709fe2b086df35))
* **diff:** add the diff model and view core ([b5ac3ff](https://github.com/black-atom-industries/iter.nvim/commit/b5ac3ffeb04245e6c781569fefc87d802bc5a89d))
* **diff:** add treesitter syntax and word emphasis to the diff view ([ccef10f](https://github.com/black-atom-industries/iter.nvim/commit/ccef10f5095d2c0893d5cfed0ae07c71281d4503))
* **diff:** diff.args for git diff ([42afa26](https://github.com/black-atom-industries/iter.nvim/commit/42afa26b34209824990f9e0b76780521d7d7551b)), closes [#11](https://github.com/black-atom-industries/iter.nvim/issues/11)
* **diff:** side-by-side view ([8878b77](https://github.com/black-atom-industries/iter.nvim/commit/8878b7702d83746acc7b1b4d0997988402c77200)), closes [#9](https://github.com/black-atom-industries/iter.nvim/issues/9)
* **diff:** stage selected lines ([802770e](https://github.com/black-atom-industries/iter.nvim/commit/802770e7f7153df89c6761f585d7f283bd5734e5)), closes [#5](https://github.com/black-atom-industries/iter.nvim/issues/5)
* **drawer:** &lt;C-d&gt;/&lt;C-u&gt; scroll the preview ([83d075d](https://github.com/black-atom-industries/iter.nvim/commit/83d075d3fd20bdf03a7e073a5eb0db2d74c6d637)), closes [#16](https://github.com/black-atom-industries/iter.nvim/issues/16)
* **drawer:** &lt;CR&gt; in the status preview opens the file at that line ([bf98bf3](https://github.com/black-atom-industries/iter.nvim/commit/bf98bf34aac643e32a8b4f3244e1a623136bf1fb)), closes [#2](https://github.com/black-atom-industries/iter.nvim/issues/2)
* **drawer:** add header, help float, clean state and auto refresh ([5c8f599](https://github.com/black-atom-industries/iter.nvim/commit/5c8f599bfb92dfb291169ff6e549d2086af98364))
* **drawer:** m, | and - in the status drawer and its diff ([4f71323](https://github.com/black-atom-industries/iter.nvim/commit/4f7132341f3394d34479a39295be0f1b6a33f2d8))
* **drawer:** replace the status window with the bottom drawer float ([d52c908](https://github.com/black-atom-industries/iter.nvim/commit/d52c908c31e6e20e40bd52ec1535827a5a5ad872))
* **export:** yank the review as a prompt for agents ([a59916b](https://github.com/black-atom-industries/iter.nvim/commit/a59916bc5c8a499d77c5bd8b33e1d52198039a3e))
* **highlight:** colorschemes can define Iter* groups ([18228f3](https://github.com/black-atom-industries/iter.nvim/commit/18228f3876421f721c1a355dbf582d7469eb8354)), closes [#15](https://github.com/black-atom-industries/iter.nvim/issues/15)
* **highlight:** file headers sit on a band with a rule above ([15a3f9c](https://github.com/black-atom-industries/iter.nvim/commit/15a3f9cfbad104fd69cbe709718b5c20bfb29c1a))
* renames as one row, ignore, statusline and events ([182fc27](https://github.com/black-atom-industries/iter.nvim/commit/182fc2745dd79039645030bb072cd9e8a2cda321)), closes [#10](https://github.com/black-atom-industries/iter.nvim/issues/10)
* **review:** add the review tab ([69e3f7e](https://github.com/black-atom-industries/iter.nvim/commit/69e3f7e2389cf12f623f07acecd04c38eb2cd0c4))
* **review:** add viewed marks ([26575b2](https://github.com/black-atom-industries/iter.nvim/commit/26575b28fd370a04ae7456095015bda4366d56c5))
* **review:** annotations column ([d56987f](https://github.com/black-atom-industries/iter.nvim/commit/d56987fd547a684b54d81558ba405b54be48358b)), closes [#19](https://github.com/black-atom-industries/iter.nvim/issues/19)
* **review:** branch diff against the base branch ([6cdd76b](https://github.com/black-atom-industries/iter.nvim/commit/6cdd76b6ee54bcddf1f7d952f3c6ee15f3b3506d)), closes [#6](https://github.com/black-atom-industries/iter.nvim/issues/6)
* **review:** continuous all-files mode ([471a7bb](https://github.com/black-atom-industries/iter.nvim/commit/471a7bb2a84d8d682061a5a22323b34a311ba1ac)), closes [#8](https://github.com/black-atom-industries/iter.nvim/issues/8)
* **review:** files stacked beside the annotations ([eb3938a](https://github.com/black-atom-industries/iter.nvim/commit/eb3938a832862753f1e883250bf4cf8f40f38378)), closes [#22](https://github.com/black-atom-industries/iter.nvim/issues/22)
* **review:** r marks a file reviewed ([8361e2b](https://github.com/black-atom-industries/iter.nvim/commit/8361e2b01d55ac005691fef15c46a2d1cb5329dc))
* **review:** r moves on to the next file not reviewed ([f4c0f6d](https://github.com/black-atom-industries/iter.nvim/commit/f4c0f6dacb7c6bc04a9265ebc80e2bd2b6e8c089))
* **review:** stage and unstage hunks from the diff pane ([be62af9](https://github.com/black-atom-industries/iter.nvim/commit/be62af95f86d032f126f9134988e0e3f2582c466))
* **review:** viewed files collapse in all-files mode ([73c623e](https://github.com/black-atom-industries/iter.nvim/commit/73c623ed0a71fde1bb9b0221d1f1f8b5808954f6)), closes [#23](https://github.com/black-atom-industries/iter.nvim/issues/23)
* routable iter:// buffers ([aee6514](https://github.com/black-atom-industries/iter.nvim/commit/aee6514d22833f6dc4efd330306d928ae2dccc4e)), closes [#12](https://github.com/black-atom-industries/iter.nvim/issues/12)
* **status:** ahead / behind and recent commits ([dca196c](https://github.com/black-atom-industries/iter.nvim/commit/dca196c86c087a4657295a78b2c765ce7024dbd6)), closes [#7](https://github.com/black-atom-industries/iter.nvim/issues/7)
* **ui:** add the pane-anchored float, change list and path utilities ([935d1bf](https://github.com/black-atom-industries/iter.nvim/commit/935d1bf39f79a554a8fb620b2cd9928947a9a3ff))


### Refactors

* comments become annotations ([d974e12](https://github.com/black-atom-industries/iter.nvim/commit/d974e12ba47975498231d565a3a927909a02aa5b)), closes [#14](https://github.com/black-atom-industries/iter.nvim/issues/14)
* **drawer:** split ui/drawer.lua ([41deac3](https://github.com/black-atom-industries/iter.nvim/commit/41deac31792ffa6cba6b000eb2c543d2e3b312b9)), closes [#3](https://github.com/black-atom-industries/iter.nvim/issues/3) [#13](https://github.com/black-atom-industries/iter.nvim/issues/13)
* one outdated rule, store lock, strict lint ([bb79fe3](https://github.com/black-atom-industries/iter.nvim/commit/bb79fe3c6619f7dde57ec394d8ede9eb3346e212)), closes [#13](https://github.com/black-atom-industries/iter.nvim/issues/13)
* **review:** remove the Branch column ([c71a3e3](https://github.com/black-atom-industries/iter.nvim/commit/c71a3e3f1bd7457559ca3688e159023594511b75)), closes [#18](https://github.com/black-atom-industries/iter.nvim/issues/18)


### Bug Fixes

* **drawer:** &lt;C-j&gt; from the diff pane focuses the drawer ([6a939b1](https://github.com/black-atom-industries/iter.nvim/commit/6a939b1f04d5c72b0035aea173989f4e4483a9ef)), closes [#24](https://github.com/black-atom-industries/iter.nvim/issues/24)
* **drawer:** same background as the main area ([fb23fc4](https://github.com/black-atom-industries/iter.nvim/commit/fb23fc4e0c00ba0e6e0b7edd1e53686c4a49a396)), closes [#21](https://github.com/black-atom-industries/iter.nvim/issues/21)
* findings from the v1 final review ([01ba3ff](https://github.com/black-atom-industries/iter.nvim/commit/01ba3ffecc8cbd0885e2e5f3d4b953e24fb090bd))
* loose ends from the M1 review ([734adad](https://github.com/black-atom-industries/iter.nvim/commit/734adad9d70bf5efabbd472807182bbfd7bc1518)), closes [#4](https://github.com/black-atom-industries/iter.nvim/issues/4)
* **review:** keep the review tab on buffer switches and polish the flow ([c863d7e](https://github.com/black-atom-industries/iter.nvim/commit/c863d7efed5364080862fa897d1493db3b0fde5f))


### Documentation

* add renovation plan and align agent instructions ([16c312e](https://github.com/black-atom-industries/iter.nvim/commit/16c312e7e13eb59961992fbef11ab8dfac198b28))
* document the renovated iter and remove unused code ([9f5fbdc](https://github.com/black-atom-industries/iter.nvim/commit/9f5fbdcf50831e76ca40151235d20ef3ce6d7673))
* move scope and architecture into CONVENTIONS, track work in issues ([95e2aa1](https://github.com/black-atom-industries/iter.nvim/commit/95e2aa1971cc26d1640b85610affb2e86fad75a1))
* README built around the review loop ([97c7b79](https://github.com/black-atom-industries/iter.nvim/commit/97c7b79499c0de996982cd9a89a6d6e6ce4d5360))
* README clips in Black Atom Sienna Light, layouts clip ([eed7ec4](https://github.com/black-atom-industries/iter.nvim/commit/eed7ec452bdd9aa955cd9d5ede88417308cd80b0))
* README clips of the drawer and the review tab ([c914850](https://github.com/black-atom-industries/iter.nvim/commit/c914850eebcc0499665fc345ec8a1fae2ebccbe8)), closes [#13](https://github.com/black-atom-industries/iter.nvim/issues/13)
* **renovation:** add the M1 inspection, module sketch and slice plan ([c8c174a](https://github.com/black-atom-industries/iter.nvim/commit/c8c174ab42547e53231ccaf4c6c7f29fe69c31d3))
* **renovation:** record the pure Lua renderer decision ([f724972](https://github.com/black-atom-industries/iter.nvim/commit/f7249724ab40a36975fffd65b00ea73a4bff1e86))
