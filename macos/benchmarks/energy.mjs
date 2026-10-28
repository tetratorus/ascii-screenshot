import { appendFile, copyFile, mkdir, mkdtemp, readFile, stat, writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  if (!args[i + 1] || args[i + 1].startsWith('--')) throw Error(`${name} requires a value`);
  return args[i + 1];
};
const requestedOutput = option('--output', null);
const endpoint = option('--chrome', 'http://127.0.0.1:9222');
const seconds = Number(option('--seconds', '120'));
const warmup = Number(option('--warmup', '10'));
const powerLog = option('--power-log', '/tmp/ascii-screen-matrix-power.txt');
const prepare = args.includes('--prepare');
const run = args.includes('--run');
if (!prepare && !run) {
  console.log('Use --prepare to open the fixture without capture; --run starts capture. Options: --output <dir> --before <binary> --power-log <file> --seconds <120> --warmup <10> --chrome <http://127.0.0.1:9222> --only <mode> --workload <static|small|scroll>');
  process.exit(0);
}
if (!Number.isFinite(seconds) || seconds <= 0 || !Number.isFinite(warmup) || warmup < 0) throw Error('Invalid duration');
if (prepare && run) throw Error('Choose either --prepare or --run');
const output = requestedOutput ? path.resolve(requestedOutput) : await mkdtemp(path.join(tmpdir(), 'ascii-screen-energy-'));
if (requestedOutput) await mkdir(output, { mode: 0o700 });

class CDP {
  pending = new Map();
  sequence = 0;
  constructor(url) {
    this.socket = new WebSocket(url);
    this.socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      const p = this.pending.get(message.id);
      if (!p) return;
      clearTimeout(p.timer);
      this.pending.delete(message.id);
      if (message.error) p.reject(Error(JSON.stringify(message.error)));
      else p.resolve(message.result);
    });
    this.socket.addEventListener('close', () => {
      for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(Error('Chrome disconnected')); }
      this.pending.clear();
    });
  }
  async connect() {
    if (this.socket.readyState === WebSocket.OPEN) return;
    await new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
  }
  call(method, params = {}, sessionId) {
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error(`CDP timeout: ${method}`)); }, 10000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
}

const version = await (await fetch(`${endpoint}/json/version`)).json();
const cdp = new CDP(version.webSocketDebuggerUrl);
await cdp.connect();
let targetId, child, childLog, stopping = false;
const stopChild = async () => {
  if (child?.pid && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, 'exit');
    process.kill(-child.pid, 'SIGTERM');
    await exited;
  }
  child = undefined;
  if (childLog) { await new Promise(resolve => childLog.end(resolve)); childLog = undefined; }
};
const cleanup = async () => {
  await stopChild();
  if (targetId) await cdp.call('Target.closeTarget', { targetId }).catch(() => {});
  cdp.socket.close();
};
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
  if (stopping) return;
  stopping = true;
  await cleanup();
  process.exit(130);
});
const event = async value => appendFile(path.join(output, 'events.jsonl'), JSON.stringify({ time: Date.now(), ...value }) + '\n');
try {
  if (run) {
    const info = await stat(powerLog);
    if (Date.now() - info.mtimeMs > 10000 || info.size === 0) throw Error('Power log is not actively updating; start powermetrics first');
    await writeFile(path.join(output, 'run.lock'), String(process.pid), { flag: 'wx' });
  }
  ({ targetId } = await cdp.call('Target.createTarget', { url: pathToFileURL(path.join(here, 'workload.html')).href, newWindow: true }));
  const { sessionId } = await cdp.call('Target.attachToTarget', { targetId, flatten: true });
  const { windowId } = await cdp.call('Browser.getWindowForTarget', { targetId });
  await cdp.call('Browser.setWindowBounds', { windowId, bounds: { windowState: 'fullscreen' } });
  await cdp.call('Page.bringToFront', {}, sessionId);
  await sleep(2500);
  const evaluate = async expression => {
    const result = await cdp.call('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
    if (result.exceptionDetails) throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  if (prepare) {
    const screenshot = await cdp.call('Page.captureScreenshot', { format: 'png' }, sessionId);
    await writeFile(path.join(output, 'fixture.png'), Buffer.from(screenshot.data, 'base64'));
    console.log(JSON.stringify({ status: 'fixture ready; no screen capture started', targetId, viewport: await evaluate("window.setWorkload('static')"), screenshot: path.join(output, 'fixture.png') }));
    cdp.socket.close();
  } else {
    const native = path.join(output, 'ascii-screen-after');
    await copyFile(path.join(root, 'macos/.build/release/ascii-screen'), native);
    const before = option('--before', null);
    const modes = [
      { name: 'control', kind: 'control' },
      ...(before ? [{ name: 'before-default-1x', kind: 'native', binary: path.resolve(before), flags: ['--scale', '1'] }] : []),
      ...['default', 'fast', 'correction'].flatMap(mode => [1, 2].map(scale => ({
        name: `after-${mode}-${scale}x`, kind: 'native', binary: native,
        flags: ['--scale', String(scale), ...(mode === 'default' ? [] : [`--${mode}`])],
      }))),
    ].filter(mode => !option('--only', null) || mode.name === option('--only', null));
    const workloads = ['static', 'small', 'scroll'].filter(name => !option('--workload', null) || name === option('--workload', null));
    if (!modes.length || !workloads.length) throw Error('Unknown mode or workload');
    const manifest = {
      created: new Date().toISOString(), seconds, warmup, powerLog, chrome: version.Browser,
      afterSHA256: createHash('sha256').update(await readFile(native)).digest('hex'),
      beforeSHA256: before ? createHash('sha256').update(await readFile(before)).digest('hex') : null,
      note: 'Native warmup starts after the first output file exists, excluding cold model initialization. Rail power is system-wide. No Activity Monitor UI readings.',
      modes,
    };
    await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2));
    for (const workload of workloads) {
      for (const mode of modes) {
        const name = `${workload}-${mode.name}`;
        console.log(`Starting ${name}`);
        const viewport = await evaluate(`window.setWorkload(${JSON.stringify(workload)})`);
        await sleep(3000);
        let command, argv;
        if (mode.kind === 'native') {
          command = mode.binary;
          argv = ['--stats', '--out', path.join(output, `${name}.txt`), ...mode.flags];
        }
        if (command) {
          childLog = createWriteStream(path.join(output, `${name}.log`), { flags: 'wx' });
          child = spawn(command, argv, { cwd: root, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
          child.stdout.pipe(childLog, { end: false });
          child.stderr.pipe(childLog, { end: false });
          await once(child, 'spawn');
        }
        const pid = child?.pid ?? null;
        if (mode.kind === 'native') {
          const deadline = Date.now() + 90000;
          while (!(await stat(path.join(output, `${name}.txt`)).catch(error => {
            if (error.code === 'ENOENT') return null;
            throw error;
          }))) {
            if (child.exitCode !== null || child.signalCode !== null) throw Error(`${name} exited before its first frame`);
            if (Date.now() > deadline) throw Error(`${name} produced no frame within 90 seconds`);
            await sleep(100);
          }
        }
        await event({ event: 'warmup', name, pid, viewport, command, argv });
        await sleep(warmup * 1000);
        if (child && (child.exitCode !== null || child.signalCode !== null)) throw Error(`${name} exited during warmup`);
        const started = Date.now();
        await event({ event: 'start', name, pid, kind: mode.kind, workload });
        for (let elapsed = 0; elapsed < seconds; elapsed += 5) {
          await sleep(Math.min(5, seconds - elapsed) * 1000);
          if (child && (child.exitCode !== null || child.signalCode !== null)) throw Error(`${name} exited unexpectedly`);
          if (Date.now() - (await stat(powerLog)).mtimeMs > 15000) throw Error('Power sampler stopped or stalled');
          if (!(await evaluate('document.hasFocus()'))) throw Error('Test window lost focus; measurement interrupted');
        }
        await event({ event: 'end', name, pid, elapsedMs: Date.now() - started });
        await stopChild();
        console.log(`Finished ${name}`);
      }
    }
    await event({ event: 'complete' });
    console.log(`Matrix complete: ${output}`);
    await cleanup();
  }
} catch (error) {
  await event({ event: 'error', error: String(error) });
  await cleanup();
  console.error(error);
  process.exitCode = 1;
}
