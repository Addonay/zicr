import {webGLImports} from './gl.js';
import {webGPUImports} from './wgpu.js';
const output = document.querySelector('#results');
window.__zicr_results = null;
async function run() {
  const query = new URLSearchParams(location.search);
  const backend = query.get('backend') ?? 'webgl2';
  if (!['webgl2','wgpu'].includes(backend)) throw new Error('Unknown backend: ' + backend);
  const canvas = document.querySelector('canvas');
  const gl = backend === 'webgl2' ? canvas.getContext('webgl2', {antialias:false, depth:true, stencil:true, premultipliedAlpha:false}) : null;
  let device, adapterInfo, wasm;
  const nativeErrors = [];
  if (backend === 'wgpu') {
    const adapter = await navigator.gpu?.requestAdapter();
    if (!adapter) throw new Error('WebGPU adapter unavailable');
    adapterInfo = {vendor:adapter.info.vendor, architecture:adapter.info.architecture, device:adapter.info.device, description:adapter.info.description};
    device = await adapter.requestDevice({requiredFeatures:[...adapter.features]});
    device.addEventListener('uncapturederror', event => nativeErrors.push(event.error.message));
    device.lost.then(info => { if (info.reason !== 'destroyed') { wasm?.notify_device_lost(-1); nativeErrors.push('Device lost: ' + info.message); } });
  } else if (!gl) throw new Error('WebGL2 unavailable');
  canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); wasm?.notify_device_lost(0x9242); nativeErrors.push('WebGL context lost'); });
  const messages = [];
  const decoder = new TextDecoder();
  const read = (p, n) => decoder.decode(new Uint8Array(wasm.memory.buffer, p, n));
  const bridge = gl ? webGLImports(gl, () => wasm.memory) : null;
  const wgpu = webGPUImports(device, () => wasm);
  const unusedGL = new Proxy({}, {get: (_, name) => () => {throw new Error('GL import called by WebGPU: ' + name);}});
  ({instance: {exports: wasm}} = await WebAssembly.instantiateStreaming(fetch('zicr-scenes.wasm'), {
    gl: bridge?.imports ?? unusedGL,
    webgpu: wgpu.imports,
    host: {log(p, n) { const text = read(p, n); messages.push(text); console.error(text); }},
  }));
  bridge?.initializeStrings(wasm.string_table());
  wgpu.initialize();
  if (!wasm.init(backend === 'wgpu' ? 1 : 0, wgpu.deviceId)) throw new Error('GPU initialization failed: ' + messages.join('\n'));
  const results = [];
  const filter = query.get('filter') ?? '';
  const yieldToBrowser = () => new Promise(resolve => setTimeout(resolve, 0));
  for (let i = 0; i < wasm.scene_count(); i++) {
    const name = read(wasm.scene_name(i), wasm.scene_name_len(i));
    if (!name.includes(filter)) continue;
    messages.length = 0;
    let status;
    try {
      for (;;) {
        status = wasm.run_scene(i);
        if (status !== 3) break;
        const deadline = performance.now() + 15000;
        let state;
        do {
          await yieldToBrowser();
          state = wasm.poll_read();
          if (performance.now() > deadline) throw new Error('Async readback timed out');
        } while (state === 0);
        if (state !== 1) throw new Error('Async readback failed');
      }
    } catch (error) { throw new Error(`${name}: ${error.stack ?? error}; diagnostics: ${messages.join("; ")}; native: ${nativeErrors.join("; ")}`); }
    // Both WebGPU errors and mapping callbacks need a turn of the event loop.
    await yieldToBrowser();
    if (gl) for (let j = 0, e; j < 64 && (e = gl.getError()); j++) nativeErrors.push('GL error 0x' + e.toString(16));
    if (nativeErrors.length) { status = 1; messages.push(...nativeErrors.splice(0)); }
    results.push({name, status: ['pass','fail','skip'][status] ?? 'fail', messages:[...messages]});
    output.textContent = JSON.stringify({backend, results, running:true}, null, 2);
  }
  // Exercise acquired canvas images over real browser presentation turns. Keep
  // the last read before yielding: the default GL drawing buffer is discarded
  // after compositing, and a WebGPU current texture expires at the next frame.
  const canvasContext = device ? canvas.getContext('webgpu') : null;
  canvasContext?.configure({device, format:'rgba8unorm', usage:GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC, alphaMode:'opaque'});
  let finalPixel;
  for (let frame = 0; frame < 32; frame++) {
    await new Promise(resolve => requestAnimationFrame(resolve));
    const texture = canvasContext?.getCurrentTexture();
    const viewId = texture ? wgpu.addObject(texture.createView()) : 0;
    try {
      if (!wasm.present_frame(frame, viewId)) throw new Error('Canvas pass diagnostic');
      if (frame === 31) {
        if (gl) {
          finalPixel = new Uint8Array(4);
          gl.bindFramebuffer(gl.FRAMEBUFFER, null);
          gl.readPixels(32,32,1,1,gl.RGBA,gl.UNSIGNED_BYTE,finalPixel);
        } else {
          const buffer = device.createBuffer({size:256, usage:GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ});
          try {
            const encoder = device.createCommandEncoder();
            encoder.copyTextureToBuffer({texture, origin:[32,32,0]}, {buffer, bytesPerRow:256}, [1,1,1]);
            device.queue.submit([encoder.finish()]);
            await buffer.mapAsync(GPUMapMode.READ);
            finalPixel = new Uint8Array(buffer.getMappedRange()).slice(0,4);
            buffer.unmap();
          } finally { buffer.destroy(); }
        }
      }
    } finally { if (viewId) wgpu.releaseObject(viewId); }
  }
  await yieldToBrowser();
  if (gl) { const error = gl.getError(); if (error) nativeErrors.push('Canvas GL error 0x'+error.toString(16)); }
  const canvasPass = finalPixel?.every((value,index) => value === [0,0,255,255][index]) && !nativeErrors.length;
  results.push({name:'canvas_presentation', status:canvasPass ? 'pass' : 'fail', messages:canvasPass ? [] : ['Last canvas pixel: '+[...finalPixel], ...nativeErrors]});
  canvasContext?.unconfigure();
  wasm.shutdown();
  device?.destroy();
  const debugInfo = gl?.getExtension('WEBGL_debug_renderer_info');
  const renderer = gl ? gl.getParameter(debugInfo?.UNMASKED_RENDERER_WEBGL ?? gl.RENDERER) : undefined;
  window.__zicr_results = {backend, renderer, adapter:adapterInfo, results, failed:results.filter(r => r.status === 'fail').length};
  output.textContent = JSON.stringify(window.__zicr_results, null, 2);
}
run().catch(error => {
  window.__zicr_results = {failed:1, error:String(error), stack:error.stack};
  output.textContent = JSON.stringify(window.__zicr_results, null, 2);
});
