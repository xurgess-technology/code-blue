export const TILE = 32;

export enum Tile { Wall, Floor, Door, Bed, Cabinet, Table, Clock, Pod, Prop }

export interface Vec { x: number; y: number }
export interface RayHit { x: number; y: number; dist: number }
export interface MapExtras { lights?: Vec[] }
/** Decorative clutter that also blocks movement. Character -> kind. */
export const PROP_CHARS: Record<string, string> = { g: 'gurney', w: 'wheelchair', i: 'ivstand', v: 'vending', x: 'bin', l: 'locker', s: 'screen' };
export interface Prop { x: number; y: number; kind: string; rot: number }

function seededRng(seed: number) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/**
 * Scatter hospital clutter along corridor walls, deterministically from the seed.
 * Only floor tiles that touch a wall and are not near a door or another prop; never both sides
 * of a 2-wide corridor at the same spot, so nothing is ever blocked off.
 */
export function addClutter(rows: string[], seed: number, density = 0.06): string[] {
  const grid = rows.map((r) => r.split(''));
  const h = grid.length, w = grid[0].length;
  const rng = seededRng(seed ^ 0x9e3779b9);
  const at = (x: number, y: number) => (x < 0 || y < 0 || x >= w || y >= h ? '#' : grid[y][x]);
  const kinds = ['g', 'w', 'i', 'x', 'l', 'v', 's', 'i', 'x', 'g'];
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      if (grid[y][x] !== '.') continue;
      if (rng() > density) continue;
      const wallN = at(x, y - 1) === '#', wallS = at(x, y + 1) === '#', wallW = at(x - 1, y) === '#', wallE = at(x + 1, y) === '#';
      if (!(wallN || wallS || wallW || wallE)) continue;
      // Corridors only: the tile across from the wall must be open floor, and beyond that a wall (2-wide) or more floor.
      let clear = true;
      for (let dy = -2; dy <= 2 && clear; dy++) for (let dx = -2; dx <= 2; dx++) {
        const c = at(x + dx, y + dy);
        if (c === '+' || c === 'P' || c === 'K' || c === 'C' || c === 'O' || c === 'T' || c === 'M' || PROP_CHARS[c]) { clear = false; break; }
      }
      if (!clear) continue;
      // Keep a walkable neighbour on the side away from the wall.
      const openAcross = (wallN && at(x, y + 1) === '.') || (wallS && at(x, y - 1) === '.') || (wallW && at(x + 1, y) === '.') || (wallE && at(x - 1, y) === '.');
      if (!openAcross) continue;
      grid[y][x] = kinds[Math.floor(rng() * kinds.length)];
    }
  }
  return grid.map((r) => r.join(''));
}

// Legend: # wall  . floor  + door  b bed  c cabinet  O operating table  K time clock  C cloning pod
//         P player spawn  T tool spawn  M monster spawn
// This hand-made layout is the fallback; shifts use src/mapgen.ts to generate a fresh hospital.
export const FALLBACK_LAYOUT = [
  '##################################################',
  '#...........#...........#............#...........#',
  '#.b.b.b.b...#.T.........#cccc........#...b.b.b.b.#',
  '#...........#...........#............#...........#',
  '#.....T.....#...........#......T.....#...........#',
  '#.b.b.b.b...#.b.b.b.b...#cccc....cccc#.T.b.b.b.b.#',
  '#...........#.......T...#............#...........#',
  '######+###########+###########+############+######',
  '#...........................................M....#',
  '#................................................#',
  '#########..#############++#############..#########',
  '#.......#..#..........................#..#.......#',
  '#.b.b.b.#..#........................M.#..#.cc.cc.#',
  '#.......#..#..######################..#..#.......#',
  '#...T...+..#..#.....##########.....#..#..+.......#',
  '#.b.b.b.#..#..#cc...#c......c#...cc#..#..#.......#',
  '#.......#..#..#..T..#........#.....#..#..#..T....#',
  '#.......#..+..+.....+...OO...+.....+..+..#.......#',
  '#########..+..+.....+........+.....+..+..#########',
  '#.......#..#..#.....#........#.....#..#..#.......#',
  '#cc...cc#..#..#.....#........#..T..#..#..#.......#',
  '#..T....+..#..#.....##########.....#..#..+....T..#',
  '#.......#..#..######################..#..#.......#',
  '#cc...cc#..#..........................#..#.cc.cc.#',
  '#.......#..#..........................#..#.......#',
  '#########..#############++#############..#########',
  '#................................................#',
  '#.......................................M........#',
  '######+###########+###########+############+######',
  '#...........#...........#............#...........#',
  '#...........#.cc.cc.cc..#T...........#...........#',
  '#...........#...........#............#.....M.....#',
  '#..P..P..C..#.cc.cc.cc..#............#...........#',
  '#...........#.........T.#........cccc#........T..#',
  '#..P..P..K..#...........#............#...........#',
  '##################################################',
];

const center = (x: number, y: number): Vec => ({ x: (x + 0.5) * TILE, y: (y + 0.5) * TILE });

export class GameMap {
  readonly w: number;
  readonly h: number;
  readonly tiles: Uint8Array;
  readonly explored: Uint8Array;
  readonly spawns: Vec[] = [];
  readonly playerSpawn: Vec;
  readonly toolSpawns: Vec[] = [];
  readonly monsterSpawns: Vec[] = [];
  readonly table: Vec;
  readonly clock: Vec | null = null;
  readonly pod: Vec | null = null;
  readonly lights: Vec[];
  readonly props: Prop[] = [];
  readonly floorTiles: Vec[] = [];

  constructor(rows: string[] = FALLBACK_LAYOUT, extras: MapExtras = {}) {
    this.h = rows.length;
    this.w = rows[0].length;
    rows.forEach((r, i) => {
      if (r.length !== this.w) throw new Error(`Map row ${i} has length ${r.length}, expected ${this.w}`);
    });
    this.tiles = new Uint8Array(this.w * this.h);
    this.explored = new Uint8Array(this.w * this.h);
    const tableTiles: Vec[] = [];
    let clock: Vec | null = null, pod: Vec | null = null;
    for (let y = 0; y < this.h; y++) {
      for (let x = 0; x < this.w; x++) {
        const c = rows[y][x];
        let t = Tile.Floor;
        switch (c) {
          case '#': t = Tile.Wall; break;
          case '+': t = Tile.Door; break;
          case 'b': t = Tile.Bed; break;
          case 'c': t = Tile.Cabinet; break;
          case 'O': t = Tile.Table; tableTiles.push({ x, y }); break;
          case 'K': t = Tile.Clock; clock = center(x, y); break;
          case 'C': t = Tile.Pod; pod = center(x, y); break;
          case 'P': this.spawns.push(center(x, y)); break;
          case 'T': this.toolSpawns.push(center(x, y)); break;
          case 'M': this.monsterSpawns.push(center(x, y)); break;
          default:
            if (PROP_CHARS[c]) {
              t = Tile.Prop;
              // Face away from the wall it leans on.
              const n = rows[y - 1]?.[x] === '#', s = rows[y + 1]?.[x] === '#', wv = rows[y][x - 1] === '#';
              const rot = n ? Math.PI / 2 : s ? -Math.PI / 2 : wv ? 0 : Math.PI;
              this.props.push({ x, y, kind: PROP_CHARS[c], rot });
            }
        }
        this.tiles[y * this.w + x] = t;
        if (t === Tile.Floor || t === Tile.Door) this.floorTiles.push({ x, y });
      }
    }
    if (!this.spawns.length) throw new Error('Map has no player spawn (P)');
    if (!tableTiles.length) throw new Error('Map has no operating table (O)');
    this.playerSpawn = this.spawns[0];
    this.clock = clock;
    this.pod = pod;
    this.lights = extras.lights ?? [];
    const tx = tableTiles.reduce((s, t) => s + t.x + 0.5, 0) / tableTiles.length;
    const ty = tableTiles.reduce((s, t) => s + t.y + 0.5, 0) / tableTiles.length;
    this.table = { x: tx * TILE, y: ty * TILE };
  }

  get(tx: number, ty: number): Tile {
    if (tx < 0 || ty < 0 || tx >= this.w || ty >= this.h) return Tile.Wall;
    return this.tiles[ty * this.w + tx] as Tile;
  }
  /** Blocks movement. */
  solid(tx: number, ty: number): boolean {
    const t = this.get(tx, ty);
    return t !== Tile.Floor && t !== Tile.Door;
  }
  /** Blocks light and line of sight (only real walls; furniture does not). */
  opaque(tx: number, ty: number): boolean {
    return this.get(tx, ty) === Tile.Wall;
  }
  mark(tx: number, ty: number) {
    if (tx < 0 || ty < 0 || tx >= this.w || ty >= this.h) return;
    this.explored[ty * this.w + tx] = 1;
  }
  isExplored(tx: number, ty: number): boolean {
    return this.explored[ty * this.w + tx] === 1;
  }

  circleHitsSolid(x: number, y: number, r: number): boolean {
    const x0 = Math.floor((x - r) / TILE), x1 = Math.floor((x + r) / TILE);
    const y0 = Math.floor((y - r) / TILE), y1 = Math.floor((y + r) / TILE);
    for (let ty = y0; ty <= y1; ty++) {
      for (let tx = x0; tx <= x1; tx++) {
        if (!this.solid(tx, ty)) continue;
        const cx = Math.max(tx * TILE, Math.min(x, (tx + 1) * TILE));
        const cy = Math.max(ty * TILE, Math.min(y, (ty + 1) * TILE));
        const dx = x - cx, dy = y - cy;
        if (dx * dx + dy * dy < r * r) return true;
      }
    }
    return false;
  }

  /** DDA raycast against opaque tiles. (dx, dy) must be a unit vector; distances in world px. */
  raycast(x: number, y: number, dx: number, dy: number, maxDist: number, mark = false): RayHit {
    const px = x / TILE, py = y / TILE;
    let tx = Math.floor(px), ty = Math.floor(py);
    const stepX = dx >= 0 ? 1 : -1, stepY = dy >= 0 ? 1 : -1;
    const tDeltaX = dx !== 0 ? Math.abs(1 / dx) : Infinity;
    const tDeltaY = dy !== 0 ? Math.abs(1 / dy) : Infinity;
    let tMaxX = dx !== 0 ? (dx > 0 ? tx + 1 - px : px - tx) * tDeltaX : Infinity;
    let tMaxY = dy !== 0 ? (dy > 0 ? ty + 1 - py : py - ty) * tDeltaY : Infinity;
    const maxT = maxDist / TILE;
    let t = 0;
    if (mark) this.mark(tx, ty);
    if (this.opaque(tx, ty)) return { x, y, dist: 0 };
    for (let i = 0; i < 512; i++) {
      if (tMaxX < tMaxY) { t = tMaxX; tx += stepX; tMaxX += tDeltaX; }
      else { t = tMaxY; ty += stepY; tMaxY += tDeltaY; }
      if (t >= maxT) break;
      if (mark) this.mark(tx, ty);
      if (this.opaque(tx, ty)) {
        const d = t * TILE;
        return { x: x + dx * d, y: y + dy * d, dist: d };
      }
    }
    return { x: x + dx * maxDist, y: y + dy * maxDist, dist: maxDist };
  }

  hasLOS(ax: number, ay: number, bx: number, by: number): boolean {
    const dx = bx - ax, dy = by - ay;
    const d = Math.hypot(dx, dy);
    if (d < 1e-6) return true;
    const h = this.raycast(ax, ay, dx / d, dy / d, d);
    return h.dist >= d - 0.01;
  }

  /** If the goal tile is solid, find the closest walkable tile nearby. */
  nearestWalkable(tx: number, ty: number): Vec | null {
    if (!this.solid(tx, ty)) return { x: tx, y: ty };
    for (let r = 1; r <= 3; r++) {
      for (let dy = -r; dy <= r; dy++) {
        for (let dx = -r; dx <= r; dx++) {
          if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
          if (!this.solid(tx + dx, ty + dy)) return { x: tx + dx, y: ty + dy };
        }
      }
    }
    return null;
  }

  /** A* over tiles (8-way, no corner cutting). Returns tile path excluding start. */
  findPath(sx: number, sy: number, gx: number, gy: number): Vec[] {
    const goalTile = this.nearestWalkable(gx, gy);
    if (!goalTile) return [];
    gx = goalTile.x; gy = goalTile.y;
    const w = this.w, n = w * this.h;
    const start = sy * w + sx, goal = gy * w + gx;
    if (start === goal) return [];
    const g = new Float32Array(n).fill(Infinity);
    const f = new Float32Array(n);
    const parent = new Int32Array(n).fill(-1);
    const closed = new Uint8Array(n);
    const heap: number[] = [];
    const push = (i: number) => {
      heap.push(i);
      let k = heap.length - 1;
      while (k > 0) {
        const p = (k - 1) >> 1;
        if (f[heap[p]] <= f[heap[k]]) break;
        [heap[p], heap[k]] = [heap[k], heap[p]];
        k = p;
      }
    };
    const pop = (): number => {
      const top = heap[0];
      const last = heap.pop()!;
      if (heap.length) {
        heap[0] = last;
        let k = 0;
        for (;;) {
          const l = 2 * k + 1, r = l + 1;
          let m = k;
          if (l < heap.length && f[heap[l]] < f[heap[m]]) m = l;
          if (r < heap.length && f[heap[r]] < f[heap[m]]) m = r;
          if (m === k) break;
          [heap[m], heap[k]] = [heap[k], heap[m]];
          k = m;
        }
      }
      return top;
    };
    const hx = (i: number) => {
      const x = i % w, y = (i - x) / w;
      const dx = Math.abs(x - gx), dy = Math.abs(y - gy);
      return Math.max(dx, dy) + 0.414 * Math.min(dx, dy);
    };
    const dirs = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]];
    g[start] = 0; f[start] = hx(start); push(start);
    while (heap.length) {
      const cur = pop();
      if (cur === goal) break;
      if (closed[cur]) continue;
      closed[cur] = 1;
      const cx = cur % w, cy = (cur - cx) / w;
      for (const [ddx, ddy] of dirs) {
        const nx = cx + ddx, ny = cy + ddy;
        if (this.solid(nx, ny)) continue;
        if (ddx !== 0 && ddy !== 0 && (this.solid(cx + ddx, cy) || this.solid(cx, cy + ddy))) continue;
        const ni = ny * w + nx;
        if (closed[ni]) continue;
        const ng = g[cur] + (ddx !== 0 && ddy !== 0 ? 1.414 : 1);
        if (ng < g[ni]) { g[ni] = ng; f[ni] = ng + hx(ni); parent[ni] = cur; push(ni); }
      }
    }
    if (parent[goal] === -1) return [];
    const path: Vec[] = [];
    for (let i = goal; i !== start; i = parent[i]) path.push({ x: i % w, y: (i - (i % w)) / w });
    path.reverse();
    return path;
  }

  randomFloorTile(rng: () => number = Math.random): Vec {
    return this.floorTiles[Math.floor(rng() * this.floorTiles.length)];
  }
}
