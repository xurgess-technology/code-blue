'use strict';
/**
 * Preload: the only bridge between the renderer and the Electron main process.
 * Everything here is reachable in the game as `window.desktop`. In a plain
 * browser `window.desktop` is undefined, so the game can feature-detect with
 * `if (window.desktop?.isDesktop) ...`.
 */

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('desktop', {
  isDesktop: true,

  /** Start the co-op relay in the main process. Resolves { port, addresses: string[] }. */
  startRelay: (port) => ipcRenderer.invoke('desktop:startRelay', port),

  /** Stop the relay if one is running. */
  stopRelay: () => ipcRenderer.invoke('desktop:stopRelay'),

  /** This machine's non-internal IPv4 addresses, for showing "join at ws://x.x.x.x:port". */
  getAddresses: () => ipcRenderer.invoke('desktop:getAddresses'),

  toggleFullscreen: () => ipcRenderer.invoke('desktop:toggleFullscreen'),

  quit: () => ipcRenderer.invoke('desktop:quit'),
});
