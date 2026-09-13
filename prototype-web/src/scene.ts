// First-person Three.js view of the hospital. All geometry, textures and creatures are built
// procedurally from the 2D simulation, so there are still no asset files.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

// Optional real models (Blender .glb exports in public/models). Each is scaled to a target height,
// grounded at y=0, rotated to face local +x, and dropped into the matching creature rig when loaded.
const MODELS: Record<string, { url: string; height: number; color: number; faceRotY: number }> = {
  // Zach's first Blender sculpt. For now he is the friendly guy wandering the OR before the shift.
  uhoh: { url: 'models/uh-oh.glb', height: 2.5, color: 0x8fa38a, faceRotY: Math.PI / 2 },
};
const modelCache = new Map<string, Promise<THREE.Group>>();
function loadModel(key: string): Promise<THREE.Group> {
  const def = MODELS[key];
  let p = modelCache.get(key);
  if (p) return p;
  p = new GLTFLoader().loadAsync(def.url).then((gltf) => {
    const root = gltf.scene;
    const material = mat(def.color, { roughness: 0.85 });
    root.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.isMesh) { m.material = material; m.castShadow = true; m.receiveShadow = true; }
    });
    const box = new THREE.Box3().setFromObject(root);
    const size = new THREE.Vector3(); box.getSize(size);
    const s = def.height / Math.max(size.y, 1e-3);
    const wrap = new THREE.Group();
    root.scale.setScalar(s);
    root.position.set(-(box.min.x + box.max.x) / 2 * s, -box.min.y * s, -(box.min.z + box.max.z) / 2 * s);
    const turn = new THREE.Group();
    turn.rotation.y = def.faceRotY;
    turn.add(root);
    wrap.add(turn);
    return wrap;
  });
  modelCache.set(key, p);
  return p;
}
import { Game, Tool, Monster, Player, CONE_HALF, CONE_RANGE, GLOW_RANGE } from './game';
import { GameMap, Tile, TILE, Vec } from './map';

export const WALL_H = 2.2;
export const EYE_H = 1.35;
const U = 1 / TILE; // world px -> 3D units (one tile is one unit)
const LIGHT_POOL = 12;

function mulberry32(seed: number) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeTexture(w: number, h: number, seed: number, paint: (g: CanvasRenderingContext2D, rng: () => number) => void): THREE.CanvasTexture {
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  paint(c.getContext('2d')!, mulberry32(seed));
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
  tex.anisotropy = 8;
  return tex;
}

function floorTexture() {
  return makeTexture(512, 512, 7, (g, rng) => {
    const T = 128;
    for (let y = 0; y < 4; y++) {
      for (let x = 0; x < 4; x++) {
        g.fillStyle = ((x + y) & 1) === 0 ? '#8a968f' : '#78847d';
        g.fillRect(x * T, y * T, T, T);
        g.strokeStyle = 'rgba(0,0,0,0.35)'; g.lineWidth = 3; g.strokeRect(x * T + 1.5, y * T + 1.5, T - 3, T - 3);
        for (let i = 0; i < 3; i++) {
          if (rng() < 0.5) {
            g.fillStyle = `rgba(35,28,20,${0.05 + rng() * 0.2})`;
            g.beginPath(); g.ellipse(x * T + rng() * T, y * T + rng() * T, 10 + rng() * 40, 6 + rng() * 20, rng() * 3, 0, Math.PI * 2); g.fill();
          }
        }
      }
    }
    g.strokeStyle = 'rgba(0,0,0,0.12)'; g.lineWidth = 2;
    for (let i = 0; i < 40; i++) {
      const x = rng() * 512, y = rng() * 512;
      g.beginPath(); g.moveTo(x, y); g.lineTo(x + (rng() - 0.5) * 80, y + (rng() - 0.5) * 80); g.stroke();
    }
  });
}

function wallTexture() {
  return makeTexture(256, 512, 3, (g, rng) => {
    g.fillStyle = '#a3aaa5'; g.fillRect(0, 0, 256, 512);
    for (let i = 0; i < 25; i++) {
      g.fillStyle = `rgba(60,50,40,${0.05 + rng() * 0.15})`;
      g.beginPath(); g.ellipse(rng() * 256, rng() * 300, 10 + rng() * 40, 10 + rng() * 60, rng() * 3, 0, Math.PI * 2); g.fill();
    }
    g.strokeStyle = 'rgba(40,30,25,0.25)'; g.lineWidth = 2;
    for (let i = 0; i < 12; i++) { const x = rng() * 256; g.beginPath(); g.moveTo(x, 300); g.lineTo(x + (rng() - 0.5) * 6, 300 - rng() * 120); g.stroke(); }
    g.fillStyle = '#5f7a6f'; g.fillRect(0, 300, 256, 212);
    g.strokeStyle = 'rgba(0,0,0,0.35)'; g.lineWidth = 2;
    for (let y = 300; y <= 512; y += 53) { g.beginPath(); g.moveTo(0, y); g.lineTo(256, y); g.stroke(); }
    for (let x = 0; x <= 256; x += 64) { g.beginPath(); g.moveTo(x, 300); g.lineTo(x, 512); g.stroke(); }
    g.fillStyle = '#3a4a44'; g.fillRect(0, 296, 256, 10);
    const grad = g.createLinearGradient(0, 420, 0, 512);
    grad.addColorStop(0, 'rgba(0,0,0,0)'); grad.addColorStop(1, 'rgba(0,0,0,0.45)');
    g.fillStyle = grad; g.fillRect(0, 420, 256, 92);
    g.strokeStyle = 'rgba(30,30,30,0.5)'; g.lineWidth = 1.5; g.beginPath();
    let cx = 40 + rng() * 150, cy = 0; g.moveTo(cx, cy);
    while (cy < 280) { cx += (rng() - 0.5) * 30; cy += 20 + rng() * 30; g.lineTo(cx, cy); }
    g.stroke();
  });
}

function ceilingTexture() {
  return makeTexture(512, 512, 11, (g, rng) => {
    g.fillStyle = '#b9bbb2'; g.fillRect(0, 0, 512, 512);
    for (let i = 0; i < 80; i++) {
      g.fillStyle = `rgba(80,70,50,${0.04 + rng() * 0.12})`;
      g.beginPath(); g.ellipse(rng() * 512, rng() * 512, 10 + rng() * 40, 10 + rng() * 40, 0, 0, Math.PI * 2); g.fill();
    }
    g.strokeStyle = 'rgba(0,0,0,0.5)'; g.lineWidth = 4;
    for (let i = 0; i <= 4; i++) { g.beginPath(); g.moveTo(i * 128, 0); g.lineTo(i * 128, 512); g.moveTo(0, i * 128); g.lineTo(512, i * 128); g.stroke(); }
    g.fillStyle = '#141414'; g.fillRect(260, 132, 120, 120);
  });
}

function ecgTexture() {
  return makeTexture(256, 64, 5, (g) => {
    g.fillStyle = '#0b2a18'; g.fillRect(0, 0, 256, 64);
    g.strokeStyle = '#3dff7a'; g.lineWidth = 2; g.beginPath();
    for (let x = 0; x <= 256; x++) {
      const ph = x % 128;
      const y = 40 - (ph === 60 ? 26 : ph === 66 ? -12 : ph === 63 ? 6 : 0) - (ph > 20 && ph < 40 ? 3 : 0);
      x ? g.lineTo(x, y) : g.moveTo(x, y);
    }
    g.stroke();
  });
}

function nameSprite(name: string, color: number): THREE.Sprite {
  const c = document.createElement('canvas');
  c.width = 256; c.height = 64;
  const g = c.getContext('2d')!;
  g.font = 'bold 34px "Courier New", monospace'; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillStyle = 'rgba(0,0,0,0.55)'; g.fillRect(0, 8, 256, 48);
  g.fillStyle = '#' + color.toString(16).padStart(6, '0'); g.fillRect(0, 8, 6, 48);
  g.fillStyle = '#f0e6c8'; g.fillText(name.slice(0, 14), 128, 32);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, transparent: true, depthTest: false }));
  sp.scale.set(1.2, 0.3, 1);
  return sp;
}

type Mat = THREE.MeshStandardMaterial;
const mat = (color: number, extra: Partial<THREE.MeshStandardMaterialParameters> = {}): Mat =>
  new THREE.MeshStandardMaterial({ color, roughness: 0.8, ...extra });

function box(w: number, h: number, d: number, m: THREE.Material, x = 0, y = 0, z = 0, shadow = true): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m);
  mesh.position.set(x, y, z);
  mesh.castShadow = shadow; mesh.receiveShadow = shadow;
  return mesh;
}
function sphere(r: number, m: THREE.Material, x = 0, y = 0, z = 0): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.SphereGeometry(r, 12, 10), m);
  mesh.position.set(x, y, z);
  mesh.castShadow = true;
  return mesh;
}
function cylinder(r: number, h: number, m: THREE.Material, x = 0, y = 0, z = 0): THREE.Mesh {
  const mesh = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, 10), m);
  mesh.position.set(x, y, z);
  mesh.castShadow = true;
  return mesh;
}
function bone(a: THREE.Vector3, b: THREE.Vector3, r: number, m: THREE.Material): THREE.Mesh {
  const dir = new THREE.Vector3().subVectors(b, a);
  const len = dir.length();
  const mesh = new THREE.Mesh(new THREE.CylinderGeometry(r, r * 0.6, len, 6), m);
  mesh.position.copy(a).addScaledVector(dir, 0.5);
  mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.normalize());
  mesh.castShadow = true;
  return mesh;
}
const lerpAngle = (a: number, b: number, k: number) => a + Math.atan2(Math.sin(b - a), Math.cos(b - a)) * k;

interface ToolRig { group: THREE.Group; glint: Mat; light: THREE.PointLight; kind: string }
interface MonsterRig { group: THREE.Group; kind: string; arms: THREE.Group[]; legs: THREE.Object3D[]; eyes: Mat; light?: THREE.PointLight; baseAngles: number[]; sx: number; sy: number; sf: number }
interface PlayerRig { group: THREE.Group; spot: THREE.SpotLight; lens: Mat; legs: THREE.Object3D[]; arm: THREE.Group; sx: number; sy: number; sf: number; sp: number }
interface TableRig { group: THREE.Group; patientGroup: THREE.Group; patientBody: string; wound: THREE.Mesh | null; ecg: THREE.CanvasTexture; markers: THREE.Mesh[]; light: THREE.PointLight }
interface Fixture { x: number; y: number; mode: number; phase: number }

export class Scene3D {
  renderer: THREE.WebGLRenderer;
  scene = new THREE.Scene();
  camera: THREE.PerspectiveCamera;
  private spot: THREE.SpotLight;
  private glow: THREE.PointLight;
  private lens: Mat;
  private handTray: THREE.Group;
  private tex = { floor: floorTexture(), wall: wallTexture(), ceil: ceilingTexture() };
  private builtFor: GameMap | null = null;
  private world = new THREE.Group();
  private toolRigs = new Map<number, ToolRig>();
  private monsterRigs = new Map<number, MonsterRig>();
  private playerRigs = new Map<number, PlayerRig>();
  private table: TableRig | null = null;
  /** The friendly wanderer in the OR during the lobby: purely visual, walks between random spots near the table. */
  private mascot: { group: THREE.Group; pose: THREE.Group; x: number; y: number; tx: number; ty: number; f: number; twitch: number; nextTwitch: number; moving: number } | null = null;
  private fixtures: Fixture[] = [];
  private fixtureMats: Mat[] = [];
  private pool: THREE.PointLight[] = [];
  private t = 0;
  private W = 0; private H = 0;

  constructor(canvas: HTMLCanvasElement) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.5));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.1;
    this.scene.background = new THREE.Color(0x000000);
    this.scene.fog = new THREE.FogExp2(0x000000, 0.075);
    this.scene.add(new THREE.AmbientLight(0x6070a0, 0.1));

    this.camera = new THREE.PerspectiveCamera(75, 1, 0.05, 60);
    this.camera.rotation.order = 'YXZ';
    this.scene.add(this.camera);

    this.spot = new THREE.SpotLight(0xfff1c8, 30, CONE_RANGE * U, CONE_HALF, 0.45, 1.6);
    this.spot.position.set(0.15, -0.1, 0);
    this.spot.target.position.set(0, 0, -1);
    this.spot.castShadow = true;
    this.spot.shadow.mapSize.set(1024, 1024);
    this.spot.shadow.camera.near = 0.1;
    this.spot.shadow.camera.far = CONE_RANGE * U + 2;
    this.spot.shadow.bias = -0.0004;
    this.spot.shadow.normalBias = 0.06;
    this.camera.add(this.spot, this.spot.target);
    this.glow = new THREE.PointLight(0xc8c0b0, 1.6, GLOW_RANGE * U, 1.8);
    this.camera.add(this.glow);

    // Your hands: flashlight on the right, a tray on the left when you carry something.
    const hand = new THREE.Group();
    hand.position.set(0.3, -0.27, -0.45);
    hand.rotation.set(0.06, 0.08, 0);
    const body = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.036, 0.24, 12), mat(0x2a2c30, { metalness: 0.6, roughness: 0.4 }));
    body.rotation.x = Math.PI / 2;
    this.lens = mat(0x222222, { emissive: 0xffe9a0, emissiveIntensity: 1.2 });
    const lens = new THREE.Mesh(new THREE.CylinderGeometry(0.028, 0.028, 0.01, 12), this.lens);
    lens.rotation.x = Math.PI / 2; lens.position.z = -0.118;
    hand.add(body, lens, sphere(0.05, mat(0xe2b998, { roughness: 0.7 }), 0, -0.05, 0.05));
    this.camera.add(hand);
    this.handTray = new THREE.Group();
    this.handTray.position.set(-0.3, -0.3, -0.5);
    this.handTray.rotation.set(0.2, -0.1, 0);
    this.handTray.add(box(0.28, 0.02, 0.2, mat(0xaeb6be, { metalness: 0.7, roughness: 0.35 })), sphere(0.05, mat(0xe2b998, { roughness: 0.7 }), 0, -0.04, 0.08));
    this.handTray.add(box(0.14, 0.01, 0.02, mat(0xe4e9ec, { metalness: 0.9, roughness: 0.25 }), 0, 0.02, -0.02));
    this.camera.add(this.handTray);

    for (let i = 0; i < LIGHT_POOL; i++) {
      const l = new THREE.PointLight(0xd9f0e6, 0, 5.5, 1.8);
      l.visible = false;
      this.scene.add(l);
      this.pool.push(l);
    }
    this.scene.add(this.world);
  }

  resize(w: number, h: number) {
    if (w === this.W && h === this.H) return;
    this.W = w; this.H = h;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  sync(game: Game, dt: number) {
    this.t += dt;
    if (this.builtFor !== game.map) this.rebuild(game);
    const k = 1 - Math.exp(-dt * 14);
    const me = game.local;
    const view = game.spectated;

    // Players other than the one we are looking through.
    const seenP = new Set<number>();
    for (const p of game.players.values()) {
      seenP.add(p.id);
      let rig = this.playerRigs.get(p.id);
      if (!rig) { rig = this.buildSurgeon(p); this.playerRigs.set(p.id, rig); this.world.add(rig.group); }
      rig.sx += (p.x * U - rig.sx) * (p.local ? 1 : k);
      rig.sy += (p.y * U - rig.sy) * (p.local ? 1 : k);
      rig.sf = p.local ? p.facing : lerpAngle(rig.sf, p.facing, k);
      rig.sp += (p.pitch - rig.sp) * k;
      rig.group.visible = p.alive && p !== view;
      rig.group.position.set(rig.sx, 0, rig.sy);
      rig.group.rotation.y = -rig.sf;
      const swing = p.moving ? Math.sin(this.t * (p.sprinting ? 16 : 10)) * 0.5 : 0;
      rig.legs[0].rotation.z = swing; rig.legs[1].rotation.z = -swing;
      rig.arm.rotation.x = -rig.sp * 0.6;
      rig.spot.visible = p.flashlight;
      rig.lens.emissiveIntensity = p.flashlight ? 1.5 : 0;
    }
    for (const [id, rig] of this.playerRigs) if (!seenP.has(id)) { this.world.remove(rig.group); this.playerRigs.delete(id); }

    // Camera: our own eyes, or a teammate's when dead.
    if (view) {
      const rig = this.playerRigs.get(view.id);
      const vx = view.local ? view.x * U : rig?.sx ?? view.x * U;
      const vz = view.local ? view.y * U : rig?.sy ?? view.y * U;
      const vf = view.local ? view.facing : rig?.sf ?? view.facing;
      const vp = view.local ? view.pitch : rig?.sp ?? view.pitch;
      const bob = view.moving ? Math.sin(this.t * (view.sprinting ? 16 : 11)) * 0.035 : 0;
      const sh = game.shake * 0.06;
      this.camera.position.set(vx + (Math.random() - 0.5) * sh, EYE_H + bob + (Math.random() - 0.5) * sh, vz);
      this.camera.rotation.set(vp, -vf - Math.PI / 2, 0);
      const flick = 0.85 + 0.15 * Math.sin(this.t * 37) * Math.sin(this.t * 11.3) - (Math.random() < 0.012 ? 0.5 : 0);
      this.spot.visible = view.flashlight;
      this.spot.intensity = 30 * Math.max(0.3, flick);
      this.lens.emissiveIntensity = view.flashlight ? 1.2 * flick : 0;
      this.handTray.visible = !!me && me.alive && me.carried.length > 0 && view === me;
    }

    // Tools on the floor.
    const seenT = new Set<number>();
    for (const tool of game.tools) {
      seenT.add(tool.id);
      let rig = this.toolRigs.get(tool.id);
      if (!rig || rig.kind !== tool.kind) { if (rig) this.world.remove(rig.group); rig = this.buildTool(tool); this.toolRigs.set(tool.id, rig); this.world.add(rig.group); }
      rig.group.visible = tool.state === 'floor';
      if (!rig.group.visible) continue;
      rig.group.position.set(tool.x * U, 0, tool.y * U);
      const pulse = (Math.sin(this.t * 4 + tool.bob) + 1) / 2;
      rig.glint.emissiveIntensity = 0.15 + 0.5 * pulse;
      rig.light.intensity = 0.35 + 0.35 * pulse;
    }
    for (const [id, rig] of this.toolRigs) if (!seenT.has(id)) { this.world.remove(rig.group); this.toolRigs.delete(id); }

    // Monsters.
    const seenM = new Set<number>();
    for (const m of game.monsters) {
      seenM.add(m.id);
      let rig = this.monsterRigs.get(m.id);
      if (!rig || rig.kind !== m.kind) {
        if (rig) this.world.remove(rig.group);
        rig = m.kind === 'nurse' ? this.buildNurse() : m.kind === 'lurker' ? this.buildLurker() : this.buildOrderly();
        rig.sx = m.x * U; rig.sy = m.y * U; rig.sf = m.facing;
        this.monsterRigs.set(m.id, rig); this.world.add(rig.group);
      }
      const km = game.isHost ? 1 : k;
      rig.sx += (m.x * U - rig.sx) * km; rig.sy += (m.y * U - rig.sy) * km; rig.sf = lerpAngle(rig.sf, m.facing, km);
      this.animateMonster(m, rig, dt);
    }
    for (const [id, rig] of this.monsterRigs) if (!seenM.has(id)) { this.world.remove(rig.group); this.monsterRigs.delete(id); }

    // The table and the patient.
    if (this.table) {
      const tb = this.table;
      const body = game.patient?.body ?? 'none';
      if (tb.patientBody !== body) this.buildPatient(tb, body);
      if (tb.wound) { const s = Math.max(0.12, 1 - (game.patient ? (game.stepIndex + game.stepProgress) / game.patient.steps.length : 0) * 0.85); tb.wound.scale.set(s, 0.3 * s + 0.05, s * 0.6); }
      const anyOp = [...game.players.values()].some((p) => p.operating);
      tb.ecg.offset.x -= dt * (game.phase !== 'shift' ? 0.15 : 0.25 + (1 - game.vitals / 100) * 0.9);
      const delivered = game.tools.filter((t) => t.state === 'delivered').length;
      tb.markers.forEach((mk, i) => { mk.visible = i < delivered; });
      tb.light.intensity = game.phase === 'lost' ? 0.2 : 0.9 + (anyOp ? Math.sin(this.t * 12) * 0.4 : 0);
      tb.light.color.setHex(game.phase === 'lost' ? 0xff3030 : 0x3dff7a);
    }

    this.updateMascot(game, dt);
    this.updateFixtures();
  }

  private updateMascot(game: Game, dt: number) {
    const map = game.map, tb = map.table;
    if (!this.mascot) {
      const group = new THREE.Group();
      const pose = new THREE.Group();
      group.add(pose);
      const m = { group, pose, x: tb.x / TILE, y: tb.y / TILE + 1.5, tx: tb.x / TILE, ty: tb.y / TILE + 1.5, f: 0, twitch: 0, nextTwitch: 3, moving: 0 };
      this.mascot = m;
      this.world.add(group);
      loadModel('uhoh').then((model) => pose.add(model.clone())).catch((e) => console.warn('Mascot model failed to load', e));
    }
    const m = this.mascot;
    if (m.group.parent !== this.world) this.world.add(m.group); // survives rebuilds
    m.group.visible = game.phase === 'lobby';
    if (!m.group.visible) return;

    // Wander between spots near the table; pause to stare at whoever comes close.
    const dx = m.tx - m.x, dz = m.ty - m.y, d = Math.hypot(dx, dz);
    const view = game.spectated;
    const vd = view ? Math.hypot(view.x / TILE - m.x, view.y / TILE - m.y) : 99;
    const staring = vd < 2.5;
    let moving = false;
    if (d < 0.1 || staring) {
      if (!staring && Math.random() < dt * 0.5) {
        for (let i = 0; i < 20; i++) {
          const tx = Math.floor(tb.x / TILE + (Math.random() - 0.5) * 7), ty = Math.floor(tb.y / TILE + (Math.random() - 0.5) * 5);
          if (!map.solid(tx, ty) && map.hasLOS(tb.x, tb.y, (tx + 0.5) * TILE, (ty + 0.5) * TILE)) { m.tx = tx + 0.5; m.ty = ty + 0.5; break; }
        }
      }
      if (staring && view) m.f = lerpAngle(m.f, Math.atan2(view.y / TILE - m.y, view.x / TILE - m.x), Math.min(1, dt * 3));
    } else {
      const step = Math.min(d, 0.7 * dt);
      const nx = m.x + (dx / d) * step, nz = m.y + (dz / d) * step;
      if (!map.circleHitsSolid(nx * TILE, nz * TILE, 12)) { m.x = nx; m.y = nz; moving = true; } else { m.tx = m.x; m.ty = m.y; }
      m.f = lerpAngle(m.f, Math.atan2(dz, dx), Math.min(1, dt * 4));
    }
    // Procedural life: walk cycle with squash on each footfall, breathing at rest, the odd twitch.
    m.moving += ((moving ? 1 : 0) - m.moving) * Math.min(1, dt * 6);
    m.nextTwitch -= dt;
    if (m.nextTwitch <= 0) { m.twitch = 1; m.nextTwitch = 2 + Math.random() * 6; }
    m.twitch = Math.max(0, m.twitch - dt * 4);
    const t = this.t, walk = Math.sin(t * 6), foot = Math.abs(walk), breathe = Math.sin(t * 1.4);
    const w = m.moving, idle = 1 - w;
    m.group.position.set(m.x, foot * 0.09 * w, m.y);
    m.group.rotation.y = -m.f;
    const pose = m.pose;
    pose.rotation.z = walk * 0.07 * w + Math.sin(t * 0.9) * 0.02 * idle + Math.sin(t * 40) * 0.05 * m.twitch;
    pose.rotation.x = 0.1 * w + Math.cos(t * 3) * 0.02 * w + (staring ? 0.06 : 0) + Math.sin(t * 0.7) * 0.015 * idle;
    const squash = 1 - 0.05 * (1 - foot) * w + 0.02 * breathe * idle + 0.06 * m.twitch;
    pose.scale.set(1 + (1 - squash) * 0.6, squash, 1 + (1 - squash) * 0.6);
  }

  render() {
    this.renderer.render(this.scene, this.camera);
  }

  private rebuild(game: Game) {
    this.builtFor = game.map;
    this.world.clear();
    this.toolRigs.clear();
    this.monsterRigs.clear();
    this.playerRigs.clear();
    this.world.add(this.buildStatic(game.map, game.seed));
    this.table = this.buildTable(game.map);
    this.world.add(this.table.group);
    if (this.mascot) { this.mascot.x = this.mascot.tx = game.map.table.x / TILE; this.mascot.y = this.mascot.ty = game.map.table.y / TILE + 1.5; }
  }

  private buildStatic(map: GameMap, seed: number): THREE.Group {
    const g = new THREE.Group();
    this.tex.floor.repeat.set(map.w / 4, map.h / 4);
    const floor = new THREE.Mesh(new THREE.PlaneGeometry(map.w, map.h), new THREE.MeshStandardMaterial({ map: this.tex.floor, roughness: 0.85 }));
    floor.rotation.x = -Math.PI / 2;
    floor.position.set(map.w / 2, 0, map.h / 2);
    floor.receiveShadow = true;
    g.add(floor);

    this.tex.ceil.repeat.set(map.w / 4, map.h / 4);
    const ceil = new THREE.Mesh(new THREE.PlaneGeometry(map.w, map.h), new THREE.MeshStandardMaterial({ map: this.tex.ceil, roughness: 0.95 }));
    ceil.rotation.x = Math.PI / 2;
    ceil.position.set(map.w / 2, WALL_H, map.h / 2);
    ceil.receiveShadow = true;
    g.add(ceil);

    const boxes: THREE.BufferGeometry[] = [];
    for (let y = 0; y < map.h; y++) {
      for (let x = 0; x < map.w; x++) {
        if (map.get(x, y) !== Tile.Wall) continue;
        let exposed = false;
        for (let dy = -1; dy <= 1 && !exposed; dy++) for (let dx = -1; dx <= 1; dx++) if (map.get(x + dx, y + dy) !== Tile.Wall) { exposed = true; break; }
        if (!exposed) continue;
        const b = new THREE.BoxGeometry(1, WALL_H, 1);
        b.translate(x + 0.5, WALL_H / 2, y + 0.5);
        boxes.push(b);
      }
    }
    if (boxes.length) {
      const walls = new THREE.Mesh(mergeGeometries(boxes), new THREE.MeshStandardMaterial({ map: this.tex.wall, roughness: 0.9 }));
      walls.castShadow = true; walls.receiveShadow = true;
      g.add(walls);
    }

    const rng = mulberry32(seed ^ 0x5bd1e995);
    const bedFrame = mat(0x4b525c, { metalness: 0.4, roughness: 0.5 });
    const sheet = mat(0xd5d9d3, { roughness: 0.95 });
    const pillow = mat(0xeceeea, { roughness: 0.95 });
    const blood = mat(0x5a0a10, { roughness: 0.35 });
    const cabinet = mat(0x6b7480, { metalness: 0.3, roughness: 0.55 });
    const cabinetFace = mat(0x8a94a1, { metalness: 0.3, roughness: 0.55 });
    const frame = mat(0x4a3222, { roughness: 0.8 });
    const steel = mat(0x8d97a0, { metalness: 0.8, roughness: 0.3 });
    for (let y = 0; y < map.h; y++) {
      for (let x = 0; x < map.w; x++) {
        const t = map.get(x, y), cx = x + 0.5, cz = y + 0.5;
        if (t === Tile.Bed) {
          g.add(box(0.9, 0.45, 0.95, bedFrame, cx, 0.225, cz));
          g.add(box(0.86, 0.14, 0.9, sheet, cx, 0.52, cz));
          g.add(box(0.5, 0.08, 0.28, pillow, cx, 0.63, cz - 0.3));
          if (rng() < 0.45) { const s = sphere(0.16, blood, cx, 0.59, cz + 0.1); s.scale.set(1, 0.08, 0.8); g.add(s); }
        } else if (t === Tile.Cabinet) {
          g.add(box(0.9, 1.5, 0.9, cabinet, cx, 0.75, cz));
          g.add(box(0.94, 0.6, 0.94, cabinetFace, cx, 0.45, cz, false));
          g.add(box(0.94, 0.6, 0.94, cabinetFace, cx, 1.15, cz, false));
        } else if (t === Tile.Door) {
          const alongX = map.get(x - 1, y) === Tile.Wall && map.get(x + 1, y) === Tile.Wall;
          if (alongX) g.add(box(0.12, 2.0, 0.14, frame, x + 0.06, 1.0, cz), box(0.12, 2.0, 0.14, frame, x + 0.94, 1.0, cz), box(1, 0.25, 0.14, frame, cx, 2.075, cz));
          else g.add(box(0.14, 2.0, 0.12, frame, cx, 1.0, y + 0.06), box(0.14, 2.0, 0.12, frame, cx, 1.0, y + 0.94), box(0.14, 0.25, 1, frame, cx, 2.075, cz));
        } else if (t === Tile.Clock) {
          // The time clock: a pillar with a glowing punch slot.
          g.add(box(0.5, 1.3, 0.5, steel, cx, 0.65, cz));
          g.add(box(0.56, 0.5, 0.56, mat(0x2b2f36, { roughness: 0.6 }), cx, 1.45, cz));
          const screen = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.2, 0.58), new THREE.MeshBasicMaterial({ color: 0x3dff7a }));
          screen.position.set(cx, 1.5, cz);
          g.add(screen);
          const l = new THREE.PointLight(0x3dff7a, 0.8, 4, 1.8); l.position.set(cx, 1.8, cz); g.add(l);
        } else if (t === Tile.Pod) {
          // The Re-Gen Pod: a glass tube full of something teal.
          g.add(cylinder(0.45, 0.3, steel, cx, 0.15, cz));
          const glass = new THREE.Mesh(new THREE.CylinderGeometry(0.38, 0.38, 1.5, 16, 1, true), new THREE.MeshStandardMaterial({ color: 0x6fd8c8, transparent: true, opacity: 0.35, roughness: 0.1, side: THREE.DoubleSide }));
          glass.position.set(cx, 1.05, cz);
          g.add(glass);
          const goo = sphere(0.22, mat(0x3fa090, { emissive: 0x2fb0a0, emissiveIntensity: 0.6, roughness: 0.4 }), cx, 0.9, cz);
          goo.scale.set(1, 1.6, 1);
          g.add(goo);
          g.add(cylinder(0.45, 0.2, steel, cx, 1.9, cz));
          const l = new THREE.PointLight(0x4fe0c8, 1.2, 5, 1.8); l.position.set(cx, 1.4, cz); g.add(l);
        }
      }
    }
    const splat = new THREE.MeshStandardMaterial({ color: 0x5a0a10, roughness: 0.3, polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2 });
    for (let i = 0; i < 50; i++) {
      const ft = map.floorTiles[Math.floor(rng() * map.floorTiles.length)];
      const m = new THREE.Mesh(new THREE.CircleGeometry(0.12 + rng() * 0.3, 9), splat);
      m.rotation.x = -Math.PI / 2;
      m.position.set(ft.x + rng(), 0.004, ft.y + rng());
      m.scale.set(1, 0.5 + rng(), 1);
      g.add(m);
    }

    // Ceiling fixtures: emissive panels everywhere, real lights only near the camera (see updateFixtures).
    this.fixtures = [];
    this.fixtureMats = [];
    map.lights.forEach((l, i) => {
      const r = rng();
      const mode = r < 0.55 ? 0 : r < 0.85 ? 1 : 2; // steady, flicker, dead
      this.fixtures.push({ x: l.x + 0.5, y: l.y + 0.5, mode, phase: rng() * 100 });
      const fm = new THREE.MeshStandardMaterial({ color: 0x222222, emissive: 0xd9f0e6, emissiveIntensity: mode === 2 ? 0 : 1.4, roughness: 0.9 });
      this.fixtureMats.push(fm);
      const panel = new THREE.Mesh(new THREE.BoxGeometry(1.1, 0.06, 0.5), fm);
      panel.position.set(l.x + 0.5, WALL_H - 0.03, l.y + 0.5);
      panel.rotation.y = i % 2 ? Math.PI / 2 : 0;
      g.add(panel);
    });
    return g;
  }

  private updateFixtures() {
    if (!this.fixtures.length) { for (const l of this.pool) l.visible = false; return; }
    const cx = this.camera.position.x, cz = this.camera.position.z;
    const ranked = this.fixtures
      .map((f, i) => ({ i, d: (f.x - cx) * (f.x - cx) + (f.y - cz) * (f.y - cz) }))
      .filter((e) => this.fixtures[e.i].mode !== 2)
      .sort((a, b) => a.d - b.d)
      .slice(0, LIGHT_POOL);
    this.pool.forEach((l, n) => {
      const e = ranked[n];
      if (!e) { l.visible = false; return; }
      const f = this.fixtures[e.i];
      let level = 1;
      if (f.mode === 1) {
        const s = Math.sin(this.t * 23 + f.phase) * Math.sin(this.t * 7.3 + f.phase * 2);
        level = s > 0.2 ? 1 : s > -0.5 ? 0.35 : 0;
      }
      this.fixtureMats[e.i].emissiveIntensity = 1.4 * level;
      l.visible = level > 0;
      l.intensity = 1.5 * level;
      l.position.set(f.x, WALL_H - 0.2, f.y);
    });
  }

  private buildTable(map: GameMap): TableRig {
    const group = new THREE.Group();
    group.position.set(map.table.x * U, 0, map.table.y * U);
    group.add(box(1.9, 0.7, 0.9, mat(0x39454d, { metalness: 0.5, roughness: 0.4 }), 0, 0.35, 0));
    group.add(box(1.95, 0.08, 0.95, mat(0xcdd4d0, { roughness: 0.95 }), 0, 0.78, 0));
    group.add(cylinder(0.03, 1.5, mat(0x555a60, { metalness: 0.7, roughness: 0.4 }), -0.85, 0.75, -0.7));
    group.add(box(0.5, 0.38, 0.1, mat(0x1c1f24, { roughness: 0.6 }), -0.85, 1.55, -0.7));
    const ecg = ecgTexture();
    const screen = new THREE.Mesh(new THREE.PlaneGeometry(0.44, 0.3), new THREE.MeshBasicMaterial({ map: ecg }));
    screen.position.set(-0.85, 1.55, -0.64);
    group.add(screen);
    const light = new THREE.PointLight(0x3dff7a, 0.9, 5, 1.8);
    light.position.set(-0.85, 1.6, -0.5);
    group.add(light);
    group.add(cylinder(0.025, 0.9, mat(0x555a60, { metalness: 0.7, roughness: 0.4 }), 0.4, 0.45, 0.85));
    group.add(box(0.7, 0.03, 0.42, mat(0x8d97a0, { metalness: 0.8, roughness: 0.3 }), 0.4, 0.9, 0.85));
    const markers: THREE.Mesh[] = [];
    const steel = mat(0xe8eef0, { metalness: 0.9, roughness: 0.25 });
    for (let i = 0; i < 7; i++) {
      const mk = box(0.05, 0.02, 0.26, steel, 0.13 + i * 0.09, 0.925, 0.85, false);
      mk.visible = false;
      markers.push(mk);
      group.add(mk);
    }
    const patientGroup = new THREE.Group();
    group.add(patientGroup);
    return { group, patientGroup, patientBody: 'none', wound: null, ecg, markers, light };
  }

  /** Swap the patient model when a new one arrives. */
  private buildPatient(tb: TableRig, body: string) {
    tb.patientBody = body;
    tb.patientGroup.clear();
    tb.wound = null;
    if (body === 'none') return;
    let torso: THREE.Mesh, head: THREE.Mesh;
    if (body === 'elephant') {
      torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.34, 1.0, 4, 10), mat(0x8a8d90, { roughness: 0.95 }));
      head = sphere(0.28, mat(0x8a8d90, { roughness: 0.95 }), 0.95, 1.05, 0);
      const trunk = cylinder(0.07, 0.8, mat(0x8a8d90, { roughness: 0.95 }), 1.25, 0.75, 0.1);
      trunk.rotation.z = 0.5;
      const ear = box(0.05, 0.4, 0.45, mat(0x7d8083, { roughness: 0.95 }), 0.8, 1.15, -0.35);
      tb.patientGroup.add(trunk, ear);
    } else if (body === 'wolf') {
      torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.22, 0.95, 4, 10), mat(0x5a4632, { roughness: 1 }));
      head = sphere(0.18, mat(0x5a4632, { roughness: 1 }), 0.75, 1.0, 0);
      const snout = box(0.22, 0.12, 0.14, mat(0x4a3826, { roughness: 1 }), 0.93, 0.98, 0);
      const earL = box(0.06, 0.16, 0.05, mat(0x4a3826), 0.7, 1.2, -0.1), earR = box(0.06, 0.16, 0.05, mat(0x4a3826), 0.7, 1.2, 0.1);
      tb.patientGroup.add(snout, earL, earR);
    } else if (body === 'ghost') {
      const m = new THREE.MeshStandardMaterial({ color: 0xdfe8ff, transparent: true, opacity: 0.45, roughness: 0.3, emissive: 0x8090ff, emissiveIntensity: 0.25 });
      torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 0.9, 4, 10), m);
      head = sphere(0.17, m, 0.72, 1.0, 0);
    } else {
      torso = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 0.9, 4, 10), mat(0x5a9fb4, { roughness: 0.9 }));
      head = sphere(0.17, mat(0xe6c6a6, { roughness: 0.7 }), 0.72, 1.0, 0);
    }
    torso.rotation.z = Math.PI / 2; torso.position.set(-0.1, 0.98 + (body === 'elephant' ? 0.12 : 0), 0); torso.castShadow = true;
    const wound = sphere(0.16, mat(0x6a0b12, { roughness: 0.3 }), -0.15, body === 'elephant' ? 1.4 : 1.15, 0.04);
    tb.wound = wound;
    tb.patientGroup.add(torso, head, wound);
  }

  private buildTool(tool: Tool): ToolRig {
    const group = new THREE.Group();
    group.add(box(0.42, 0.03, 0.28, mat(0xaeb6be, { metalness: 0.7, roughness: 0.35 }), 0, 0.015, 0));
    const glint = mat(0xe4e9ec, { metalness: 0.9, roughness: 0.25, emissive: 0xffffff, emissiveIntensity: 0.2 });
    const dark = mat(0x333b44, { metalness: 0.3, roughness: 0.6 });
    const y = 0.045;
    switch (tool.kind) {
      case 'Scalpel': group.add(box(0.2, 0.012, 0.03, glint, 0, y, 0), box(0.08, 0.016, 0.03, dark, -0.12, y, 0)); break;
      case 'Forceps': {
        const a = box(0.22, 0.01, 0.022, glint, 0, y, 0.02), b = box(0.22, 0.01, 0.022, glint, 0, y, -0.02);
        a.rotation.y = 0.18; b.rotation.y = -0.18; group.add(a, b); break;
      }
      case 'Clamp': {
        const ring = new THREE.Mesh(new THREE.TorusGeometry(0.04, 0.008, 6, 14), glint);
        ring.rotation.x = Math.PI / 2; ring.position.set(-0.07, y, 0);
        group.add(ring, box(0.16, 0.01, 0.025, glint, 0.05, y, 0)); break;
      }
      case 'Retractor': group.add(box(0.18, 0.012, 0.03, glint, -0.03, y, 0), box(0.03, 0.03, 0.12, glint, 0.08, y + 0.01, 0)); break;
      case 'Sutures': {
        const spool = cylinder(0.035, 0.06, dark, -0.05, y + 0.02, 0);
        spool.rotation.z = Math.PI / 2;
        group.add(spool, box(0.12, 0.008, 0.008, glint, 0.06, y, 0)); break;
      }
      case 'Bone Saw': group.add(box(0.24, 0.01, 0.07, glint, 0.02, y, 0), box(0.07, 0.035, 0.03, dark, -0.13, y + 0.01, 0)); break;
      case 'Anesthetic': {
        const barrel = cylinder(0.022, 0.14, mat(0xdfe6ea, { roughness: 0.2, metalness: 0.1, transparent: true, opacity: 0.85 }), -0.02, y + 0.01, 0);
        barrel.rotation.z = Math.PI / 2;
        const needle = cylinder(0.004, 0.08, glint, 0.09, y + 0.01, 0);
        needle.rotation.z = Math.PI / 2;
        group.add(barrel, needle); break;
      }
    }
    const light = new THREE.PointLight(0xffe0a0, 0.5, 1.8, 1.6);
    light.position.set(0, 0.35, 0);
    group.add(light);
    return { group, glint, light, kind: tool.kind };
  }

  /** A teammate: scrubs in their color, cap, flashlight in hand, name over the head. Faces local +x. */
  private buildSurgeon(p: Player): PlayerRig {
    const group = new THREE.Group();
    const scrubs = mat(p.col, { roughness: 0.9 });
    const skin = mat(0xe2b998, { roughness: 0.7 });
    const legs: THREE.Object3D[] = [];
    for (const z of [-0.09, 0.09]) {
      const hip = new THREE.Group(); hip.position.set(0, 0.5, z);
      hip.add(cylinder(0.06, 0.5, scrubs, 0, -0.25, 0));
      group.add(hip); legs.push(hip);
    }
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 0.5, 4, 10), scrubs);
    body.position.y = 0.85; body.castShadow = true;
    group.add(body);
    group.add(sphere(0.16, skin, 0.02, 1.42, 0));
    group.add(box(0.2, 0.06, 0.24, scrubs, -0.02, 1.58, 0));
    group.add(box(0.14, 0.06, 0.2, mat(0x8fd0c8), 0.1, 1.36, 0)); // mask
    const arm = new THREE.Group(); arm.position.set(0.12, 1.22, 0.24);
    const fl = cylinder(0.03, 0.24, mat(0x2a2c30, { metalness: 0.6, roughness: 0.4 }), 0.3, 0, 0);
    fl.rotation.z = Math.PI / 2;
    const lens = mat(0x222222, { emissive: 0xffe9a0, emissiveIntensity: 1.5 });
    const lensMesh = cylinder(0.028, 0.01, lens, 0.42, 0, 0);
    lensMesh.rotation.z = Math.PI / 2;
    arm.add(cylinder(0.05, 0.3, scrubs, 0.15, 0, 0).rotateZ(Math.PI / 2), sphere(0.05, skin, 0.3, 0, 0), fl, lensMesh);
    const spot = new THREE.SpotLight(0xfff1c8, 14, CONE_RANGE * U, CONE_HALF, 0.45, 1.6);
    spot.position.set(0.42, 0, 0);
    spot.target.position.set(3, -0.3, 0);
    arm.add(spot, spot.target);
    group.add(arm);
    const tag = nameSprite(p.name, p.col);
    tag.position.set(0, 1.95, 0);
    group.add(tag);
    return { group, spot, lens, legs, arm, sx: p.x * U, sy: p.y * U, sf: p.facing, sp: p.pitch };
  }

  private buildNurse(): MonsterRig {
    const group = new THREE.Group();
    const uniform = mat(0xd6d1c6, { roughness: 0.9 });
    const skin = mat(0xe9e1d6, { roughness: 0.7 });
    const hair = mat(0x141414, { roughness: 1 });
    const eyes = mat(0x050505, { emissive: 0xffffff, emissiveIntensity: 0 });
    const legs: THREE.Object3D[] = [];
    for (const z of [-0.09, 0.09]) {
      const hip = new THREE.Group(); hip.position.set(0, 0.5, z);
      hip.add(cylinder(0.06, 0.5, uniform, 0, -0.25, 0));
      group.add(hip); legs.push(hip);
    }
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.2, 0.5, 4, 10), uniform);
    body.position.y = 0.85; body.castShadow = true;
    group.add(body);
    const stain = sphere(0.09, mat(0x5a0a10, { roughness: 0.4 }), 0.17, 0.8, 0.05);
    stain.scale.set(0.4, 1, 1.2);
    group.add(stain);
    group.add(sphere(0.16, skin, 0.02, 1.42, 0));
    group.add(sphere(0.175, hair, -0.05, 1.45, 0));
    group.add(box(0.18, 0.05, 0.22, mat(0xf4f4f4), 0, 1.6, 0), box(0.02, 0.07, 0.02, mat(0xc01818), 0.09, 1.6, 0), box(0.02, 0.02, 0.07, mat(0xc01818), 0.09, 1.6, 0));
    group.add(sphere(0.022, eyes, 0.16, 1.44, -0.05), sphere(0.022, eyes, 0.16, 1.44, 0.05));
    group.add(box(0.02, 0.02, 0.06, mat(0x7d0d18), 0.17, 1.37, 0));
    const arms: THREE.Group[] = [];
    for (const z of [-0.27, 0.27]) {
      const shoulder = new THREE.Group(); shoulder.position.set(0.05, 1.22, z);
      shoulder.add(cylinder(0.05, 0.55, uniform, 0, -0.275, 0), sphere(0.05, skin, 0, -0.56, 0));
      group.add(shoulder); arms.push(shoulder);
    }
    return { group, kind: 'nurse', arms, legs, eyes, baseAngles: [], sx: 0, sy: 0, sf: 0 };
  }

  private buildLurker(): MonsterRig {
    const group = new THREE.Group();
    const dark = mat(0x15151c, { roughness: 0.55, metalness: 0.25 });
    const body = sphere(0.28, dark, 0, 0.38, 0);
    body.scale.set(1.25, 0.65, 1);
    group.add(body, sphere(0.14, dark, 0.3, 0.42, 0));
    const eyes = mat(0x200000, { emissive: 0xff2020, emissiveIntensity: 2.5 });
    group.add(sphere(0.035, eyes, 0.42, 0.46, -0.07), sphere(0.035, eyes, 0.42, 0.46, 0.07));
    const light = new THREE.PointLight(0xff2020, 1.4, 3, 1.8);
    light.position.set(0.4, 0.45, 0);
    group.add(light);
    const legs: THREE.Object3D[] = [];
    const baseAngles: number[] = [];
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * Math.PI * 2 + Math.PI / 6;
      const leg = new THREE.Group();
      leg.position.y = 0.38;
      leg.rotation.y = a;
      const knee = new THREE.Vector3(0.45, 0.28, 0), foot = new THREE.Vector3(0.75, -0.38, 0);
      leg.add(bone(new THREE.Vector3(0, 0, 0), knee, 0.035, dark), bone(knee, foot, 0.03, dark));
      group.add(leg); legs.push(leg); baseAngles.push(a);
    }
    return { group, kind: 'lurker', arms: [], legs, eyes, light, baseAngles, sx: 0, sy: 0, sf: 0 };
  }

  /** The Orderly: two meters of stained scrubs that never stops walking. Faces local +x. */
  private buildOrderly(): MonsterRig {
    const group = new THREE.Group();
    const scrubs = mat(0x4f6b4a, { roughness: 0.95 });
    const skin = mat(0xb9b0a0, { roughness: 0.8 });
    const legs: THREE.Object3D[] = [];
    for (const z of [-0.17, 0.17]) {
      const hip = new THREE.Group(); hip.position.set(0, 0.8, z);
      hip.add(cylinder(0.11, 0.8, scrubs, 0, -0.4, 0));
      group.add(hip); legs.push(hip);
    }
    const body = new THREE.Mesh(new THREE.CapsuleGeometry(0.42, 0.7, 4, 12), scrubs);
    body.position.y = 1.35; body.castShadow = true;
    group.add(body);
    for (let i = 0; i < 3; i++) { const s = sphere(0.12, mat(0x5a0a10, { roughness: 0.4 }), 0.36, 1.0 + i * 0.25, -0.15 + i * 0.15); s.scale.set(0.35, 1, 1); group.add(s); }
    group.add(sphere(0.2, skin, 0.1, 2.0, 0));
    group.add(box(0.36, 0.05, 0.3, mat(0x2a2f2a), 0.05, 2.19, 0)); // cap
    const eyes = mat(0x000000, { emissive: 0xffe0a0, emissiveIntensity: 0.4 });
    group.add(sphere(0.03, eyes, 0.28, 2.02, -0.07), sphere(0.03, eyes, 0.28, 2.02, 0.07));
    group.add(box(0.05, 0.03, 0.12, mat(0x3a1015), 0.29, 1.9, 0));
    const arms: THREE.Group[] = [];
    for (const z of [-0.55, 0.55]) {
      const shoulder = new THREE.Group(); shoulder.position.set(0.05, 1.75, z);
      shoulder.add(cylinder(0.09, 0.95, scrubs, 0, -0.48, 0), sphere(0.11, skin, 0, -0.98, 0));
      group.add(shoulder); arms.push(shoulder);
    }
    return { group, kind: 'orderly', arms, legs, eyes, baseAngles: [], sx: 0, sy: 0, sf: 0 };
  }

  private animateMonster(m: Monster, rig: MonsterRig, dt: number) {
    rig.group.position.set(rig.sx, 0, rig.sy);
    rig.group.rotation.y = -rig.sf;
    const chasing = m.state === 'chase';
    const stunned = m.state === 'stunned';
    if (m.kind === 'lurker') {
      const alive = !m.frozen && !stunned;
      rig.legs.forEach((leg, i) => {
        const a = rig.baseAngles[i];
        leg.rotation.y = a + (alive && m.moving ? Math.sin(m.anim * 14 + i * 1.3) * 0.28 : 0);
        leg.rotation.z = alive && m.moving ? Math.sin(m.anim * 14 + i * 2.1) * 0.14 : 0;
      });
      rig.group.position.y = alive && m.moving ? Math.abs(Math.sin(m.anim * 14)) * 0.03 : 0;
      if (rig.light) rig.light.intensity = 1.1 + Math.sin(this.t * 9 + m.anim) * 0.4;
      rig.eyes.emissiveIntensity = m.frozen ? 3.5 : 2.5;
      return;
    }
    const rate = m.kind === 'orderly' ? 4.5 : chasing ? 14 : 8;
    if (!rig.legs.length) {
      // Imported model with no rig: a heavy lumbering sway is all the animation it gets for now.
      rig.group.rotation.z = m.moving ? Math.sin(m.anim * rate) * 0.06 : 0;
      rig.group.rotation.x = m.moving ? Math.cos(m.anim * rate * 0.5) * 0.03 : 0;
      rig.group.position.y = m.moving ? Math.abs(Math.sin(m.anim * rate)) * 0.08 : 0;
      return;
    }
    const swing = m.moving ? Math.sin(m.anim * rate) * (m.kind === 'orderly' ? 0.35 : 0.45) : 0;
    rig.legs[0].rotation.z = swing; rig.legs[1].rotation.z = -swing;
    const reach = m.kind === 'orderly' ? (chasing ? 0.9 : 0.15) : chasing ? 1.35 : 0.1;
    for (const arm of rig.arms) arm.rotation.z += (reach - arm.rotation.z) * Math.min(1, dt * 6);
    rig.arms[0].rotation.x = chasing ? Math.sin(m.anim * rate) * 0.15 : swing * 0.5;
    rig.arms[1].rotation.x = chasing ? -Math.sin(m.anim * rate) * 0.15 : -swing * 0.5;
    rig.group.rotation.z = stunned ? Math.sin(m.anim * 6) * 0.18 : 0;
    rig.group.position.y = m.moving ? Math.abs(Math.sin(m.anim * rate)) * (m.kind === 'orderly' ? 0.06 : 0.03) : 0;
    rig.eyes.emissiveIntensity = m.kind === 'nurse' ? (chasing ? 1.6 : 0) : 0.4;
  }
}

export type { Vec };
