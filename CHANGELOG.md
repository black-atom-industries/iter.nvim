# Changelog

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
