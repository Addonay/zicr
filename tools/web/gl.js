// WebGL2 implements the GLES 3.0 dispatch ABI. Views are recreated after every
// wasm call, since memory.grow can detach the previous memory.buffer.
export function webGLImports(gl, getMemory) {
  const objects = [null], reverse = new WeakMap(), free = [];
  const locations = [null], freeLocations = [], programLocations = new Map();
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  const bytes = (p, n) => new Uint8Array(getMemory().buffer, p, n);
  const u32 = (p, n) => new Uint32Array(getMemory().buffer, p, n);
  const i32 = (p, n) => new Int32Array(getMemory().buffer, p, n);
  const f32 = (p, n) => new Float32Array(getMemory().buffer, p, n);
  const string = p => {
    if (!p) return '';
    const all = bytes(p, getMemory().buffer.byteLength - p);
    return decoder.decode(all.subarray(0, all.indexOf(0)));
  };
  const add = value => {
    if (!value) return 0;
    const id = free.length ? free.pop() : objects.length;
    objects[id] = value; reverse.set(value, id); return id;
  };
  const obj = id => objects[id] ?? null;
  const names = [];
  // Reporting an extension means it has actually been enabled.
  for (const name of gl.getSupportedExtensions() ?? []) {
    if (gl.getExtension(name)) names.push(name);
  }
  let extensionPointers = [];
  function initializeStrings(base, capacity = 65536) {
    const limit = base + capacity;
    extensionPointers = [];
    for (const name of names) {
      const data = encoder.encode(name);
      if (base + data.length + 1 > limit) throw new Error('WebGL extension string table is too small');
      extensionPointers.push(base); bytes(base, data.length + 1).set([...data, 0]);
      base += data.length + 1;
    }
  }
  const api = {};
  const set = (name, fn) => api['gl' + name[0].toUpperCase() + name.slice(1)] = fn;
  const direct = `invalidateFramebuffer bindVertexArray clearBufferfi useProgram linkProgram disableVertexAttribArray compileShader stencilFuncSeparate stencilOpSeparate renderbufferStorageMultisample vertexAttribDivisor activeTexture polygonOffset blendEquationSeparate viewport drawArrays drawElementsInstanced vertexAttribIPointer uniform1i disable colorMask depthMask drawArraysInstanced scissor blendFuncSeparate enable blitFramebuffer stencilMask blendColor depthFunc stencilOp stencilFunc enableVertexAttribArray blendFunc readBuffer frontFace cullFace pixelStorei texStorage2D texStorage3D renderbufferStorage texParameteri texParameterf`;
  for (const name of direct.split(' ')) set(name, (...args) => gl[name](...args));
  // Object arguments need translating even when the rest of a call is scalar.
  for (const name of ['bindVertexArray', 'useProgram', 'linkProgram', 'compileShader'])
    set(name, id => gl[name](obj(id)));
  for (const kind of ['Buffer', 'Texture', 'Framebuffer', 'Renderbuffer', 'Sampler', 'VertexArray']) {
    const plural = kind === 'VertexArray' ? 'VertexArrays' : kind + 's';
    set('gen' + plural, (n, p) => { for (let j = 0; j < n; j++) u32(p, n)[j] = add(gl['create' + kind]()); });
    set('delete' + plural, (n, p) => {
      for (const id of [...u32(p, n)]) if (id) { gl['delete' + kind](obj(id)); reverse.delete(obj(id)); objects[id] = null; free.push(id); }
    });
  }
  for (const name of ['bindBuffer', 'bindTexture', 'bindFramebuffer', 'bindRenderbuffer', 'bindSampler'])
    set(name, (target, id) => gl[name](target, obj(id)));
  set('createShader', type => add(gl.createShader(type)));
  set('createProgram', () => add(gl.createProgram()));
  for (const kind of ['Shader', 'Program']) {
    set('delete' + kind, id => { if (id) { if (kind === 'Program') { for (const slot of programLocations.get(id) ?? []) { locations[slot] = null; freeLocations.push(slot); } programLocations.delete(id); } gl['delete' + kind](obj(id)); reverse.delete(obj(id)); objects[id] = null; free.push(id); } });
    set('get' + kind + 'iv', (id, pname, p) => {
      const value = pname === gl.INFO_LOG_LENGTH ? encoder.encode(gl['get' + kind + 'InfoLog'](obj(id)) ?? '').length + 1 : gl['get' + kind + 'Parameter'](obj(id), pname);
      i32(p, 1)[0] = Number(value);
    });
    set('get' + kind + 'InfoLog', (id, capacity, length, p) => {
      const message = encoder.encode(gl['get' + kind + 'InfoLog'](obj(id)) ?? '');
      const n = Math.min(message.length, Math.max(0, capacity - 1));
      if (capacity) { bytes(p, capacity).set(message.subarray(0, n)); bytes(p + n, 1)[0] = 0; }
      if (length) i32(length, 1)[0] = n;
    });
  }
  set('attachShader', (p, s) => gl.attachShader(obj(p), obj(s)));
  set('shaderSource', (id, count, pointers, lengths) => {
    let source = '';
    for (let j = 0; j < count; j++) {
      const p = u32(pointers, count)[j], n = lengths ? i32(lengths, count)[j] : -1;
      source += n < 0 ? string(p) : decoder.decode(bytes(p, n));
    }
    gl.shaderSource(obj(id), source);
  });
  set('getAttribLocation', (id, p) => gl.getAttribLocation(obj(id), string(p)));
  set('getUniformLocation', (id, p) => {
    const value = gl.getUniformLocation(obj(id), string(p));
    if (value === null) return -1;
    const slot = freeLocations.length ? freeLocations.pop() : locations.length;
    locations[slot] = value;
    if (!programLocations.has(id)) programLocations.set(id, []);
    programLocations.get(id).push(slot);
    return slot;
  });
  set('uniform1i', (id, value) => gl.uniform1i(locations[id] ?? null, value));
  for (let count = 1; count <= 4; count++) {
    for (const type of ['f', 'i']) set(`uniform${count}${type}v`, (id, n, p) => gl[`uniform${count}${type}v`](locations[id] ?? null, (type === 'f' ? f32 : i32)(p, n * count)));
  }
  set('uniformMatrix4fv', (id, n, transpose, p) => gl.uniformMatrix4fv(locations[id] ?? null, !!transpose, f32(p, n * 16)));
  set('getIntegerv', (pname, p) => {
    let value;
    if (pname === 0x821B) value = 3; // GL_MAJOR_VERSION: WebGL2 is GLES 3.0
    else if (pname === 0x821C) value = 0;
    else if (pname === 0x821D) value = names.length;
    else value = gl.getParameter(pname);
    if (value && typeof value === 'object' && !ArrayBuffer.isView(value) && !Array.isArray(value)) value = reverse.get(value) ?? 0;
    if (ArrayBuffer.isView(value) || Array.isArray(value)) i32(p, value.length).set(value);
    else i32(p, 1)[0] = Number(value);
  });
  set('getStringi', (_, index) => extensionPointers[index] ?? 0);
  set('getError', () => gl.getError());
  set('flush', () => gl.flush());
  set('fenceSync', (condition, flags) => add(gl.fenceSync(condition, flags)));
  set('clientWaitSync', (id, flags, timeout) => gl.clientWaitSync(obj(id), flags, Number(timeout)));
  set('deleteSync', id => { if (id) { gl.deleteSync(obj(id)); reverse.delete(obj(id)); objects[id] = null; free.push(id); } });
  set('bufferData', (target, size, p, usage) => gl.bufferData(target, p ? bytes(p, size) : size, usage));
  set('bufferSubData', (target, offset, size, p) => gl.bufferSubData(target, offset, bytes(p, size)));
  set('getBufferSubData', (target, offset, size, p) => gl.getBufferSubData(target, offset, bytes(p, size)));
  set('copyBufferSubData', (...args) => gl.copyBufferSubData(...args));
  set('vertexAttribPointer', (index, count, type, normalized, stride, offset) => gl.vertexAttribPointer(index, count, type, !!normalized, stride, offset));
  set('drawElements', (...args) => gl.drawElements(...args));
  set('framebufferTexture2D', (target, attachment, textarget, id, level) => gl.framebufferTexture2D(target, attachment, textarget, obj(id), level));
  set('framebufferTextureLayer', (target, attachment, id, level, layer) => gl.framebufferTextureLayer(target, attachment, obj(id), level, layer));
  set('framebufferRenderbuffer', (target, attachment, rbtarget, id) => gl.framebufferRenderbuffer(target, attachment, rbtarget, obj(id)));
  set('checkFramebufferStatus', target => gl.checkFramebufferStatus(target));
  set('drawBuffers', (n, p) => gl.drawBuffers([...u32(p, n)]));
  set('invalidateFramebuffer', (target, n, p) => gl.invalidateFramebuffer(target, [...u32(p, n)]));
  for (const [suffix, view] of [['fv', f32], ['iv', i32], ['uiv', u32]])
    set('clearBuffer' + suffix, (buffer, drawbuffer, p) => gl['clearBuffer' + suffix](buffer, drawbuffer, view(p, buffer === gl.COLOR ? 4 : 1)));
  for (const name of ['samplerParameteri', 'samplerParameterf']) set(name, (id, param, value) => gl[name](obj(id), param, value));
  // Border colours are unavailable and the backend advertises that limitation.
  set('samplerParameterfv', () => {});
  const components = format => ({[gl.RED]:1, [gl.RED_INTEGER]:1, [gl.RG]:2, [gl.RG_INTEGER]:2, [gl.RGB]:3, [gl.RGB_INTEGER]:3}[format] ?? 4);
  const pixelView = (p, count, type) => {
    const T = ({[gl.BYTE]:Int8Array, [gl.UNSIGNED_BYTE]:Uint8Array, [gl.SHORT]:Int16Array, [gl.UNSIGNED_SHORT]:Uint16Array, [gl.HALF_FLOAT]:Uint16Array, [gl.INT]:Int32Array, [gl.UNSIGNED_INT]:Uint32Array, [gl.FLOAT]:Float32Array})[type] ?? Uint32Array;
    return new T(getMemory().buffer, p, count);
  };
  for (const dimension of [2, 3]) {
    for (const sub of [false, true]) {
      const name = `tex${sub ? 'Sub' : ''}Image${dimension}D`;
      set(name, (...args) => {
        const p = args.pop(), type = args.at(-1), format = args.at(-2);
        const w = args[sub ? dimension === 2 ? 4 : 5 : 3];
        const h = args[sub ? dimension === 2 ? 5 : 6 : 4];
        const depth = dimension === 3 ? args[sub ? 7 : 5] : 1;
        // A bound PBO changes the last argument from a view into a byte offset.
        const rowPixels = gl.getParameter(gl.UNPACK_ROW_LENGTH) || w;
        const imageRows = gl.getParameter(gl.UNPACK_IMAGE_HEIGHT) || h;
        const elements = [gl.UNSIGNED_INT_2_10_10_10_REV, gl.UNSIGNED_INT_10F_11F_11F_REV, gl.UNSIGNED_INT_24_8].includes(type) ? 1 : components(format);
        const count = ((depth - 1) * rowPixels * imageRows + (h - 1) * rowPixels + w) * elements;
        const data = gl.getParameter(gl.PIXEL_UNPACK_BUFFER_BINDING) ? p : p ? pixelView(p, count, type) : null;
        gl[name](...args, data);
      });
      const compressed = `compressedTex${sub ? 'Sub' : ''}Image${dimension}D`;
      set(compressed, (...args) => { const p = args.pop(), n = args.pop(); gl[compressed](...args, bytes(p, n)); });
    }
  }
  set('readPixels', (x, y, w, h, format, type, p) => {
    if (gl.getParameter(gl.PIXEL_PACK_BUFFER_BINDING)) { gl.readPixels(x, y, w, h, format, type, p); return; }
    // WebGL permits canonical RGBA read formats, not arbitrary texture formats.
    const count = components(format);
    const integer = [gl.RED_INTEGER, gl.RG_INTEGER, gl.RGB_INTEGER, gl.RGBA_INTEGER].includes(format);
    const canonicalType = integer ? ([gl.BYTE, gl.SHORT, gl.INT].includes(type) ? gl.INT : gl.UNSIGNED_INT) : type === gl.HALF_FLOAT ? gl.FLOAT : type;
    const T = canonicalType === gl.FLOAT ? Float32Array : canonicalType === gl.INT ? Int32Array : canonicalType === gl.UNSIGNED_INT ? Uint32Array : Uint8Array;
    const rgba = new T(w * h * 4);
    const rowLength = gl.getParameter(gl.PACK_ROW_LENGTH) || w;
    gl.pixelStorei(gl.PACK_ROW_LENGTH, 0);
    gl.readPixels(x, y, w, h, integer ? gl.RGBA_INTEGER : gl.RGBA, canonicalType, rgba);
    gl.pixelStorei(gl.PACK_ROW_LENGTH, rowLength === w ? 0 : rowLength);
    const dst = pixelView(p, (h - 1) * rowLength * count + w * count, type);
    for (let row = 0; row < h; row++) for (let col = 0; col < w; col++) for (let c = 0; c < count; c++) {
      const value = rgba[(row * w + col) * 4 + c];
      dst[(row * rowLength + col) * count + c] = type === gl.HALF_FLOAT ? toHalf(value) : value;
    }
  });
  function toHalf(value) {
    const b = new ArrayBuffer(4), f = new Float32Array(b), u = new Uint32Array(b); f[0] = value;
    const sign = (u[0] >>> 16) & 0x8000, exponent = ((u[0] >>> 23) & 255) - 127 + 15, mantissa = u[0] & 0x7fffff;
    if (exponent >= 31) return sign | 0x7c00 | (mantissa ? 0x200 : 0);
    if (exponent <= 0) return exponent < -10 ? sign : sign | ((mantissa | 0x800000) + (1 << (13 - exponent)) >>> (14 - exponent));
    return sign | ((exponent << 10) + ((mantissa + 0x1000) >>> 13));
  }
  // Optional native-only entry points are imported into the table but must never
  // be called by GLES 3.0. Throwing here exposes accidental feature promotion.
  return { imports: new Proxy(api, {get: (target, name) => target[name] ?? (() => {throw new Error(`Unsupported WebGL2 entry point: ${String(name)}`);})}), initializeStrings };
}
