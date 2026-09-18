// Patients and their procedures. Only the tools a patient needs are spawned for a shift.

export const TOOL_KINDS = ['Scalpel', 'Forceps', 'Clamp', 'Retractor', 'Sutures', 'Bone Saw', 'Anesthetic'] as const;
export type ToolKind = (typeof TOOL_KINDS)[number];

export interface SurgeryStep {
  label: string;
  tool: ToolKind;
  /** Seconds of in-zone holding needed by one surgeon. */
  duration: number;
  /** Half-width of the steady-hand zone on the -1..1 marker bar at shift 1. */
  zone: number;
  /** Marker sway speed in radians per second at shift 1. */
  speed: number;
}

export interface PatientDef {
  name: string;
  blurb: string;
  body: 'human' | 'wolf' | 'elephant' | 'ghost';
  steps: SurgeryStep[];
}

export const PATIENTS: PatientDef[] = [
  {
    name: 'Gary Pruitt, 44',
    blurb: 'Ate a stop sign. All of it.',
    body: 'human',
    steps: [
      { label: 'Open him up', tool: 'Retractor', duration: 7, zone: 0.42, speed: 1.6 },
      { label: 'Extract the stop sign', tool: 'Forceps', duration: 9, zone: 0.32, speed: 2.2 },
      { label: 'Close', tool: 'Sutures', duration: 6, zone: 0.4, speed: 1.8 },
    ],
  },
  {
    name: 'Unregistered werewolf',
    blurb: 'Silver bullet, left shoulder. The moon is at 80%.',
    body: 'wolf',
    steps: [
      { label: 'Sedate before the moon', tool: 'Anesthetic', duration: 5, zone: 0.45, speed: 1.4 },
      { label: 'Incision', tool: 'Scalpel', duration: 7, zone: 0.35, speed: 2.0 },
      { label: 'Dig out the bullet', tool: 'Forceps', duration: 9, zone: 0.28, speed: 2.4 },
      { label: 'Stitch the fur', tool: 'Sutures', duration: 6, zone: 0.4, speed: 1.8 },
    ],
  },
  {
    name: 'Bartholomew (elephant)',
    blurb: 'Swallowed a tricycle. Do not ask.',
    body: 'elephant',
    steps: [
      { label: 'Sedate (double dose)', tool: 'Anesthetic', duration: 6, zone: 0.45, speed: 1.5 },
      { label: 'Cut through the hide', tool: 'Bone Saw', duration: 10, zone: 0.35, speed: 1.6 },
      { label: 'Clamp the big vein', tool: 'Clamp', duration: 6, zone: 0.3, speed: 2.2 },
      { label: 'Retrieve the tricycle', tool: 'Retractor', duration: 9, zone: 0.3, speed: 2.0 },
    ],
  },
  {
    name: 'Patient 0 (ghost)',
    blurb: 'Ruptured appendix. It keeps phasing through the table.',
    body: 'ghost',
    steps: [
      { label: 'Pin it down', tool: 'Clamp', duration: 7, zone: 0.3, speed: 2.6 },
      { label: 'Incision on the count of three', tool: 'Scalpel', duration: 8, zone: 0.28, speed: 2.4 },
      { label: 'Close whatever that was', tool: 'Sutures', duration: 6, zone: 0.4, speed: 1.6 },
    ],
  },
];

/** Unique tools a patient needs, in procedure order. */
export function toolsFor(p: PatientDef): ToolKind[] {
  const out: ToolKind[] = [];
  for (const s of p.steps) if (!out.includes(s.tool)) out.push(s.tool);
  return out;
}

/** Difficulty scaling for a step on a given shift (1-based). */
export function scaledStep(step: SurgeryStep, shift: number): SurgeryStep {
  const k = Math.max(0, shift - 1);
  return {
    ...step,
    // A little wider than authored: the marker is only inside the zone a fraction of the time,
    // so one surgeon alone finishes a shift-1 procedure in roughly a minute of holding.
    zone: Math.max(0.14, (step.zone + 0.08) * Math.pow(0.9, k)),
    speed: step.speed * (1 + 0.07 * k),
  };
}
