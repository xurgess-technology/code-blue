'use strict';
/**
 * Electron main process for Malpractice.
 *
 *   electron . --dev      load the Vite dev server (http://localhost:5173 or $VITE_DEV_SERVER_URL)
 *   electron .            load the built renderer from dist/index.html
 *   electron . --smoke    load the same target, print "SMOKE OK" / a failure reason, and exit
 *
 * The renderer talks to this process only through the `window.desktop` bridge
 * defined in preload.cjs (contextIsolation on, nodeIntegration off).
 */

const path = require('node:path');
const { app, BrowserWindow, ipcMain } = require('electron');
const { createRelay, lanAddresses } = require('../server/relay.cjs');

// Let the game play audio immediately (menus, ambience) without a click first.
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

// NOTE (Steam): when the Steam overlay is wired up later, Chromium's
// multi-process GPU compositing hides the overlay. It needs these switches,
// which we deliberately do NOT enable yet because they cost some rendering
// performance and are only useful once steamworks is integrated:
//   app.commandLine.appendSwitch('in-process-gpu');
//   app.commandLine.appendSwitch('disable-direct-composition');

const args = process.argv.slice(1);
const IS_SMOKE = args.includes('--smoke');
const DEV_URL = process.env.VITE_DEV_SERVER_URL || (args.includes('--dev') ? 'http://localhost:5173' : '');
const SMOKE_TIMEOUT_MS = 20_000;
const SMOKE_GRACE_MS = 1000; // after did-finish-load, give a crashing renderer a moment to report

/** @type {BrowserWindow | null} */
let mainWindow = null;
/** @type {{ port: number, close: () => Promise<void> } | null} */
let relay = null;

function loadTarget(win) {
  if (DEV_URL) return win.loadURL(DEV_URL);
  return win.loadFile(path.join(app.getAppPath(), 'dist', 'index.html'));
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 720,
    autoHideMenuBar: true,
    backgroundColor: '#000000',
    title: 'Malpractice',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  mainWindow = win;
  win.on('closed', () => {
    if (mainWindow === win) mainWindow = null;
  });

  // F11 toggles fullscreen (window-local; a global shortcut would steal F11 from other apps).
  win.webContents.on('before-input-event', (event, input) => {
    if (input.type === 'keyDown' && input.key === 'F11') {
      event.preventDefault();
      win.setFullScreen(!win.isFullScreen());
    }
  });

  // The game never opens popups; refuse anything that tries.
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));

  if (IS_SMOKE) installSmokeProbe(win);
  loadTarget(win);
  return win;
}

function installSmokeProbe(win) {
  const target = DEV_URL || `dist/index.html (app path ${app.getAppPath()})`;
  console.log(`[smoke] loading ${target}`);
  let settled = false;
  const finish = (code, line) => {
    if (settled) return;
    settled = true;
    console[code === 0 ? 'log' : 'error'](line);
    app.exit(code);
  };
  const timeout = setTimeout(() => finish(1, `SMOKE FAIL: timed out after ${SMOKE_TIMEOUT_MS / 1000} s`), SMOKE_TIMEOUT_MS);

  const wc = win.webContents;
  // Surface renderer warnings/errors (e.g. a failed module import) so a bad build is diagnosable
  // from the console alone. Electron >= 32 delivers the details on the event object.
  wc.on('console-message', (event) => {
    if (event.level === 'error' || event.level === 'warning') {
      console.log(`[smoke] renderer ${event.level}: ${event.message} (${event.sourceId}:${event.lineNumber})`);
    }
  });
  wc.on('did-fail-load', (_e, code, desc, url, isMainFrame) => {
    if (!isMainFrame || code === -3 /* ERR_ABORTED: a redirect or replaced navigation */) return;
    clearTimeout(timeout);
    finish(1, `SMOKE FAIL: did-fail-load ${code} ${desc} ${url}`);
  });
  wc.on('render-process-gone', (_e, details) => {
    clearTimeout(timeout);
    finish(1, `SMOKE FAIL: render-process-gone reason=${details.reason} exitCode=${details.exitCode}`);
  });
  wc.on('did-finish-load', () => {
    clearTimeout(timeout);
    setTimeout(() => finish(0, 'SMOKE OK'), SMOKE_GRACE_MS);
  });
}

// ---- IPC: window.desktop.* --------------------------------------------------

ipcMain.handle('desktop:startRelay', async (_event, port) => {
  const wanted = Number.isInteger(port) && port >= 0 && port < 65536 ? port : 7777;
  if (relay && (wanted === 0 || relay.port === wanted)) {
    return { port: relay.port, addresses: lanAddresses() };
  }
  if (relay) {
    const old = relay;
    relay = null;
    await old.close();
  }
  relay = await createRelay({ port: wanted, host: '0.0.0.0', log: (line) => console.log(`[relay] ${line}`) });
  console.log(`[relay] listening on 0.0.0.0:${relay.port}`);
  return { port: relay.port, addresses: lanAddresses() };
});

ipcMain.handle('desktop:stopRelay', async () => {
  if (!relay) return;
  const old = relay;
  relay = null;
  await old.close();
  console.log('[relay] stopped');
});

ipcMain.handle('desktop:getAddresses', () => lanAddresses());

ipcMain.handle('desktop:toggleFullscreen', (event) => {
  const win = BrowserWindow.fromWebContents(event.sender) || mainWindow;
  if (win) win.setFullScreen(!win.isFullScreen());
});

ipcMain.handle('desktop:quit', () => {
  app.quit();
});

// ---- lifecycle --------------------------------------------------------------

app.whenReady().then(createWindow);

app.on('window-all-closed', () => app.quit());

app.on('will-quit', (event) => {
  if (!relay) return;
  event.preventDefault();
  const old = relay;
  relay = null;
  old.close().finally(() => app.quit());
});
