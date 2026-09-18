// Optional real assets: .glb models and PBR texture sets described by manifests in public/.
// Everything degrades to the procedural placeholders when a manifest or file is missing.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { clone as skeletonClone } from 'three/addons/utils/SkeletonUtils.js';

export interface ModelDef {
  file: string;
  role: 'monster' | 'player' | 'prop' | 'patient';
  height: number;
  animations?: Record<string, string>;
  forward?: '+x' | '-x' | '+z' | '-z';
  footprint?: [number, number];
}
export interface TextureSetDef { dir: string; maps: string[]; repeatPerTile: number }

export interface LoadedModel {
  /** Normalized template: scaled to `height`, feet at y=0, centered on x/z, facing local +x. Clone it, never add it directly. */
  template: THREE.Group;
  clips: THREE.AnimationClip[];
  def: ModelDef;
  skinned: boolean;
}

export interface AnimRig {
  root: THREE.Group;
  mixer: THREE.AnimationMixer;
  actions: Map<string, THREE.AnimationAction>;
  current: string;
}

const FORWARD_ROT: Record<string, number> = { '+x': 0, '-x': Math.PI, '+z': Math.PI / 2, '-z': -Math.PI / 2 };

export class Assets {
  models: Record<string, ModelDef> = {};
  textures: Record<string, TextureSetDef> = {};
  private modelCache = new Map<string, Promise<LoadedModel | null>>();
  private texCache = new Map<string, THREE.Texture>();
  private loader = new GLTFLoader();
  private texLoader = new THREE.TextureLoader();
  ready: Promise<void>;

  constructor() {
    this.ready = Promise.all([
      fetch('models/manifest.json').then((r) => (r.ok ? r.json() : null)).then((j) => { if (j?.models) this.models = j.models; }).catch(() => undefined),
      fetch('textures/manifest.json').then((r) => (r.ok ? r.json() : null)).then((j) => { if (j?.sets) this.textures = j.sets; }).catch(() => undefined),
    ]).then(() => undefined);
  }

  has(key: string) { return !!this.models[key]; }

  loadModel(key: string): Promise<LoadedModel | null> {
    let p = this.modelCache.get(key);
    if (p) return p;
    const def = this.models[key];
    if (!def) return Promise.resolve(null);
    p = this.loader.loadAsync(def.file).then((gltf) => {
      const root = gltf.scene;
      let skinned = false;
      root.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) {
          m.castShadow = true; m.receiveShadow = true;
          if ((m as THREE.SkinnedMesh).isSkinnedMesh) skinned = true;
          m.frustumCulled = !skinned;
        }
      });
      // Normalize: measure in the rest pose, scale to the wanted height, ground and center, turn to face +x.
      const box = new THREE.Box3().setFromObject(root);
      const size = new THREE.Vector3(); box.getSize(size);
      const s = def.height / Math.max(size.y, 1e-3);
      root.scale.setScalar(s);
      root.position.set(-((box.min.x + box.max.x) / 2) * s, -box.min.y * s, -((box.min.z + box.max.z) / 2) * s);
      const turn = new THREE.Group();
      turn.rotation.y = FORWARD_ROT[def.forward ?? '+z'] ?? 0;
      turn.add(root);
      const template = new THREE.Group();
      template.add(turn);
      return { template, clips: gltf.animations, def, skinned };
    }).catch((e) => { console.warn(`Model ${key} failed to load`, e); return null; });
    this.modelCache.set(key, p);
    return p;
  }

  /** A fresh instance with its own animation mixer. */
  instantiate(m: LoadedModel): AnimRig {
    const root = (m.skinned ? skeletonClone(m.template) : m.template.clone()) as THREE.Group;
    const mixer = new THREE.AnimationMixer(root);
    const actions = new Map<string, THREE.AnimationAction>();
    const roles = m.def.animations ?? {};
    for (const [role, clipName] of Object.entries(roles)) {
      const clip = m.clips.find((c) => c.name === clipName) ?? m.clips.find((c) => c.name.toLowerCase().includes(clipName.toLowerCase()));
      if (clip) actions.set(role, mixer.clipAction(clip));
    }
    return { root, mixer, actions, current: '' };
  }

  /** Cross-fade to a clip role; falls back through the given alternatives. */
  play(rig: AnimRig, role: string, fallbacks: string[] = [], fade = 0.25, loopOnce = false) {
    const pick = [role, ...fallbacks].find((r) => rig.actions.has(r));
    if (!pick || pick === rig.current) return;
    const next = rig.actions.get(pick)!;
    const prev = rig.actions.get(rig.current);
    next.reset();
    next.setLoop(loopOnce ? THREE.LoopOnce : THREE.LoopRepeat, Infinity);
    next.clampWhenFinished = loopOnce;
    next.enabled = true;
    if (prev) { next.crossFadeFrom(prev, fade, true); } else { next.fadeIn(fade); }
    next.play();
    rig.current = pick;
  }

  hasTextures(key: string) { return !!this.textures[key]; }

  /** PBR maps for a set, or null when the manifest lacks it. Repeat is in texture tiles across (repeatX, repeatY). */
  textureSet(key: string, repeatX: number, repeatY: number): { map: THREE.Texture; normalMap?: THREE.Texture; roughnessMap?: THREE.Texture; aoMap?: THREE.Texture } | null {
    const def = this.textures[key];
    if (!def) return null;
    const get = (name: string, srgb: boolean) => {
      const url = `${def.dir}/${name}.jpg`;
      const id = `${url}|${repeatX.toFixed(3)}|${repeatY.toFixed(3)}`;
      let t = this.texCache.get(id);
      if (!t) {
        t = this.texLoader.load(url);
        t.wrapS = t.wrapT = THREE.RepeatWrapping;
        t.repeat.set(repeatX * def.repeatPerTile, repeatY * def.repeatPerTile);
        t.anisotropy = 8;
        if (srgb) t.colorSpace = THREE.SRGBColorSpace;
        this.texCache.set(id, t);
      }
      return t;
    };
    const out: { map: THREE.Texture; normalMap?: THREE.Texture; roughnessMap?: THREE.Texture; aoMap?: THREE.Texture } = { map: get('color', true) };
    if (def.maps.includes('normal')) out.normalMap = get('normal', false);
    if (def.maps.includes('roughness')) out.roughnessMap = get('roughness', false);
    if (def.maps.includes('ao')) out.aoMap = get('ao', false);
    return out;
  }
}
