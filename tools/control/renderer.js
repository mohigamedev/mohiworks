'use strict';

const $ = (id) => document.getElementById(id);
let current = { scenarios: [], presets: [], snapshots: [], results: [] };
let frames = []; // { t, ms } of the current run
let reachedWorld = false;

function option(value, text) {
  const o = document.createElement('option');
  o.value = value;
  o.textContent = text;
  return o;
}

function fill(select, values, blank) {
  const keep = select.value;
  select.replaceChildren();
  if (blank) select.append(option('', blank));
  values.forEach((v) => select.append(option(v, v)));
  if ([...select.options].some((o) => o.value === keep)) select.value = keep;
}

function fmt(v, digits = 0) {
  return v == null || Number.isNaN(v) ? '–' : Number(v).toFixed(digits);
}

function render(state) {
  current = state;
  fill($('scenario'), state.scenarios.map((s) => s.name));
  fill($('rec-snapshot'), state.snapshots, '(current data)');
  fill($('rec-preset'), state.presets, '(no preset)');
  showScenario();
  const body = $('results');
  body.replaceChildren();
  for (const { dir, result } of state.results) {
    const tr = document.createElement('tr');
    tr.className = 'clickable';
    tr.title = 'Open the result folder';
    tr.onclick = () => window.victory.open(dir);
    const r = result && result.result;
    const cells = [
      dir.slice(0, 15).replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/, '$1-$2-$3 $4:$5:$6'),
      result ? result.scenario : dir,
      result ? (result.passed ? 'PASS' : 'FAIL') : '…',
      r ? fmt(r.WorldMedianMs) : '–',
      r ? fmt(r.WorldDropped) : '–',
      r ? `${fmt(r.PeakCommitMB)} MB` : '–',
      r && r.HardFaults ? fmt(r.HardFaults.Median) : '–',
    ];
    cells.forEach((c, i) => {
      const td = document.createElement('td');
      td.textContent = c;
      if (i === 2 && result) td.className = result.passed ? 'pass' : 'fail';
      tr.append(td);
    });
    body.append(tr);
  }
}

function showScenario() {
  const s = current.scenarios.find((x) => x.name === $('scenario').value);
  $('scenario-info').textContent = s
    ? `${s.description || ''} ${s.seconds} s` +
      (s.snapshot ? ` · snapshot ${s.snapshot}` : '') +
      (s.preset ? ` · preset ${s.preset}` : '')
    : '';
}

function setPhase(text, cls) {
  const b = $('phase');
  b.textContent = text;
  b.className = `badge ${cls || ''}`;
}

function resetRun() {
  frames = [];
  reachedWorld = false;
  $('inputs').replaceChildren();
  $('logs').replaceChildren();
  ['t-ms', 't-fps', 't-dropped', 't-making', 't-commit', 't-ram'].forEach((id) => ($(id).textContent = '–'));
  setPhase('starting', 'running');
  draw();
}

function push(list, text, max = 300) {
  const li = document.createElement('li');
  li.textContent = text;
  list.append(li);
  while (list.children.length > max) list.firstChild.remove();
  list.scrollTop = list.scrollHeight;
}

function onEvent(e) {
  switch (e.kind) {
    case 'adapter':
      $('adapter').textContent = e.name;
      break;
    case 'display':
      push($('logs'), `display mode reported: ${e.width}x${e.height}`);
      break;
    case 'input':
      if (e.down) push($('inputs'), `${fmt(e.it, 1)} s  ${e.device}  ${e.name}`);
      break;
    case 'frame': {
      frames.push({ t: e.t, ms: e.ms });
      $('t-ms').textContent = `${fmt(e.ms)} ms`;
      $('t-fps').textContent = fmt(e.fps, 1);
      $('t-dropped').textContent = fmt(e.dropped);
      $('t-making').textContent = fmt(e.making);
      // Menus draw under 50 a frame; the world hundreds.
      if (e.draws > 300) {
        reachedWorld = true;
        setPhase('world', 'world');
      } else if (e.dropped > 0 || e.making > 0) setPhase('loading', 'loading');
      else setPhase(reachedWorld ? 'world (quiet frame)' : 'menus', reachedWorld ? 'world' : 'running');
      draw();
      break;
    }
    case 'memory':
      $('t-commit').textContent = `${fmt(e.committed_mb / 1024, 1)} GB`;
      $('t-ram').textContent = `${fmt(e.ram_free_mb / 1024, 1)} GB`;
      break;
    case 'removed':
      setPhase('device removed', 'error');
      push($('logs'), `GPU device removed: ${e.reason}`);
      break;
    default:
      break;
  }
}

function draw() {
  const c = $('chart');
  const w = (c.width = c.clientWidth * devicePixelRatio);
  const h = (c.height = 160 * devicePixelRatio);
  const g = c.getContext('2d');
  g.clearRect(0, 0, w, h);
  const css = getComputedStyle(document.documentElement);
  g.strokeStyle = css.getPropertyValue('--line');
  g.fillStyle = css.getPropertyValue('--muted');
  g.font = `${11 * devicePixelRatio}px Segoe UI`;
  const max = Math.max(100, ...frames.map((f) => f.ms));
  for (const level of [33.3, 100, 500, 1000, 2000].filter((l) => l <= max)) {
    const y = h - (level / max) * (h - 10);
    g.beginPath();
    g.moveTo(0, y);
    g.lineTo(w, y);
    g.stroke();
    g.fillText(`${level} ms`, 4, y - 3);
  }
  if (frames.length < 2) return;
  const t0 = frames[0].t;
  const span = Math.max(1, frames[frames.length - 1].t - t0);
  g.strokeStyle = css.getPropertyValue('--chart');
  g.lineWidth = 2 * devicePixelRatio;
  g.beginPath();
  frames.forEach((f, i) => {
    const x = ((f.t - t0) / span) * (w - 8) + 4;
    const y = h - (f.ms / max) * (h - 10);
    if (i) g.lineTo(x, y);
    else g.moveTo(x, y);
  });
  g.stroke();
}

async function harness(args) {
  const r = await window.victory.harness(args);
  if (r && r.error) push($('logs'), r.error);
}

window.victory.on('output', (line) => {
  const o = $('output');
  o.textContent += `${line}\n`;
  o.scrollTop = o.scrollHeight;
});
window.victory.on('run-dir', () => resetRun());
window.victory.on('event', onEvent);
window.victory.on('log', (line) => {
  push($('logs'), line.replace(/^\S+Z\s+/, ''));
  if (/unhandled exception/.test(line)) setPhase('crashed', 'error');
});
window.victory.on('job', (j) => {
  const b = $('job');
  b.textContent = j.running ? `running: ${j.args.join(' ')}` : `idle (last exit ${j.code})`;
  b.className = `badge ${j.running ? 'running' : 'idle'}`;
  ['run', 'run-all', 'record', 'snapshot', 'restore'].forEach((id) => ($(id).disabled = j.running));
});
window.victory.on('state', render);

$('scenario').onchange = showScenario;
$('refresh').onclick = async () => render(await window.victory.state());
$('open-harness').onclick = () => window.victory.open('harness');
$('run').onclick = () => harness(['run', $('scenario').value]);
$('run-all').onclick = () => harness(['run-all']);
$('stop').onclick = () => window.victory.stopTitle();
$('snapshot').onclick = () => {
  const name = $('snap-name').value.trim();
  if (name) harness(['snapshot', name]);
};
$('restore').onclick = () => harness(['restore']);
$('record').onclick = () => {
  const name = $('rec-name').value.trim();
  if (!/^[\w-]+$/.test(name)) {
    push($('logs'), 'record: give the scenario a name (letters, digits, - and _)');
    return;
  }
  const args = ['record', name];
  if ($('rec-snapshot').value) args.push('-Snapshot', $('rec-snapshot').value);
  if ($('rec-preset').value) args.push('-Preset', $('rec-preset').value);
  if ($('rec-env').value.trim()) args.push('-Env', $('rec-env').value.trim());
  if ($('rec-snapshot-as').value.trim()) args.push('-SnapshotAs', $('rec-snapshot-as').value.trim());
  harness(args);
};
window.addEventListener('resize', draw);

// Live control: the on-screen pad holds a button while the mouse is down;
// forwarded keys go down and up with the real key.
async function control(verb, key) {
  const r = await window.victory.control(verb, key);
  if (r && r.error) push($('logs'), r.error);
}
document.querySelectorAll('.pad-btn').forEach((b) => {
  const key = b.dataset.key;
  b.addEventListener('mousedown', () => {
    b.classList.add('held');
    control('down', key);
  });
  const release = () => {
    if (!b.classList.contains('held')) return;
    b.classList.remove('held');
    control('up', key);
  };
  b.addEventListener('mouseup', release);
  b.addEventListener('mouseleave', release);
});

const FORWARD = {
  Enter: 'Enter', Escape: 'Esc', Tab: 'Tab', Backspace: 'Back',
  ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
};
function forwardedKey(e) {
  if (!$('forward').checked) return null;
  if (['INPUT', 'SELECT'].includes(document.activeElement.tagName) && document.activeElement.id !== 'forward') return null;
  if (FORWARD[e.key]) return FORWARD[e.key];
  return /^[a-zA-Z0-9]$/.test(e.key) ? e.key.toUpperCase() : null;
}
window.addEventListener('keydown', (e) => {
  const key = forwardedKey(e);
  if (!key) return;
  e.preventDefault();
  if (!e.repeat) control('down', key);
});
window.addEventListener('keyup', (e) => {
  const key = forwardedKey(e);
  if (!key) return;
  e.preventDefault();
  control('up', key);
});

window.victory.state().then(render);
