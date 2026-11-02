import assert from 'node:assert/strict';
import {textureFormatName} from './formats.mjs';
// Web IDL names, independent of the native header's underscore conventions.
const examples = {
  rgba8_unorm: 'rgba8unorm', rgba8_unorm_srgb: 'rgba8unorm-srgb',
  rg11_b10_ufloat: 'rg11b10ufloat', rgb10_a2_uint: 'rgb10a2uint',
  depth24_plus_stencil8: 'depth24plus-stencil8', depth32_float: 'depth32float',
  depth32_float_stencil8: 'depth32float-stencil8',
  bc1_rgba_unorm: 'bc1-rgba-unorm', bc3_rgba_unorm_srgb: 'bc3-rgba-unorm-srgb',
  bc4_r_snorm: 'bc4-r-snorm', bc5_rg_unorm: 'bc5-rg-unorm',
  bc6_hrgb_ufloat: 'bc6h-rgb-ufloat', bc6_hrgb_float: 'bc6h-rgb-float',
  bc7_rgba_unorm: 'bc7-rgba-unorm', etc2_rgb8_unorm: 'etc2-rgb8unorm',
  etc2_rgb8_unorm_srgb: 'etc2-rgb8unorm-srgb', etc2_rgb8_a1_unorm: 'etc2-rgb8a1unorm',
  etc2_rgba8_unorm_srgb: 'etc2-rgba8unorm-srgb', eacr11_unorm: 'eac-r11unorm',
  eacr11_snorm: 'eac-r11snorm', eacrg11_unorm: 'eac-rg11unorm',
  astc4x4_unorm: 'astc-4x4-unorm', astc12x12_unorm_srgb: 'astc-12x12-unorm-srgb',
};
for (const [native, web] of Object.entries(examples)) assert.equal(textureFormatName(native), web, native);
console.log(`${Object.keys(examples).length} WebGPU format spellings checked`);
