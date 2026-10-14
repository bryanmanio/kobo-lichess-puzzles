# The puzzle bench

An interactive isometric figure that explains how this plugin works, as one
machine you could build. Everything it shows is taken from the code:

| On the bench | In the plugin |
| --- | --- |
| The magazine on the left, ten cards to a batch | `BATCH_SIZE = 10`, `GET /api/puzzle/batch` |
| Its level scale, and the lamp that calls for a refill | `QUEUE_LOW_WATER = 2` |
| The cards staying in the well with the power off | the queue in `lichesspuzzles.lua` |
| The board in the middle, with the move just played shaded | `Session.last_move` |
| The print head that visits only the squares that changed | `PuzzleView:refreshSquares` |
| The tick it stamps in the corner of a square | `paintBadge` in `boardwidget.lua` |
| The outbox on the right, and the lever that empties it | the pending list, retried next run |
| The dial, and the bezel lock a hint screws down | `Session:isRatedAttempt` |
| The chute from the mast, and the one going back up | `getBatch` and `solve` |

Press **H** to take a hint and watch the bezel lock go down: the puzzle is
still reported, so it is never served again, but the needle cannot move.
Click or press space to step the machine on.

## Putting it on a page

**As a block in your own page.** `puzzle-bench.embed.html` is a fragment with
everything it needs: one themed wrapper, its styles, the figure, and the module
script that moves it. Paste it where you want the figure. It takes the width of
whatever contains it, and follows the reader's light or dark setting.

```html
<article>
  <p>…</p>
  <!-- paste the contents of puzzle-bench.embed.html here -->
  <p>…</p>
</article>
```

**In a frame.** `puzzle-bench.html` is the same figure as a standalone page,
with no external requests, so it can be served from anywhere:

```html
<iframe src="/figure/puzzle-bench.html" title="How Lichess Puzzles for Kobo works"
        width="100%" height="900" loading="lazy" style="border:0"></iframe>
```

Both files are self-contained: no fonts, no scripts, no network. About 430 KB
each, most of it the drawing itself.

## Rebuilding it

`src/` holds the figure's source. It is built with the Anatomy figure kit, and
expects that kit two directories up, the way the kit's own examples are laid
out:

```sh
cp -R src <anatomy>/examples/puzzle-bench
cd <anatomy>/examples/puzzle-bench
node build.mjs --auto     # the standalone page
node build.mjs --embed    # the fragment
node build.mjs --audit    # prove the geometry: clearances, supports, depth order
node ../../scripts/lines.mjs puzzle-bench.html   # every line must end on something
```

`geometry.mjs` is the world: where each station sits, how big a card is, the
position on the board and the profiles the chessmen are turned from.
`live.js` is the loop the figure plays. `build.mjs` draws it.
