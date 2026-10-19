// No npm dependencies: use an isolated headless Chromium process, never a user's profile.
import http from 'node:http';
import {runFirefox} from './firefox.mjs';
import {readFile, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve, sep} from 'node:path';
import {spawn} from 'node:child_process';
const root = resolve(process.argv[2] ?? 'zig-out/web');
const server = http.createServer(async (req, res) => {
  try {
    const file = resolve(root, '.' + new URL(req.url, 'http://localhost').pathname.replace(/\/$/, '/index.html'));
    if (!file.startsWith(root + sep)) { res.writeHead(403).end(); return; }
    const data = await readFile(file);
    res.setHeader('Content-Type', file.endsWith('.wasm') ? 'application/wasm' : (file.endsWith('.js') || file.endsWith('.mjs')) ? 'text/javascript' : 'text/html');
    res.end(data);
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const profile = await mkdtemp(join(tmpdir(), 'zicr-browser-'));
try {
  const browser = process.env.CHROMIUM ?? 'google-chrome';
  const url = `http://127.0.0.1:${server.address().port}/?backend=${process.argv[3] ?? "webgl2"}`;
  if (process.env.ZICR_BROWSER === 'firefox') {
    const result = await runFirefox(url, profile);
    console.log(JSON.stringify(result, null, 2));
    if (result.failed || result.running || !result.results?.length) process.exitCode = 1;
  } else {
  const hardware = process.env.ZICR_GPU === 'hardware';
  const gpuArgs = hardware ? ['--enable-gpu', '--use-angle=vulkan', '--enable-unsafe-webgpu'] : ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader'];
  const args = ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check', ...gpuArgs, '--enable-features=Vulkan', '--disable-background-networking', `--user-data-dir=${profile}`, '--remote-debugging-pipe', 'about:blank'];
  const child = spawn(browser, args, {stdio:['ignore','ignore','pipe','pipe','pipe']});
  let stderr = '', incoming = '', sequence = 0;
  const requests = new Map();
  const exited = new Promise(resolve => child.once('close', resolve));
  let closed = false;
  const failPending = error => { for (const {reject} of requests.values()) reject(error); requests.clear(); };
  child.on('error', error => { closed = true; failPending(error); });
  child.on('exit', code => { closed = true; failPending(new Error(`Browser exited (${code}): ${stderr.slice(-2000)}`)); });
  child.stdio[3].on('error', failPending);
  child.stderr.on('data', data => { stderr += data; });
  child.stdio[4].on('data', data => {
    incoming += data.toString();
    for (;;) {
      const end = incoming.indexOf('\0');
      if (end < 0) break;
      const message = JSON.parse(incoming.slice(0, end)); incoming = incoming.slice(end + 1);
      if (message.id && requests.has(message.id)) {
        const {resolve, reject} = requests.get(message.id); requests.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error))); else resolve(message.result);
      }
    }
  });
  function send(method, params = {}, sessionId) {
    if (closed) return Promise.reject(new Error("Browser is closed"));
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      requests.set(id, {resolve, reject});
      child.stdio[3].write(JSON.stringify({id, method, params, sessionId}) + '\0');
    });
  }
  const timeout = setTimeout(() => {
    for (const {reject} of requests.values()) reject(new Error('Browser test timed out: ' + stderr.slice(-2000)));
    requests.clear(); child.kill('SIGKILL');
  }, 90000);
  try {
    const {targetId} = await send('Target.createTarget', {url:'about:blank'});
    const {sessionId} = await send('Target.attachToTarget', {targetId, flatten:true});
    await send('Page.enable', {}, sessionId);
    await send('Page.navigate', {url}, sessionId);
    const evaluated = await send('Runtime.evaluate', {
      expression:`new Promise((resolve, reject) => { const started = Date.now(); const timer = setInterval(() => { if (window.__zicr_results) { clearInterval(timer); resolve(window.__zicr_results); } else if (Date.now() - started > 60000) { clearInterval(timer); reject(new Error('Scene suite timed out')); } }, 20); })`,
      awaitPromise:true, returnByValue:true,
    }, sessionId);
    if (evaluated.exceptionDetails) throw new Error(JSON.stringify(evaluated.exceptionDetails));
    const result = evaluated.result.value;
    if (hardware) {
      const identity = result.renderer ?? Object.values(result.adapter ?? {}).join(' ');
      if (!identity || /swiftshader|llvmpipe|lavapipe|software/i.test(identity)) {
        result.failed = (result.failed || 0) + 1;
        result.hardwareError = 'Hardware adapter not established: ' + identity;
      }
    }
    console.log(JSON.stringify(result, null, 2));
    if (result.failed || result.running || !result.results?.length) process.exitCode = 1;
  } finally {
    clearTimeout(timeout);
    await send('Browser.close').catch(() => {});
    child.kill();
    await exited;
  }
  }
} finally {
  server.close();
  await rm(profile, {recursive:true, force:true});
}
