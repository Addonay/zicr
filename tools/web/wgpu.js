import {textureFormatName} from './formats.mjs';
// webgpu.h ABI adapter. The wasm module supplies its own struct layouts and enum
// values, so a header change cannot silently change offsets underneath this file.
export function webGPUImports(device, getWasm) {
  let schema;
  const objects = [null], refs = [0], freeIds = [], mapped = new Map();
  const decoder = new TextDecoder();
  const memory = () => getWasm().memory;
  const view = () => new DataView(memory().buffer);
  const bytes = (p, n) => new Uint8Array(memory().buffer, p, n);
  const number = value => typeof value === 'bigint' ? Number(value) : value;
  const camel = name => name.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
  const enumName = (kind, value) => {
    const raw = schema[kind].enum[value];
    if (raw === undefined) throw new Error(`Unknown ${kind} value ${value}`);
    if (['undefined','binding_not_used'].includes(raw)) return undefined;
    if (kind === 'OptionalBool') return raw === 'true';
    if (kind === 'TextureFormat') return textureFormatName(raw);
    if (kind === 'FeatureName') {
      const special = {depth32_float_stencil8:'depth32float-stencil8', rg11_b10_ufloat_renderable:'rg11b10ufloat-renderable', bgra8_unorm_storage:'bgra8unorm-storage', texture_compression_bc_sliced3_d:'texture-compression-bc-sliced-3d', texture_compression_astc_sliced3_d:'texture-compression-astc-sliced-3d'};
      return special[raw] ?? raw.replaceAll('_', '-');
    }
    if (kind === 'TextureDimension' || kind === 'TextureViewDimension') return raw.replace(/_d(?=_|$)/, 'd').replaceAll('_', '-');
    if (kind === 'VertexFormat' && raw === 'unorm10_10_10_2') return 'unorm10-10-10-2';
    return raw.replaceAll('_', '-');
  };
  function read(kind, p) {
    if (!p) return undefined;
    if (kind === 'StringView') {
      const fields = schema.StringView.fields;
      const ptr = view().getUint32(p + fields[0][1], true), len = view().getUint32(p + fields[1][1], true);
      if (!ptr) return '';
      if (len === 0xffffffff) { const data = bytes(ptr, memory().buffer.byteLength - ptr); return decoder.decode(data.subarray(0, data.indexOf(0))); }
      return decoder.decode(bytes(ptr, len));
    }
    const out = {};
    for (const [name, offset, type] of schema[kind].fields) {
      const at = p + offset;
      let value;
      if (type.startsWith('struct:')) value = read(type.slice(7), at);
      else if (type.startsWith('enum:')) value = enumName(type.slice(5), view().getUint32(at, true));
      else if (type === 'u64') value = Number(view().getBigUint64(at, true));
      else if (type === 'f64') value = view().getFloat64(at, true);
      else if (type === 'f32') value = view().getFloat32(at, true);
      else if (type === 'u16') value = view().getUint16(at, true);
      else if (type === 'i32') value = view().getInt32(at, true);
      else value = view().getUint32(at, true);
      out[camel(name)] = value;
    }
    return out;
  }
  const array = (kind, p, count) => Array.from({length:count}, (_, i) => read(kind, p + i * schema[kind].size));
  const handles = (p, count) => Array.from({length:count}, (_, i) => object(view().getUint32(p + 4 * i, true)));
  const add = obj => { if (!obj) return 0; const id = freeIds.length ? freeIds.pop() : objects.length; objects[id] = obj; refs[id] = 1; return id; };
  const object = id => objects[id] ?? undefined;
  const release = id => {
    if (!id || !objects[id]) return;
    if (--refs[id]) return;
    // Releasing a C reference is not GPUBuffer.destroy(): recorded command
    // buffers may still own the resource, just as they do in native WebGPU.
    objects[id] = null; freeIds.push(id);
  };
  const api = {};
  for (const kind of ['BindGroupLayout','BindGroup','Buffer','CommandBuffer','CommandEncoder','ComputePassEncoder','ComputePipeline','Device','PipelineLayout','Queue','RenderPassEncoder','RenderPipeline','Sampler','ShaderModule','Texture','TextureView']) {
    api[`wgpu${kind}Release`] = release;
    api[`wgpu${kind}AddRef`] = id => { if (id) refs[id]++; };
  }
  function state(kind, p) {
    const d = read(kind, p);
    d.module = object(d.module);
    if (d.constantCount) d.constants = Object.fromEntries(array('ConstantEntry', d.constants, d.constantCount).map(c => [c.key, c.value])); else delete d.constants;
    return d;
  }
  function pipeline(kind, p) {
    const d = read(kind, p); d.layout = object(d.layout) ?? 'auto';
    if (kind === 'ComputePipelineDescriptor') d.compute = state('ComputeState', p + fieldOffset(kind, 'compute'));
    else {
      d.vertex = state('VertexState', p + fieldOffset(kind, 'vertex'));
      d.vertex.buffers = array('VertexBufferLayout', d.vertex.buffers, d.vertex.bufferCount).map(b => ({...b, attributes:array('VertexAttribute', b.attributes, b.attributeCount)}));
      if (d.fragment) { const ptr = d.fragment; d.fragment = state('FragmentState', ptr); d.fragment.targets = array('ColorTargetState', d.fragment.targets, d.fragment.targetCount).map(t => ({...t, blend:read('BlendState', t.blend)})); }
      else delete d.fragment;
      d.depthStencil = read('DepthStencilState', d.depthStencil);
      if (d.multisample) d.multisample.alphaToCoverageEnabled = !!d.multisample.alphaToCoverageEnabled;
    }
    return d;
  }
  const fieldOffset = (kind, name) => schema[kind].fields.find(f => f[0] === name)[1];
  api.wgpuDeviceGetQueue = id => add(object(id).queue);
  api.wgpuDeviceHasFeature = (id, feature) => object(id).features.has(enumName('FeatureName', feature)) ? 1 : 0;
  api.wgpuDeviceGetLimits = (id, p) => {
    const limits = object(id).limits;
    for (const [name, offset, kind] of schema.Limits.fields) {
      if (name === 'next_in_chain') continue;
      const jsName = camel(name).replace(/([123])D$/, '$1D');
      const value = limits[jsName] ?? 0;
      if (kind === 'u64') view().setBigUint64(p + offset, BigInt(value), true);
      else view().setUint32(p + offset, value, true);
    }
    return 1;
  };
  api.wgpuDeviceCreateBuffer = (id, p) => add(object(id).createBuffer({...read('BufferDescriptor', p), mappedAtCreation:!!read('BufferDescriptor', p).mappedAtCreation}));
  api.wgpuDeviceCreateTexture = (id, p) => { const d = read('TextureDescriptor', p); d.viewFormats = Array.from({length:d.viewFormatCount}, (_, i) => enumName('TextureFormat', view().getUint32(d.viewFormats + i * 4, true))); return add(object(id).createTexture(d)); };
  api.wgpuTextureCreateView = (id, p) => { const d = read('TextureViewDescriptor', p); if (d) { if (d.mipLevelCount === 0xffffffff) delete d.mipLevelCount; if (d.arrayLayerCount === 0xffffffff) delete d.arrayLayerCount; } return add(object(id).createView(d)); };
  api.wgpuDeviceCreateSampler = (id, p) => add(object(id).createSampler(read('SamplerDescriptor', p)));
  api.wgpuDeviceCreateShaderModule = (id, p) => {
    const d = read('ShaderModuleDescriptor', p), chain = read('ChainedStruct', d.nextInChain);
    if (chain?.sType !== 'shader-source-wgsl') throw new Error('Only WGSL source chains are supported');
    return add(object(id).createShaderModule({label:d.label, code:read('ShaderSourceWGSL', d.nextInChain).code}));
  };
  api.wgpuDeviceCreateBindGroupLayout = (id, p) => {
    const d = read('BindGroupLayoutDescriptor', p);
    d.entries = array('BindGroupLayoutEntry', d.entries, d.entryCount).map(e => {
      const out = {binding:e.binding, visibility:e.visibility};
      if (e.buffer.type) out.buffer = {...e.buffer, hasDynamicOffset:!!e.buffer.hasDynamicOffset};
      if (e.sampler.type) out.sampler = e.sampler;
      if (e.texture.sampleType) out.texture = {...e.texture, multisampled:!!e.texture.multisampled};
      if (e.storageTexture.access) out.storageTexture = e.storageTexture;
      return out;
    });
    return add(object(id).createBindGroupLayout(d));
  };
  api.wgpuDeviceCreateBindGroup = (id, p) => {
    const d = read('BindGroupDescriptor', p); d.layout = object(d.layout);
    d.entries = array('BindGroupEntry', d.entries, d.entryCount).map(e => ({binding:e.binding, resource:e.buffer ? {buffer:object(e.buffer), offset:e.offset, size:e.size === Number(0xffffffffffffffffn) ? undefined : e.size} : object(e.sampler || e.textureView)}));
    return add(object(id).createBindGroup(d));
  };
  api.wgpuDeviceCreatePipelineLayout = (id, p) => { const d = read('PipelineLayoutDescriptor', p); d.bindGroupLayouts = handles(d.bindGroupLayouts, d.bindGroupLayoutCount); return add(object(id).createPipelineLayout(d)); };
  api.wgpuDeviceCreateRenderPipeline = (id, p) => add(object(id).createRenderPipeline(pipeline('RenderPipelineDescriptor', p)));
  api.wgpuDeviceCreateComputePipeline = (id, p) => add(object(id).createComputePipeline(pipeline('ComputePipelineDescriptor', p)));
  api.wgpuDeviceCreateCommandEncoder = (id, p) => add(object(id).createCommandEncoder(read('CommandEncoderDescriptor', p)));
  api.wgpuCommandEncoderBeginComputePass = (id, p) => { const d = read('ComputePassDescriptor', p); if (d) delete d.timestampWrites; return add(object(id).beginComputePass(d)); };
  api.wgpuCommandEncoderBeginRenderPass = (id, p) => {
    const d = read('RenderPassDescriptor', p);
    d.colorAttachments = array('RenderPassColorAttachment', d.colorAttachments, d.colorAttachmentCount).map(a => !a.view ? null : ({...a, view:object(a.view), resolveTarget:object(a.resolveTarget), depthSlice:a.depthSlice === 0xffffffff ? undefined : a.depthSlice}));
    d.depthStencilAttachment = read('RenderPassDepthStencilAttachment', d.depthStencilAttachment);
    if (d.depthStencilAttachment) { const a = d.depthStencilAttachment; a.view = object(a.view); a.depthReadOnly = !!a.depthReadOnly; a.stencilReadOnly = !!a.stencilReadOnly; }
    delete d.timestampWrites; delete d.occlusionQuerySet;
    return add(object(id).beginRenderPass(d));
  };
  api.wgpuCommandEncoderFinish = (id, p) => add(object(id).finish(read('CommandBufferDescriptor', p)));
  api.wgpuQueueSubmit = (id, n, p) => object(id).submit(handles(p, n));
  api.wgpuQueueWriteBuffer = (id, buf, offset, p, n) => object(id).writeBuffer(object(buf), number(offset), bytes(p, n));
  const textureCopy = p => {const d = read('TexelCopyTextureInfo', p); d.texture = object(d.texture); return d;};
  const bufferCopy = p => {const d = read('TexelCopyBufferInfo', p); return {...d.layout, buffer:object(d.buffer)};};
  api.wgpuQueueWriteTexture = (id, dst, p, n, layout, extent) => object(id).writeTexture(textureCopy(dst), bytes(p, n), read('TexelCopyBufferLayout', layout), read('Extent3D', extent));
  api.wgpuCommandEncoderCopyBufferToBuffer = (id, src, so, dst, off, n) => object(id).copyBufferToBuffer(object(src), number(so), object(dst), number(off), number(n));
  api.wgpuCommandEncoderCopyBufferToTexture = (id, src, dst, extent) => object(id).copyBufferToTexture(bufferCopy(src), textureCopy(dst), read('Extent3D', extent));
  api.wgpuCommandEncoderCopyTextureToBuffer = (id, src, dst, extent) => object(id).copyTextureToBuffer(textureCopy(src), bufferCopy(dst), read('Extent3D', extent));
  for (const prefix of ['Render', 'Compute']) {
    api[`wgpu${prefix}PassEncoderEnd`] = id => object(id).end();
    api[`wgpu${prefix}PassEncoderSetPipeline`] = (id, pipeline) => object(id).setPipeline(object(pipeline));
    api[`wgpu${prefix}PassEncoderSetBindGroup`] = (id, index, group, count, p) => object(id).setBindGroup(index, object(group), [...new Uint32Array(memory().buffer, p, count)]);
  }
  api.wgpuRenderPassEncoderSetVertexBuffer = (id, slot, buf, offset, size) => object(id).setVertexBuffer(slot, object(buf), number(offset), number(size));
  api.wgpuRenderPassEncoderSetIndexBuffer = (id, buf, format, offset, size) => object(id).setIndexBuffer(object(buf), enumName('IndexFormat', format), number(offset), number(size));
  api.wgpuRenderPassEncoderSetBlendConstant = (id, p) => object(id).setBlendConstant(read('Color', p));
  for (const name of ['Draw','DrawIndexed','SetScissorRect','SetStencilReference','SetViewport']) api['wgpuRenderPassEncoder' + name] = (id, ...args) => object(id)[name[0].toLowerCase() + name.slice(1)](...args);
  api.wgpuComputePassEncoderDispatchWorkgroups = (id, ...args) => object(id).dispatchWorkgroups(...args);
  function mappedRange(id, offset, size, write) {
    let m = mapped.get(id);
    if (!m) {
      const data = object(id).getMappedRange(offset, size);
      const ptr = getWasm().alloc(size);
      if (!ptr) return 0;
      bytes(ptr, size).set(new Uint8Array(data));
      m = {ptr, size, data, write}; mapped.set(id, m);
    }
    return m.ptr;
  }
  api.wgpuBufferGetMappedRange = (id, offset, size) => mappedRange(id, offset, size, true);
  api.wgpuBufferGetConstMappedRange = (id, offset, size) => mappedRange(id, offset, size, false);
  api.wgpuBufferUnmap = id => {
    const m = mapped.get(id);
    if (m) {
      if (m.write) new Uint8Array(m.data).set(bytes(m.ptr, m.size));
      getWasm().free(m.ptr, m.size); mapped.delete(id);
    }
    object(id).unmap();
  };
  api.wgpuBufferMapAsync = (id, mode, offset, size, callbackInfo) => {
    const callback = read('BufferMapCallbackInfo', callbackInfo);
    object(id).mapAsync(number(mode), offset, size).then(
      () => getWasm().mapped_callback(callback.callback, 1, callback.userdata1, callback.userdata2),
      () => getWasm().mapped_callback(callback.callback, 5, callback.userdata1, callback.userdata2),
    );
    return 1n;
  };
  const deviceId = add(device);
  return {imports:api, deviceId, addObject:add, releaseObject:release, initialize() {
    schema = JSON.parse(decoder.decode(bytes(getWasm().wgpu_layout_ptr(), getWasm().wgpu_layout_len())));
  }};
}
