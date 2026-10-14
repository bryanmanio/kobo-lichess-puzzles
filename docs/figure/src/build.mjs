// The puzzle bench: how "Lichess Puzzles for Kobo" works, as one machine.
// Build with:  node build.mjs          (dark)
//              node build.mjs --light  (light)
//              node build.mjs --audit  (prove the geometry)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as k from "../../kit/iso-kit.mjs";
import * as G from "../../kit/lathe.mjs";
import { tubePieces, tubeSvg, crossingsOf } from "../../kit/tube.mjs";
import * as A from "../../kit/audit.mjs";
import { kitScript } from "../../scripts/inline-kit.mjs";
import * as W from "./geometry.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const AUTO = process.argv.includes("--auto");
const EMBED = process.argv.includes("--embed");
const THEME = AUTO || EMBED || process.argv.includes("--light") ? "light" : "dark";

const WIDTH = 680;
const HEIGHT = 496;
const AZIMUTH = 56;
const ELEVATION = 30;

const P = k.fitProjection(
  [
    ...k.boxCorners(W.PLATE, -W.PLATE_H - W.FOOT_H, 0),
    [W.MAST[0], W.MAST[1], W.MAST_TOP + 6],
    W.CHUTE_A,
    [W.DIAL[0], W.DIAL[1] - W.DIAL_R, W.DIAL_TOP + 4],
    [W.DIAL[0] + W.DIAL_R, W.DIAL[1], W.DIAL_TOP + 4],
    [0, W.GRAIL.y + W.GRAIL.d, W.GLAND_Z + W.GLAND_H + 4],
    [W.GRAIL.x, W.GRAIL.y + W.GRAIL.d, 0],
    [W.GRAIL.x + W.GRAIL.w, W.GRAIL.y + W.GRAIL.d, 0],
  ],
  WIDTH,
  HEIGHT,
  { pad: 26, azimuth: AZIMUTH, elevation: ELEVATION },
);

const V = G.viewOf(P);
const KS = G.scaleOf(P);
const at = (point) => k.iso(point, P);
const S = (paths, style) => k.solidSvg(paths, style);
const Ln = (d, style) => k.lineSvg(d, style);
const Dots = (points, style) => k.dotsSvg(points, style);
const f2 = (v) => Math.round(v * 100) / 100;
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));

const R = A.recorder(P);
const record = R.solid;
const put = (name, ref, svg, shapes = [], rest = {}) => R.put({ name, at: ref, bias: 0, svg, shapes, ...rest });

// ---- small builders that draw and record in one go -----------------------
function slab(name, plan, z, h, style = {}, opts = {}) {
  const { steps = 6, bevel = 0.6, extra = "", inner = "", bias = 0, ref, attrs } = opts;
  const shape = record(A.slab(plan, z, h, { name, ...(opts.meta ?? {}) }, steps));
  const centre = ref ?? [plan.x + plan.w / 2, plan.y + plan.d / 2, z + h / 2];
  put(name, centre, S(k.slabOf(plan, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias, attrs });
  return shape;
}
function cyl(name, cx, cy, r, z, h, style = {}, opts = {}) {
  const { steps = Math.max(16, Math.round(G.stepsFor(r, 18, 72, KS))), bevel = 0, extra = "", inner = "", bias = 0 } = opts;
  const shape = record(A.cylinder(cx, cy, r, z, h, { name, ...(opts.meta ?? {}) }));
  put(name, [cx, cy, z + h / 2], S(k.cylinder(cx, cy, r, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias });
  return shape;
}
const upAt = (x, y, z) => G.frameOf([x, y, z], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
function turned(name, F, profile, style = {}, opts = {}) {
  const { extra = "", inner = "", bias = 0, radius, attrs } = opts;
  const shape = record(A.solid(F, profile, { name, radius, ...(opts.meta ?? {}) }));
  const mid = G.pointOf(F, (profile[0][0] + profile[profile.length - 1][0]) / 2, 0, 0);
  put(name, mid, S(G.solidOf(profile, F, P), { tone: "hi", ...style, inner }) + extra, [shape], { bias, attrs });
  return shape;
}

// =========================================================================
// 1. Base plate, feet, ruler strip, label plate
// =========================================================================
function base() {
  const out = [`<path class="iso-halo" d="${k.haloOf(W.PLATE, -W.PLATE_H - W.FOOT_H, W.PLATE_H, P)}"/>`];
  const baseShapes = [];
  for (const [x, y] of byDepth(k.corners(W.PLATE, 24))) {
    out.push(S(k.cylinder(x, y, 7.4, -W.PLATE_H - W.FOOT_H, 1.6, P, 30), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 5.6, -W.PLATE_H - W.FOOT_H + 1.6, W.FOOT_H - 1.6, P, 30), { tone: "mid" }));
    baseShapes.push(record(A.cylinder(x, y, 7.4, -W.PLATE_H - W.FOOT_H, W.FOOT_H, { name: "stand.foot", ground: true })));
  }
  out.push(S(k.slabOf(W.PLATE, -W.PLATE_H, W.PLATE_H, P, 9, 1.6), { tone: "lo" }));
  out.push(Ln(k.planOutline(k.insetPlan(W.PLATE, 5.5), 0, P, 9), { tone: "lo" }));
  const screws = k.corners(W.PLATE, 11);
  out.push(Ln(screws.map(([x, y]) => k.ring(x, y, 2.2, 0, P, 16)).join(""), { tone: "lo" }));
  out.push(Dots(screws.map(([x, y]) => at([x, y, 0])), { size: 0.5 }));

  // a ruler strip along the back edge, and a label plate beside it
  const strip = { x: W.PLATE.x + 16, y: W.PLATE.y + 5.5, w: 150, d: 7, r: 1 };
  out.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 4, 5, strip.y + strip.d - 0.8, 0.6, [2, 3.6], P);
  out.push(Ln(ticks.minor, { tone: "lo" }), Ln(ticks.major, { tone: "mid" }));
  out.push(Dots([at([strip.x + 2, strip.y + 3.5, 0.6]), at([strip.x + strip.w - 2, strip.y + 3.5, 0.6])], { size: 0.45 }));

  const label = { x: 18, y: W.PLATE.y + W.PLATE.d - 21, w: 76, d: 16, r: 2 };
  out.push(S(k.slabOf(label, 0, 0.9, P, 4), { tone: "lo", crease: "none" }));
  out.push(Ln(k.planOutline(k.insetPlan(label, 1.8), 0.9, P, 4), { tone: "faint" }));
  const rules = [[0.74, 4.4], [0.52, 8.0], [0.63, 11.6]];
  out.push(Ln(rules.map(([share, dy]) => k.lineOnTop([label.x + 4, label.y + dy], [label.x + 4 + (label.w - 8) * share, label.y + dy], 0.9, P)).join(""), { tone: "lo", free: true }));
  out.push(Dots([at([label.x + 2.6, label.y + label.d - 2.6, 0.9]), at([label.x + label.w - 2.6, label.y + 2.6, 0.9])], { size: 0.45 }));
  for (const fx of [-108, 100]) {
    const front = { x: fx, y: W.PLATE.y + W.PLATE.d - 12.5, w: 44, d: 7, r: 1 };
    out.push(S(k.slabOf(front, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
    const ft2 = k.topTicks(front.x + 3, front.x + front.w - 3, 4, 5, front.y + 0.8, 0.6, [2, 3.6], P);
    out.push(Ln(ft2.minor, { tone: "lo" }), Ln(ft2.major, { tone: "mid" }));
    out.push(Dots([at([front.x + 1.6, front.y + 3.5, 0.6]), at([front.x + front.w - 1.6, front.y + 3.5, 0.6])], { size: 0.45 }));
  }
  baseShapes.push(record(A.slab(W.PLATE, -W.PLATE_H, W.PLATE_H, { name: "stand.plate", ground: true }, 9)));
  put("stand.plate", [0, 0, -W.PLATE_H / 2], out.join(""), baseShapes, { bias: -400 });
}

// A card-count scale: one band round the post for every card the well can hold.
// sideSeam wraps the visible corners and ends on the slab's silhouette edges.
function levels(plan, count, steps = 2) {
  const minor = [], major = [];
  for (let i = 0; i <= count; i++) {
    const z = W.DECK_Z + 0.6 + i * W.CARD_T;
    (i % 5 === 0 ? major : minor).push(k.sideSeam(plan, z, P, steps));
  }
  return Ln(minor.join(""), { tone: "lo" }) + Ln(major.join(""), { tone: "mid" });
}

// =========================================================================
// 2. The magazine: the queue of puzzles, ten to a batch
// =========================================================================
function magazine() {
  const magBase = slab("mag.base", W.MAG, 0, W.DECK_Z, { tone: "mid" }, { steps: 5, bevel: 0.8, meta: { owner: "mag" }, inner: Ln(k.sideSeam(W.MAG, W.DECK_Z - 4.2, P, 5), { tone: "faint" }) });
  const inner = { x: W.MAG.x + 4, y: W.MAG.y + 4, w: W.MAG.w - 8, d: W.MAG.d - 8, r: 2 };
  put("mag.floor", [W.MAG.x + W.MAG.w / 2, W.MAG.y + W.MAG.d / 2, W.DECK_Z], Ln(k.planOutline(inner, W.DECK_Z, P, 5), { tone: "faint" }), [magBase], { bias: 0.4 });

  const wallTop = W.MAG_TOP - W.DECK_Z;
  const own = { meta: { owner: "mag" } };
  slab("mag.wall.back", { x: W.MAG.x, y: W.MAG.y, w: W.MAG.w, d: 4, r: 1 }, W.DECK_Z, wallTop, { tone: "mid" }, {
    steps: 3, bevel: 0.5, ...own,
    extra: Dots([at([W.MAG.x + 24, W.MAG.y + 2, W.MAG_TOP]), at([W.MAG.x + W.MAG.w - 24, W.MAG.y + 2, W.MAG_TOP])], { size: 0.45 }),
  });
  slab("mag.wall.left", { x: W.MAG.x, y: W.MAG.y + 4, w: 4, d: W.MAG.d - 8, r: 1 }, W.DECK_Z, wallTop, { tone: "mid" }, {
    steps: 3, bevel: 0.5, ...own,
    extra: Dots([at([W.MAG.x + 2, W.MAG.y + 16, W.MAG_TOP]), at([W.MAG.x + 2, W.MAG.y + W.MAG.d - 16, W.MAG_TOP])], { size: 0.45 }),
  });
  // front corner posts, open between them so the stack is in view
  const postW = 7;
  let magPost;
  for (const px of [W.MAG.x, W.MAG.x + W.MAG.w - postW]) {
    const plan = { x: px, y: W.MAG.y + W.MAG.d - 4, w: postW, d: 4, r: 0.3 };
    const name = px === W.MAG.x ? "mag.post.left" : "mag.post.right";
    const left = name === "mag.post.left";
    const shape = slab(name, plan, W.DECK_Z, wallTop - 5, { tone: "mid" }, {
      steps: 2, bevel: 0.5, meta: { owner: "mag" },
      inner: left ? levels(plan, W.STACK) : "",
    });
    if (left) magPost = shape;
  }
  const magCap = slab("mag.cap", { x: W.MAG.x, y: W.MAG.y + W.MAG.d - 4, w: W.MAG.w, d: 4, r: 1 }, W.MAG_TOP - 5, 5, { tone: "mid" }, {
    steps: 3, bevel: 0.5, meta: { owner: "mag" },
    extra: Dots([at([W.MAG.x + 3.5, W.MAG.y + W.MAG.d - 2, W.MAG_TOP]), at([W.MAG.x + W.MAG.w - 3.5, W.MAG.y + W.MAG.d - 2, W.MAG_TOP])], { size: 0.5 }),
  });
  // exit throat on the right: two short guides
  for (const gy of [W.MAG.y + 4, W.MAG.y + W.MAG.d - 15]) {
    slab("mag.guide", { x: W.MAG.x + W.MAG.w - 4, y: gy, w: 4, d: 11, r: 1 }, W.DECK_Z, wallTop, { tone: "mid" }, { steps: 3, bevel: 0.5, meta: { owner: "mag" } });
  }
}

// a blank card: the body plus a punched id row, drawn at a given centre
function cardBody(cx, z, { lit = false, board = false } = {}) {
  const plan = { x: cx - W.CARD.w / 2, y: W.CARD.y, w: W.CARD.w, d: W.CARD.d, r: W.CARD.r };
  const top = z + W.CARD_T;
  const out = [S(k.slabOf(plan, z, W.CARD_T, P, 4, 0.4), { tone: board ? "hi" : "lo", crease: board ? "lo" : "faint", lit })];
  out.push(Ln(k.planOutline(k.insetPlan(plan, 2.4), top, P, 4), { tone: "faint" }));
  if (board) out.push(boardFace(cx, top));
  else {
    // the id row: eight punched holes along the back edge, and two rule lines
    out.push(Dots(Array.from({ length: 8 }, (_, i) => at([plan.x + 10 + i * 5.6, plan.y + 5.6, top])), { size: 0.5, tone: "lo" }));
    out.push(Ln([0.66, 0.4].map((share, i) => k.lineOnTop([plan.x + 10, plan.y + 12 + i * 4], [plan.x + 10 + 44 * share, plan.y + 12 + i * 4], top, P)).join(""), { tone: "faint", free: true }));
  }
  return out.join("");
}

// the 8x8 face printed on a card, with its dark squares and edge ticks
function boardFace(cx, top) {
  const dark = [];
  for (let file = 0; file < 8; file++) {
    for (let rank = 0; rank < 8; rank++) {
      if ((file + rank) % 2 === 1) continue;
      const x0 = cx + W.BOARD0 + file * W.SQ;
      const y0 = W.BOARD0 + rank * W.SQ;
      dark.push(k.pathOf([at([x0, y0, top]), at([x0 + W.SQ, y0, top]), at([x0 + W.SQ, y0 + W.SQ, top]), at([x0, y0 + W.SQ, top])], true));
    }
  }
  const grid = [];
  for (let i = 0; i <= 8; i++) {
    grid.push(k.lineOnTop([cx + W.BOARD0 + i * W.SQ, W.BOARD0], [cx + W.BOARD0 + i * W.SQ, W.BOARD0 + W.SQ * 8], top, P));
    grid.push(k.lineOnTop([cx + W.BOARD0, W.BOARD0 + i * W.SQ], [cx + W.BOARD0 + W.SQ * 8, W.BOARD0 + i * W.SQ], top, P));
  }
  return `<path class="iso-shade" data-shade="1" d="${dark.join("")}"/>` +
    Ln(grid.join(""), { tone: "faint" }) +
    Ln(k.planOutline({ x: cx + W.BOARD0, y: W.BOARD0, w: W.SQ * 8, d: W.SQ * 8, r: 0 }, top, P, 2), { tone: "lo" });
}

// =========================================================================
// 3. The feed: a roller shaft that draws one card out of the magazine
// =========================================================================
function feed() {
  const own = { meta: { owner: "feed" } };
  slab("feed.table", { x: W.MAG.x + W.MAG.w, y: W.MAG.y + 3, w: W.BED.x - (W.MAG.x + W.MAG.w), d: W.MAG.d - 6, r: 2 }, W.DECK_Z - 2.6, 2.6, { tone: "lo" }, { steps: 3, bevel: 0.4 });
  const z = W.DECK_Z + 5.0;
  const yAxis = (y) => G.frameOf([W.FEED_X, y, z], [0, 1, 0], [1, 0, 0], [0, 0, 1]);
  const F = yAxis(0);
  // the bearing pillars at each end, the shaft between them
  for (const [by, name] of [[-46, "feed.pillar.back"], [40, "feed.pillar.front"]]) {
    slab(name, { x: W.FEED_X - 4, y: by, w: 8, d: 6, r: 1.5 }, 0, z + 3.6, { tone: "mid" }, {
      steps: 3, bevel: 0.4, ...own, extra: Dots([at([W.FEED_X, by + 3, z + 3.6])], { size: 0.5 }),
    });
  }
  for (const [s0, s1] of [[-40.1, -29.4], [-22.6, 22.6], [29.4, 40.1], [45.9, 48]]) {
    const shape = record(A.disc(F, s0, s1, 1.3, { name: "feed.shaft", owner: "feed" }));
    put("feed.shaft", G.pointOf(F, (s0 + s1) / 2, 0, 0), S(G.disc(s0, s1, 1.3, F, P, { steps: 20 }), { tone: "mid" }), [shape]);
  }
  // the two rollers that grip a card, and the hand knob on the outer end
  for (const ry of [-26, 26]) {
    const RF = yAxis(ry);
    const roller = [[-3.4, 1.3], [-3.0, 4.2], [3.0, 4.2], [3.4, 1.3]];
    put("feed.roller", G.pointOf(RF, 0, 0, 0),
      S(G.solidOf(roller, RF, P, { steps: 36 }), { tone: "hi", crease: "lo" }) +
      Ln(G.ribsOf(RF, -2.8, 2.8, 4.2, 26, P, { least: 0.1, seams: true }), { tone: "lo" }),
      [record(A.solid(RF, roller, { name: "feed.roller", owner: "feed" }))], { bias: 0.2 });
  }
  const KF = yAxis(52);
  const knob = [[-4.1, 1.3], [-3.4, 5.6], [3.0, 5.6], [3.6, 1.3]];
  put("feed.knob", G.pointOf(KF, 0, 0, 0),
    S(G.solidOf(knob, KF, P, { steps: 40 }), { tone: "mid" }) +
    Ln(G.ribsOf(KF, -2.8, 2.6, 5.6, 28, P, { least: 0.1, seams: true }), { tone: "lo" }),
    [record(A.solid(KF, knob, { name: "feed.knob", owner: "feed" }))], { bias: 0.3 });
}

// =========================================================================
// 4. The bed: where the puzzle is solved
// =========================================================================
function bed() {
  slab("bed.plinth", W.PLINTH, 0, W.BED_Z, { tone: "mid" }, { steps: 4, bevel: 0.7, inner: Ln(k.sideSeam(W.PLINTH, W.BED_Z - 3.2, P, 4), { tone: "faint" }) });
  const bedFloor = slab("bed.floor", W.BED, W.BED_Z, W.DECK_Z - W.BED_Z, { tone: "hi", crease: "lo" }, { steps: 5, bevel: 0.9 });
  put("bed.pocket", [0, 0, W.DECK_Z], Ln(k.planOutline(k.insetPlan(W.BED, 6), W.DECK_Z, P, 5), { tone: "faint" }), [bedFloor], { bias: 0.4 });
  let bedRail;
  for (const sign of [-1, 1]) {
    const y = sign < 0 ? W.BED.y : W.BED.y + W.BED.d - W.RAIL_D;
    const name = sign < 0 ? "bed.rail.back" : "bed.rail.front";
    const plan = { x: W.BED.x, y, w: W.BED.w, d: W.RAIL_D, r: 2 };
    const extra = Dots([at([W.BED.x + 8, y + W.RAIL_D / 2, W.RAIL_TOP]), at([W.BED.x + W.BED.w - 8, y + W.RAIL_D / 2, W.RAIL_TOP])], { size: 0.5 });
    bedRail = slab(name, plan, W.DECK_Z, W.RAIL_TOP - W.DECK_Z, { tone: "hi", crease: "lo" }, { steps: 3, bevel: 0.5, extra, inner: Ln(k.sideSeam(plan, W.DECK_Z + 3.4, P, 3), { tone: "faint" }) });
  }
  // file ticks hanging from the front rail's inner edge: eight squares
  const ft = k.topTicks(W.BOARD0, W.BOARD0 + W.SQ * 8, W.SQ, 4, W.BED.y + W.BED.d - W.RAIL_D, W.RAIL_TOP, [2, 3.4], P);
  put("bed.files", [0, W.BED.y + W.BED.d - W.RAIL_D, W.RAIL_TOP], Ln(ft.minor, { tone: "lo" }) + Ln(ft.major, { tone: "mid" }), [bedRail], { bias: 1.2 });
}

// =========================================================================
// 5. The outbox: results waiting to be reported
// =========================================================================
function outbox() {
  const outBase = slab("out.base", W.OUT, 0, W.DECK_Z, { tone: "mid" }, { steps: 5, bevel: 0.8, meta: { owner: "out" }, inner: Ln(k.sideSeam(W.OUT, W.DECK_Z - 4.2, P, 5), { tone: "faint" }) });
  put("out.floor", [W.OUT.x + W.OUT.w / 2, 0, W.DECK_Z],
    Ln(k.planOutline(k.insetPlan(W.OUT, 4), W.DECK_Z, P, 5), { tone: "faint" }) +
    Ln([-28, 0, 28].map((gy) => k.lineOnTop([W.OUT.x + 4, gy], [W.OUT.x + W.OUT.w - 4, gy], W.DECK_Z, P)).join(""), { tone: "faint" }),
    [outBase], { bias: 0.4 });
  const h = W.OUT_TOP - W.DECK_Z;
  slab("out.wall.back", { x: W.OUT.x, y: W.OUT.y, w: W.OUT.w, d: 4, r: 1 }, W.DECK_Z, h, { tone: "mid" }, {
    steps: 3, bevel: 0.5, meta: { owner: "out" },
    extra: Dots([at([W.OUT.x + 26, W.OUT.y + 2, W.OUT_TOP]), at([W.OUT.x + W.OUT.w - 26, W.OUT.y + 2, W.OUT_TOP])], { size: 0.45 }),
  });
  const rw = { x: W.OUT.x + W.OUT.w - 4, y: W.OUT.y + 4, w: 4, d: W.OUT.d - 8, r: 1 };
  slab("out.wall.right", rw, W.DECK_Z, h, { tone: "mid" }, {
    steps: 3, bevel: 0.5, meta: { owner: "out" },
    inner: Ln(k.sideSeam(rw, W.DECK_Z + h - 4.4, P, 3), { tone: "faint" }),
    extra: Ln(k.sideTicks(W.OUT.y + 12, W.OUT.y + W.OUT.d - 12, 3.4, 5, rw.x + rw.w, W.DECK_Z + h - 4.4, [h - 4.4, h - 4.4], P, "y").minor, { tone: "faint" }) +
      Dots([at([rw.x + 2, -18, W.OUT_TOP]), at([rw.x + 2, 18, W.OUT_TOP])], { size: 0.45 }),
  });
  for (const px of [W.OUT.x, W.OUT.x + W.OUT.w - 13]) {
    const plan = { x: px, y: W.OUT.y + W.OUT.d - 4, w: 13, d: 4, r: 0.3 };
    slab("out.post", plan, W.DECK_Z, h, { tone: "mid" }, {
      steps: 2, bevel: 0.5, meta: { owner: "out" },
      inner: px === W.OUT.x ? levels(plan, 6) : "",
    });
  }
  // the lever that sends the pending results back
  const pivot = { x: W.OUT.x + 20, y: W.OUT.y + W.OUT.d + 1, w: 11, d: 7, r: 1.5 };
  const lev = { x: pivot.x + 3, y: pivot.y + pivot.d, w: 5, d: 15, r: 1.2 };
  const levOwn = { meta: { owner: "out.lever" } };
  slab("out.lever.pivot", pivot, 0, W.OUT_TOP, { tone: "mid" }, { steps: 2, bevel: 0.4, ...levOwn, inner: Ln(k.sideSeam(pivot, W.DECK_Z, P, 2), { tone: "faint" }) });
  slab("out.lever.arm", lev, W.OUT_TOP - 3.4, 3.4, { tone: "hi", crease: "lo" }, { steps: 2, bevel: 0.4, ...levOwn });
  cyl("out.lever.knob", lev.x + lev.w / 2, lev.y + lev.d - 0.4, 3.0, W.OUT_TOP - 4.4, 5.4, { tone: "hi", crease: "lo" }, {
    bias: 0.6, ...levOwn, extra: Ln(k.knurl(lev.x + lev.w / 2, lev.y + lev.d - 0.4, 3.0, W.OUT_TOP - 4.4, W.OUT_TOP + 1.0, 18, P), { tone: "lo" }),
  });
}

// =========================================================================
// 6. The pieces, turned on the card they stand on
// =========================================================================
const PIECE_Z = W.DECK_Z + W.CARD_T;

const U = W.U;                        // one unit of a piece's own height
const up = (profile) => profile.map(([a, r, m]) => (m ? [a * U, r * U, m] : [a * U, r * U]));

function pieceSvg(code, cx, cy, z, { lit = false } = {}) {
  const type = code[1];
  const white = code[0] === "w";
  const man = W.MEN[type];
  const F = upAt(cx, cy, z);
  const style = white ? { tone: "hi", crease: "lo", lit } : { tone: "mid", crease: "faint", lit, className: "pb-black" };
  const edge = white ? "lo" : "mid";
  const turn = (profile, opts) => S(G.solidOf(up(profile), F, P, { steps: 30, ...opts }), style);
  const out = [turn(W.BASE), turn(man.stem, { rims: "none" })];
  if (man.collar) out.push(turn(man.collar));
  if (type === "R") {
    out.push(turn(man.body, { rims: "none" }), turn(man.crown));
    // four crenellations round the crown, ending on its own two rims
    out.push(Ln(G.ribsOf(F, man.crown[0][0] * U + 0.3, man.crown[1][0] * U - 0.2, man.crown[0][1] * U, 7, P, { least: 0.1, seams: true }), { tone: edge }));
  }
  if (type === "N") {
    const HF = G.frameOf([cx, cy, z + man.head[0] * U], [0, 1, 0], [1, 0, 0], [0, 0, 1]);
    out.push(S(G.prismOf(HF, KNIGHT_HEAD, -1.1 * U, 1.1 * U, P), style));
  }
  if (type === "B") {
    out.push(turn(man.mitre, { rims: "first" }));
    out.push(Ln(G.arcOf(F, man.mitre[1][0] * U, man.mitre[1][1] * U, P, { slope: -0.35 }), { tone: edge }));
  }
  if (type === "Q" || type === "K") out.push(turn(man.crown, { rims: "none" }));
  if (man.ball) out.push(S(G.sphereOf([cx, cy, z + man.ball[0] * U], man.ball[1] * U, P, { steps: 26 }), style));
  if (man.cross) {
    const [c0, c1] = man.cross;
    out.push(S(k.slabOf({ x: cx - 0.42 * U, y: cy - 0.42 * U, w: 0.84 * U, d: 0.84 * U, r: 0 }, z + c0 * U, (c1 - c0) * U, P, 2), style));
    out.push(S(k.slabOf({ x: cx - 1.25 * U, y: cy - 0.42 * U, w: 2.5 * U, d: 0.84 * U, r: 0 }, z + (c1 - 0.86) * U, 0.5 * U, P, 2), style));
  }
  return out.join("");
}
const KNIGHT_HEAD = W.KNIGHT_HEAD.map(([a, b]) => [a * U, b * U]);

// the full profile of a man, closed to the axis, for the audit
const manProfile = (type) => {
  const man = W.MEN[type];
  return up([...W.BASE, ...man.stem, ...(man.collar ?? []), [man.top, 0.4]]);
};

// =========================================================================
// 7. The mast, the delivery chute and its gate: a batch arriving
// =========================================================================
function chuteOf(a, b) {
  const axis = G.unit3(G.sub3(b, a));
  const u = G.unit3(G.cross3(axis, [0, 0, 1]));
  const v = G.cross3(u, axis);
  const F = G.frameOf(a, axis, u, v);
  const len = G.len3(G.sub3(b, a));
  const pt = (s, du, dv) => G.add3(G.add3(G.add3(a, G.mul3(axis, s)), G.mul3(u, du)), G.mul3(v, dv));
  return { F, u, v, axis, len, pt };
}
const CH = chuteOf(W.CHUTE_A, W.CHUTE_B);
const RT = chuteOf(W.RETURN_A, W.RETURN_B);
const CHUTE = CH.F, CH_U = CH.u, CH_V = CH.v, CH_LEN = CH.len, chPt = CH.pt;
const GATE_S = [CH_LEN - 16, CH_LEN - 13.4];

function mast() {
  const [mx, my] = W.MAST;
  cyl("mast.collar", mx, my, 6.0, 0, 5, { tone: "lo" }, { bevel: 0.4, meta: { owner: "mast" } });
  const clampZ = W.MAST_CLAMP;
  cyl("mast.post.low", mx, my, 3.4, 5, clampZ[0] - 5, { tone: "mid", crease: "none" }, {
    meta: { owner: "mast" }, extra: Ln([26, 48, 70].map((z) => k.sideArc(mx, my, 3.4, z, P, 18)).join(""), { tone: "faint" }),
  });
  const clamp = { x: mx - 7.5, y: my - 7, w: 13, d: 14, r: 2.5 };
  slab("mast.clamp", clamp, clampZ[0], clampZ[1] - clampZ[0], { tone: "mid" }, { steps: 4, bevel: 0.6, meta: { owner: "mast" } });
  const thumb = [clamp.x + clamp.w / 2, clamp.y + clamp.d + 1.6];
  slab("mast.neck", { x: thumb[0] - 1.5, y: clamp.y + clamp.d - 0.6, w: 3, d: 2.6, r: 0.8 }, clampZ[0] + 3.4, 4, { tone: "mid", crease: "none" }, { steps: 2, bevel: 0, meta: { owner: "mast" } });
  cyl("mast.thumb", thumb[0], thumb[1] + 1.4, 2.6, clampZ[0] + 2.4, 6, { tone: "mid" }, {
    meta: { owner: "mast" }, extra: Ln(k.knurl(thumb[0], thumb[1] + 1.4, 2.6, clampZ[0] + 2.4, clampZ[0] + 8.4, 18, P), { tone: "lo" }),
  });
  cyl("mast.post.high", mx, my, 3.4, clampZ[1], W.MAST_TOP - clampZ[1], { tone: "mid", crease: "none" }, { meta: { owner: "mast" } });
  cyl("mast.cap", mx, my, 4.4, W.MAST_TOP, 2.4, { tone: "mid" }, { bevel: 0.4, meta: { owner: "mast" } });
  // the link lamp: lit while lichess is being talked to
  const lampZ = W.MAST_TOP + 2.4 + 2.6;
  put("mast.lamp", [mx, my, lampZ],
    `<g data-lamp="link" class="pb-lamp">${S(G.sphereOf([mx, my, lampZ], 2.8, P, { steps: 28 }), { tone: "hi" })}</g>` +
    Ln(k.ring(mx, my, 3.2, W.MAST_TOP + 2.4, P, 20), { tone: "lo" }),
    [record(A.ball([mx, my, lampZ], 2.8, { name: "mast.lamp", owner: "mast" }))], { bias: 0.4 });
  // the bracket that carries the chute
  const hold = G.add3(G.pointOf(CHUTE, 20, 0, 0), G.mul3(CH_V, -1.6));
  const brkt = { x: Math.min(mx, hold[0]) - 2.2, y: Math.min(my, hold[1]) - 2.2, w: Math.abs(hold[0] - mx) + 4.4, d: Math.abs(hold[1] - my) + 4.4, r: 1.6 };
  slab("mast.bracket", brkt, hold[2] - 5.4, 5.4, { tone: "mid" }, { steps: 3, bevel: 0.4, meta: { owner: "mast" } });
}

function trough(tag, C, { gate = false, lip = "start", ribs = [], extra = 0 } = {}) {
  const FLOOR = [[-7.5, 0], [7.5, 0], [7.5, 1.8], [-7.5, 1.8]];
  const SIDE_L = [[-9.6, 0], [-7.5, 0], [-7.5, 7.6], [-9.6, 7.6]];
  const SIDE_R = [[7.5, 0], [9.6, 0], [9.6, 7.6], [7.5, 7.6]];
  const prism = (name, poly, s0, s1, style, bias = 0) => {
    const shape = record(A.prism(C.F, poly, s0, s1, { name, owner: tag }));
    const cu = poly.reduce((a, pt) => a + pt[0], 0) / poly.length;
    const cv = poly.reduce((a, pt) => a + pt[1], 0) / poly.length;
    put(name, G.pointOf(C.F, (s0 + s1) / 2, Math.hypot(cu, cv), Math.atan2(cv, cu)), S(G.prismOf(C.F, poly, s0, s1, P), style), [shape], { bias: bias + extra });
    return shape;
  };
  const floorShape = prism(`${tag}.floor`, FLOOR, 0, C.len, { tone: "mid" });
  prism(`${tag}.side.back`, SIDE_L, 0, C.len, { tone: "mid" });
  prism(`${tag}.side.front`, SIDE_R, 0, C.len, { tone: "mid" }, 0.3);
  const lipAt = lip === "start" ? [-2.6, 0] : [C.len, C.len + 2.6];
  prism(`${tag}.lip`, [[-11.4, 0], [11.4, 0], [11.4, 2.0], [-11.4, 2.0]], lipAt[0], lipAt[1], { tone: "lo" }, 0.4);
  const rails = ribs.map((v) =>
    k.pathOf([at(C.pt(v, -9.6, 7.6)), at(C.pt(v, -9.6, 0)), at(C.pt(v, 9.6, 0)), at(C.pt(v, 9.6, 7.6))])).join("");
  if (ribs.length) put(`${tag}.ribs`, C.pt(C.len / 2, 0, 0), Ln(rails, { tone: "faint" }), [floorShape], { bias: 1.4 + extra });
  if (!gate) return;
  // the gate: it lifts out of the trough when a batch is let through
  const face = [[-7.5, 1.8], [7.5, 1.8], [7.5, 7.6], [-7.5, 7.6]];
  put(`${tag}.gate`, C.pt((GATE_S[0] + GATE_S[1]) / 2, 0, 4.7),
    `<g data-part="gate">${S(G.prismOf(C.F, face, GATE_S[0], GATE_S[1], P), { tone: "hi", crease: "lo" })}</g>`,
    [record(A.prism(C.F, face, GATE_S[0], GATE_S[1], { name: `${tag}.gate`, owner: tag }))], { bias: 1.8 });
  prism(`${tag}.guide.back`, [[-9.6, 7.6], [-7.5, 7.6], [-7.5, 14.4], [-9.6, 14.4]], GATE_S[0] - 1.4, GATE_S[1] + 1.4, { tone: "lo" }, 1.2);
  prism(`${tag}.guide.front`, [[7.5, 7.6], [9.6, 7.6], [9.6, 14.4], [7.5, 14.4]], GATE_S[0] - 1.4, GATE_S[1] + 1.4, { tone: "lo" }, 2.0);
  prism(`${tag}.yoke`, [[-9.6, 14.4], [9.6, 14.4], [9.6, 16.4], [-9.6, 16.4]], GATE_S[0] - 1.4, GATE_S[1] + 1.4, { tone: "lo" }, 2.2);
}

function chute() {
  trough("chute", CH, { gate: true, lip: "start", ribs: [14, 28, 42, 56] });
}

// the results go back up a second trough, out of the outbox
function returnChute() {
  trough("ret", RT, { lip: "end", ribs: [16, 34, 52], extra: 6 });
  // the post that holds it up, with a ball head tangent to the trough's underside
  const under = RT.pt(38, 0, 0);
  const ball = G.sub3(under, G.mul3(RT.v, 3.0));
  cyl("ret.post", ball[0], ball[1], 2.8, 2.4, ball[2] - 2.6 - 2.4, { tone: "mid" }, {
    bias: 5.6, meta: { owner: "ret" },
    extra: Ln([18, 38].map((z) => k.sideArc(ball[0], ball[1], 2.8, z, P, 18)).join(""), { tone: "faint" }),
  });
  cyl("ret.foot", ball[0], ball[1], 4.6, 0, 2.4, { tone: "lo" }, { bias: 5.4, bevel: 0.4, meta: { owner: "ret" } });
  put("ret.ball", ball, S(G.sphereOf(ball, 3.0, P, { steps: 26 }), { tone: "mid" }),
    [record(A.ball(ball, 3.0, { name: "ret.ball", owner: "ret" }))], { bias: 5.8 });
}

// =========================================================================
// 8. The rating dial, on its column, with the bezel lock a hint closes
// =========================================================================
const PER_TURN = 40;   // rating points in one turn of the needle
let DIAL_PUCK = null;

function dial() {
  const [dx, dy] = W.DIAL;
  const dialCol = slab("dial.column", W.COL, 0, W.COL_H, { tone: "mid" }, { steps: 4, bevel: 0.7, meta: { owner: "dial" }, inner: Ln(k.sideSeam(W.COL, W.COL_H - 26, P, 4), { tone: "faint" }) });
  put("dial.col.screws", [dx, dy, W.COL_H], Dots([at([dx - 3.4, dy - 3.4, W.COL_H]), at([dx + 3.4, dy + 3.4, W.COL_H]), at([dx + 3.4, dy - 3.4, W.COL_H])], { size: 0.45 }), [dialCol], { bias: 0.5 });
  const PED = upAt(dx, dy, W.COL_H);
  turned("dial.pedestal", PED, [[0, 8.4], [1.6, 8.4], [2.2, 6.0], [W.DIAL_Z - W.COL_H - 0.8, 6.0], [W.DIAL_Z - W.COL_H, 7.6]], { tone: "mid" }, { meta: { owner: "dial" } });
  DIAL_PUCK = cyl("dial.puck", dx, dy, W.DIAL_R, W.DIAL_Z, W.DIAL_H, { tone: "hi", crease: "lo" }, {
    steps: 64, bevel: 0.8, meta: { owner: "dial" },
    extra: Ln(k.knurl(dx, dy, W.DIAL_R, W.DIAL_TOP - 3.0, W.DIAL_TOP, 76, P, 0.3), { tone: "lo" }) +
      Ln(k.sideArc(dx, dy, W.DIAL_R, W.DIAL_TOP - 3.0, P, 40), { tone: "faint" }),
  });
  const ticks = k.radialTicks(dx, dy, W.DIAL_R - 2.6, 40, 5, W.DIAL_TOP, [1.2, 2.6], P);
  put("dial.face", [dx, dy, W.DIAL_TOP],
    Ln(k.ring(dx, dy, W.DIAL_R - 1.8, W.DIAL_TOP, P, 64), { tone: "lo" }) +
    Ln(ticks.minor, { tone: "lo" }) + Ln(ticks.major, { tone: "mid" }) +
    Ln(k.radialTicks(dx, dy, W.DIAL_R - 2.6, 1, 1, W.DIAL_TOP, [4.2, 4.2], P).major, { tone: "hi" }) +
    Ln(k.ring(dx, dy, 1.6, W.DIAL_TOP, P, 16), { tone: "mid" }), [DIAL_PUCK], { bias: 1.2 });
  // the bezel lock: a hint screws it down, and the needle cannot move
  const lug = { x: dx + 15.4, y: dy - 3.6, w: 8, d: 7.2, r: 1.5 };
  slab("dial.lug", lug, W.DIAL_Z + 1, 6.4, { tone: "mid" }, { steps: 3, bevel: 0.4, meta: { owner: "dial" } });
  const screwX = lug.x + lug.w - 0.3;
  put("dial.lock", [screwX + 2.6, dy, W.DIAL_Z + 4.2],
    `<g data-part="pin">${S(k.cylinder(screwX + 2.6, dy, 2.4, W.DIAL_Z + 1.8, 4.8, P, 20), { tone: "hi", crease: "lo" })}` +
    Ln(k.knurl(screwX + 2.6, dy, 2.4, W.DIAL_Z + 1.8, W.DIAL_Z + 6.6, 16, P), { tone: "lo" }) + `</g>`,
    [record(A.cylinder(screwX + 2.6, dy, 2.4, W.DIAL_Z + 1.8, 4.8, { name: "dial.lock", owner: "dial" }))], { bias: 1.6 });
}

const needleAt = (rating) => {
  const [dx, dy] = W.DIAL;
  const turn = ((rating % PER_TURN) + PER_TURN) % PER_TURN / PER_TURN;
  const a = turn * Math.PI * 2;
  return k.lineOnTop([dx - Math.sin(a) * 3.2, dy + Math.cos(a) * 3.2], [dx + Math.sin(a) * (W.DIAL_R - 4), dy - Math.cos(a) * (W.DIAL_R - 4)], W.DIAL_TOP + 0.2, P);
};

// =========================================================================
// 9. The control box and the one cable on the bench
// =========================================================================
const CLIPS = [-92, -72];
const CABLE_R = 0.62;

function controlBox() {
  slab("box.body", W.BOX, 0, W.BOX_H, { tone: "mid" }, {
    steps: 4, bevel: 0.7, meta: { owner: "box" },
    inner: Ln(k.sideSeam(W.BOX, W.BOX_H - 3.2, P, 4), { tone: "faint" }),
    extra: Ln(k.planOutline(k.insetPlan(W.BOX, 2.6), W.BOX_H, P, 4), { tone: "faint" }) +
      Dots(k.corners(W.BOX, 3.4).map(([x, y]) => at([x, y, W.BOX_H])), { size: 0.45 }) +
      Dots(k.dotGrid(W.BOX.x + 7, W.BOX.y + 5.4, 7, 3, 2.6, W.BOX_H, P), { size: 0.4, tone: "lo" }),
  });
  // two lamps on the lid: the link, and the low-queue call for a refill
  const lamps = [["link", W.BOX.x + 34, W.BOX.y + 5.4], ["low", W.BOX.x + 41, W.BOX.y + 5.4]];
  for (const [which, lx, ly] of lamps) {
    const lamp = cyl(`box.lamp.${which}`, lx, ly, 2.6, W.BOX_H, 1.4, { tone: "lo" }, { steps: 20, bias: 0.4, meta: { owner: "box" } });
    put(`box.lamp.${which}.lens`, [lx, ly, W.BOX_H + 1.4],
      `<g data-lamp="${which}" class="pb-lamp"><path class="pb-lens" d="${k.pathOf(k.circleRing(0, 0, 1, 20).map(([cx, cy]) => at([lx + cx * 1.8, ly + cy * 1.8, W.BOX_H + 1.4])), true)}"/></g>` +
      Ln(k.ring(lx, ly, 1.8, W.BOX_H + 1.4, P, 20), { tone: "lo" }), [lamp], { bias: 0.6 });
  }
  // the cable's boss on the right-hand end face
  const BF = G.frameOf([W.BOX.x + W.BOX.w, W.BOX.y + 8, 7], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  put("box.boss", G.pointOf(BF, 0.8, 0, 0), S(G.disc(-0.3, 1.9, 2.2, BF, P, { steps: 20 }), { tone: "lo" }),
    [record(A.disc(BF, -0.3, 1.9, 2.2, { name: "box.boss", owner: "cable.head" }))], { bias: 0.5 });
}

function cable() {
  const pillarX = W.GRAIL.x + 4;
  const from = [W.BOX.x + W.BOX.w, W.BOX.y + 8, 7];
  const to = [pillarX - 4, W.GRAIL.y + 4, 9.4];
  const route = G.fillet([from, [from[0] + 13, from[1], 6.2], [to[0] - 15, to[1], 6.2], to], 2.4, 7, { P, tube: CABLE_R });
  // the clips that hold it down, and the gaps they cover
  const gaps = [[0, 2.0], [G.pathLength(route) - 2.0, G.pathLength(route)]];
  for (const cx of CLIPS) {
    const CF = G.frameOf([cx, W.BOX.y + 8, 6.2], [1, 0, 0], [0, 1, 0], [0, 0, 1]);
    for (const [s0, s1] of crossingsOf(route, [cx, W.BOX.y + 8, 6.2], [1, 0, 0], 2.4).map((s) => [s - 1.1, s + 1.1])) gaps.push([s0, s1]);
    slab("clip.post", { x: cx - 2.2, y: W.BOX.y + 5.6, w: 4.4, d: 4.8, r: 1.2 }, 0, 4.0, { tone: "lo" }, { steps: 2, bevel: 0.3 });
    put("clip.collar", [cx, W.BOX.y + 8, 6.2], S(G.disc(-1.1, 1.1, 2.0, CF, P, { steps: 20 }), { tone: "mid" }),
      [record(A.disc(CF, -1.1, 1.1, 2.0, { name: "clip.collar", fitting: true, touch: ["cable.head"] }))], { bias: 0.7 });
  }
  const runs = R.route("cable.head", route, CABLE_R, { gaps, touch: ["clip.collar", "box.boss", "gantry.pillar", "box.body"] });
  const pieces = tubePieces(route, CABLE_R, P, { maxLength: 14, gaps });
  for (const piece of pieces) {
    const run = runs.find((r) => piece.from >= r.offset - 0.6 && piece.from < r.offset + 0.6 + G.pathLength(r.points)) ?? runs[0];
    put("cable.head", piece.mid, tubeSvg(piece, { tone: "mid" }), [run], { bias: 0.6 });
  }
  // where it lands on the gantry pillar
  const PF = G.frameOf(to, [1, 0, 0], [0, 1, 0], [0, 0, 1]);
  put("gantry.boss", G.pointOf(PF, -0.8, 0, 0), S(G.disc(-1.9, 0.3, 2.2, PF, P, { steps: 20 }), { tone: "lo" }),
    [record(A.disc(PF, -1.9, 0.3, 2.2, { name: "gantry.boss", owner: "cable.head" }))], { bias: 0.5 });
}

// =========================================================================
// 10. The print gantry: it visits only the squares that changed
// =========================================================================
function gantryRail() {
  for (const px of [W.GRAIL.x + 4, W.GRAIL.x + W.GRAIL.w - 12]) {
    slab("gantry.pillar", { x: px - 4, y: W.GRAIL.y, w: 8, d: W.GRAIL.d, r: 1.5 }, 0, W.GRAIL_Z, { tone: "mid" }, { steps: 3, bevel: 0.5 });
  }
  const face = W.GRAIL.y + W.GRAIL.d;
  slab("gantry.rail", W.GRAIL, W.GRAIL_Z, W.GRAIL_H, { tone: "mid" }, {
    steps: 3, bevel: 0.5,
    inner: Ln(k.sideSeam(W.GRAIL, W.GRAIL_Z + W.GRAIL_H - 2.0, P, 3), { tone: "faint" }),
    // the rack the pinion runs in: teeth across the full height of the front face
    extra: Ln(k.sideTicks(W.GRAIL.x + 5, W.GRAIL.x + W.GRAIL.w - 5, 2.6, 5, face, W.GRAIL_Z + W.GRAIL_H - 2.0, [W.GRAIL_H - 2.0, W.GRAIL_H - 2.0], P, "x").minor, { tone: "lo" }),
  });
  for (const px of [W.GRAIL.x - 3, W.GRAIL.x + W.GRAIL.w]) {
    slab("gantry.stop", { x: px, y: W.GRAIL.y - 1, w: 3, d: W.GRAIL.d + 2, r: 1 }, W.GRAIL_Z, W.GRAIL_H + 3, { tone: "mid" }, {
      steps: 2, bevel: 0.4, extra: Dots([at([px + 1.5, W.GRAIL.y + W.GRAIL.d / 2, W.GRAIL_Z + W.GRAIL_H + 3])], { size: 0.5 }),
    });
  }
}

// Everything that travels, built at x = 0 with the head parked.
function gantryCar() {
  const out = [];
  const shapes = [];
  const push = (shape) => { shapes.push(record(A.moved(shape, [W.PARK_X, 0, 0]))); };
  const hy = W.HEAD_PARK;
  const qz = W.QUILL_Z;
  // the head, furthest from the viewer, and its nozzle below it
  const nozzle = { x: -4.6, y: hy + W.NOZZLE_DY - 4.6, w: 9.2, d: 9.2, r: 1.5 };
  const tipF = upAt(0, hy + W.NOZZLE_DY, W.TIP_Z);
  const tip = [[0, 1.5], [0.6, 2.0], [2.0, 2.7]];
  const head = { x: -8, y: hy - W.HEAD_BACK, w: 16, d: W.HEAD_BACK + W.HEAD_FRONT, r: 2 };
  const headSvg = [
    S(G.solidOf(tip, tipF, P, { steps: 24 }), { tone: "hi", crease: "lo" }),
    S(k.slabOf(nozzle, W.NOZZLE_Z, W.NOZZLE_H, P, 3, 0.4), { tone: "hi", crease: "lo" }),
    Ln(k.sideSeam(nozzle, W.NOZZLE_Z + 2.4, P, 3), { tone: "faint" }),
    S(k.slabOf(head, W.HEAD_Z, W.HEAD_H, P, 3, 0.5), { tone: "hi", crease: "lo" }),
    Ln(k.planOutline(k.insetPlan(head, 2.2), W.HEAD_Z + W.HEAD_H, P, 3), { tone: "faint" }),
    Dots([at([-5.4, hy - 5.4, W.HEAD_Z + W.HEAD_H]), at([5.4, hy - 5.4, W.HEAD_Z + W.HEAD_H]), at([-5.4, hy + 3.4, W.HEAD_Z + W.HEAD_H]), at([5.4, hy + 3.4, W.HEAD_Z + W.HEAD_H])], { size: 0.45 }),
  ].join("");
  push(A.slab(nozzle, W.NOZZLE_Z, W.NOZZLE_H, { name: "gantry.nozzle" }, 3));
  push(A.solid(tipF, tip, { name: "gantry.tip" }));
  push(A.slab(head, W.HEAD_Z, W.HEAD_H, { name: "gantry.head" }, 3));
  out.push(`<g data-part="head">${headSvg}</g>`);
  // the quill, rebuilt in the page as the head goes in and out
  const quillPlan = { x: -W.QUILL_W / 2, y: hy + W.HEAD_FRONT, w: W.QUILL_W, d: W.QUILL_FACE - (hy + W.HEAD_FRONT), r: 0.8 };
  out.push(`<g data-part="quill">${S(k.slabOf(quillPlan, qz, W.QUILL_H, P, 2, 0.4), { tone: "mid", crease: "lo" })}` +
    Ln([-3.2, 3.2].map((ox) => k.lineOnTop([ox, quillPlan.y], [ox, quillPlan.y + quillPlan.d], qz + W.QUILL_H, P)).join(""), { tone: "faint" }) + `</g>`);
  push(A.slab(quillPlan, qz, W.QUILL_H, { name: "gantry.quill" }, 2));
  // the gland it slides through, and the carriage under it
  out.push(S(k.slabOf(W.GLAND, W.GLAND_Z, W.GLAND_H, P, 3, 0.5), { tone: "mid" }));
  out.push(Ln(k.sideSeam(W.GLAND, W.GLAND_Z + 3.0, P, 3), { tone: "faint" }));
  out.push(Dots([at([-5, W.GLAND.y + 2.6, W.GLAND_Z + W.GLAND_H]), at([5, W.GLAND.y + 2.6, W.GLAND_Z + W.GLAND_H]), at([-5, W.GLAND.y + W.GLAND.d - 2.6, W.GLAND_Z + W.GLAND_H]), at([5, W.GLAND.y + W.GLAND.d - 2.6, W.GLAND_Z + W.GLAND_H])], { size: 0.45 }));
  push(A.slab(W.GLAND, W.GLAND_Z, W.GLAND_H, { name: "gantry.gland" }, 3));
  out.push(S(k.slabOf(W.CARR, W.CARR_Z, W.CARR_H, P, 3, 0.5), { tone: "mid" }));
  out.push(Ln(k.sideSeam(W.CARR, W.CARR_Z + 3.4, P, 3), { tone: "faint" }));
  push(A.slab(W.CARR, W.CARR_Z, W.CARR_H, { name: "gantry.carriage" }, 3));
  // the pinion that runs in the rack, on the carriage's front face
  const PF = G.frameOf([0, W.CARR.y + W.CARR.d + 1.4, W.CARR_Z + 3.2], [0, 1, 0], [1, 0, 0], [0, 0, 1]);
  const pinion = [[-1.4, 1.2], [-1.0, 4.4], [1.0, 4.4], [1.4, 1.2]];
  out.push(S(G.solidOf(pinion, PF, P, { steps: 32 }), { tone: "hi", crease: "lo" }));
  out.push(Ln(G.ribsOf(PF, -0.8, 0.8, 4.4, 20, P, { least: 0.1 }), { tone: "lo" }));
  push(A.solid(PF, pinion, { name: "gantry.pinion" }));
  put("gantry.car", [W.PARK_X, W.CARR.y + W.CARR.d / 2, W.CARR_Z + W.CARR_H],
    `<g transform="${k.translateAlong(P, [W.PARK_X, 0, 0])}">${out.join("")}</g>`, shapes, { bias: 60, attrs: ` data-part="gantry"` });
}

// =========================================================================
// 11. The puzzle on the bed: the card, its pieces, the last move and the tick
// =========================================================================
const BADGE = 2.5;      // the tick or cross, in the corner of the square it marks
const BADGE_OFF = 2.9;
const badgeSvg = (file, rank, kind) => {
  const m = k.topMatrix([W.sqX(file) + BADGE_OFF, W.sqY(rank) + BADGE_OFF], PIECE_Z + 0.1, P, "x");
  const mark = kind === "tick" ? "M-1.25 0.1L-0.35 1.0L1.35 -1.1" : "M-1.1 -1.1L1.1 1.1M1.1 -1.1L-1.1 1.1";
  return `<g data-mark="${kind}" transform="${m}" style="display:none"><circle class="pb-badge-disc" r="${BADGE}"/><path class="pb-badge-mark" d="${mark}"/></g>`;
};
const squarePath = (file, rank) => {
  const x0 = W.sqX(file) - W.SQ / 2;
  const y0 = W.sqY(rank) - W.SQ / 2;
  return k.pathOf([at([x0, y0, PIECE_Z]), at([x0 + W.SQ, y0, PIECE_Z]), at([x0 + W.SQ, y0 + W.SQ, PIECE_Z]), at([x0, y0 + W.SQ, PIECE_Z])], true);
};

function work() {
  const shapes = [record(A.slab(W.CARD, W.DECK_Z, W.CARD_T, { name: "work.card" }, 4))];
  const out = [cardBody(0, W.DECK_Z, { board: true })];
  // the opponent's move, shaded as it is the moment a puzzle opens
  out.push(`<g data-part="hl">` + W.LAST_MOVE.map(([f, r]) => `<path class="iso-shade" data-shade="0" d="${squarePath(f, r)}"/>`).join("") +
    Ln(W.LAST_MOVE.map(([f, r]) => squarePath(f, r)).join(""), { tone: "lo" }) + `</g>`);
  out.push(`<g data-part="flash">` + W.SOLUTION.map(([f, r], i) =>
    `<path class="pb-flash" data-flash="${i}" d="${squarePath(f, r)}" style="display:none"/>`).join("") + `</g>`);
  // every piece but the one that moves, back to front
  const rest = W.POSITION.filter(([, f, r]) => !(f === W.SOLUTION[0][0] && r === W.SOLUTION[0][1]));
  rest.sort((a, b) => k.depthOf([W.sqX(a[1]), W.sqY(a[2]), PIECE_Z], P) - k.depthOf([W.sqX(b[1]), W.sqY(b[2]), PIECE_Z], P));
  for (const [code, f, r] of rest) {
    out.push(pieceSvg(code, W.sqX(f), W.sqY(r), PIECE_Z));
    shapes.push(record(A.solid(upAt(W.sqX(f), W.sqY(r), PIECE_Z), manProfile(code[1]), { name: `piece.${code}` })));
  }
  // the rook that mates, drawn last: nothing on the board overlaps its file
  const [sf, sr] = W.SOLUTION[0];
  out.push(`<g data-piece="lit">${pieceSvg("wR", W.sqX(sf), W.sqY(sr), PIECE_Z, { lit: true })}</g>`);
  shapes.push(record(A.solid(upAt(W.sqX(sf), W.sqY(sr), PIECE_Z), manProfile("R"), { name: "piece.lit" })));
  // the badges sit on top of whatever is under them, as they do on the device
  out.push(`<g data-part="marks">${badgeSvg(W.SOLUTION[1][0], W.SOLUTION[1][1], "tick")}${badgeSvg(W.SOLUTION[1][0], W.SOLUTION[1][1], "cross")}</g>`);
  put("work", [0, 0, W.DECK_Z + W.CARD_T], out.join(""), shapes, { bias: 0.2, attrs: ` data-part="work"` });
}

// =========================================================================
// 12. Build it
// =========================================================================
base();
magazine();
feed();
bed();
outbox();
mast();
chute();
returnChute();
dial();
controlBox();
cable();
gantryRail();
work();
gantryCar();

// the stacks: ten in the magazine, six the outbox can hold
for (let i = 0; i < W.STACK; i++) {
  const z = W.DECK_Z + i * W.CARD_T;
  const hide = i >= W.START_QUEUE ? ' style="display:none"' : "";
  put(`mag.card`, [W.MAG_X, 0, z + W.CARD_T / 2], `<g data-mag="${i}"${hide}>${cardBody(W.MAG_X, z)}</g>`,
    [record(A.slab({ ...W.CARD, x: W.MAG_X - W.CARD.w / 2 }, z, W.CARD_T, { name: "mag.card" }, 4))], { bias: 0.1 + i * 0.01 });
}
for (let i = 0; i < 6; i++) {
  const z = W.DECK_Z + i * W.CARD_T;
  put(`out.card`, [W.OUT_X, 0, z + W.CARD_T / 2], `<g data-out="${i}" style="display:none">${cardBody(W.OUT_X, z)}</g>`,
    [record(A.slab({ ...W.CARD, x: W.OUT_X - W.CARD.w / 2 }, z, W.CARD_T, { name: "out.card", owner: "out" }, 4))], { bias: 0.1 + i * 0.01 });
}
// the needle, over the dial face
put("dial.needle", [W.DIAL[0], W.DIAL[1], W.DIAL_TOP],
  `<path data-part="needle" class="iso-line" data-tone="lit" data-free="start" d="${needleAt(W.RATING)}" style="stroke-width:1.1"/>`,
  [DIAL_PUCK], { bias: 1.4 });

A.settle(R, P);
R.items.sort((a, b) => a.key - b.key);

const indexOf = (name) => R.items.findIndex((item) => item.name === name);
const lastOf = (name) => R.items.map((item, i) => (item.name === name ? i : -1)).reduce((a, b) => Math.max(a, b), -1);
const travel = (tag) => `<g data-travel="${tag}" style="display:none">${cardBody(0, W.DECK_Z)}</g>`;
const slots = new Map();
slots.set(lastOf("mag.floor"), travel("a"));
slots.set(lastOf("bed.pocket"), travel("b"));
slots.set(lastOf("out.floor"), travel("c"));

const groups = R.items.map((item, index) =>
  `<g class="it" data-name="${item.name}"${item.attrs ?? ""}>${item.svg}</g>${slots.get(index) ?? ""}`);

const LABEL =
  "A bench machine that stands for the Kobo puzzle plugin. On the left a magazine holds a batch of ten puzzle cards, fed in down a chute from a mast whose lamp lights while lichess is being reached. A roller shaft draws one card at a time onto the bed in the middle, where an eight by eight board is printed on its face and turned pieces stand on it. A print head on a gantry at the front travels on a rail and runs a quill out over the board to re-ink only the squares that changed, stamping a tick when the move is right. The finished card slides into the outbox on the right, and a dial on a column reads the puzzle rating, with a bezel lock that a hint screws down so the needle cannot move.";

const svg = k.figureSvg({ width: WIDTH, height: HEIGHT, label: LABEL, body: groups.join("") });

const DATA = {
  P, V,
  deck: W.DECK_Z, cardT: W.CARD_T, stack: W.STACK, low: W.LOW_WATER, queue: W.START_QUEUE, parkX: W.PARK_X,
  magX: W.MAG_X, outX: W.OUT_X, bedX: 0,
  sq: { size: W.SQ, origin: W.BOARD0, badge: BADGE_OFF },
  solution: W.SOLUTION, lastMove: W.LAST_MOVE, rating: W.RATING, gain: W.GAIN,
  perTurn: PER_TURN,
  dial: W.DIAL, dialTop: W.DIAL_TOP, dialR: W.DIAL_R,
  head: { park: W.HEAD_PARK, back: W.HEAD_BACK, front: W.HEAD_FRONT, face: W.QUILL_FACE, z: W.QUILL_Z, h: W.QUILL_H, w: W.QUILL_W, dy: W.NOZZLE_DY },
  reach: W.GRAIL_REACH,
  gate: { u: CH_U, v: CH_V },
};

const CSS = readFileSync(join(HERE, "puzzle-bench.css"), "utf8");
const LIVE = readFileSync(join(HERE, "live.js"), "utf8").replace("__DATA__", JSON.stringify(DATA));

const body = `<style>${CSS}</style>` + k.plateHtml({
  fig: "Fig 1",
  title: "Lichess puzzles on a Kobo",
  hint: "H for a hint · click to step",
  readout: `queue ${W.START_QUEUE} · pending 0 · ${W.RATING}`,
  keys: [
    { mark: "lit", label: "The move you play, and the head that inks the squares it changed" },
    { mark: "raised", label: "A card's run: magazine, bed, outbox, and back to lichess" },
    { mark: "edge", label: "The bezel lock a hint screws down, so the rating cannot move" },
  ],
  caption:
    "A KOReader plugin that solves lichess puzzles on an e-reader. Puzzles arrive ten at a time from /api/puzzle/batch and wait in a queue that is written to disk, so it survives being switched off; when fewer than two are left the next report asks for ten more in the same request. One puzzle at a time goes to the board, which is drawn once and then re-inked a square at a time, because a full e-ink repaint is slow and leaves ghosting. A right move gets a tick, a wrong one a cross, and any mate is accepted, not just the listed one. The finished result joins a pending list and goes back to lichess as a solved round, which is what moves the puzzle rating. Take a hint and the attempt is reported casual instead: it is never served again, but the rating cannot move in either direction.",
  body: `<div class="iso-stage pb-stage" tabindex="0" role="group" aria-label="Puzzle bench. Press H to take a hint; click or press space to step the machine.">${svg}<span class="pb-sr" role="status" aria-live="polite" data-status></span></div>`,
});

// --embed writes a fragment to paste into a page of your own: one themed
// wrapper, the styles it needs, the figure, and the script that moves it.
let page, name;
if (EMBED) {
  page = `<div class="iso" data-theme="light" data-follow="1">\n<style>${k.ISO_CSS}${CSS}</style>\n${body.replace(`<style>${CSS}</style>`, "")}\n</div>\n<script type="module">\n${(kitScript() + LIVE).replace(/<\/(script)/gi, "<\\/$1")}\n</script>\n`;
  name = "puzzle-bench.embed.html";
} else {
  page = k.pageHtml({ title: "Lichess puzzles on a Kobo", theme: THEME, body, script: kitScript() + LIVE, width: 700 });
  // --auto: one file that follows whatever colour scheme the reader is in
  if (AUTO) page = page.replace('data-theme="light"', 'data-theme="light" data-follow="1"');
  name = AUTO ? "puzzle-bench-auto.html" : THEME === "light" ? "puzzle-bench-light.html" : "puzzle-bench.html";
}
writeFileSync(join(HERE, name), page);
console.log("wrote", name, `${(page.length / 1024).toFixed(0)} KB`, `${R.items.length} items`, `scale ${KS.toFixed(3)}`);

A.auditOrExit(R, P, { crowd: [["clip.collar", "cable.head"]] });
