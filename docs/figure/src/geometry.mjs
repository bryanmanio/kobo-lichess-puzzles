// Shared world layout for the puzzle bench. Pure numbers and profiles.
// x runs left to right along the bench, +y is toward the viewer, z is up.

export const PLATE = { x: -170, y: -78, w: 320, d: 166, r: 9 };
export const PLATE_H = 13;
export const FOOT_H = 5;

// ---- the deck every card rides along -------------------------------------
export const DECK_Z = 24;
export const CARD_T = 2.6;
export const CARD = { x: -36, y: -36, w: 72, d: 72, r: 2 };
export const SQ = 8;
export const BOARD0 = -32;         // the board runs -32..32 on both axes

// ---- stations -------------------------------------------------------------
export const MAG = { x: -150, y: -41, w: 84, d: 82, r: 4 };
export const MAG_TOP = 57;
export const MAG_X = -108;
export const STACK = 10;           // one batch
export const START_QUEUE = 7;
export const LOW_WATER = 2;

export const BED = { x: -50, y: -45, w: 100, d: 90, r: 4 };
export const PLINTH = { x: -42, y: -37, w: 84, d: 74, r: 4 };
export const BED_Z = 14;           // the bed slab starts here, on the plinth
export const RAIL_D = 9;
export const RAIL_TOP = 32;

export const FEED_X = -58;
export const OUT = { x: 54, y: -41, w: 84, d: 82, r: 4 };
export const OUT_X = 96;
export const OUT_TOP = 42;

export const MAST = [-158, -14];
export const MAST_TOP = 118;
export const MAST_CLAMP = [92, 106];
export const CHUTE_A = [-152, -12, 106];
export const CHUTE_B = [-104, 2, 64];

export const DIAL = [122, 54];
export const DIAL_Z = 60;
export const DIAL_H = 8;
export const DIAL_R = 16;
export const DIAL_TOP = DIAL_Z + DIAL_H;
export const COL = { x: 116, y: 48, w: 12, d: 12, r: 2 };
export const COL_H = 54;

export const RETURN_A = [136, -6, 43.5];
export const RETURN_B = [148, -38, 99];
export const BOX = { x: -164, y: 62, w: 48, d: 16, r: 2 };
export const BOX_H = 13;
export const CABLE_Y = 70;

// ---- the print gantry -----------------------------------------------------
export const GRAIL = { x: -58, y: 64, w: 116, d: 8, r: 1.5 };
export const GRAIL_Z = 30;
export const GRAIL_H = 6;
export const GRAIL_REACH = [-32, 32];
export const CARR = { x: -13, y: 63, w: 26, d: 12, r: 2 };
export const CARR_Z = 36;
export const CARR_H = 13;
export const TIP_Z = 40;
export const GLAND = { x: -7, y: 54, w: 14, d: 11, r: 2 };
export const GLAND_Z = 49;
export const GLAND_H = 12;
export const QUILL_FACE = 54;
export const QUILL_Z = 52.2;
export const QUILL_H = 5.4;
export const QUILL_W = 13;
export const HEAD_BACK = 7;
export const HEAD_FRONT = 5;
export const HEAD_Z = 49;
export const HEAD_H = 10;
export const NOZZLE_Z = 42;
export const NOZZLE_H = 7;
export const HEAD_PARK = 30;
export const PARK_X = -42;

// ---- the puzzle -----------------------------------------------------------
// Black has just played Nd7-b6; White mates with Re1-e8.
export const POSITION = [
  ["wK", 6, 0], ["wR", 4, 0], ["wP", 5, 1], ["wP", 6, 1], ["wP", 7, 1],
  ["bK", 6, 7], ["bP", 0, 6], ["bP", 5, 6], ["bP", 6, 6], ["bP", 7, 6], ["bN", 1, 5],
];
export const LAST_MOVE = [[3, 6], [1, 5]];
export const SOLUTION = [[4, 0], [4, 7]];
export const RATING = 1961;
export const GAIN = 6;

export function sqX(file) { return BOARD0 + SQ * file + SQ / 2; }
export function sqY(rank) { return -BOARD0 - SQ * rank - SQ / 2; }
export const NOZZLE_DY = 3.5;   // the tip sits this far in front of the head's centre
export const headY = (rank) => sqY(rank) - NOZZLE_DY;

// ---- the chessmen -------------------------------------------------------
// Each is a stack of small turned solids, the way a Staunton set is made:
// a base, a tapered stem, a collar, and whatever the piece wears on top.
// Built in units of its own, scaled by U; a man stands about 1.2 squares tall.
export const U = 1.5;
export const RB = 2.0;             // base radius, in the same units

const stem = (s0, s1, r0, r1) => [[s0, r0], [s1, r1]];
const collar = (s0, r) => [[s0, r], [s0 + 0.5, r], [s0 + 0.9, r - 0.45]];
export const BASE = [[0, RB], [0.62, RB], [0.86, RB - 0.42]];

export const MEN = {
  P: { stem: stem(0.86, 3.2, RB - 0.42, 0.82), collar: collar(3.2, 1.32), ball: [4.42, 0.88], top: 5.3 },
  R: { stem: stem(0.86, 3.0, RB - 0.42, 1.25), body: [[3.0, 1.36], [4.5, 1.36]], crown: [[4.5, 1.75], [5.5, 1.75], [5.5, 1.5]], top: 5.5 },
  N: { stem: stem(0.86, 2.5, RB - 0.42, 1.3), collar: collar(2.5, 1.46), head: [2.9, 6.1], top: 6.1 },
  B: { stem: stem(0.86, 3.3, RB - 0.42, 0.86), collar: collar(3.3, 1.36), mitre: [[3.9, 1.15], [5.0, 0.86, 1], [5.9, 0.3, 1], [6.1, 0]], ball: [6.25, 0.34], top: 6.4 },
  Q: { stem: stem(0.86, 3.5, RB - 0.42, 0.9), collar: collar(3.5, 1.43), crown: [[4.1, 1.06], [4.7, 1.3], [5.5, 1.53]], ball: [5.9, 0.58], top: 6.3 },
  K: { stem: stem(0.86, 3.5, RB - 0.42, 0.9), collar: collar(3.5, 1.43), crown: [[4.1, 1.06], [4.6, 1.22], [5.2, 1.36]], cross: [5.2, 6.5], top: 6.5 },
};
export const KNIGHT_HEAD = [[-1.35, 0], [1.2, 0], [1.62, 1.5], [0.78, 2.8], [-0.78, 2.95], [-1.5, 1.5]];
export const PIECE_TOP = Object.fromEntries(Object.entries(MEN).map(([key, man]) => [key, man.top * U]));
