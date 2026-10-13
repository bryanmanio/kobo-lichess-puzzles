#!/bin/sh
# Runs the desktop test suites. Requires luajit (brew install luajit).
# KOReader runs LuaJIT, so testing on luajit rather than lua5.4 keeps the
# engine honest about Lua 5.1 semantics.
set -e
cd "$(dirname "$0")/.."
for spec in perft san board session api integration; do
    printf '=== %s ===\n' "$spec"
    luajit "spec/${spec}_spec.lua"
    printf '\n'
done
echo "All suites passed."
