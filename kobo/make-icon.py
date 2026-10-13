#!/usr/bin/env python3
"""Draws the home screen tile: a chessboard with the title under it.

The tile is what you tap on the Kobo, so it is a cover image rather than an
icon: high contrast, no fine detail, legible at thumbnail size on e-ink.

Written with the standard library only (zlib and struct), so the artwork can
be regenerated anywhere without installing an imaging library.

    python3 -I kobo/make-icon.py kobo/lichess-puzzles.png
"""

import struct
import sys
import zlib

WIDTH, HEIGHT = 758, 1024
WHITE, LIGHT, DARK, BLACK = 0xFF, 0xFF, 0x6E, 0x00

SQUARE = 80
BOARD = SQUARE * 8
BOARD_X = (WIDTH - BOARD) // 2
BOARD_Y = 150
BORDER = 4

TITLE = "LICHESS PUZZLES"
GLYPH_SCALE = 7
GLYPH_GAP = 1  # in unscaled columns, doubled between words

# A 5x7 bitmap font, only the letters the title needs.
GLYPHS = {
    " ": ("     ",) * 7,
    "C": (" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "),
    "E": ("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"),
    "H": ("#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
    "I": (" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "),
    "L": ("#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"),
    "P": ("#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "),
    "S": (" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "),
    "U": ("#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
    "Z": ("#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"),
}


def blank():
    return [bytearray([WHITE] * WIDTH) for _ in range(HEIGHT)]


def fill(rows, x, y, w, h, value):
    for row in rows[max(0, y):max(0, y + h)]:
        row[max(0, x):max(0, x + w)] = bytes([value]) * len(row[max(0, x):max(0, x + w)])


def draw_frame(rows):
    # A hairline edge so the tile reads as a card on the Kobo's white home
    # screen instead of bleeding into it.
    fill(rows, 0, 0, WIDTH, 2, BLACK)
    fill(rows, 0, HEIGHT - 2, WIDTH, 2, BLACK)
    fill(rows, 0, 0, 2, HEIGHT, BLACK)
    fill(rows, WIDTH - 2, 0, 2, HEIGHT, BLACK)


def draw_board(rows):
    fill(rows, BOARD_X - BORDER, BOARD_Y - BORDER,
         BOARD + 2 * BORDER, BOARD + 2 * BORDER, BLACK)
    for rank in range(8):
        for file_ in range(8):
            value = LIGHT if (rank + file_) % 2 == 0 else DARK
            fill(rows, BOARD_X + file_ * SQUARE, BOARD_Y + rank * SQUARE,
                 SQUARE, SQUARE, value)


def glyph_advance(char):
    # A space of one blank column reads as a gap in the word, not between
    # words, so the word break gets a column of its own.
    return (5 + GLYPH_GAP) * GLYPH_SCALE + (GLYPH_SCALE if char == " " else 0)


def draw_title(rows, baseline_y):
    text_w = sum(glyph_advance(c) for c in TITLE) - GLYPH_GAP * GLYPH_SCALE
    x = (WIDTH - text_w) // 2
    for char in TITLE:
        glyph = GLYPHS[char]
        for row_index, line in enumerate(glyph):
            for col_index, pixel in enumerate(line):
                if pixel == "#":
                    fill(rows,
                         x + col_index * GLYPH_SCALE,
                         baseline_y + row_index * GLYPH_SCALE,
                         GLYPH_SCALE, GLYPH_SCALE, BLACK)
        x += glyph_advance(char)


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(kind, payload):
        body = kind + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    # Bit depth 8, colour type 0 (greyscale): e-ink has no use for more.
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 0, 0, 0, 0)
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", header))
        out.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        out.write(chunk(b"IEND", b""))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "lichess-puzzles.png"
    rows = blank()
    draw_frame(rows)
    draw_board(rows)
    draw_title(rows, BOARD_Y + BOARD + 90)
    write_png(path, rows)
    print("wrote", path)


if __name__ == "__main__":
    main()
