// webgpu.h enum spellings differ from Web IDL for several compressed families.
// Canonical names: https://www.w3.org/TR/webgpu/#enumdef-gputextureformat
export function textureFormatName(raw) {
  if (raw.startsWith('depth') && raw.endsWith('_stencil8')) return raw.slice(0, -9).replaceAll('_', '') + '-stencil8';
  if (raw.startsWith('bc6_hrgb_')) return 'bc6h-rgb-' + raw.slice('bc6_hrgb_'.length).replaceAll('_', '-');
  if (raw.startsWith('bc')) return raw.replaceAll('_', '-');
  if (raw.startsWith('etc2_')) return 'etc2-' + raw.slice(5).replace(/_srgb$/, '-srgb').replaceAll('_', '');
  if (raw.startsWith('eac')) return 'eac-' + raw.slice(3).replaceAll('_', '');
  if (raw.startsWith('astc')) return 'astc-' + raw.slice(4).replaceAll('_', '-');
  return raw.replace(/_srgb$/, '-srgb').replaceAll('_', '');
}
