// Sanity-check the procedural map generator across many seeds.
// Run with: node scripts/mapcheck.ts
import { generateHospital, validateGenerated, isWalkableChar } from '../src/mapgen.ts';
import type { GeneratedMap } from '../src/mapgen.ts';

const SEED_FROM = 1;
const SEED_TO = 300;
const SHOW_SEED = 7;

function count(g: GeneratedMap, ch: string): number {
  let n = 0;
  for (const row of g.rows) for (const c of row) if (c === ch) n++;
  return n;
}

function summarize(name: string, values: number[]): string {
  const min = Math.min(...values);
  const max = Math.max(...values);
  const avg = values.reduce((s, v) => s + v, 0) / values.length;
  return `${name.padEnd(8)} min ${String(min).padStart(3)}  avg ${avg.toFixed(1).padStart(6)}  max ${String(max).padStart(3)}`;
}

const roomsPerSeed: number[] = [];
const toolsPerSeed: number[] = [];
const monstersPerSeed: number[] = [];
const lightsPerSeed: number[] = [];
const doorsPerSeed: number[] = [];
const kindTotals: Record<string, number> = {};
let failures = 0;

for (let seed = SEED_FROM; seed <= SEED_TO; seed++) {
  let g: GeneratedMap;
  try {
    g = generateHospital(seed);
  } catch (err) {
    failures++;
    console.log(`seed ${seed}: generator threw: ${(err as Error).message}`);
    continue;
  }
  const problems = validateGenerated(g);
  if (problems.length) {
    failures++;
    console.log(`seed ${seed}: ${problems.length} problem(s)`);
    for (const p of problems) console.log(`  - ${p}`);
  }
  // Same seed must reproduce byte-for-byte (all players build the map from a shared seed).
  const again = generateHospital(seed);
  if (JSON.stringify(again) !== JSON.stringify(g)) {
    failures++;
    console.log(`seed ${seed}: NOT DETERMINISTIC (second run differs)`);
  }
  const generated = g.rooms.filter((r) => r.kind !== 'or' && r.kind !== 'anteroom' && r.kind !== 'clockin');
  roomsPerSeed.push(generated.length);
  toolsPerSeed.push(count(g, 'T'));
  monstersPerSeed.push(count(g, 'M'));
  lightsPerSeed.push(g.lights.length);
  doorsPerSeed.push(count(g, '+'));
  for (const r of generated) kindTotals[r.kind] = (kindTotals[r.kind] ?? 0) + 1;
}

const n = SEED_TO - SEED_FROM + 1;
console.log('');
console.log(`Checked seeds ${SEED_FROM}..${SEED_TO}: ${failures === 0 ? 'ALL VALID' : `${failures} FAILED`}`);
console.log(summarize('rooms', roomsPerSeed));
console.log(summarize('T', toolsPerSeed));
console.log(summarize('M', monstersPerSeed));
console.log(summarize('lights', lightsPerSeed));
console.log(summarize('doors', doorsPerSeed));
const totalRooms = Object.values(kindTotals).reduce((s, v) => s + v, 0);
console.log(
  'kinds    ' +
    Object.keys(kindTotals)
      .sort()
      .map((k) => `${k} ${((100 * kindTotals[k]) / totalRooms).toFixed(0)}%`)
      .join('  '),
);
console.log(`(${n} seeds)`);

// Eyeball one map with light fixtures overlaid as '*'.
const show = generateHospital(SHOW_SEED);
const overlay = show.rows.map((r) => r.split(''));
for (const l of show.lights) {
  if (overlay[l.y][l.x] === '.') overlay[l.y][l.x] = '*';
}
console.log('');
console.log(`Seed ${SHOW_SEED} (${show.rows[0].length}x${show.rows.length}), lights shown as '*':`);
console.log('');
for (const row of overlay) console.log(row.join(''));
console.log('');
console.log(
  'rooms: ' +
    show.rooms.map((r) => `${r.kind}@${r.x},${r.y} ${r.w}x${r.h}`).join('  '),
);
const walkableCount = show.rows.reduce((s, row) => s + [...row].filter(isWalkableChar).length, 0);
console.log(`walkable tiles: ${walkableCount}, lights: ${show.lights.length}`);

process.exitCode = failures === 0 ? 0 : 1;
