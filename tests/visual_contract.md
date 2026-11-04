# Ribbons: visual contract

Rules of the split layout's ribbons that screenshots can't check, because a test's
child Neovim shows no images. The designs are the "Split ribbons" page of the
[iter.nvim canvas](https://claude.ai/artifact/N3QkZ8nf9AuZvRTnR3geRQ): R2 in G2's
5-column gutter. `tests/test_ribbons.lua` and
`tests/test_ui_ribbons.lua` check what can be checked in memory. Check the rest by eye
in a Ghostty-based and a Kitty-based terminal.

## Where they show

- Terminals that answer the graphics query before the device attributes sentinel,
  outside tmux, with `termguicolors`.
- Everywhere else the split keeps its `╱` filler rows and its separator.
- A terminal rejecting an image gets one warning and the same split without ribbons for
  the rest of the session.

## Rows

- Rows, `scrollbind`, staging and annotations match the split without ribbons.
- Filler rows are blank, also in their rail.
- Both sides show the same width of text; an odd cell goes to the new side.

## Gutter

- It is 5 cells wide: the separator and 4 rail cells of the new side.
- The float never scrolls. Scrolling changes the image only.
- Every float of iter or the user covers it, and the cells show again when that float
  closes.
- It follows height changes of its window, and shows nothing outside it.
- Header rows, hunk rows and gap rows with a background carry it through the gutter. The
  rule between two files runs through it too.

## Bands

- A chunk is a run of lines with a change on either side. It has one band.
- Each side of a band spans from that side's first changed line to its last. A filler
  between two changed lines on one side lies inside the band.
- Same-size changes are straight, and fade from `IterDiffDelete` to `IterDiffAdd`.
- Sizes that differ fan out across the blank filler rows.
- Added lines are a solid `IterDiffAdd` band, narrowing to a thin point on the old side,
  at the bottom of the line above. Deleted lines are the same in `IterDiffDelete`,
  narrowing on the new side.
- A band's colour looks the same as its row's tint, in Ghostty on macOS too, whose images
  are Display P3.
- Rows with annotations count: bands follow the screen rows, not the line numbers, and
  slope off the window's edge without bending.

## The change under the cursor

- Its rows, their rail and its band take the tint of `IterDiffAddCursor` and
  `IterDiffDeleteCursor`, and its blank filler rows stay blank.
- On a line outside a chunk nothing changes.
- Every edge between rows, rail and band sits on a cell's edge, so they meet in any font.
  iter draws no terminal underlines here, since each font places them differently.
- The row under the cursor stands out through its line number and the cursor.
