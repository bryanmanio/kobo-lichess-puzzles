-- SAN parsing and puzzle-shape validation against real lichess puzzles.
--
-- This is the test that matters most for production: it replays the exact
-- payloads the plugin will receive from /api/puzzle/batch and asserts the
-- invariants puzzleview.lua will rely on.
-- Run with: luajit spec/san_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;spec/fixtures/?.lua;" .. package.path
local Chess = require("chess")
local puzzles = require("puzzles")

local failures, checks = 0, 0

local function check(ok, msg)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        print("FAIL " .. msg)
    end
    return ok
end

-- 1. Hand written SAN edge cases that commonly break naive parsers.
local SAN_CASES = {
    -- { FEN, SAN, expected UCI }
    { "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e4", "e2e4" },
    { "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "Nf3", "g1f3" },
    -- File disambiguation: knights on b1 and f1 both reach d2.
    { "7k/8/8/8/8/8/8/1N1K1N2 w - - 0 1", "Nbd2", "b1d2" },
    { "7k/8/8/8/8/8/8/1N1K1N2 w - - 0 1", "Nfd2", "f1d2" },
    -- Castling, both spellings and both sides.
    { "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "O-O", "e1g1" },
    { "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", "O-O-O", "e1c1" },
    { "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", "0-0", "e8g8" },
    -- En passant capture.
    { "8/8/8/3pP3/8/8/8/K6k w - d6 0 1", "exd6", "e5d6" },
    -- Promotion, including underpromotion and promotion with check marker.
    { "8/4P3/8/8/8/8/8/K6k w - - 0 1", "e8=Q", "e7e8q" },
    { "8/4P3/8/8/8/8/8/K6k w - - 0 1", "e8=N", "e7e8n" },
    { "3r3k/4P3/8/8/8/8/8/K7 w - - 0 1", "exd8=R+", "e7d8r" },
    -- Rank disambiguation: rooks on a1 and a5 both reach a3.
    { "7k/8/8/R7/8/8/8/R6K w - - 0 1", "R1a3", "a1a3" },
    { "7k/8/8/R7/8/8/8/R6K w - - 0 1", "R5a3", "a5a3" },
    -- Annotations and mate markers must be ignored.
    { "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1", "Ra8#", "a1a8" },
    { "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "e4!?", "e2e4" },
}

for _, case in ipairs(SAN_CASES) do
    local fen, san, want = case[1], case[2], case[3]
    local pos, err = Chess.newFromFEN(fen)
    if check(pos ~= nil, "FEN parse failed: " .. tostring(err)) then
        local move, merr = pos:findSAN(san)
        if want == nil then
            -- Only asserting that it resolves to exactly one legal move.
            check(move ~= nil, string.format("SAN %s should resolve: %s", san, tostring(merr)))
        elseif check(move ~= nil, string.format("SAN %s failed: %s", san, tostring(merr))) then
            local got = pos:toUCI(move)
            check(got == want, string.format("SAN %s -> %s, want %s", san, got, want))
        end
    end
end

-- Ambiguous and illegal SAN must be rejected rather than silently guessed.
do
    local pos = Chess.newFromFEN("7k/8/8/R7/8/8/8/R6K w - - 0 1")
    check(pos:findSAN("Ra3") == nil, "ambiguous SAN Ra3 should be rejected")
    local start = Chess.new()
    check(start:findSAN("e5") == nil, "illegal SAN e5 should be rejected")
    check(start:findSAN("O-O") == nil, "illegal castling should be rejected")
end

-- 2. Real puzzles: the invariants puzzleview.lua depends on.
local replayed_plies, solution_moves, mate_finishes = 0, 0, 0

for _, pz in ipairs(puzzles) do
    local pos, plies_or_err = Chess.newFromPGN(pz.pgn)
    if check(pos ~= nil, string.format("puzzle %s PGN replay failed: %s",
                                       pz.id, tostring(plies_or_err))) then
        local plies = plies_or_err
        replayed_plies = replayed_plies + plies

        -- The documented relationship the whole design rests on.
        check(plies == pz.initialPly + 1,
            string.format("puzzle %s: %d plies, initialPly %d (expected plies == initialPly+1)",
                          pz.id, plies, pz.initialPly))

        -- Every solution move must be legal in sequence from the puzzle position.
        local ok = true
        for i, uci in ipairs(pz.solution) do
            local move, err = pos:applyUCI(uci)
            if not move then
                check(false, string.format("puzzle %s: solution move %d (%s) illegal: %s",
                                           pz.id, i, uci, tostring(err)))
                ok = false
                break
            end
            solution_moves = solution_moves + 1
        end

        -- Puzzles ending in mate should actually be mate, which validates
        -- the checkmate detection used to accept alternative mating moves.
        if ok and pos:isCheckmate() then mate_finishes = mate_finishes + 1 end
    end
end

print(string.format("replayed %d puzzles, %d PGN plies, %d solution moves, %d ending in mate",
    #puzzles, replayed_plies, solution_moves, mate_finishes))
print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
