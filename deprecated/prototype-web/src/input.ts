export class Input {
  keys = new Set<string>();
  pressed = new Set<string>();
  anyKey = false;
  clicked = false;
  /** Pointer lock state. Mouse look uses raw movement deltas, so it works even without lock as a fallback. */
  locked = false;
  lockEverAcquired = false;
  private lookDX = 0;
  private lookDY = 0;

  constructor(private target: HTMLElement) {
    window.addEventListener('keydown', (e) => {
      if (['Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(e.code)) e.preventDefault();
      if (!e.repeat) { this.pressed.add(e.code); this.anyKey = true; }
      this.keys.add(e.code);
    });
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.keys.clear());
    document.addEventListener('mousemove', (e) => {
      this.lookDX += e.movementX;
      this.lookDY += e.movementY;
    });
    window.addEventListener('mousedown', () => {
      this.clicked = true;
      this.anyKey = true;
      if (!this.locked) this.requestLock();
    });
    window.addEventListener('contextmenu', (e) => e.preventDefault());
    document.addEventListener('pointerlockchange', () => {
      this.locked = document.pointerLockElement === this.target;
      if (this.locked) this.lockEverAcquired = true;
    });
  }

  private requestLock() {
    // Pointer lock can be refused (embedded browsers, iframes). Raw mouse deltas still drive the camera then.
    const el = this.target as HTMLElement & { requestPointerLock(opts?: { unadjustedMovement?: boolean }): Promise<void> | void };
    const attempt = (opts?: { unadjustedMovement?: boolean }): Promise<void> => {
      try {
        const r = opts ? el.requestPointerLock(opts) : el.requestPointerLock();
        return r && typeof (r as Promise<void>).then === 'function' ? (r as Promise<void>) : Promise.resolve();
      } catch (e) { return Promise.reject(e); }
    };
    attempt({ unadjustedMovement: true }).catch(() => attempt()).catch(() => { /* unsupported here */ });
  }

  down(code: string) { return this.keys.has(code); }
  justPressed(code: string) { return this.pressed.has(code); }
  /** Mouse movement since the last call, clamped so a lock transition cannot whip the camera around. */
  takeLook(): { dx: number; dy: number } {
    const dx = Math.max(-300, Math.min(300, this.lookDX)), dy = Math.max(-300, Math.min(300, this.lookDY));
    this.lookDX = 0; this.lookDY = 0;
    return { dx, dy };
  }
  endFrame() { this.pressed.clear(); this.anyKey = false; this.clicked = false; }
}
