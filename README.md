# Lichess Puzzles for Kobo

Solve [lichess.org](https://lichess.org) puzzles on a Kobo e-reader, with results
reported back so your puzzle rating moves exactly as it does on the website.

A [KOReader](https://koreader.rocks) plugin, so it runs on nearly any Kobo and
survives firmware updates. Developed on a Libra H2O; the board sizes itself to
the screen, so other models work with no per-device code.

- Rated solving. Results go to `POST /api/puzzle/batch`, so your lichess puzzle
  rating updates and the change is shown after each puzzle.
- Puzzles you have never seen before, fetched in batches.
- Tap a piece, tap a square. The opponent's move is highlighted when the puzzle
  opens, correct moves get a tick, wrong ones a cross.
- Hints that make the puzzle casual rather than failing it, a solution replay,
  and Redo.
- Any mating move is accepted, not just the listed one, as on the website.
- Results survive a dropped connection: they are queued and sent on the next run.
- Optional NickelMenu entry that opens straight into the board.

---

## Requirements

| What | Why | Where |
| --- | --- | --- |
| A Kobo running firmware 4.x | KOReader and its launchers do not support 5.x/6.x yet | — |
| **KOReader** | The runtime this plugin is written for | [Install guide](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices) · [Releases](https://github.com/koreader/koreader/releases) |
| **KFMon** or **NickelMenu** | KOReader needs a launcher; both ship in NiLuJe's one-click package | [KFMon](https://github.com/NiLuJe/kfmon) · [NickelMenu](https://pgaskin.net/NickelMenu/) |
| A **lichess account** | Puzzles are fetched and results recorded against it | [lichess.org](https://lichess.org/signup) |
| A lichess **API token** | Scopes `puzzle:read` and `puzzle:write` | [Create one](https://lichess.org/account/oauth/token/create?scopes[]=puzzle:read&scopes[]=puzzle:write&description=Kobo+Puzzles) |
| **LuaJIT** *(developers only)* | Runs the test suite; KOReader itself runs LuaJIT | `brew install luajit` |

You can solve puzzles without a token, but nothing is recorded and puzzles may
repeat.

---

## Installing

### 1. Install KOReader

Easiest is NiLuJe's **one-click package** (`OCP-KOReader-*.zip`), which bundles
KOReader, KFMon and NickelMenu together: see the
[MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=314220)
or the [official guide](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices).

> **Extract it to the root of the Kobo, not into a subfolder.** On macOS,
> double-clicking the zip in Finder creates a folder named after the archive and
> puts everything inside it, so nothing lands where Nickel looks and KOReader
> never appears. Extract, then move the contents (`.adds`, `.kobo`, the `.png`
> files) to the top level of the `KOBOeReader` volume.
>
> Finder hides dot-folders, so you will not see `.adds` at all until you press
> <kbd>Cmd</kbd>+<kbd>Shift</kbd>+<kbd>.</kbd>

Eject, unplug, and let the Kobo finish its "Updating…" reboot — that step is
what installs KFMon.

### 2. Install the plugin

Copy the `lichesspuzzles.koplugin` folder to `.adds/koreader/plugins/`:

```sh
cp -R lichesspuzzles.koplugin /Volumes/KOBOeReader/.adds/koreader/plugins/
```

### 3. Sign in

Create a token with **both** `puzzle:read` and `puzzle:write`:

<https://lichess.org/account/oauth/token/create?scopes[]=puzzle:read&scopes[]=puzzle:write&description=Kobo+Puzzles>

Save it as a single line in `.adds/koreader/settings/lichess_token.txt`:

```sh
printf 'lip_yourtokenhere\n' > /Volumes/KOBOeReader/.adds/koreader/settings/lichess_token.txt
```

The token is never typed on the device. **Account** in the plugin menu confirms
who you are signed in as and your current puzzle rating.

### 4. Eject properly

```sh
sync && diskutil eject /Volumes/KOBOeReader
```

Then fully quit and relaunch KOReader — plugins load only at startup.

Open it from **Tools → More tools → Lichess puzzles**.

### 5. Optional: a NickelMenu entry

The `kobo/` folder adds a **Lichess Puzzles** item to the NickelMenu menu that
opens straight into the board and returns to the home screen when you leave.

```sh
KO=/Volumes/KOBOeReader
mkdir -p "$KO/.adds/lichess-puzzles"
cp kobo/launch.sh           "$KO/.adds/lichess-puzzles/"
cp kobo/nm-lichess-puzzles  "$KO/.adds/nm/lichess-puzzles"
chmod +x "$KO/.adds/lichess-puzzles/launch.sh"
```

This deliberately uses NickelMenu rather than a KFMon tile on the home screen.
A tile has to exist in the library for KFMon to accept it, and tapping it makes
Nickel open the image as a one-page book before handing over — which leaves a
"1% read" entry in **My Books** every single time. Spawning the launcher from
the menu avoids the library altogether.

### Nothing here modifies your existing setup

Every step above only **adds** files. Nothing in this project edits, moves or
deletes any part of KOReader, KFMon, NickelMenu or your library, and the plugin
only ever writes to its own two files in `.adds/koreader/settings/`. Your
existing launchers keep working exactly as they did, and you can go on starting
KOReader however you already do.

### Uninstalling

Delete what you copied in; there is nothing else to undo:

```sh
KO=/Volumes/KOBOeReader
rm -rf "$KO/.adds/koreader/plugins/lichesspuzzles.koplugin"
rm -f  "$KO/.adds/koreader/settings/lichesspuzzles.lua"
rm -f  "$KO/.adds/koreader/settings/lichess_token.txt"
# only if you installed the optional launcher in step 5
rm -rf "$KO/.adds/lichess-puzzles"
rm -f  "$KO/.adds/nm/lichess-puzzles"
```

Revoke the token at <https://lichess.org/account/oauth/token> if you no longer
want it.

---

## Using it

| Control | Action |
| --- | --- |
| Tap a piece | Select it. Tapping a square it cannot reach keeps it selected |
| Tap the piece again | Put it down |
| Tap a destination | Play the move |
| **Hint** | Highlights the piece to move, then the square to move it to |
| **Solution** | Plays out the rest of the line |
| **Redo** | Restart the puzzle. Available as soon as it is lost |
| **Next** | Next puzzle, once the current one has finished |
| **←** / **→** | After a puzzle, step through the solution |
| Page-turn buttons | Forward: next puzzle. Back: hint |
| Back | Leave |

### What the status line means

| Shown | Meaning |
| --- | --- |
| `White to play · Puzzle 1961` | Whose move, and the puzzle's difficulty rating |
| `Casual` | This attempt cannot change your rating |
| `Failed (wrong move)` | Lost, and why |
| `Solved` | You finished the line yourself |
| `Solved (mistake)` | Solved, but a wrong move means it earned nothing |
| `Failed` *(at the end)* | You were shown the answer |
| `No token` | Not signed in, so nothing is being recorded at all |

**Taking a hint makes that puzzle casual.** It is reported to lichess so it is
not served to you again, but as a casual round, so your rating does not move in
either direction — a nudge costs you the chance to gain, not a loss. The next
puzzle is rated again automatically; your own **Rated** setting is untouched.

A wrong move or viewing the solution still loses the puzzle, and is reported as
a loss, the same as on the website. **Rated** in the menu turns rating updates
off entirely if you want to practise without affecting anything.

---

## Troubleshooting

**KOReader does not appear after installing.** The archive was almost certainly
extracted into a subfolder; see the warning in step 1. Check that
`.adds/koreader/koreader.sh` and `.kobo/KoboRoot.tgz` exist at the volume root.

**Pieces show as letters (`K`, `q`, …).** The piece artwork could not be read, so
the board falls back to FEN letters rather than rendering blank. Re-copy
`lichesspuzzles.koplugin` to the device.

**Files you copied have vanished.** Writes to a Kobo can be lost if the volume is
unplugged without ejecting — macOS reports the copy as complete while the data
is still cached. Always `sync` and eject before unplugging.

**The library is full of plugin files.** Stop Nickel scanning hidden folders by
adding this under `[FeatureSettings]` in `.kobo/Kobo/Kobo eReader.conf`:

```ini
ExcludeSyncFolders=\\.(?:adds|kobo|kobo-images)
```

**"no token" even though the file is there.** Confirm it is at
`.adds/koreader/settings/lichess_token.txt`, one line, no quotes. Verify the
token itself with `./spec/live_check.sh <token>`.

**Asked to turn on Wi-Fi when it is already connected.** Fixed in current
versions. KOReader treats "online" as a successful DNS lookup, which a Kobo
radio waking from power save fails often enough to be annoying, and the plugin
used to read that as being offline. It now only asks for a connection, so if
you still see the prompt the device genuinely is not on a network.

---

## Development

The chess engine, solving rules and API client have no KOReader dependencies and
are tested on a desktop with LuaJIT — the same runtime KOReader uses, which
keeps the code honest about Lua 5.1 semantics.

```sh
brew install luajit
./spec/run.sh
```

| Suite | Covers |
| --- | --- |
| `perft_spec` | Move generation, against reference perft counts |
| `san_spec` | SAN parsing over 6000+ plies of real puzzle PGNs |
| `board_spec` | Square/pixel mapping, orientation, refresh regions, badges |
| `session_spec` | Solving rules, exercised on 100 real puzzles |
| `api_spec` | Request shaping and HTTP error mapping, transport injected |
| `integration_spec` | The whole flow, with KOReader and the network stubbed |

- `./spec/fetch_fixtures.sh` refreshes the puzzle fixtures from the live API.
- `./spec/live_check.sh <token>` verifies a real token, including the submission
  path that the stubbed suites cannot reach.

### Layout

| File | Responsibility |
| --- | --- |
| `chess.lua` | Board state, legal moves, SAN parsing, UCI. Pure Lua |
| `session.lua` | The rules of solving one puzzle. Pure Lua |
| `api.lua` | Lichess client. Transport injectable |
| `boardwidget.lua` | Draws the board, turns taps into squares |
| `puzzleview.lua` | Solving screen and e-ink refresh strategy |
| `main.lua` | Menu, settings, token, queue, submission |
| `kobo/` | NickelMenu entry and launcher |

### Notes for anyone extending this

**The puzzle format.** Puzzles arrive as a PGN plus `initialPly` and a UCI
solution, with no FEN. The puzzle position is the end of the PGN
(`plies == initialPly + 1`), and `solution[1]` is *your* move, not the
opponent's — the opposite of the convention in the downloadable puzzle CSV. That
is why a real SAN parser and legal move generator are needed.

**e-ink refreshes.** Never use the `fast` waveform on the board. It is DU, which
renders any content to pure black and white, so it erases the grey squares. All
board refreshes use `ui`, over the smallest region that changed.

---

## Credits

Piece artwork is the **cburnett** set from
[lila](https://github.com/lichess-org/lila/tree/master/public/piece/cburnett)
(GPLv2+), the pieces lichess uses by default.

Built on [KOReader](https://github.com/koreader/koreader) (AGPL-3.0), and
launched by [KFMon](https://github.com/NiLuJe/kfmon) and
[NickelMenu](https://pgaskin.net/NickelMenu/).

## Licence

[GPL-3.0-or-later](LICENSE), as required by the bundled cburnett artwork.
