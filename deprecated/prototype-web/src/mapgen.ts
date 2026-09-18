/**
 * Deterministic procedural hospital map generator.
 *
 * Produces the same kind of ASCII rows as the hand-authored LAYOUT in ./map.ts.
 * No imports, no Math.random, erasable-TypeScript only (so `node` can run it directly).
 *
 * Legend:
 *   #  wall                 .  floor            +  door (walkable)
 *   b  bed (solid)          c  cabinet (solid)  O  operating table (2 tiles, solid)
 *   K  time clock (solid)   C  cloning pod (solid)
 *   P  player spawn (x4)    T  tool spawn candidate     M  monster spawn candidate
 * Walkable: . + P T M. Everything else is solid. Only # blocks line of sight.
 */

export interface GenRoom {
  x: number;
  y: number;
  w: number;
  h: number;
  kind: 'ward' | 'storage' | 'office' | 'empty' | 'or' | 'anteroom' | 'clockin';
}

export interface GeneratedMap {
  seed: number;
  rows: string[];
  lights: { x: number; y: number }[];
  rooms: GenRoom[];
}

export type RoomKind = GenRoom['kind'];

export const DEFAULT_WIDTH = 56;
export const DEFAULT_HEIGHT = 40;
/** Smallest size that still yields a valid map (enough room strips around the central block for 16 tool spawns). */
export const MIN_WIDTH = 48;
export const MIN_HEIGHT = 36;

export const BLOCK_W = 30;
export const BLOCK_H = 19;
/** Central block: OR + two anterooms + clock-in room + 2-wide inner ring. Stamped verbatim, centered. */
export const BLOCK_TEMPLATE: readonly string[] = [
  '##############################',
  '#............................#',
  '#............................#',
  '#..########################..#',
  '#..#.....#..........#.....#..#',
  '#..#cc...#c........c#...cc#..#',
  '#..+.....+..........+.....+..#',
  '#..+.....+....OO....+.....+..#',
  '#..#.....#..........#.....#..#',
  '#..#.....#..........#.....#..#',
  '#..###########++###########..#',
  '#..#ccc...C.........K..ccc#..#',
  '#..#..P....P......P....P..#..#',
  '#..#......................#..#',
  '#..#ccc................ccc#..#',
  '#..###########++###########..#',
  '#............................#',
  '#............................#',
  '##############################',
];

const WALKABLE_CHARS = '.+PTM';
const LEGEND_CHARS = '#.+bcOKCPTM';
const MIN_TOOLS = 16;
const MIN_MONSTERS = 6;
const WANT_MONSTERS = 8;
const MONSTER_MIN_DIST = 18;

export function isWalkableChar(c: string): boolean {
  return WALKABLE_CHARS.includes(c);
}

// ---------------------------------------------------------------------------
// PRNG
// ---------------------------------------------------------------------------

/** mulberry32: tiny deterministic 32-bit PRNG. Returns floats in [0, 1). */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

class Rng {
  private readonly next: () => number;
  constructor(seed: number) {
    this.next = mulberry32(seed);
  }
  float(): number {
    return this.next();
  }
  /** Integer in [lo, hi], inclusive. */
  int(lo: number, hi: number): number {
    return lo + Math.floor(this.next() * (hi - lo + 1));
  }
  chance(p: number): boolean {
    return this.next() < p;
  }
  pick<T>(arr: readonly T[]): T {
    return arr[Math.floor(this.next() * arr.length)];
  }
  shuffle<T>(arr: T[]): T[] {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = Math.floor(this.next() * (i + 1));
      const tmp = arr[i];
      arr[i] = arr[j];
      arr[j] = tmp;
    }
    return arr;
  }
}

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

interface Pt {
  x: number;
  y: number;
}

const DIRS: readonly (readonly [number, number])[] = [[0, -1], [0, 1], [-1, 0], [1, 0]];

class Grid {
  readonly w: number;
  readonly h: number;
  /** Row-major tile characters. */
  readonly cells: string[];
  /** 1 = corridor tile (rings, spokes, secondary corridors). */
  readonly corridor: Uint8Array;
  /** 1 = part of the stamped central block; never re-carved except by the spokes. */
  readonly locked: Uint8Array;

  constructor(w: number, h: number) {
    this.w = w;
    this.h = h;
    this.cells = new Array<string>(w * h).fill('#');
    this.corridor = new Uint8Array(w * h);
    this.locked = new Uint8Array(w * h);
  }
  inBounds(x: number, y: number): boolean {
    return x >= 0 && y >= 0 && x < this.w && y < this.h;
  }
  get(x: number, y: number): string {
    return this.inBounds(x, y) ? this.cells[y * this.w + x] : '#';
  }
  set(x: number, y: number, c: string): void {
    if (this.inBounds(x, y)) this.cells[y * this.w + x] = c;
  }
  isCorridor(x: number, y: number): boolean {
    return this.inBounds(x, y) && this.corridor[y * this.w + x] === 1;
  }
  isCorridorFloor(x: number, y: number): boolean {
    return this.isCorridor(x, y) && this.get(x, y) === '.';
  }
  markCorridor(x: number, y: number): void {
    if (this.inBounds(x, y)) this.corridor[y * this.w + x] = 1;
  }
  /** Set floor and mark as corridor. */
  carve(x: number, y: number): void {
    this.set(x, y, '.');
    this.markCorridor(x, y);
  }
  isLocked(x: number, y: number): boolean {
    return this.inBounds(x, y) && this.locked[y * this.w + x] === 1;
  }
  lock(x: number, y: number): void {
    if (this.inBounds(x, y)) this.locked[y * this.w + x] = 1;
  }
  walkable(x: number, y: number): boolean {
    return isWalkableChar(this.get(x, y));
  }
  find(ch: string): Pt[] {
    const out: Pt[] = [];
    for (let i = 0; i < this.cells.length; i++) {
      if (this.cells[i] === ch) out.push({ x: i % this.w, y: Math.floor(i / this.w) });
    }
    return out;
  }
  rows(): string[] {
    const out: string[] = [];
    for (let y = 0; y < this.h; y++) out.push(this.cells.slice(y * this.w, (y + 1) * this.w).join(''));
    return out;
  }
}

/** BFS over walkable tiles (4-connected). Returns a reached mask. */
function flood(g: Grid, starts: number[]): Uint8Array {
  const reached = new Uint8Array(g.w * g.h);
  const queue: number[] = [];
  for (const s of starts) {
    if (!reached[s] && isWalkableChar(g.cells[s])) {
      reached[s] = 1;
      queue.push(s);
    }
  }
  for (let qi = 0; qi < queue.length; qi++) {
    const i = queue[qi];
    const x = i % g.w;
    const y = (i - x) / g.w;
    for (const [dx, dy] of DIRS) {
      const nx = x + dx;
      const ny = y + dy;
      if (!g.inBounds(nx, ny)) continue;
      const ni = ny * g.w + nx;
      if (reached[ni] || !isWalkableChar(g.cells[ni])) continue;
      reached[ni] = 1;
      queue.push(ni);
    }
  }
  return reached;
}

/** True when there is a door in the 8-neighbourhood of (x, y). */
function doorNear(g: Grid, x: number, y: number): boolean {
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -1; dx <= 1; dx++) {
      if ((dx !== 0 || dy !== 0) && g.get(x + dx, y + dy) === '+') return true;
    }
  }
  return false;
}

function inRoom(r: GenRoom, x: number, y: number): boolean {
  return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
}

function isGeneratedKind(k: RoomKind): boolean {
  return k === 'ward' || k === 'storage' || k === 'office' || k === 'empty';
}

// ---------------------------------------------------------------------------
// Layout: central block, rings, spokes, regions
// ---------------------------------------------------------------------------

interface Sides {
  n: boolean;
  s: boolean;
  e: boolean;
  w: boolean;
}

/**
 * A rectangle of buildable space (inclusive bounds, includes its own boundary walls).
 * `wall.<side>` = this region must keep its outermost line solid on that side.
 * `open.<side>` = the tile just beyond that edge is a corridor (doors / secondary corridors can connect).
 */
interface Region {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  wall: Sides;
  open: Sides;
}

/** A straight 2-wide corridor (lanes `lane` and `lane + 1`, running from a..b). Used for lights. */
interface Segment {
  horizontal: boolean;
  lane: number;
  a: number;
  b: number;
}

function stampBlock(g: Grid, bx: number, by: number, rooms: GenRoom[], segs: Segment[]): void {
  if (BLOCK_TEMPLATE.length !== BLOCK_H) throw new Error(`Block template has ${BLOCK_TEMPLATE.length} rows, expected ${BLOCK_H}`);
  for (let ty = 0; ty < BLOCK_H; ty++) {
    const row = BLOCK_TEMPLATE[ty];
    if (row.length !== BLOCK_W) throw new Error(`Block template row ${ty} has length ${row.length}, expected ${BLOCK_W}`);
    for (let tx = 0; tx < BLOCK_W; tx++) {
      g.set(bx + tx, by + ty, row[tx]);
      g.lock(bx + tx, by + ty);
    }
  }
  // Inner ring corridor: template rows 1-2 / 16-17 and cols 1-2 / 27-28.
  for (let ty = 1; ty <= 17; ty++) {
    for (let tx = 1; tx <= 28; tx++) {
      if (ty <= 2 || ty >= 16 || tx <= 2 || tx >= 27) g.markCorridor(bx + tx, by + ty);
    }
  }
  segs.push(
    { horizontal: true, lane: by + 1, a: bx + 1, b: bx + 28 },
    { horizontal: true, lane: by + 16, a: bx + 1, b: bx + 28 },
    { horizontal: false, lane: bx + 1, a: by + 3, b: by + 15 },
    { horizontal: false, lane: bx + 27, a: by + 3, b: by + 15 },
  );
  rooms.push(
    { x: bx + 10, y: by + 4, w: 10, h: 6, kind: 'or' },
    { x: bx + 4, y: by + 4, w: 5, h: 6, kind: 'anteroom' },
    { x: bx + 21, y: by + 4, w: 5, h: 6, kind: 'anteroom' },
    { x: bx + 4, y: by + 11, w: 22, h: 4, kind: 'clockin' },
  );
}

/** 2-wide ring inset by one tile from the map edge. */
function carveOuterRing(g: Grid, segs: Segment[]): void {
  const { w, h } = g;
  for (let x = 1; x <= w - 2; x++) {
    for (const y of [1, 2, h - 3, h - 2]) g.carve(x, y);
  }
  for (let y = 1; y <= h - 2; y++) {
    for (const x of [1, 2, w - 3, w - 2]) g.carve(x, y);
  }
  segs.push(
    { horizontal: true, lane: 1, a: 1, b: w - 2 },
    { horizontal: true, lane: h - 3, a: 1, b: w - 2 },
    { horizontal: false, lane: 1, a: 3, b: h - 4 },
    { horizontal: false, lane: w - 3, a: 3, b: h - 4 },
  );
}

/** Four 2-wide spokes from the middle of each block side out to the outer ring, cutting the block's outer wall. */
function carveSpokes(g: Grid, bx: number, by: number, segs: Segment[]): void {
  const { w, h } = g;
  const sx = bx + 14; // north/south spoke columns sx, sx + 1
  const sy = by + 9; // east/west spoke rows sy, sy + 1
  for (let y = 3; y <= by; y++) {
    g.carve(sx, y);
    g.carve(sx + 1, y);
  }
  for (let y = by + BLOCK_H - 1; y <= h - 4; y++) {
    g.carve(sx, y);
    g.carve(sx + 1, y);
  }
  for (let x = 3; x <= bx; x++) {
    g.carve(x, sy);
    g.carve(x, sy + 1);
  }
  for (let x = bx + BLOCK_W - 1; x <= w - 4; x++) {
    g.carve(x, sy);
    g.carve(x, sy + 1);
  }
  segs.push(
    { horizontal: false, lane: sx, a: 3, b: by },
    { horizontal: false, lane: sx, a: by + BLOCK_H - 1, b: h - 4 },
    { horizontal: true, lane: sy, a: 3, b: bx },
    { horizontal: true, lane: sy, a: bx + BLOCK_W - 1, b: w - 4 },
  );
}

/**
 * The four quadrants are L-shaped; each is split into a horizontal arm (above/below the block,
 * between the outer ring and the spoke) and a vertical arm (beside the block, between the outer
 * ring and the spoke). The vertical arm owns the wall line that separates it from the horizontal arm.
 */
function buildArms(g: Grid, bx: number, by: number): Region[] {
  const { w, h } = g;
  const sx0 = bx + 14;
  const sx1 = bx + 15;
  const sy0 = by + 9;
  const sy1 = by + 10;
  const bxe = bx + BLOCK_W - 1;
  const bye = by + BLOCK_H - 1;
  const T = true;
  const F = false;
  return [
    // top-left
    { x0: 3, y0: 3, x1: sx0 - 1, y1: by - 1, wall: { n: T, s: F, e: T, w: T }, open: { n: T, s: F, e: T, w: T } },
    { x0: 3, y0: by, x1: bx - 1, y1: sy0 - 1, wall: { n: T, s: T, e: F, w: T }, open: { n: F, s: T, e: F, w: T } },
    // top-right
    { x0: sx1 + 1, y0: 3, x1: w - 4, y1: by - 1, wall: { n: T, s: F, e: T, w: T }, open: { n: T, s: F, e: T, w: T } },
    { x0: bxe + 1, y0: by, x1: w - 4, y1: sy0 - 1, wall: { n: T, s: T, e: T, w: F }, open: { n: F, s: T, e: T, w: F } },
    // bottom-left
    { x0: 3, y0: sy1 + 1, x1: bx - 1, y1: bye, wall: { n: T, s: T, e: F, w: T }, open: { n: T, s: F, e: F, w: T } },
    { x0: 3, y0: bye + 1, x1: sx0 - 1, y1: h - 4, wall: { n: F, s: T, e: T, w: T }, open: { n: F, s: T, e: T, w: T } },
    // bottom-right
    { x0: bxe + 1, y0: sy1 + 1, x1: w - 4, y1: bye, wall: { n: T, s: T, e: T, w: F }, open: { n: T, s: F, e: T, w: F } },
    { x0: sx1 + 1, y0: bye + 1, x1: w - 4, y1: h - 4, wall: { n: F, s: T, e: T, w: T }, open: { n: F, s: T, e: T, w: T } },
  ];
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

/** Recursively split regions that are > 13 in both dimensions with a 2-wide secondary corridor. */
function splitRegion(g: Grid, r: Region, rng: Rng, segs: Segment[], out: Region[]): void {
  const rw = r.x1 - r.x0 + 1;
  const rh = r.y1 - r.y0 + 1;
  if (rw <= 13 || rh <= 13) {
    out.push(r);
    return;
  }
  const canV = r.open.n || r.open.s; // a vertical corridor would connect at its top/bottom
  const canH = r.open.w || r.open.e;
  let vertical: boolean;
  if (canV && canH) vertical = rng.chance(0.5);
  else if (canV) vertical = true;
  else if (canH) vertical = false;
  else vertical = rng.chance(0.5);

  if (vertical) {
    const cx = clamp(r.x0 + Math.floor((rw - 2) / 2) + rng.int(-2, 2), r.x0 + 6, r.x1 - 7);
    // Run to the edge where a corridor is waiting; stop one short where another region's rooms are.
    const top = r.open.n || !r.wall.n ? r.y0 : r.y0 + 1;
    const bot = r.open.s || !r.wall.s ? r.y1 : r.y1 - 1;
    for (let y = top; y <= bot; y++) {
      g.carve(cx, y);
      g.carve(cx + 1, y);
    }
    segs.push({ horizontal: false, lane: cx, a: top, b: bot });
    splitRegion(g, { x0: r.x0, y0: r.y0, x1: cx - 1, y1: r.y1, wall: { ...r.wall, e: true }, open: { ...r.open, e: true } }, rng, segs, out);
    splitRegion(g, { x0: cx + 2, y0: r.y0, x1: r.x1, y1: r.y1, wall: { ...r.wall, w: true }, open: { ...r.open, w: true } }, rng, segs, out);
  } else {
    const cy = clamp(r.y0 + Math.floor((rh - 2) / 2) + rng.int(-2, 2), r.y0 + 6, r.y1 - 7);
    const left = r.open.w || !r.wall.w ? r.x0 : r.x0 + 1;
    const right = r.open.e || !r.wall.e ? r.x1 : r.x1 - 1;
    for (let x = left; x <= right; x++) {
      g.carve(x, cy);
      g.carve(x, cy + 1);
    }
    segs.push({ horizontal: true, lane: cy, a: left, b: right });
    splitRegion(g, { x0: r.x0, y0: r.y0, x1: r.x1, y1: cy - 1, wall: { ...r.wall, s: true }, open: { ...r.open, s: true } }, rng, segs, out);
    splitRegion(g, { x0: r.x0, y0: cy + 2, x1: r.x1, y1: r.y1, wall: { ...r.wall, n: true }, open: { ...r.open, n: true } }, rng, segs, out);
  }
}

// ---------------------------------------------------------------------------
// Rooms
// ---------------------------------------------------------------------------

/** Split a run of `total` interior tiles into room widths of 4-9 separated by 1-tile walls. */
function partition(total: number, rng: Rng): number[] {
  const out: number[] = [];
  let rem = total;
  while (rem >= 4) {
    if (rem < 9 || (rem === 9 && rng.chance(0.5))) {
      out.push(rem);
      break;
    }
    const len = rng.int(4, Math.min(9, rem - 5)); // keep >= 4 + wall for the remainder
    out.push(len);
    rem -= len + 1;
  }
  return out;
}

/** Carve room interiors inside every leaf region. Kinds are assigned later by furnish(). */
function carveRooms(g: Grid, leaves: Region[], rng: Rng, rooms: GenRoom[]): void {
  for (const r of leaves) {
    const ix0 = r.x0 + (r.wall.w ? 1 : 0);
    const ix1 = r.x1 - (r.wall.e ? 1 : 0);
    const iy0 = r.y0 + (r.wall.n ? 1 : 0);
    const iy1 = r.y1 - (r.wall.s ? 1 : 0);
    const iw = ix1 - ix0 + 1;
    const ih = iy1 - iy0 + 1;
    if (iw < 4 || ih < 4) continue; // sliver: stays solid wall
    const alongX = iw >= ih;
    const depth = alongX ? ih : iw;
    const length = alongX ? iw : ih;
    // Two rows of rooms back to back only when both the front and the back face a corridor.
    const twoRows = depth > 8 && (alongX ? r.open.n && r.open.s : r.open.w && r.open.e);
    const strips: [number, number][] = [];
    if (twoRows) {
      const d1 = Math.floor((depth - 1) / 2);
      strips.push([0, d1], [d1 + 1, depth - 1 - d1]);
    } else {
      strips.push([0, depth]);
    }
    for (const [off, d] of strips) {
      let pos = 0;
      for (const len of partition(length, rng)) {
        const room: GenRoom = alongX
          ? { x: ix0 + pos, y: iy0 + off, w: len, h: d, kind: 'empty' }
          : { x: ix0 + off, y: iy0 + pos, w: d, h: len, kind: 'empty' };
        for (let y = room.y; y < room.y + room.h; y++) {
          for (let x = room.x; x < room.x + room.w; x++) g.set(x, y, '.');
        }
        rooms.push(room);
        pos += len + 1;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Doors
// ---------------------------------------------------------------------------

interface DoorSpot {
  x: number;
  y: number;
  /** Interior tile just inside the door. */
  ix: number;
  iy: number;
}

/** Visit every wall tile on the room's perimeter with the direction pointing out of the room. */
function forEachPerimeter(r: GenRoom, fn: (wx: number, wy: number, dx: number, dy: number) => void): void {
  for (let x = r.x; x < r.x + r.w; x++) {
    fn(x, r.y - 1, 0, -1);
    fn(x, r.y + r.h, 0, 1);
  }
  for (let y = r.y; y < r.y + r.h; y++) {
    fn(r.x - 1, y, -1, 0);
    fn(r.x + r.w, y, 1, 0);
  }
}

/** Candidate door tiles: unlocked wall with room floor inside and corridor floor directly outside. */
function doorSpots(g: Grid, r: GenRoom): DoorSpot[] {
  const out: DoorSpot[] = [];
  forEachPerimeter(r, (wx, wy, dx, dy) => {
    if (g.get(wx, wy) !== '#' || g.isLocked(wx, wy)) return;
    if (!g.isCorridorFloor(wx + dx, wy + dy)) return;
    if (g.get(wx - dx, wy - dy) !== '.') return;
    out.push({ x: wx, y: wy, ix: wx - dx, iy: wy - dy });
  });
  return out;
}

/** Existing doors on the room's perimeter. */
function roomDoors(g: Grid, r: GenRoom): DoorSpot[] {
  const out: DoorSpot[] = [];
  forEachPerimeter(r, (wx, wy, dx, dy) => {
    if (g.get(wx, wy) === '+') out.push({ x: wx, y: wy, ix: wx - dx, iy: wy - dy });
  });
  return out;
}

function placeDoors(g: Grid, rooms: GenRoom[], rng: Rng): void {
  for (const r of rooms) {
    let spots = doorSpots(g, r).filter((s) => !doorNear(g, s.x, s.y));
    if (!spots.length) continue;
    const first = rng.pick(spots);
    g.set(first.x, first.y, '+');
    if (!rng.chance(0.45)) continue;
    spots = spots.filter((s) => !doorNear(g, s.x, s.y));
    // Prefer a different wall for the second door; on the same wall keep them well apart.
    const sameWall = (s: DoorSpot) => s.x - s.ix === first.x - first.ix && s.y - s.iy === first.y - first.iy;
    const other = spots.filter((s) => !sameWall(s));
    const pool = other.length ? other : spots.filter((s) => Math.abs(s.x - first.x) + Math.abs(s.y - first.y) >= 3);
    if (pool.length) {
      const d = rng.pick(pool);
      g.set(d.x, d.y, '+');
    }
  }
}

// ---------------------------------------------------------------------------
// Furniture
// ---------------------------------------------------------------------------

/** True when all walkable tiles inside the room form a single 4-connected component. */
function interiorConnected(g: Grid, r: GenRoom): boolean {
  let total = 0;
  let start = -1;
  for (let y = r.y; y < r.y + r.h; y++) {
    for (let x = r.x; x < r.x + r.w; x++) {
      if (g.walkable(x, y)) {
        total++;
        if (start < 0) start = y * g.w + x;
      }
    }
  }
  if (total === 0) return true;
  const reached = new Uint8Array(g.w * g.h);
  const queue = [start];
  reached[start] = 1;
  let count = 0;
  for (let qi = 0; qi < queue.length; qi++) {
    const i = queue[qi];
    count++;
    const x = i % g.w;
    const y = (i - x) / g.w;
    for (const [dx, dy] of DIRS) {
      const nx = x + dx;
      const ny = y + dy;
      if (!inRoom(r, nx, ny) || !g.walkable(nx, ny)) continue;
      const ni = ny * g.w + nx;
      if (reached[ni]) continue;
      reached[ni] = 1;
      queue.push(ni);
    }
  }
  return count === total;
}

function countWalkable(g: Grid, r: GenRoom): number {
  let n = 0;
  for (let y = r.y; y < r.y + r.h; y++) {
    for (let x = r.x; x < r.x + r.w; x++) if (g.walkable(x, y)) n++;
  }
  return n;
}

/** Assign room kinds (ward 40 / storage 25 / office 15 / empty 20) and place furniture. */
function furnish(g: Grid, rooms: GenRoom[], rng: Rng): void {
  for (const r of rooms) {
    const roll = rng.float();
    r.kind = roll < 0.4 ? 'ward' : roll < 0.65 ? 'storage' : roll < 0.8 ? 'office' : 'empty';
    if (r.kind === 'empty') continue;

    // Tiles that must stay clear: the interior tile directly inside every door.
    const keep = new Set<number>();
    for (const d of roomDoors(g, r)) keep.add(d.iy * g.w + d.ix);

    const place = (x: number, y: number, ch: string): boolean => {
      if (!inRoom(r, x, y) || keep.has(y * g.w + x) || g.get(x, y) !== '.') return false;
      g.set(x, y, ch);
      if (interiorConnected(g, r)) return true;
      g.set(x, y, '.');
      return false;
    };

    const x0 = r.x;
    const y0 = r.y;
    const x1 = r.x + r.w - 1;
    const y1 = r.y + r.h - 1;

    if (r.kind === 'ward') {
      // Rows of beds on alternating columns; bed rows are at least two clear rows apart.
      const bedRows = [y0];
      for (let y = y0 + 3; y <= y1 - 3; y += 3) bedRows.push(y);
      if (r.h >= 4) bedRows.push(y1);
      const start = x0 + rng.int(0, 1);
      for (const y of bedRows) {
        for (let x = start; x <= x1; x += 2) place(x, y, 'b');
      }
    } else if (r.kind === 'storage') {
      // Cabinets along 2-4 walls with the occasional gap.
      const sides = rng.shuffle([0, 1, 2, 3]).slice(0, rng.int(2, 4));
      for (const side of sides) {
        if (side === 0) for (let x = x0; x <= x1; x++) if (!rng.chance(0.2)) place(x, y0, 'c');
        if (side === 1) for (let x = x0; x <= x1; x++) if (!rng.chance(0.2)) place(x, y1, 'c');
        if (side === 2) for (let y = y0; y <= y1; y++) if (!rng.chance(0.2)) place(x0, y, 'c');
        if (side === 3) for (let y = y0; y <= y1; y++) if (!rng.chance(0.2)) place(x1, y, 'c');
      }
    } else if (r.kind === 'office') {
      // A few cabinets, corners first.
      let n = rng.int(2, 4);
      const corners: [number, number][] = rng.shuffle([[x0, y0], [x1, y0], [x0, y1], [x1, y1]]);
      for (const [x, y] of corners) {
        if (n <= 0) break;
        if (place(x, y, 'c')) n--;
      }
      if (n > 0) place(rng.int(x0, x1), rng.chance(0.5) ? y0 : y1, 'c');
    }
  }
}

// ---------------------------------------------------------------------------
// Connectivity repair
// ---------------------------------------------------------------------------

/**
 * Flood from a P; for every unreachable pocket, punch a door through an unlocked wall into
 * reachable space (never adjacent to another door, never on the map border). If no such wall
 * exists the pocket is filled with '#'.
 */
function fixConnectivity(g: Grid): void {
  const n = g.w * g.h;
  const ps = g.find('P');
  if (!ps.length) return;
  const start = ps[0].y * g.w + ps[0].x;
  for (let guard = 0; guard < 1000; guard++) {
    const reach = flood(g, [start]);
    let pocketStart = -1;
    for (let i = 0; i < n; i++) {
      if (!reach[i] && isWalkableChar(g.cells[i])) {
        pocketStart = i;
        break;
      }
    }
    if (pocketStart < 0) return;
    const pocketMask = flood(g, [pocketStart]);
    const pocket: number[] = [];
    for (let i = 0; i < n; i++) if (pocketMask[i]) pocket.push(i);

    let punched = false;
    for (const i of pocket) {
      const x = i % g.w;
      const y = (i - x) / g.w;
      for (const [dx, dy] of DIRS) {
        const wx = x + dx;
        const wy = y + dy;
        if (wx <= 0 || wy <= 0 || wx >= g.w - 1 || wy >= g.h - 1) continue;
        if (g.get(wx, wy) !== '#' || g.isLocked(wx, wy) || doorNear(g, wx, wy)) continue;
        const ox = wx + dx;
        const oy = wy + dy;
        if (!g.inBounds(ox, oy) || !reach[oy * g.w + ox]) continue;
        g.set(wx, wy, '+');
        punched = true;
        break;
      }
      if (punched) break;
    }
    if (!punched) {
      for (const i of pocket) g.cells[i] = '#';
    }
  }
}

// ---------------------------------------------------------------------------
// Spawn candidates
// ---------------------------------------------------------------------------

function toolCandidates(g: Grid, r: GenRoom): Pt[] {
  const out: Pt[] = [];
  for (let y = r.y; y < r.y + r.h; y++) {
    for (let x = r.x; x < r.x + r.w; x++) {
      if (g.get(x, y) === '.' && !doorNear(g, x, y)) out.push({ x, y });
    }
  }
  return out;
}

/** 1-3 tool candidates per room on floor tiles away from doors; top up until the minimum is met. */
function placeTools(g: Grid, rooms: GenRoom[], rng: Rng, minTotal: number): number {
  let total = 0;
  for (const r of rooms) {
    const c = rng.shuffle(toolCandidates(g, r));
    const n = Math.min(c.length, rng.int(1, 3));
    for (let i = 0; i < n; i++) g.set(c[i].x, c[i].y, 'T');
    total += n;
  }
  for (let pass = 0; pass < 20 && total < minTotal; pass++) {
    let placed = false;
    for (const r of rooms) {
      if (total >= minTotal) break;
      const c = toolCandidates(g, r);
      if (!c.length) continue;
      const t = rng.pick(c);
      g.set(t.x, t.y, 'T');
      total++;
      placed = true;
    }
    if (!placed) break;
  }
  return total;
}

function manhattan(a: Pt, b: Pt): number {
  return Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
}

/** Monster candidates on corridor floor far from every P, spread out by farthest-point sampling. */
function placeMonsters(g: Grid, rng: Rng, minDist: number, want: number): number {
  const ps = g.find('P');
  const cands: Pt[] = [];
  for (let y = 0; y < g.h; y++) {
    for (let x = 0; x < g.w; x++) {
      if (!g.isCorridorFloor(x, y)) continue;
      const p = { x, y };
      let ok = true;
      for (const s of ps) {
        if (manhattan(p, s) < minDist) {
          ok = false;
          break;
        }
      }
      if (ok) cands.push(p);
    }
  }
  if (!cands.length) return 0;
  const chosen: Pt[] = [rng.pick(cands)];
  while (chosen.length < want && chosen.length < cands.length) {
    let best: Pt | null = null;
    let bestD = -1;
    for (const c of cands) {
      let d = Infinity;
      for (const k of chosen) d = Math.min(d, manhattan(c, k));
      if (d > bestD) {
        bestD = d;
        best = c;
      }
    }
    if (!best || bestD <= 0) break;
    chosen.push(best);
  }
  for (const c of chosen) g.set(c.x, c.y, 'M');
  return chosen.length;
}

// ---------------------------------------------------------------------------
// Lights
// ---------------------------------------------------------------------------

/** Nearest walkable tile inside the room to (cx, cy), or null when the room has none. */
function nearestWalkableInRoom(g: Grid, r: GenRoom, cx: number, cy: number): Pt | null {
  let best: Pt | null = null;
  let bestD = Infinity;
  for (let y = r.y; y < r.y + r.h; y++) {
    for (let x = r.x; x < r.x + r.w; x++) {
      if (!g.walkable(x, y)) continue;
      const d = Math.abs(x - cx) + Math.abs(y - cy);
      if (d < bestD) {
        bestD = d;
        best = { x, y };
      }
    }
  }
  return best;
}

function placeLights(g: Grid, bx: number, by: number, rooms: GenRoom[], segs: Segment[]): Pt[] {
  const lights: Pt[] = [];
  const seen = new Set<number>();
  const add = (x: number, y: number): void => {
    if (!g.walkable(x, y)) return;
    const key = y * g.w + x;
    if (seen.has(key)) return;
    seen.add(key);
    lights.push({ x, y });
  };
  // Generated rooms: one fixture at the interior centre (nudged onto a walkable tile).
  for (const r of rooms) {
    const p = nearestWalkableInRoom(g, r, r.x + Math.floor((r.w - 1) / 2), r.y + Math.floor((r.h - 1) / 2));
    if (p) add(p.x, p.y);
  }
  // Template rooms: anterooms, OR (either side of the table), clock-in room.
  add(bx + 6, by + 6);
  add(bx + 23, by + 6);
  add(bx + 12, by + 7);
  add(bx + 17, by + 7);
  add(bx + 14, by + 12);
  // Corridors: every ~4-5 tiles, alternating between the two lanes.
  for (const s of segs) {
    const len = s.b - s.a + 1;
    if (len <= 0) continue;
    const n = Math.max(1, Math.round(len / 4.5));
    for (let i = 0; i < n; i++) {
      const p = s.a + Math.floor(((i + 0.5) * len) / n);
      const lane = s.lane + (i % 2);
      if (s.horizontal) add(p, lane);
      else add(lane, p);
    }
  }
  return lights;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function generateHospital(seed: number, opts: { width?: number; height?: number } = {}): GeneratedMap {
  const w = Math.floor(opts.width ?? DEFAULT_WIDTH);
  const h = Math.floor(opts.height ?? DEFAULT_HEIGHT);
  if (!(w >= MIN_WIDTH) || !(h >= MIN_HEIGHT)) {
    throw new Error(`generateHospital: map must be at least ${MIN_WIDTH}x${MIN_HEIGHT}, got ${w}x${h}`);
  }
  const rng = new Rng(seed);
  const g = new Grid(w, h);
  const bx = Math.floor((w - BLOCK_W) / 2);
  const by = Math.floor((h - BLOCK_H) / 2);
  const segs: Segment[] = [];
  const templateRooms: GenRoom[] = [];

  stampBlock(g, bx, by, templateRooms, segs);
  carveOuterRing(g, segs);
  carveSpokes(g, bx, by, segs);

  const leaves: Region[] = [];
  for (const arm of buildArms(g, bx, by)) splitRegion(g, arm, rng, segs, leaves);

  const genRooms: GenRoom[] = [];
  carveRooms(g, leaves, rng, genRooms);
  placeDoors(g, genRooms, rng);
  furnish(g, genRooms, rng);
  fixConnectivity(g);
  const liveRooms = genRooms.filter((r) => countWalkable(g, r) > 0);

  placeTools(g, liveRooms, rng, MIN_TOOLS);
  placeMonsters(g, rng, MONSTER_MIN_DIST, WANT_MONSTERS);
  const lights = placeLights(g, bx, by, liveRooms, segs);

  return { seed, rows: g.rows(), lights, rooms: [...templateRooms, ...liveRooms] };
}

/** Returns a list of problems; empty when the map is valid. */
export function validateGenerated(g: GeneratedMap): string[] {
  const problems: string[] = [];
  const rows = g.rows;
  if (!rows || !rows.length) return ['map has no rows'];
  const h = rows.length;
  const w = rows[0].length;
  rows.forEach((r, i) => {
    if (r.length !== w) problems.push(`row ${i} has length ${r.length}, expected ${w}`);
  });
  if (problems.length) return problems;

  const at = (x: number, y: number): string => (x < 0 || y < 0 || x >= w || y >= h ? '#' : rows[y][x]);
  const walk = (x: number, y: number): boolean => isWalkableChar(at(x, y));
  const pos: Record<string, Pt[]> = {};
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const c = rows[y][x];
      if (!LEGEND_CHARS.includes(c)) problems.push(`unknown tile '${c}' at ${x},${y}`);
      (pos[c] ??= []).push({ x, y });
    }
  }
  const of = (c: string): Pt[] => pos[c] ?? [];

  for (let x = 0; x < w; x++) {
    if (at(x, 0) !== '#') problems.push(`border not wall at ${x},0`);
    if (at(x, h - 1) !== '#') problems.push(`border not wall at ${x},${h - 1}`);
  }
  for (let y = 0; y < h; y++) {
    if (at(0, y) !== '#') problems.push(`border not wall at 0,${y}`);
    if (at(w - 1, y) !== '#') problems.push(`border not wall at ${w - 1},${y}`);
  }

  const os = of('O');
  if (os.length !== 2) problems.push(`expected exactly 2 'O', found ${os.length}`);
  else if (os[0].y !== os[1].y || Math.abs(os[0].x - os[1].x) !== 1) problems.push(`'O' tiles are not horizontally adjacent`);
  if (of('K').length !== 1) problems.push(`expected exactly 1 'K', found ${of('K').length}`);
  if (of('C').length !== 1) problems.push(`expected exactly 1 'C', found ${of('C').length}`);
  const ps = of('P');
  if (ps.length !== 4) problems.push(`expected exactly 4 'P', found ${ps.length}`);

  // Rooms.
  const kindCount: Record<string, number> = {};
  for (const r of g.rooms) {
    kindCount[r.kind] = (kindCount[r.kind] ?? 0) + 1;
    if (r.w < 1 || r.h < 1 || r.x < 1 || r.y < 1 || r.x + r.w > w - 1 || r.y + r.h > h - 1) {
      problems.push(`room ${r.kind} at ${r.x},${r.y} ${r.w}x${r.h} is out of bounds`);
      continue;
    }
    for (let y = r.y; y < r.y + r.h; y++) {
      for (let x = r.x; x < r.x + r.w; x++) {
        if (at(x, y) === '#') problems.push(`room ${r.kind} at ${r.x},${r.y} contains a wall at ${x},${y}`);
      }
    }
  }
  if ((kindCount['or'] ?? 0) !== 1) problems.push(`expected 1 'or' room, found ${kindCount['or'] ?? 0}`);
  if ((kindCount['clockin'] ?? 0) !== 1) problems.push(`expected 1 'clockin' room, found ${kindCount['clockin'] ?? 0}`);
  if ((kindCount['anteroom'] ?? 0) !== 2) problems.push(`expected 2 'anteroom' rooms, found ${kindCount['anteroom'] ?? 0}`);
  const clockin = g.rooms.find((r) => r.kind === 'clockin');
  const orRoom = g.rooms.find((r) => r.kind === 'or');
  if (clockin) {
    for (const p of [...ps, ...of('K'), ...of('C')]) {
      if (!inRoom(clockin, p.x, p.y)) problems.push(`'${at(p.x, p.y)}' at ${p.x},${p.y} is outside the clock-in room`);
    }
  }
  if (orRoom) {
    for (const p of os) if (!inRoom(orRoom, p.x, p.y)) problems.push(`'O' at ${p.x},${p.y} is outside the OR`);
  }

  // Tool candidates: >= 16, only inside generated rooms.
  const ts = of('T');
  if (ts.length < MIN_TOOLS) problems.push(`expected >= ${MIN_TOOLS} 'T', found ${ts.length}`);
  for (const t of ts) {
    if (!g.rooms.some((r) => isGeneratedKind(r.kind) && inRoom(r, t.x, t.y))) problems.push(`'T' at ${t.x},${t.y} is not inside a generated room`);
  }

  // Monster candidates: >= 6, never inside a room, far from every P.
  const ms = of('M');
  if (ms.length < MIN_MONSTERS) problems.push(`expected >= ${MIN_MONSTERS} 'M', found ${ms.length}`);
  for (const m of ms) {
    if (g.rooms.some((r) => inRoom(r, m.x, m.y))) problems.push(`'M' at ${m.x},${m.y} is inside a room`);
    for (const p of ps) {
      const d = manhattan(m, p);
      if (d < MONSTER_MIN_DIST) problems.push(`'M' at ${m.x},${m.y} is only ${d} tiles from 'P' at ${p.x},${p.y}`);
    }
  }

  // Doors: passable straight through, never adjacent to another door (the stamped template's
  // own double-wide doorways are the one permitted exception).
  const bx = Math.floor((w - BLOCK_W) / 2);
  const by = Math.floor((h - BLOCK_H) / 2);
  const inBlock = (x: number, y: number): boolean => x >= bx && x < bx + BLOCK_W && y >= by && y < by + BLOCK_H;
  for (const d of of('+')) {
    const ns = walk(d.x, d.y - 1) && walk(d.x, d.y + 1);
    const ew = walk(d.x - 1, d.y) && walk(d.x + 1, d.y);
    if (!ns && !ew) problems.push(`door at ${d.x},${d.y} lacks walkable tiles on two opposite sides`);
    for (const [dx, dy] of [[1, 0], [0, 1]] as const) {
      const nx = d.x + dx;
      const ny = d.y + dy;
      if (at(nx, ny) === '+' && !(inBlock(d.x, d.y) && inBlock(nx, ny))) problems.push(`doors at ${d.x},${d.y} and ${nx},${ny} are adjacent`);
    }
  }

  // Beds must be walkable-adjacent on at least two sides.
  for (const b of of('b')) {
    let open = 0;
    for (const [dx, dy] of DIRS) if (walk(b.x + dx, b.y + dy)) open++;
    if (open < 2) problems.push(`bed at ${b.x},${b.y} has only ${open} walkable neighbour(s)`);
  }

  // Lights sit on walkable floor tiles.
  for (const l of g.lights) {
    if (!walk(l.x, l.y)) problems.push(`light at ${l.x},${l.y} is not on a walkable tile`);
  }

  // Everything walkable must be reachable from a P.
  if (ps.length) {
    const reached = new Uint8Array(w * h);
    const queue = [ps[0].y * w + ps[0].x];
    reached[queue[0]] = 1;
    let count = 0;
    for (let qi = 0; qi < queue.length; qi++) {
      const i = queue[qi];
      count++;
      const x = i % w;
      const y = (i - x) / w;
      for (const [dx, dy] of DIRS) {
        const nx = x + dx;
        const ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        const ni = ny * w + nx;
        if (reached[ni] || !walk(nx, ny)) continue;
        reached[ni] = 1;
        queue.push(ni);
      }
    }
    let total = 0;
    let example: Pt | null = null;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (!walk(x, y)) continue;
        total++;
        if (!reached[y * w + x] && !example) example = { x, y };
      }
    }
    if (count !== total) problems.push(`${total - count} walkable tile(s) unreachable from 'P' (e.g. ${example?.x},${example?.y})`);
  }

  return problems;
}
