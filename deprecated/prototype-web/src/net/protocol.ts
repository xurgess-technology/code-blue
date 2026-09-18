// Wire format between host and clients. The host owns the world; each player owns their own body.
import type { ToolKind } from '../patients';

export type Phase = 'menu' | 'lobby' | 'shift' | 'won' | 'lost';

/** What a client reports about its own surgeon, 20 times a second. */
export interface PlayerState {
  x: number; y: number;
  f: number;   // facing
  p: number;   // pitch
  fl: boolean; // flashlight on
  sp: boolean; // sprinting
  mv: boolean; // moving
  op: boolean; // operating (E held at the table)
  ia: boolean; // interact held (E)
  sh: number;  // shove counter, increments per shove press so the host can detect each one
  dr: number;  // drop counter, same idea for G
}

export interface PlayerSnap {
  id: number; name: string; col: number;
  x: number; y: number; f: number; p: number;
  fl: boolean; sp: boolean; mv: boolean; op: boolean;
  hp: number; alive: boolean; inv: boolean;
  carried: number[]; // tool ids
}

export interface MonsterSnap {
  id: number; kind: string; x: number; y: number; f: number;
  st: string; fz: boolean; mv: boolean;
}

export interface ToolSnap {
  id: number; kind: ToolKind; x: number; y: number;
  st: 'floor' | 'carried' | 'delivered'; car: number;
}

export type GameEvent =
  | { type: 'sound'; name: string; x?: number; y?: number }
  | { type: 'hit'; player: number; kx: number; ky: number; hp: number }
  | { type: 'shoved'; player: number; kx: number; ky: number; by: string }
  | { type: 'respawn'; player: number; x: number; y: number }
  | { type: 'msg'; text: string; secs: number };

export interface Snapshot {
  tick: number;
  time: number;
  phase: Phase;
  shift: number;
  seed: number;
  vit: number;      // patient vitals 0..100
  pat: number;      // patient index, -1 when none
  step: number;     // current surgery step index
  prog: number;     // progress of the current step 0..1
  punch: number;    // time clock hold progress 0..1
  pod: number;      // revival pod hold progress 0..1
  endT: number;     // seconds left on the won/lost screen
  players: PlayerSnap[];
  monsters: MonsterSnap[];
  tools: ToolSnap[];
  events: GameEvent[];
}

export type ClientMsg = { t: 'state'; s: PlayerState };
export type HostMsg =
  | { t: 'welcome'; id: number; seed: number; shift: number; phase: Phase }
  | { t: 'snap'; snap: Snapshot };
