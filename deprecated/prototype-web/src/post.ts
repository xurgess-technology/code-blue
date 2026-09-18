// Post-processing: bloom on lights and monitors, then a single grade pass with film grain,
// vignette, chromatic aberration at the edges, and a sickly green tint in the shadows.
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

const GradeShader = {
  uniforms: {
    tDiffuse: { value: null },
    time: { value: 0 },
    grain: { value: 0.07 },
    vignette: { value: 0.55 },
    aberration: { value: 0.0025 },
    hurt: { value: 0 },
    tint: { value: new THREE.Vector3(0.9, 1.0, 0.92) },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;
    void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    uniform float time, grain, vignette, aberration, hurt;
    uniform vec3 tint;
    varying vec2 vUv;
    float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233)) + time * 61.0) * 43758.5453); }
    void main() {
      vec2 c = vUv - 0.5;
      float r2 = dot(c, c);
      vec2 dir = c * (aberration * (1.0 + r2 * 6.0));
      vec3 col;
      col.r = texture2D(tDiffuse, vUv + dir).r;
      col.g = texture2D(tDiffuse, vUv).g;
      col.b = texture2D(tDiffuse, vUv - dir).b;
      // shadows lean green, highlights stay warm
      float lum = dot(col, vec3(0.299, 0.587, 0.114));
      col = mix(col * tint, col, smoothstep(0.15, 0.7, lum));
      col += (hash(vUv) - 0.5) * grain * (1.0 - lum * 0.6);
      float v = 1.0 - smoothstep(0.25, 1.1, r2 * 2.2) * vignette;
      col *= v;
      col = mix(col, vec3(0.55, 0.02, 0.02), hurt * smoothstep(0.05, 0.6, r2) * 0.8);
      gl_FragColor = vec4(col, 1.0);
    }`,
};

export class Post {
  composer: EffectComposer;
  private grade: ShaderPass;
  private bloom: UnrealBloomPass;

  constructor(renderer: THREE.WebGLRenderer, scene: THREE.Scene, camera: THREE.Camera) {
    this.composer = new EffectComposer(renderer);
    this.composer.addPass(new RenderPass(scene, camera));
    this.bloom = new UnrealBloomPass(new THREE.Vector2(1, 1), 0.45, 0.5, 0.82);
    this.composer.addPass(this.bloom);
    this.grade = new ShaderPass(GradeShader);
    this.composer.addPass(this.grade);
    this.composer.addPass(new OutputPass());
  }

  resize(w: number, h: number, pixelRatio: number) {
    this.composer.setPixelRatio(pixelRatio);
    this.composer.setSize(w, h);
    this.bloom.setSize(w, h);
  }

  render(time: number, hurt: number) {
    this.grade.uniforms.time.value = time;
    this.grade.uniforms.hurt.value = hurt;
    this.composer.render();
  }
}
