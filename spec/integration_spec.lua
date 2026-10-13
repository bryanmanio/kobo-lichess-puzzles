-- End to end flow through the real main.lua, puzzleview.lua and boardwidget.lua,
-- with KOReader and the network stubbed. Catches wiring mistakes that a syntax
-- check cannot: wrong method names, nil fields, broken callbacks.
-- Run with: luajit spec/integration_spec.lua

package.path = "lichesspuzzles.koplugin/?.lua;spec/fixtures/?.lua;spec/support/?.lua;"
    .. package.path

local stub = require("koreader_stub")

local SETTINGS_DIR = os.getenv("TMPDIR") or "/tmp"
SETTINGS_DIR = string.gsub(SETTINGS_DIR, "/$", "")
stub.install{ settings_dir = SETTINGS_DIR }

-- Canned HTTP transport, shared by all tests in this file.
local net = { responses = {}, calls = {}, encoded = {}, decoded = nil }
package.preload["socket.http"] = function()
    return { request = function(req)
        net.calls[#net.calls + 1] = req
        local r = table.remove(net.responses, 1)
        if not r then error("unexpected HTTP call to " .. tostring(req.url)) end
        if r.fail then return nil, r.fail end
        net.decoded = r.decoded
        if req.sink then req.sink("body") end
        return 1, r.status or 200
    end }
end
package.preload["json"] = function()
    return {
        encode = function(t) net.encoded[#net.encoded + 1] = t; return '{"stub":1}' end,
        decode = function()
            if net.decoded == nil then error("no decoded payload queued") end
            return net.decoded
        end,
    }
end

local Chess = require("chess")
local puzzles = require("puzzles")
local Lichess = require("main")

local failures, checks = 0, 0
local function check(ok, msg)
    checks = checks + 1
    if not ok then failures = failures + 1; print("FAIL " .. msg) end
    return ok
end

-- Wraps a flat fixture puzzle back into the shape the API returns.
local function apiEntry(pz)
    return {
        game = { pgn = pz.pgn, id = "gameid" },
        puzzle = { id = pz.id, solution = pz.solution, rating = pz.rating,
                   themes = { "fork" }, initialPly = pz.initialPly },
    }
end

local TOKEN_PATH = SETTINGS_DIR .. "/lichess_token.txt"
local function writeToken(value)
    if value == nil then
        os.remove(TOKEN_PATH)
        return
    end
    local f = assert(io.open(TOKEN_PATH, "w"))
    f:write(value)
    f:close()
end

local function newPlugin()
    stub.reset()
    net.responses, net.calls, net.encoded, net.decoded = {}, {}, {}, nil
    return Lichess:new{ ui = { menu = { registerToMainMenu = function() end } } }
end

--- Finds the PuzzleView among the widgets shown.
local function shownView()
    for i = #stub.shown, 1, -1 do
        if stub.shown[i].session then return stub.shown[i] end
    end
end

--- Plays a solver move through the view exactly as two taps would.
local function tapMove(view, uci)
    local from = Chess.algebraicToSquare(string.sub(uci, 1, 2))
    local to = Chess.algebraicToSquare(string.sub(uci, 3, 4))
    view:onSquareTap(from)
    view:onSquareTap(to)
end

-- 1. The token is read from the USB-reachable file, with trailing newline tolerated.
do
    writeToken("lip_testtoken123\n")
    local plugin = newPlugin()
    check(plugin:readToken() == "lip_testtoken123",
        "token should be read and trimmed, got " .. tostring(plugin:readToken()))
    check(plugin.api:hasToken(), "client should be authenticated")
end

-- 2. Full flow: fetch a batch, solve a puzzle, submit, show the rating change.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]

    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz), apiEntry(puzzles[2]) } } },
        { status = 200, decoded = {
            rounds = { { id = pz.id, win = true, ratingDiff = 11 } },
            puzzles = {},
            glicko = { rating = 1612 },
        } },
    }

    plugin:start()

    local view = shownView()
    if check(view ~= nil, "a puzzle view should be shown") then
        check(view.session.puzzle.id == pz.id, "the first queued puzzle should be shown")
        check(view.board.flipped == (view.session.player_color == "black"),
            "the board should be oriented for the solver")

        local fetch = net.calls[1]
        check(fetch.method == "GET", "the first call should fetch puzzles")
        check(fetch.url:find("/api/puzzle/batch/mix", 1, true) ~= nil,
            "should fetch from the batch endpoint, got " .. tostring(fetch.url))
        check(fetch.headers["Authorization"] == "Bearer lip_testtoken123",
            "the fetch should be authenticated")

        -- Solve it by tapping out the solver's moves.
        for i = 1, #pz.solution, 2 do
            tapMove(view, pz.solution[i])
        end
        check(view.session:isFinished(), "the puzzle should be finished")
        check(view.session.win == true, "solving cleanly should be a win")

        -- The result must have been submitted.
        local submit = net.calls[2]
        if check(submit ~= nil, "the result should have been submitted") then
            check(submit.method == "POST", "submission should be a POST")
            check(submit.url:find("/api/puzzle/batch/mix", 1, true) ~= nil,
                "submission goes to the batch endpoint")
            local body = net.encoded[1]
            check(body and body.solutions and #body.solutions == 1,
                "submission should carry one solution")
            check(body.solutions[1].id == pz.id, "submission should name the puzzle")
            check(body.solutions[1].win == true, "submission should report the win")
            check(body.solutions[1].rated == true, "submission should be rated by default")
        end

        -- The rating change should reach the user.
        check(tostring(view.status_text.text):find("+11", 1, true) ~= nil,
            "the rating delta should be shown, got: " .. tostring(view.status_text.text))
        check(tostring(view.status_text.text):find("1612", 1, true) ~= nil,
            "the new rating should be shown")

        check(#plugin:pending() == 0, "pending results should be cleared after submission")

        -- Next should be enabled only once the puzzle is over.
        local next_button = view.button_table:getButtonById("next")
        check(next_button and next_button.enabled == true,
            "the Next button should be enabled when finished")
    end
end

-- 3. A failed submission keeps the result pending instead of losing it.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { fail = "connection refused" },
    }
    plugin:start()
    local view = shownView()
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end

    local pending = plugin:pending()
    check(#pending == 1, "a failed submission should leave the result pending, got " .. #pending)
    check(pending[1].id == pz.id, "the pending result should name the puzzle")
    check(tostring(view.status_text.text):lower():find("sent", 1, true) ~= nil,
        "the user should be told it will be sent later, got: "
        .. tostring(view.status_text.text))
end

-- 4. Without a token, puzzles still play but nothing is recorded.
do
    writeToken(nil)
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    check(view ~= nil, "anonymous users should still get a puzzle")
    check(view.signed_in == false, "an anonymous session is not signed in")
    check(tostring(view.status_text.text):find("no token", 1, true) ~= nil,
        "the status should say no token, not casual, got: "
        .. tostring(view.status_text.text))
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    check(#net.calls == 1, "no submission should be attempted without a token")
    check(tostring(view.status_text.text):lower():find("token", 1, true) ~= nil,
        "the user should be told a token is what is missing, got: "
        .. tostring(view.status_text.text))
end

-- 5. A wrong tap is rejected, keeps the board intact, and loses the puzzle.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    local before = view.session.position:toFEN()

    -- Find a legal but non-solution move to play.
    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    stub.defer_scheduled = true   -- hold the automatic take-back
    tapMove(view, wrong)
    check(view.session.win == false, "a wrong move should lose the puzzle")
    check(view.session.position:toFEN() ~= before,
        "a wrong move should be shown on the board")
    check(view.session:isFinished() == false, "the user can still continue after a mistake")
    -- ...and the next interaction takes it back.
    view:onSquareTap(Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2)))
    check(view.session.position:toFEN() == before, "the next tap should take it back")
    stub.defer_scheduled = false
end

-- 6. Selecting a piece marks destinations and asks for a cheap partial refresh.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    local from = Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2))

    local before = #stub.dirty
    view:onSquareTap(from)
    check(view.board.selected == from, "tapping an own piece should select it")
    local dest_count = 0
    for _ in pairs(view.board.destinations) do dest_count = dest_count + 1 end
    check(dest_count > 0, "selecting a piece should mark its legal destinations")

    local refresh = stub.dirty[#stub.dirty]
    check(#stub.dirty > before, "selecting should trigger a refresh")
    check(refresh.mode == "ui", "a selection should use a greyscale waveform, got "
        .. tostring(refresh.mode))
    check(refresh.region ~= nil and refresh.region.w < view.board.dimen.w,
        "a selection should refresh a region, not the whole board")

    -- Tapping a square the piece cannot reach must NOT drop the selection:
    -- a mis-tap would then be indistinguishable from the app freezing.
    local unreachable
    for sq = 0, 119 do
        if sq % 16 <= 7 and not view.session.position:pieceCodeAt(sq)
            and not view.board.destinations[sq] then
            unreachable = sq; break
        end
    end
    view:onSquareTap(unreachable)
    check(view.board.selected == from,
        "an unreachable tap should leave the piece selected")

    -- Tapping the selected piece again is the way to put it down.
    view:onSquareTap(from)
    check(view.board.selected == nil,
        "tapping the selected piece again should deselect it")

    -- And selecting a different own piece still switches the selection.
    local other
    for sq = 0, 119 do
        if sq % 16 <= 7 and sq ~= from and view.session:isOwnPiece(sq)
            and #view.session:legalMoves(sq) > 0 then
            other = sq; break
        end
    end
    if other then
        view:onSquareTap(from)
        view:onSquareTap(other)
        check(view.board.selected == other,
            "tapping another own piece should move the selection")
    end
end

-- 7. Hint and solution both finish the puzzle as a loss, and Next moves on.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz), apiEntry(puzzles[2]) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -7 } },
                                    puzzles = {}, glicko = { rating = 1590 } } },
    }
    plugin:start()
    local view = shownView()
    view:onHint()
    check(view.session.win == false, "a hint should lose the puzzle")
    check(view.board.marks[Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2))] == "hint",
        "the hint should mark the source square")

    view:onShowSolution()
    check(view.session:isFinished(), "showing the solution should finish the puzzle")
    check(tostring(view.status_text.text):find("-7", 1, true) ~= nil,
        "a rating loss should be shown, got: " .. tostring(view.status_text.text))

    -- Next advances to the second puzzle.
    view:onNextPuzzle()
    local second = shownView()
    check(second ~= view, "Next should open a new view")
    check(second.session.puzzle.id == puzzles[2].id, "Next should show the next queued puzzle")
end

-- 8. A wrong move must announce the loss immediately, not only via the score.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()

    local status_before = view.status_text.text
    check(tostring(status_before):find("FAILED", 1, true) == nil,
        "a fresh puzzle should not be marked failed")

    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    local wrong_to = Chess.algebraicToSquare(string.sub(wrong, 3, 4))
    stub.defer_scheduled = true   -- hold the automatic take-back
    tapMove(view, wrong)

    check(tostring(view.status_text.text):find("FAILED", 1, true) ~= nil,
        "the status line should say FAILED as soon as the mistake is made, got: "
        .. tostring(view.status_text.text))
    check(view.feedback_text == nil,
        "there should be no second text row competing for board space")
    check(view.board.marks[wrong_to] == "error",
        "the rejected square should stay marked until the next tap")

    -- The mark clears on the next interaction rather than on a timer.
    view:onSquareTap(Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2)))
    check(view.board.marks[wrong_to] == nil, "the mark should clear on the next tap")
    check(tostring(view.status_text.text):find("FAILED", 1, true) ~= nil,
        "the puzzle stays marked failed")
    stub.defer_scheduled = false
end

-- 9. After the puzzle ends, the arrows step through the solution.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = true, ratingDiff = 9 } },
                                    puzzles = {}, glicko = { rating = 1700 } } },
    }
    plugin:start()
    local view = shownView()
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end

    check(view.mode == "review", "finishing should switch to review mode")
    local hint = view.button_table:getButtonById("hint")
    local solution = view.button_table:getButtonById("solution")
    local redo = view.button_table:getButtonById("redo")
    check(hint.text == "\226\134\144", "Hint should become a back arrow, got " .. tostring(hint.text))
    check(solution.text == "\226\134\146", "Solution should become a forward arrow, got " .. tostring(solution.text))
    check(redo.enabled == true, "Redo should be enabled once finished")

    check(view.review.index == #pz.solution, "review should start at the final position")
    local final_fen = view.board.position:toFEN()

    -- Step all the way back to the puzzle start.
    for _ = 1, #pz.solution do view:onReviewBack() end
    check(view.review.index == 0, "stepping back should reach the start")
    local start_fen = Chess.newFromPGN(pz.pgn):toFEN()
    check(view.board.position:toFEN() == start_fen,
        "index 0 should be the puzzle start position")

    -- Clamped at both ends.
    view:onReviewBack()
    check(view.review.index == 0, "back at the start should clamp")
    for _ = 1, #pz.solution + 3 do view:onReviewForward() end
    check(view.review.index == #pz.solution, "forward past the end should clamp")
    check(view.board.position:toFEN() == final_fen,
        "stepping forward again should restore the final position")

    -- The rating change stays visible throughout the review.
    check(tostring(view.status_text.text):find("+9", 1, true) ~= nil,
        "the result should remain in the status line while reviewing, got: "
        .. tostring(view.status_text.text))

    -- Taps on the board are inert while reviewing.
    local before_fen = view.board.position:toFEN()
    view:onSquareTap(Chess.algebraicToSquare("e2"))
    check(view.board.position:toFEN() == before_fen, "board taps should do nothing in review")
end

-- 10. Redo replays the same puzzle without reporting it a second time.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = true, ratingDiff = 9 } },
                                    puzzles = {}, glicko = { rating = 1700 } } },
    }
    plugin:start()
    local view = shownView()
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    local calls_after_first = #net.calls
    check(calls_after_first == 2, "expected fetch + submit, got " .. calls_after_first)

    view:onRedo()
    check(view.mode == "playing", "redo should return to playing mode")
    check(view.session.win == true, "redo should start a clean attempt")
    check(view.session:isFinished() == false, "redo should reopen the puzzle")
    check(view.board.position:toFEN() == Chess.newFromPGN(pz.pgn):toFEN(),
        "redo should reset the board to the puzzle start")
    local hint = view.button_table:getButtonById("hint")
    check(hint.text == "Hint", "redo should restore the Hint label, got " .. tostring(hint.text))
    check(view.button_table:getButtonById("redo").enabled == false,
        "Redo should be disabled while playing")

    -- Solving it again must not submit a second result.
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    check(view.session:isFinished(), "the redone puzzle should finish")
    check(#net.calls == calls_after_first,
        "a redone puzzle must not be submitted again, calls went to " .. #net.calls)
end

-- 11. The status line stays short and drops the puzzle id.
-- The line that overflowed a Libra H2O panel was 55 display characters:
--   "Failed  .  rating 1931 (-11)  .  puzzle 1961  .  #D5end"
-- so every state must come in comfortably under that.
local STATUS_BUDGET = 42
local function displayLength(str)
    -- Count UTF-8 characters, not bytes: the separator and arrows are multibyte.
    local n = 0
    for _ in string.gmatch(str, "[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end
    return n
end
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -11 } },
                                    puzzles = {}, glicko = { rating = 1931 } } },
    }
    plugin:start()
    local view = shownView()

    -- The id was overflowing the panel on a Libra H2O and is not useful.
    check(tostring(view.status_text.text):find("#" .. pz.id, 1, true) == nil,
        "the puzzle id should not be in the status line, got: " .. tostring(view.status_text.text))

    -- Worst case while solving: lost and casual.
    view.session.win = false
    view.rated = false
    view:updateStatus()
    local playing = tostring(view.status_text.text)
    check(playing:find("FAILED", 1, true) ~= nil, "a lost puzzle should say FAILED")
    view.rated = true
    check(displayLength(playing) <= STATUS_BUDGET,
        "playing status too long (" .. displayLength(playing) .. "): " .. playing)

    -- Worst case after finishing: result, rating change and review counter.
    view:onShowSolution()
    local reviewing = tostring(view.status_text.text)
    check(reviewing:find("-11", 1, true) ~= nil, "the rating change should be shown")
    check(reviewing:find("/", 1, true) ~= nil, "the review counter should be shown")
    check(displayLength(reviewing) <= STATUS_BUDGET,
        "review status too long (" .. displayLength(reviewing) .. "): " .. reviewing)

    -- The counter tracks navigation.
    view:onReviewBack()
    check(tostring(view.status_text.text):find(
        string.format("%d/%d", view.review.index, #pz.solution), 1, true) ~= nil,
        "the counter should follow the arrows, got: " .. tostring(view.status_text.text))
end

-- 12. No board refresh may use a waveform that cannot render grey.
-- The dark squares are grey (0xCC). KOReader's "fast" is DU and "a2" is A2,
-- both of which render any content to pure black and white, which wiped the
-- checkerboard off the board on a real device until this was fixed.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -5 } },
                                    puzzles = {}, glicko = { rating = 1900 } } },
    }
    plugin:start()
    local view = shownView()

    -- Exercise every interaction that triggers a board refresh.
    local from = Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2))
    view:onSquareTap(from)          -- select
    view:onSquareTap(from)          -- deselect
    view:onHint()                   -- hint marks
    view:onHint()
    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    tapMove(view, wrong)            -- rejected move
    tapMove(view, pz.solution[1])   -- accepted move
    view:onShowSolution()           -- reveal, then finish
    view:onReviewBack()             -- review navigation
    view:onReviewForward()
    view:onRedo()

    local GREY_SAFE = { ui = true, partial = true, full = true,
                        flashui = true, flashpartial = true,
                        ["[ui]"] = true, ["[partial]"] = true }
    local bad, modes = 0, {}
    for _, entry in ipairs(stub.dirty) do
        local mode = entry.mode
        -- A nil/function mode is the widget deciding for itself; only explicit
        -- monochrome waveforms are a problem.
        if type(mode) == "string" then
            modes[mode] = (modes[mode] or 0) + 1
            if not GREY_SAFE[mode] then bad = bad + 1 end
        end
    end
    local seen = {}
    for mode, n in pairs(modes) do seen[#seen + 1] = mode .. "x" .. n end
    table.sort(seen)
    check(#stub.dirty > 0, "the run should have produced refreshes")
    check(bad == 0, "monochrome waveform used on the grey board; modes seen: "
        .. table.concat(seen, " "))
end

-- 13. The status strip is a fixed-width container, so the text stays centred.
-- VerticalGroup caches child widths at layout time, so a bare TextWidget whose
-- text got shorter drifted off centre on a real device.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()

    check(view.status_container ~= nil, "the status line should sit in a container")
    check(view.status_container.dimen.w == view.board.dimen.w,
        "the status strip should span the board width so centring is stable")

    local width_before = view.status_container.dimen.w
    view.session.win = false
    view:updateStatus()             -- status gets materially shorter here
    check(view.status_container.dimen.w == width_before,
        "the status strip width must not change with the text")

    -- The refresh must cover the whole strip, or the longer previous line
    -- would leave pixels behind on the panel.
    local last = stub.dirty[#stub.dirty]
    check(last.region == view.status_container.dimen,
        "a status update should refresh the whole strip, not just the new text")
end

-- 14. A wrong move is played, flagged, and taken back on the next tap.
-- Previously it was silently rejected, so the board simply did not move and
-- the app looked broken.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    local before_fen = view.session.position:toFEN()

    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    local wrong_from = Chess.algebraicToSquare(string.sub(wrong, 1, 2))
    local wrong_to = Chess.algebraicToSquare(string.sub(wrong, 3, 4))

    stub.defer_scheduled = true   -- hold the automatic take-back
    tapMove(view, wrong)
    check(view.session.position:toFEN() ~= before_fen,
        "the rejected move should be visible on the board")
    check(view.board.marks[wrong_to] == "error", "its destination should be marked")
    check(tostring(view.status_text.text):find("FAILED", 1, true) ~= nil,
        "FAILED should appear immediately, got: " .. tostring(view.status_text.text))

    -- The square the piece came from must be repainted too, or the piece would
    -- appear in two places at once.
    local fx = view.board:squareRect(wrong_from)
    local covered = false
    for _, entry in ipairs(stub.dirty) do
        local r = entry.region
        if r and r.w > 0 and r.x <= fx and r.x + r.w >= fx + view.board.square_size then
            covered = true
        end
    end
    check(covered, "the refresh should cover the square the piece left")

    -- Any next tap takes the move back. Use a square that is not part of the
    -- solution, so the take-back is isolated from selecting the next piece.
    local neutral
    for s2 = 0, 119 do
        if s2 % 16 <= 7 and not view.session.position:pieceCodeAt(s2) then
            neutral = s2; break
        end
    end
    view:onSquareTap(neutral)
    check(view.session.position:toFEN() == before_fen,
        "the next tap should take the rejected move back")
    check(view.session.pending_wrong == nil, "nothing should remain pending")
    check(#stub.scheduled == 0,
        "taking the move back by hand should cancel the pending timer")

    -- And the right move still works afterwards.
    tapMove(view, pz.solution[1])
    check(view.session.index > 1, "the correct move should be accepted after a mistake")
    stub.defer_scheduled = false
end

-- 15. Finishing inverts the status strip, so pass/fail is unmissable.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = true, ratingDiff = 8 } },
                                    puzzles = {}, glicko = { rating = 1700 } } },
    }
    plugin:start()
    local view = shownView()
    check(view.status_container.inverted == false,
        "the strip should not be inverted while solving")

    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    check(view.status_container.inverted == true,
        "finishing should invert the status strip")
    check(tostring(view.status_text.text):find("SOLVED", 1, true) ~= nil,
        "a win should say SOLVED, got: " .. tostring(view.status_text.text))

    view:onRedo()
    check(view.status_container.inverted == false,
        "redo should clear the inversion")
end

-- 16. The status strip reports where it was painted.
-- A Geom defaults to x=0,y=0 and CenterContainer never records its position,
-- so status refreshes were landing in the screen corner and the result often
-- never reached the panel.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(puzzles[1]) } } } }
    plugin:start()
    local view = shownView()

    local inverted_calls = {}
    local fake_bb = {
        invertRect = function(_, x, y, w, h)
            inverted_calls[#inverted_calls + 1] = { x = x, y = y, w = w, h = h }
        end,
    }

    view.status_container:paintTo(fake_bb, 37, 101)
    check(view.status_container.dimen.x == 37 and view.status_container.dimen.y == 101,
        string.format("the strip must record where it was painted, got %s,%s",
            tostring(view.status_container.dimen.x),
            tostring(view.status_container.dimen.y)))
    check(#inverted_calls == 0, "it should not invert while solving")

    view.status_container.inverted = true
    view.status_container:paintTo(fake_bb, 37, 101)
    check(#inverted_calls == 1, "an inverted strip should invert exactly once")
    local call = inverted_calls[1]
    check(call.x == 37 and call.y == 101 and call.w == view.board.dimen.w,
        "the inversion should cover the whole strip where it was painted")
end

-- 17. Normally nothing happens until the user asks for a puzzle.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    check(plugin.kiosk == false, "a plain launch is not a kiosk launch")
    check(shownView() == nil, "no board should open on its own")
end

-- 18. The home screen launcher opens the board at startup and exits KOReader
-- when the user leaves it, which is what hands the Kobo back to its own UI.
do
    writeToken("lip_testtoken123")
    local real_getenv = os.getenv
    os.getenv = function(name)
        if name == "KO_LICHESS_PUZZLES" then return "1" end
        return real_getenv(name)
    end

    local plugin, view
    local ok, err = pcall(function()
        stub.reset()
        net.responses = { { status = 200, decoded = { puzzles = { apiEntry(puzzles[1]) } } } }
        net.calls, net.encoded, net.decoded = {}, {}, nil
        -- init() autostarts, and the stubbed nextTick runs it straight away.
        plugin = Lichess:new{ ui = { menu = { registerToMainMenu = function() end } } }
        view = shownView()
    end)
    os.getenv = real_getenv
    if not ok then error(err) end

    check(plugin.kiosk == true, "the environment variable should be noticed")
    if check(view ~= nil, "the board should open without being asked") then
        view:onClose()
        check(stub.broadcast[#stub.broadcast] == "onExit",
            "leaving the board should exit KOReader, got "
                .. tostring(stub.broadcast[#stub.broadcast]))
    end
end

-- 19. The board carries its own menu, because the kiosk never shows KOReader's.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(puzzles[1]) } } } }
    plugin:start()
    local view = shownView()

    -- The target has to follow the strip to wherever it was painted, which is
    -- the whole reason StatusBar records its position.
    view.status_container:paintTo({ invertRect = function() end }, 20, 60)
    local region = view:statusTapRegion()
    local strip = view.status_container.dimen
    check(region.x == 20 and region.w == strip.w,
        "the target should sit over the strip")
    check(region.y < 60, "the target should reach up into the empty space above")
    check(region.y + region.h == 60 + strip.h,
        "the target must stop at the strip's bottom, not reach into the board")

    view:onTapStatus()
    local dialog = stub.last_dialog
    if check(dialog ~= nil, "tapping the status line should open the menu") then
        local labels = {}
        for _, row in ipairs(dialog.buttons) do
            for _, button in ipairs(row) do labels[#labels + 1] = button.text end
        end
        local joined = table.concat(labels, "|")
        check(joined:find("Rated", 1, true) ~= nil, "the menu should toggle rated, got " .. joined)
        check(joined:find("Account", 1, true) ~= nil, "the menu should show the account")
        check(joined:find("Quit", 1, true) ~= nil, "the menu should offer a way out")

        -- Toggling rated must be visible straight away: the result is reported
        -- with whatever is set when the puzzle is submitted, not when it opened.
        check(view.rated == true, "the puzzle starts rated")
        dialog.buttons[1][1].callback()
        check(plugin:isRated() == false, "the toggle should flip the setting")
        check(view.rated == false, "the board should follow the toggle")
    end
end

-- 17. Redo becomes available the moment the puzzle is lost, mid-play.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -9 } },
                                    puzzles = {}, glicko = { rating = 1900 } } },
    }
    plugin:start()
    local view = shownView()
    local redo = view.button_table:getButtonById("redo")
    local next_button = view.button_table:getButtonById("next")
    check(redo.enabled == false, "Redo should be unavailable on a fresh puzzle")

    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    tapMove(view, wrong)
    check(redo.enabled == true, "a wrong move should make Redo available")
    check(next_button.enabled == false, "Next should still wait for the puzzle to end")
    check(view.mode == "playing", "the puzzle should still be in play")

    -- Retrying resets the board but keeps the failure, because the mistake
    -- already happened and has not been reported yet.
    view:onRedo()
    check(view.mode == "playing", "redo mid-play should stay in playing mode")
    check(view.board.position:toFEN() == Chess.newFromPGN(pz.pgn):toFEN(),
        "redo should reset the board to the puzzle start")
    check(view.session.win == false,
        "an unreported failure must carry into the retry")
    check(redo.enabled == true, "Redo should remain available on a failed puzzle")
    check(tostring(view.status_text.text):find("FAILED", 1, true) ~= nil,
        "the retry should still show FAILED, got: " .. tostring(view.status_text.text))

    -- Solving the retry must report a LOSS, never a win.
    local calls_before = #net.calls
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    check(view.session:isFinished(), "the retry should finish")
    check(#net.calls == calls_before + 1, "the result should be submitted once")
    local body = net.encoded[#net.encoded]
    check(body and body.solutions and body.solutions[1].id == pz.id,
        "the submission should name the puzzle")
    check(body.solutions[1].win == false,
        "a retried failure must be reported as a loss, not a win")
end

-- 18. A hint also loses the puzzle, so it too should offer Redo.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    local redo = view.button_table:getButtonById("redo")
    check(redo.enabled == false, "Redo should start unavailable")
    view:onHint()
    check(redo.enabled == true, "taking a hint should make Redo available")
end

-- 19. Retrying an already-reported puzzle is pure practice: it starts clean
-- and must not submit a second result.
do
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    local pz = puzzles[1]
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -9 } },
                                    puzzles = {}, glicko = { rating = 1900 } } },
    }
    plugin:start()
    local view = shownView()
    view:onShowSolution()            -- loses and finishes the puzzle, reporting it
    check(view.submitted == true, "the result should have been reported")
    local calls_after_report = #net.calls

    view:onRedo()
    check(view.session.win == true,
        "once reported, a retry starts clean rather than pre-marked failed")
    for i = 1, #pz.solution, 2 do tapMove(view, pz.solution[i]) end
    check(#net.calls == calls_after_report,
        "a practice retry must not submit again, calls went to " .. #net.calls)
end

-- 20. "casual" and "no token" are different states and must not be conflated.
-- Showing "casual" when the token is simply missing hides a fixable problem.
do
    local pz = puzzles[1]

    -- Signed in, rated off: a deliberate choice.
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin.settings:saveSetting("rated", false)
    plugin:start()
    local view = shownView()
    check(view.signed_in == true, "a token should count as signed in")
    local text = tostring(view.status_text.text)
    check(text:find("casual", 1, true) ~= nil,
        "rated-off should read casual, got: " .. text)
    check(text:find("no token", 1, true) == nil,
        "a signed-in session must not claim the token is missing")

    -- No token at all: a problem, not a preference.
    writeToken(nil)
    plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    view = shownView()
    text = tostring(view.status_text.text)
    check(text:find("no token", 1, true) ~= nil,
        "a missing token should say so, got: " .. text)
    check(text:find("casual", 1, true) == nil,
        "a missing token must not be reported as a casual preference")
end

-- 21. The token is mirrored into settings, so losing the file does not
-- silently stop results being recorded. This device has lost files before.
do
    writeToken("lip_mirrored999")
    local plugin = newPlugin()
    check(plugin:readToken() == "lip_mirrored999", "the file token should be read")
    check(plugin.settings:readSetting("token") == "lip_mirrored999",
        "the token should have been mirrored into settings")

    -- With the file gone, the mirrored copy keeps the session authenticated.
    writeToken(nil)
    check(plugin:readToken() == "lip_mirrored999",
        "a lost token file should fall back to the mirrored copy")
    check(plugin.api ~= nil, "the client should still exist")
end

-- 22. FAILED says what caused it, and a lost puzzle still reports a missing
-- token. A bare "FAILED" after a hint reads as the move having been rejected.
do
    local pz = puzzles[1]
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()

    view:onHint()
    local text = tostring(view.status_text.text)
    check(text:find("FAILED (hint)", 1, true) ~= nil,
        "a hint should say it was the hint, got: " .. text)

    -- A mistake reads differently from a hint.
    plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    view = shownView()
    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    tapMove(view, wrong)
    text = tostring(view.status_text.text)
    check(text:find("FAILED (wrong move)", 1, true) ~= nil,
        "a mistake should say so, got: " .. text)

    -- Redo keeps the reason, since the loss is carried over too.
    view:onRedo()
    check(view.session.loss_reason == "wrong move",
        "redo should carry the reason with the loss, got "
        .. tostring(view.session.loss_reason))

    -- A missing token must stay visible even on a lost puzzle.
    writeToken(nil)
    plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    view = shownView()
    view:onHint()
    text = tostring(view.status_text.text)
    check(text:find("FAILED (hint)", 1, true) ~= nil, "still says why it failed")
    check(text:find("no token", 1, true) ~= nil,
        "a lost puzzle must still report a missing token, got: " .. text)
end

-- 23. The opponent's move is highlighted when a puzzle opens, and a correct
-- move is ticked. Both are how the website presents a puzzle.
do
    local pz = puzzles[1]
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()

    check(view.board.last_move ~= nil,
        "a puzzle should open with the opponent's move highlighted")
    check(view.board.last_move.to == view.session.last_move.to,
        "the board highlight should match the session's opening move")

    -- Playing the right move ticks the square it landed on.
    local to = Chess.algebraicToSquare(string.sub(pz.solution[1], 3, 4))
    tapMove(view, pz.solution[1])
    check(view.board.marks[to] == "correct",
        "a correct move should be ticked on its destination")

    -- The tick clears once the user acts again.
    view:onSquareTap(Chess.algebraicToSquare(string.sub(pz.solution[1], 1, 2)))
    check(view.board.marks[to] == nil, "the tick should clear on the next tap")

    -- A wrong move is never ticked.
    plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    view = shownView()
    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    stub.defer_scheduled = true   -- hold the automatic take-back
    tapMove(view, wrong)
    local wrong_to = Chess.algebraicToSquare(string.sub(wrong, 3, 4))
    check(view.board.marks[wrong_to] == "error", "a wrong move is marked as an error")
    for _, kind in pairs(view.board.marks) do
        check(kind ~= "correct", "a wrong move must never be ticked")
    end
    stub.defer_scheduled = false
end

-- 24. A rejected move is shown with a cross, then put back on its own, so the
-- user can try again without having to tap to clear it.
do
    local pz = puzzles[1]
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = { { status = 200, decoded = { puzzles = { apiEntry(pz) } } } }
    plugin:start()
    local view = shownView()
    local before_fen = view.session.position:toFEN()

    local wrong
    for _, m in ipairs(view.session.position:generateLegalMoves()) do
        local uci = view.session.position:toUCI(m)
        if uci ~= pz.solution[1] then
            view.session.position:makeMove(m)
            local mate = view.session.position:isCheckmate()
            view.session.position:undoMove()
            if not mate then wrong = uci; break end
        end
    end
    local wrong_to = Chess.algebraicToSquare(string.sub(wrong, 3, 4))

    -- Hold the timer so the intermediate state can be inspected.
    stub.defer_scheduled = true
    tapMove(view, wrong)

    check(view.session.position:toFEN() ~= before_fen,
        "the move should be visible before it is put back")
    check(view.board.marks[wrong_to] == "error", "it should be crossed")
    check(#stub.scheduled == 1, "a take-back should be queued, got " .. #stub.scheduled)

    -- Let the timer fire.
    stub.runScheduled()
    check(view.session.position:toFEN() == before_fen,
        "the piece should be put back on its own")
    check(view.session.pending_wrong == nil, "nothing should remain pending")
    check(view.board.marks[wrong_to] == nil, "the cross should clear with the move")

    -- The puzzle stays lost and still playable.
    check(view.session.win == false, "the puzzle remains lost")
    check(view.session:isFinished() == false, "the user can still try again")
    tapMove(view, pz.solution[1])
    check(view.session.index > 1, "the right move should still be accepted")

    stub.defer_scheduled = false
end

-- 25. Solving a puzzle after a hint must read as solved, while still earning
-- nothing. Reporting it as FAILED hid the fact that the user solved it.
do
    local pz = puzzles[1]
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -6 } },
                                    puzzles = {}, glicko = { rating = 1925 } } },
    }
    plugin:start()
    local view = shownView()

    view:onHint()
    for i = 1, #pz.solution, 2 do
        if view.session:isFinished() then break end
        tapMove(view, pz.solution[i])
    end

    check(view.session:isFinished(), "the puzzle should be finished")
    check(view:outcomeLabel():find("SOLVED", 1, true) ~= nil,
        "finishing the line yourself should read as solved, got: " .. view:outcomeLabel())
    check(view:outcomeLabel():find("hint", 1, true) ~= nil,
        "it should say the hint is why it earned nothing, got: " .. view:outcomeLabel())
    check(tostring(view.status_text.text):find("SOLVED", 1, true) ~= nil,
        "the banner should say solved, got: " .. tostring(view.status_text.text))

    -- ...but it must still be reported as a loss, so no rating is gained.
    local body = net.encoded[#net.encoded]
    check(body and body.solutions[1].win == false,
        "a hinted solve must still be reported as a loss")

    -- Being shown the answer is not a solve.
    plugin = newPlugin()
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -6 } },
                                    puzzles = {}, glicko = { rating = 1925 } } },
    }
    plugin:start()
    view = shownView()
    view:onShowSolution()
    check(view:outcomeLabel() == "FAILED",
        "being shown the answer is not solving it, got: " .. view:outcomeLabel())
end

-- 26. A retry must not display the previous attempt's result, and must not
-- earn anything for a puzzle that was already reported.
do
    local pz = puzzles[1]
    writeToken("lip_testtoken123")
    local plugin = newPlugin()
    net.responses = {
        { status = 200, decoded = { puzzles = { apiEntry(pz) } } },
        { status = 200, decoded = { rounds = { { id = pz.id, win = false, ratingDiff = -6 } },
                                    puzzles = {}, glicko = { rating = 1925 } } },
    }
    plugin:start()
    local view = shownView()
    view:onHint()
    for i = 1, #pz.solution, 2 do
        if view.session:isFinished() then break end
        tapMove(view, pz.solution[i])
    end
    check(view.result_text ~= nil, "the first attempt should have a result")
    local calls_after_report = #net.calls

    view:onRedo()
    check(view.result_text == nil,
        "a retry must not keep showing the previous result, got: "
        .. tostring(view.result_text))
    check(tostring(view.status_text.text):find("1925", 1, true) == nil,
        "the old rating line must be gone, got: " .. tostring(view.status_text.text))
    check(view.status_container.inverted == false, "the banner should be cleared")

    -- Solving the retry perfectly still earns nothing: it was already reported.
    for i = 1, #pz.solution, 2 do
        if view.session:isFinished() then break end
        tapMove(view, pz.solution[i])
    end
    check(#net.calls == calls_after_report,
        "a retry must not be submitted again, calls went to " .. #net.calls)
end

writeToken(nil)
print(string.format("\n%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
