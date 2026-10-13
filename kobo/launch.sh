#!/bin/sh
# Starts KOReader with nothing on screen but the lichess puzzle board.
#
# KO_LICHESS_PUZZLES is what the plugin looks for: it opens the board at
# startup and exits KOReader when the board is closed. On Kobo, exiting
# KOReader restarts the stock interface, so leaving the puzzles lands back on
# the home screen.
#
# Installs to .adds/lichess-puzzles/launch.sh on the device.

export KO_LICHESS_PUZZLES=1
exec /mnt/onboard/.adds/koreader/koreader.sh "$@"
