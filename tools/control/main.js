// VIctory control app: a window over scripts/harness.ps1.
//
// It runs harness commands (run, record, snapshot, restore), streams their
// output, and follows the run's event stream (events.jsonl, written by the
// layer with VICTORY_EVENTS) and its log for errors, live. Everything the
// harness keeps (presets, snapshots, results) stays in
// %LOCALAPPDATA%\victory\harness; this app only reads it.

'use strict';

const { app, BrowserWindow, ipcMain, shell } = require('electron');
const { spawn, execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '..', '..');
const harnessScript = path.join(repo, 'scripts', 'harness.ps1');
const scenarioDir = path.join(repo, 'scenarios');
const harnessDir = path.join(process.env.LOCALAPPDATA || '', 'victory', 'harness');

let win = null;
let job = null; // the running harness command
let tails = []; // file followers of the current run
let runDir = null; // the current run's result folder

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function readJson(file) {
  try {
    // result.json is written by Windows PowerShell with a BOM.
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
  } catch {
    return null;
  }
}

function listNames(dir, test) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter(test).map((d) => d.name);
  } catch {
    return [];
  }
}

function state() {
  const scenarios = listNames(scenarioDir, (d) => d.isFile() && d.name.endsWith('.json')).map((f) => ({
    name: f.replace(/\.json$/, ''),
    ...(readJson(path.join(scenarioDir, f)) || {}),
  }));
  const presets = listNames(path.join(harnessDir, 'presets'), (d) => d.name.endsWith('.json')).map((f) =>
    f.replace(/\.json$/, '')
  );
  const snapshots = listNames(path.join(harnessDir, 'snapshots'), (d) => d.isDirectory());
  const results = listNames(path.join(harnessDir, 'results'), (d) => d.isDirectory())
    .sort()
    .reverse()
    .slice(0, 40)
    .map((dir) => ({ dir, result: readJson(path.join(harnessDir, 'results', dir, 'result.json')) }));
  return { repo, harnessDir, scenarios, presets, snapshots, results, running: !!job };
}

// Follows a growing text file, sending each complete new line to `onLine`.
function follow(file, onLine) {
  let offset = 0;
  let rest = '';
  const timer = setInterval(() => {
    fs.stat(file, (err, st) => {
      if (err || st.size <= offset) return;
      const stream = fs.createReadStream(file, { start: offset, end: st.size - 1, encoding: 'utf8' });
      offset = st.size;
      stream.on('data', (chunk) => {
        const lines = (rest + chunk).split(/\r?\n/);
        rest = lines.pop();
        for (const line of lines) if (line) onLine(line);
      });
    });
  }, 500);
  return () => clearInterval(timer);
}

function stopTails() {
  tails.forEach((stop) => stop());
  tails = [];
}

// The run's result folder is announced by the harness ("scenario <name> -> <dir>").
function watchRun(dir) {
  stopTails();
  runDir = dir;
  send('run-dir', dir);
  tails.push(
    follow(path.join(dir, 'events.jsonl'), (line) => {
      try {
        send('event', JSON.parse(line));
      } catch {
        /* a line still being written */
      }
    })
  );
  tails.push(
    follow(path.join(dir, 'run.log'), (line) => {
      // eslint-disable-next-line no-control-regex
      const text = line.replace(/\x1b\[[0-9;]*m/g, '');
      if (/ (ERROR|WARN) |unhandled exception|device removed|VIctory:/.test(text)) send('log', text);
    })
  );
}

function runHarness(args) {
  if (job) return { error: 'a harness command is already running' };
  const ps = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', harnessScript, ...args], {
    cwd: repo,
    windowsHide: true,
  });
  job = ps;
  send('job', { running: true, args });
  const onData = (data) => {
    for (const line of data.toString().split(/\r?\n/)) {
      if (!line) continue;
      send('output', line);
      const m = line.match(/^scenario\s+\S+\s+->\s+(.+)$/);
      if (m) watchRun(m[1].trim());
    }
  };
  ps.stdout.on('data', onData);
  ps.stderr.on('data', onData);
  ps.on('close', (code) => {
    job = null;
    // Let the followers read the last lines, then stop them.
    setTimeout(stopTails, 1500);
    send('job', { running: false, code });
    send('state', state());
  });
  return { ok: true };
}

ipcMain.handle('state', () => state());
ipcMain.handle('harness', (_e, args) => runHarness(args));
// Live input: one command line appended to the run's control file, which the
// layer reads (VICTORY_CONTROL): "press <key> [ms]", "down <key>", "up <key>".
const KEY = /^(Enter|Esc|Tab|Back|Up|Down|Left|Right|[A-Za-z0-9])$/;
ipcMain.handle('control', (_e, verb, key, ms) => {
  if (!job || !runDir) return { error: 'no run to control' };
  if (!['press', 'down', 'up'].includes(verb) || !KEY.test(key)) return { error: `bad command ${verb} ${key}` };
  const line = verb === 'press' && ms ? `${verb} ${key} ${Math.round(ms)}\n` : `${verb} ${key}\n`;
  fs.appendFileSync(path.join(runDir, 'control.txt'), line);
  return { ok: true };
});

ipcMain.handle('stop-title', () => {
  return new Promise((resolve) => {
    execFile('taskkill', ['/IM', 'victory.exe', '/F'], (err) => resolve({ ok: !err }));
  });
});
ipcMain.handle('open', (_e, which) => {
  const target = which === 'harness' ? harnessDir : path.join(harnessDir, 'results', which);
  return shell.openPath(target);
});

app.whenReady().then(() => {
  win = new BrowserWindow({
    width: 1280,
    height: 860,
    title: 'VIctory control',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
});

app.on('window-all-closed', () => app.quit());
