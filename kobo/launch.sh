#!/bin/sh
# Starts KOReader with nothing on screen but the lichess puzzle board.
#
# KO_LICHESS_PUZZLES is what the plugin looks for: it opens the board at
# startup and exits KOReader when the board is closed. On Kobo, exiting
# KOReader restarts the stock interface, so leaving the puzzles lands back on
# the home screen.
#
# Installs to .adds/lichess-puzzles/launch.sh on the device.

# Refuse to start unless the stock interface is running.
#
# This is a guard against an unpleasant surprise rather than a normal case:
# koreader.sh decides what to do when KOReader exits by looking at how it was
# started. If Nickel was not running, and KSM is not either, it *reboots the
# device* instead of restarting the interface. Launched from the Kobo menu
# Nickel is always running, so this only triggers if the script is run by hand
# over SSH or telnet with the interface stopped, where a sudden reboot would be
# baffling. Same check koreader.sh itself uses.
if ! pkill -0 nickel 2>/dev/null; then
    echo "The Kobo interface is not running." >&2
    echo "Start puzzles from the Kobo menu, or exiting would reboot the device." >&2
    exit 1
fi

export KO_LICHESS_PUZZLES=1
exec /mnt/onboard/.adds/koreader/koreader.sh "$@"
