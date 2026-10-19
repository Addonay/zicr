// WebDriver BiDi: https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection
// Only controls the child launched here, with a fresh profile and loopback agent.
import {spawn} from 'node:child_process';
export async function runFirefox(url, profile) {
  const child = spawn(process.env.FIREFOX || 'firefox', ['--headless', '--no-remote', '--new-instance', '--profile', profile, '--remote-debugging-port', '0', 'about:blank'], {stdio:['ignore','ignore','pipe']});
  let stderr = '', socket, sequence = 0;
  const pending = new Map();
  const rejectAll = error => { for (const request of pending.values()) request.reject(error); pending.clear(); };
  const exited = new Promise(resolve => child.once('close', resolve));
  let rejectAddress;
  const address = new Promise((resolve, reject) => {
    rejectAddress = reject;
    child.stderr.on('data', data => {
      stderr += data;
      const match = stderr.match(/WebDriver BiDi listening on (ws:\/\/[^\s]+)/);
      if (match) resolve(match[1].replace(/\/$/, '') + '/session');
    });
  });
  child.on('error', error => { rejectAddress(error); rejectAll(error); });
  child.on('exit', code => { const error = new Error(`Firefox exited (${code}): ${stderr.slice(-3000)}`); rejectAddress(error); rejectAll(error); });
  const timeout = setTimeout(() => { const error = new Error('Firefox timed out: ' + stderr.slice(-3000)); rejectAddress(error); rejectAll(error); child.kill('SIGKILL'); }, 90000);
  try {
    socket = new WebSocket(await address);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    socket.onmessage = event => {
      const message = JSON.parse(event.data);
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      if (message.type === 'error') request.reject(new Error(JSON.stringify(message)));
      else request.resolve(message.result);
    };
    socket.onclose = () => rejectAll(new Error('Firefox BiDi connection closed'));
    function send(method, params) {
      const id = ++sequence;
      return new Promise((resolve, reject) => { pending.set(id, {resolve,reject}); socket.send(JSON.stringify({id,method,params})); });
    }
    const session = await send('session.new', {capabilities:{}});
    const {context} = await send('browsingContext.create', {type:'tab'});
    await send('browsingContext.navigate', {context,url,wait:'complete'});
    const evaluated = await send('script.evaluate', {
      target:{context}, awaitPromise:true,
      expression:`new Promise((resolve, reject) => { const start=Date.now(); const timer=setInterval(() => { if(window.__zicr_results) {clearInterval(timer);resolve(JSON.stringify(window.__zicr_results));} else if(Date.now()-start>60000) {clearInterval(timer);reject(new Error('Scene suite timed out'));} },20); })`,
    });
    if (evaluated.type !== 'success' || evaluated.result?.type !== 'string') throw new Error(JSON.stringify(evaluated));
    const result = JSON.parse(evaluated.result.value);
    result.browser = session.capabilities;
    return result;
  } finally {
    clearTimeout(timeout);
    socket?.close();
    child.kill();
    const force = setTimeout(() => child.kill('SIGKILL'), 3000);
    await exited;
    clearTimeout(force);
  }
}
