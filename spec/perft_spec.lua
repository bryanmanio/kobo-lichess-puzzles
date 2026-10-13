-- Perft validation for chess.lua.
-- Perft counts leaf nodes of the legal move tree to a given depth. The expected
-- counts below are long established reference values, so any disagreement means
-- a move generation bug: castling, en passant, promotion or pinned piece handling.
-- Run with: luajit spec/perft_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;" .. package.path
local Chess = require("chess")

local function perft(pos, depth)
    if depth == 0 then return 1 end
    local moves = pos:generateLegalMoves()
    if depth == 1 then return #moves end
    local nodes = 0
    for i = 1, #moves do
        pos:makeMove(moves[i])
        nodes = nodes + perft(pos, depth - 1)
        pos:undoMove()
    end
    return nodes
end

local SUITES = {
    { name = "startpos",
      fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
      expect = { 20, 400, 8902, 197281 } },
    { name = "kiwipete (castling, pins)",
      fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
      expect = { 48, 2039, 97862 } },
    { name = "position 3 (en passant, promotion)",
      fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
      expect = { 14, 191, 2812, 43238 } },
    { name = "position 4 (promotions under check)",
      fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
      expect = { 6, 264, 9467 } },
    { name = "position 5",
      fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
      expect = { 44, 1486, 62379 } },
}

local failures, checks = 0, 0
for _, suite in ipairs(SUITES) do
    local pos, err = Chess.newFromFEN(suite.fen)
    if not pos then
        print(string.format("FAIL %-34s could not parse FEN: %s", suite.name, err))
        failures = failures + 1
    else
        for depth = 1, #suite.expect do
            local want = suite.expect[depth]
            local got = perft(pos, depth)
            checks = checks + 1
            if got == want then
                print(string.format("ok   %-34s perft(%d) = %d", suite.name, depth, got))
            else
                print(string.format("FAIL %-34s perft(%d) = %d, want %d",
                    suite.name, depth, got, want))
                failures = failures + 1
            end
            -- makeMove/undoMove must leave the position exactly as it was found.
            if pos:toFEN() ~= suite.fen then
                print(string.format("FAIL %-34s undo corrupted state: %s",
                    suite.name, pos:toFEN()))
                failures = failures + 1
            end
        end
    end
end

print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
