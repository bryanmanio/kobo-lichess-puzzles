// The bench runs the plugin's own loop: solve, ink the squares that changed,
// eject, report to lichess, refill when the queue runs low.
const D = __DATA__;
const P = D.P;
const stage = document.querySelector(".pb-stage");
const svg = stage.querySelector("svg");
const root = stage.closest(".iso") ?? document.body;
const readout = root.querySelector("[data-readout]");
const status = stage.querySelector("[data-status]");
const q = (sel) => svg.querySelector(sel);
const all = (sel) => Array.from(svg.querySelectorAll(sel));
const still = matchMedia("(prefers-reduced-motion: reduce)");

const work = q('[data-part="work"]');
const lit = q('[data-piece="lit"]');
const gantry = q('[data-part="gantry"]');
const head = q('[data-part="head"]');
const quill = q('[data-part="quill"]');
const needle = q('[data-part="needle"]');
const gate = q('[data-part="gate"]');
const pin = q('[data-part="pin"]');
const tick = q('[data-mark="tick"]');
const highlight = q('[data-part="hl"]');
const flashes = all("[data-flash]");
const lamps = { link: all('[data-lamp="link"]'), low: all('[data-lamp="low"]') };
const magCards = all("[data-mag]").sort((a, b) => +a.dataset.mag - +b.dataset.mag);
const outCards = all("[data-out]").sort((a, b) => +a.dataset.out - +b.dataset.out);
const travels = { a: q('[data-travel="a"]'), b: q('[data-travel="b"]'), c: q('[data-travel="c"]') };

const sqX = (file) => D.sq.origin + D.sq.size * file + D.sq.size / 2;
const sqY = (rank) => -D.sq.origin - D.sq.size * rank - D.sq.size / 2;
// the head prints the corner of the square, where the badge goes
const printX = (file) => sqX(file) + D.sq.badge;
const headY = (rank) => sqY(rank) + D.sq.badge - D.head.dy;
const show = (node, on) => { if (node) node.style.display = on ? "" : "none"; };
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

// ---- the state the machine is in ----------------------------------------
const S = {
  queue: D.queue, pending: 0, rating: D.rating, hinted: false,
  move: 0,          // 0..1 along the solution move
  gx: D.parkX, hy: D.head.park,
  nozzle: 0,        // how far the tip has dipped
  gateLift: 0, lock: 0,
  card: null,       // the x of a card while it is travelling
  from: 0, outCount: 0, boardOn: true, tickOn: false, hlOn: true, flash: [0, 0],
  link: false, low: false,
  label: "", phase: "",
};

const needleAt = (rating) => {
  const turn = (((rating % D.perTurn) + D.perTurn) % D.perTurn) / D.perTurn;
  const a = turn * Math.PI * 2;
  const [dx, dy] = D.dial;
  return lineOnTop(
    [dx - Math.sin(a) * 3.2, dy + Math.cos(a) * 3.2],
    [dx + Math.sin(a) * (D.dialR - 4), dy - Math.cos(a) * (D.dialR - 4)],
    D.dialTop + 0.2, P);
};

const quillAt = (hy) => {
  const y0 = hy + D.head.front;
  const plan = { x: -D.head.w / 2, y: y0, w: D.head.w, d: Math.max(0.6, D.head.face - y0), r: 0.8 };
  return solidSvg(slabOf(plan, D.head.z, D.head.h, P, 2, 0.4), { tone: "mid", crease: "lo" }) +
    lineSvg([-3.2, 3.2].map((ox) => lineOnTop([ox, plan.y], [ox, plan.y + plan.d], D.head.z + D.head.h, P)).join(""), { tone: "faint" });
};

let drawn = {};
function draw() {
  const [fromF, fromR] = D.solution[0];
  const [toF, toR] = D.solution[1];
  const mx = (sqX(toF) - sqX(fromF)) * S.move;
  const my = (sqY(toR) - sqY(fromR)) * S.move;
  const lift = Math.sin(Math.PI * clamp(S.move * 1.0, 0, 1)) * 3.2;
  lit.setAttribute("transform", translateAlong(P, [mx, my, lift]));
  gantry.setAttribute("transform", translateAlong(P, [S.gx - D.parkX, 0, 0]));
  head.setAttribute("transform", translateAlong(P, [0, S.hy - D.head.park, -S.nozzle]));
  const key = Math.round(S.hy * 4);
  if (drawn.quill !== key) { quill.innerHTML = quillAt(S.hy); drawn.quill = key; }
  const rate = Math.round(S.rating * 10) / 10;
  if (drawn.needle !== rate) { needle.setAttribute("d", needleAt(rate)); drawn.needle = rate; }
  gate.setAttribute("transform", translateAlong(P, [D.gate.v[0] * S.gateLift, D.gate.v[1] * S.gateLift, D.gate.v[2] * S.gateLift]));
  pin.setAttribute("transform", translateAlong(P, [-2.2 * S.lock, 0, 0]));

  show(work, S.boardOn);
  show(tick, S.tickOn);
  show(highlight, S.hlOn);
  flashes.forEach((node, i) => { node.style.display = S.flash[i] > 0.02 ? "" : "none"; node.style.opacity = String(0.6 * S.flash[i]); });
  magCards.forEach((node, i) => show(node, i < S.queue));
  outCards.forEach((node, i) => show(node, i < S.outCount));
  for (const name of ["a", "b", "c"]) {
    const node = travels[name];
    const on = S.card !== null && slotOf(S.card) === name;
    show(node, on);
    if (on) node.setAttribute("transform", translateAlong(P, [S.card, 0, 0]));
  }
  for (const [name, nodes] of Object.entries(lamps)) {
    for (const node of nodes) { if (S[name]) node.setAttribute("data-on", ""); else node.removeAttribute("data-on"); }
  }
  const text = `queue ${S.queue} · pending ${S.pending} · ${S.label || Math.round(S.rating)}`;
  if (readout.textContent !== text) readout.textContent = text;
  if (status && status.textContent !== S.phase) status.textContent = S.phase;
}
const slotOf = (x) => (x < -72 ? "a" : x < 26 ? "b" : "c");

// ---- the loop, written as a list of steps -------------------------------
const say = (phase, label) => { S.phase = phase; if (label !== undefined) S.label = label; };
const steps = [];
const step = (seconds, run, enter) => steps.push({ seconds, run, enter });

step(1.1, null, () => { say("White to play", ""); });
// the solver's move: the rook lifts, slides and lands
step(1.5, (t) => { S.move = ease(t); }, () => say("Re1-e8", ""));
step(0.5, null, () => { S.move = 1; S.hlOn = false; });
// the head goes to the square that changed, and inks it
step(1.2, (t) => {
  S.gx = lerp(D.parkX, printX(D.solution[1][0]), ease(t));
  S.hy = lerp(D.head.park, headY(D.solution[1][1]), ease(t));
}, () => say("Inking e8", ""));
step(0.5, (t) => { S.nozzle = dip(t); S.flash[1] = dip(t); if (t > 0.45) S.tickOn = true; });
// then the square it came from
step(0.9, (t) => { S.hy = lerp(headY(D.solution[1][1]), headY(D.solution[0][1]), ease(t)); }, () => say("Inking e1", ""));
step(0.5, (t) => { S.nozzle = dip(t); S.flash[0] = dip(t); });
step(0.7, (t) => {
  S.gx = lerp(printX(D.solution[1][0]), D.parkX, ease(t));
  S.hy = lerp(headY(D.solution[0][1]), D.head.park, ease(t));
}, () => { S.flash = [0, 0]; say(S.hinted ? "Solved, casual" : "Solved", ""); });
// the card leaves for the outbox, and the result joins the pending list
step(1.3, (t) => { S.card = lerp(D.bedX, D.outX, ease(t)); }, () => {
  S.boardOn = false; S.tickOn = false; S.pending = 1; S.card = D.bedX;
  say("Result queued", "");
});
step(0.1, null, () => { S.card = null; S.outCount = Math.min(outCards.length, S.outCount + 1); });
// POST /api/puzzle/batch: the rating moves unless a hint made it casual
step(1.4, (t) => { if (!S.hinted) S.rating = D.rating + D.gain * ease(t); }, () => {
  S.link = true;
  say(S.hinted ? "Reported casual" : "Reported won", S.hinted ? "casual" : "");
});
step(0.6, null, () => {
  S.pending = 0;
  if (!S.hinted) { D.rating += D.gain; S.label = `${D.rating} (+${D.gain})`; }
  S.hinted = false; S.lock = 0;
});
// when fewer than two are left the same request asks for ten more
step(0.4, null, () => { S.low = S.queue - 1 < D.low; S.label = ""; });
step(1.0, (t) => { if (S.low) S.gateLift = 7.6 * ease(t); }, () => { if (S.low) { S.from = S.queue; say("Fetching ten", ""); } });
step(1.2, (t) => { if (S.low) S.queue = Math.round(lerp(S.from, D.stack, ease(t))); }, null);
step(0.8, (t) => { S.gateLift = 7.6 * (1 - ease(t)); }, () => { if (S.low) S.outCount = 0; });
step(0.3, null, () => { S.low = false; S.link = false; });
// one card is drawn out of the magazine and onto the bed
step(1.5, (t) => { S.card = lerp(D.magX, D.bedX, ease(t)); }, () => {
  if (!S.low) S.queue = Math.max(0, S.queue - 1);
  S.card = D.magX; say("Next puzzle", "");
});
step(0.2, null, () => { S.card = null; S.boardOn = true; S.move = 0; S.hlOn = true; });

function lerp(a, b, t) { return a + (b - a) * t; }
function dip(t) { return Math.sin(Math.PI * clamp(t, 0, 1)); }

// ---- running it ----------------------------------------------------------
let index = 0, elapsed = 0, frame = 0, last = 0, visible = false, entered = false;
function enter() {
  if (entered) return;
  entered = true;
  const s = steps[index];
  if (s.enter) s.enter();
}
function tick2(now) {
  const dt = last ? Math.min((now - last) / 1000, 1 / 20) : 1 / 60;
  last = now;
  enter();
  const s = steps[index];
  elapsed += dt;
  const t = clamp(elapsed / s.seconds, 0, 1);
  if (s.run) s.run(t);
  if (elapsed >= s.seconds) { index = (index + 1) % steps.length; elapsed = 0; entered = false; }
  draw();
  frame = visible ? requestAnimationFrame(tick2) : 0;
}
const run = () => { if (!frame && visible && !still.matches) { last = 0; frame = requestAnimationFrame(tick2); } };
new IntersectionObserver((entries) => {
  visible = entries[entries.length - 1].isIntersecting;
  if (visible) run();
}, { rootMargin: "140px 0px" }).observe(stage);

function takeHint() {
  if (S.hinted || index > 3) return;
  S.hinted = true;
  S.lock = 1;
  say("Hint taken: casual", "casual");
  draw();
}
function stepOn() {
  elapsed = steps[index].seconds;
  if (!frame) { enter(); draw(); }
}
stage.addEventListener("keydown", (event) => {
  if (event.key === "h" || event.key === "H") { event.preventDefault(); takeHint(); }
  if (event.key === " " || event.key === "Enter") { event.preventDefault(); stepOn(); }
});
stage.addEventListener("click", stepOn);
draw();

// Where the figure is told to follow the reader, track the colour scheme.
if (root.dataset.follow === "1") {
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const apply = () => root.setAttribute("data-theme", dark.matches ? "dark" : "light");
  dark.addEventListener("change", apply);
  apply();
}
