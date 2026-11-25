'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('victory', {
  state: () => ipcRenderer.invoke('state'),
  harness: (args) => ipcRenderer.invoke('harness', args),
  stopTitle: () => ipcRenderer.invoke('stop-title'),
  open: (which) => ipcRenderer.invoke('open', which),
  on: (channel, handler) => {
    const allowed = ['output', 'event', 'log', 'job', 'state', 'run-dir'];
    if (allowed.includes(channel)) ipcRenderer.on(channel, (_e, payload) => handler(payload));
  },
});
