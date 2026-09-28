// Classify reported engines for reports, never for selecting rendering code.
export function engineFromUserAgent(ua='') {
  if(/Firefox\//.test(ua))return 'gecko';
  if(/(?:Chrome|Chromium|Edg)\//.test(ua))return 'chromium';
  if(/AppleWebKit\//.test(ua)&&/Safari\//.test(ua))return 'webkit';
  return 'unknown';
}
export function runtimeInfo(renderer) {
  const ua=navigator.userAgent||'',adapter=renderer?.adapter,device=renderer?.device;
  const names=['maxStorageBufferBindingSize','maxBufferSize','maxTextureDimension2D',
    'maxComputeInvocationsPerWorkgroup','maxComputeWorkgroupsPerDimension'];
  return {date:new Date().toISOString(),engine:engineFromUserAgent(ua),userAgent:ua,
    secureContext:globalThis.isSecureContext,webgpu:!!navigator.gpu,
    adapter:adapter?Object.fromEntries(['vendor','architecture','device','description'].map(k=>[k,adapter.info?.[k]||'undisclosed'])):null,
    features:adapter?Array.from(adapter.features||[]).sort():[],
    deviceLimits:device?Object.fromEntries(names.map(k=>[k,device.limits[k]])):null,
    timestampQuery:!!renderer?.queries,startupMS:renderer?.startupMS??null};
}
