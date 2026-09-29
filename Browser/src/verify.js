import {runtimeInfo} from './diagnostics.js';
// End-to-end checks run on the actual browser adapter and production shaders.
// Native results are a port-regression reference, not an independent GR solver.

const finite = Number.isFinite;
const relative = (actual, expected) => Math.abs(actual - expected) / Math.max(1, Math.abs(expected));
const percentile = (sorted, fraction) => sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];

async function fixture(name) {
  const response = await fetch(new URL(`../fixtures/${name}`, import.meta.url));
  if (!response.ok) throw new Error(`Verification fixture ${name}: HTTP ${response.status}`);
  return response.json();
}

function imageStatistics(pixels) {
  let finiteValues = 0, litPixels = 0, unresolvedPixels = 0, sum = 0, peak = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    for (let channel = 0; channel < 4; channel++) finiteValues += finite(pixels[i + channel]) ? 1 : 0;
    const luminance = 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2];
    if (luminance > 1e-6) litPixels++;
    if (pixels[i + 3] < 0) unresolvedPixels++;
    sum += Math.max(0, luminance);
    peak = Math.max(peak, pixels[i], pixels[i + 1], pixels[i + 2]);
  }
  return { values: pixels.length, finiteValues, pixels: pixels.length / 4, litPixels,
    unresolvedPixels, meanLuminance: sum / Math.max(1, pixels.length / 4), peak };
}

function imageDifference(before, after) {
  if (before.length !== after.length) return { compatible: false };
  let absolute = 0, baseline = 0, maxNormalized = 0, changedPixels = 0;
  for (let i = 0; i < before.length; i += 4) {
    let changed = false;
    for (let channel = 0; channel < 3; channel++) {
      const a = before[i + channel], b = after[i + channel], difference = Math.abs(a - b);
      const normalized = difference / Math.max(1, Math.abs(a), Math.abs(b));
      absolute += difference;
      baseline += Math.abs(a);
      maxNormalized = Math.max(maxNormalized, normalized);
      changed ||= normalized > 1e-5;
    }
    if (changed) changedPixels++;
  }
  return { compatible: true, normalizedL1: absolute / Math.max(1e-20, baseline), maxNormalized, changedPixels };
}

function driftSummary(rows) {
  const values = rows.filter(row => row.statusMatches && row.finite);
  return {
    count: rows.length, comparable: values.length,
    maxRelativeRadius: values.reduce((maximum, row) => Math.max(maximum, row.relativeRadius), 0),
    maxAzimuthRadians: values.reduce((maximum, row) => Math.max(maximum, row.azimuthRadians), 0),
    maxWrappedAzimuthRadians: values.reduce((maximum, row) => Math.max(maximum, row.wrappedAzimuthRadians), 0),
    maxRelativeDelay: values.reduce((maximum, row) => Math.max(maximum, row.relativeDelay), 0),
    worst: [...values].sort((a, b) => b.azimuthRadians - a.azimuthRadians).slice(0, 5),
  };
}

/** Caller must stop its animation/adaptation loop while this owns the renderer. */
export async function verify(renderer, log = () => {}, {benchmark=false}={}) {
  const started = performance.now();
  const checks = [];
  const report = {
    status: 'running', checks,
    adapter: Object.fromEntries(['vendor', 'architecture', 'device', 'description'].map(key => [key, renderer.adapter?.info?.[key] || 'undisclosed'])),
    environment: runtimeInfo(renderer),
    scope: 'Production WebGPU port against native Metal fixtures, compiled WASM invariants, HDR image motion/isolation and cached-frame throughput. This is not a new independent proof of the disk model.',
  };
  const original = { settings: { ...renderer.settings }, width: renderer.width, height: renderer.height, samples: renderer.samples };
  const check = (name, passed, details = {}) => {
    checks.push({ name, passed: !!passed, ...details });
    log(`${passed ? 'PASS' : 'FAIL'} ${name}`);
  };
  const errors = [];
  const onError = event => errors.push(event.error?.message || String(event.error));
  renderer.device.addEventListener('uncapturederror', onError);
  renderer.device.pushErrorScope('validation');
  try {
    check('Browser exposes WebGPU in a secure context', !!navigator.gpu && globalThis.isSecureContext);
    const core = renderer.core;
    check('Compiled physics ABI and table dimensions', core.abi_version() === 1 && core.radial_count() === 4096 && core.spectral_count() === 2048);
    check('Compiled Schwarzschild and high-spin ISCO references',
      Math.abs(core.isco(0) - 6) < 1e-12 && Math.abs(core.isco(0.998) - 1.2369706551751847) < 1e-11);
    const metadata = Array.from(renderer.meta);
    report.model = { iscoM: metadata[0], outerRadiusM: metadata[1], peakTemperatureK: metadata[4], gravitationalTimeSeconds: metadata[7], efficiency: metadata[8], eddingtonRatio: metadata[9], photosphereCoefficientM: metadata[10] };
    check('Initialized physical metadata is finite and ordered', metadata.length === 11 && metadata.every(finite) && metadata[1] > metadata[0] && metadata[4] > 0 && metadata[7] > 0);
    const radial = new Float32Array(core.memory.buffer, core.radial_ptr(), core.radial_count() * 4);
    const spectral = new Float32Array(core.memory.buffer, core.spectral_ptr(), core.spectral_count() * 4);
    check('WASM disk and spectral tables are finite', radial.every(finite) && spectral.every(finite) && radial[0] === 0 && radial[1] === 0);
    if (!(renderer.width > 0 && renderer.height > 0)) await renderer.rebuild(32, 24, 1);

    log('Tracing 177 native reference rays…');
    const [input, reference] = await Promise.all([fixture('physics_cases.json'), fixture('native-reference.json')]);
    const cases = input.cases;
    const expected = new Map(reference.cases.map(item => [item.id, item]));
    check('Complete unique 177-ray native reference fixture', cases.length === 177 && expected.size === 177 && new Set(cases.map(item => item.id)).size === 177 && cases.every(item => expected.has(item.id)));
    const actual = await renderer.validateCases(cases);
    const rows = actual.map((item, index) => {
      const id = item.id || cases[index]?.id;
      const result = Array.from(item.result || item);
      const target = expected.get(id)?.result;
      const valid = result.length === 16 && result.every(finite) && !!target;
      if (!valid) return { id, finite: false, statusMatches: false, critical: /^boundary-/.test(id) };
      const azimuth = Math.abs(result[6] - target[6]);
      return { id, finite: true, critical: /^boundary-/.test(id),
        expectedStatus: target[4], actualStatus: result[4], statusMatches: result[4] === target[4],
        initialConstantsError: Math.max(...[0, 1, 2].map(column => relative(result[column], target[column]))),
        initialNullResidual: result[3], finalNullResidual: result[11],
        acceptedSteps: result[12], rejectedSteps: result[13], localError: result[14], minimumRadius: result[15],
        relativeRadius: relative(result[5], target[5]), azimuthRadians: azimuth,
        wrappedAzimuthRadians: Math.abs(Math.atan2(Math.sin(azimuth), Math.cos(azimuth))),
        relativeDelay: relative(result[7], target[7]),
      };
    });
    const finiteRows = rows.filter(row => row.finite);
    const maxConstants = finiteRows.reduce((maximum, row) => Math.max(maximum, row.initialConstantsError), 0);
    const maxInitialNull = finiteRows.reduce((maximum, row) => Math.max(maximum, row.initialNullResidual), 0);
    report.rays = {
      count: rows.length, classificationsMatched: rows.filter(row => row.statusMatches).length,
      maxInitialConstantsNormalizedError: maxConstants, maxInitialNullResidual: maxInitialNull,
      maxFinalNullResidual: finiteRows.reduce((maximum, row) => Math.max(maximum, row.finalNullResidual), 0),
      ordinary: driftSummary(rows.filter(row => !row.critical)), critical: driftSummary(rows.filter(row => row.critical)),
      mismatches: rows.filter(row => !row.statusMatches || !row.finite),
      endpointNote: 'Endpoint drift is reported separately and is not folded into the classification pass. Critical rays amplify finite-precision and backend differences; wrapped and unwrapped azimuth errors are both retained.',
      results: rows,
    };
    check('Every reference ray returns sixteen finite values', rows.length === 177 && finiteRows.length === 177);
    check('All 177 capture/disk/escape classifications match native', rows.length === 177 && rows.every(row => row.statusMatches), { matched: report.rays.classificationsMatched, total: rows.length });
    check('Initial Kerr constants agree numerically with native', finiteRows.length === 177 && maxConstants < 5e-5, { maximumNormalizedError: maxConstants, tolerance: 5e-5 });
    check('Initial null constraint remains bounded', finiteRows.length === 177 && maxInitialNull < 1e-4, { maximumResidual: maxInitialNull, tolerance: 1e-4 });
    check('Final null constraint remains bounded', finiteRows.length === 177 && report.rays.maxFinalNullResidual < 3e-4,
      {maximumResidual:report.rays.maxFinalNullResidual,tolerance:3e-4});

    log('Checking finite HDR output, disk movement and scientific isolation…');
    Object.assign(renderer.settings, {
      mass: 1e8, accretion: 0.1, outerRadius: 30, thickness: 0.75, quality: 'auto',
      spin: 0.82, cameraDistance: 80, cameraYaw: 0, cameraPitch: 0.12, fov: 0.48,
      lookYaw: 0, lookPitch: 0, diagnosticMode: false, energy: false,
      appearance: 'radiant', rotation: true, playback: 1000,
      paletteTemperature: 7000, materialStrength: 0.85, glowStrength: 0.28, fluctuations: 0.06,
    });
    renderer.updateModel();
    await renderer.rebuild(480, 320, 1);
    const initialTraces = renderer.traceCount;
    await renderer.render(0);
    const radiantStart = (await renderer.readHDR()).slice();
    await renderer.render(8000);
    const radiantEnd = (await renderer.readHDR()).slice();
    const first = imageStatistics(radiantStart), last = imageStatistics(radiantEnd);
    const motion = imageDifference(radiantStart, radiantEnd);
    report.image = { width: renderer.width, height: renderer.height, samples: renderer.samples, first, last, motion };
    check('Radiant HDR images contain only finite values', first.values === 480 * 320 * 4 && first.finiteValues === first.values && last.finiteValues === last.values);
    check('Rendered HDR image contains visible emission', first.litPixels > 100 && first.meanLuminance > 1e-5, { litPixels: first.litPixels, peakRadiance: first.peak });
    check('Disk material changes with source time', motion.compatible && motion.changedPixels > 10 && motion.normalizedL1 > 1e-5, motion);
    check('Disk animation reuses Kerr geometry', finite(initialTraces) && renderer.traceCount === initialTraces, { before: initialTraces, after: renderer.traceCount });

    log('Profiling 30 cached WebGPU frames…');
    for (let i = 0; i < 4; i++) await renderer.render(8000 + i * 1000 / 60);
    const profileTraces = renderer.traceCount;
    const times = [];
    const wallStart = performance.now();
    for (let i = 0; i < 30; i++) times.push(await renderer.render(9000 + i * 1000 / 60));
    const elapsed = performance.now() - wallStart;
    const sorted = [...times].sort((a, b) => a - b);
    report.performance = {
      width: renderer.width, height: renderer.height, samples: renderer.samples, frames: times.length,
      metric: 'Serial submission-to-completion notification latency. Includes browser polling/scheduling; this rate is NOT live display FPS or isolated GPU execution time.',
      medianMS: percentile(sorted, 0.5), p95MS: percentile(sorted, 0.95), minimumMS: sorted[0], maximumMS: sorted.at(-1),
      totalWallMS: elapsed, cachedFramesPerSecond: times.length * 1000 / elapsed, frameTimesMS: times,
      traceCountBefore: profileTraces, traceCountAfter: renderer.traceCount,
    };
    check('Thirty cached frames complete with finite timings', times.length === 30 && times.every(time => finite(time) && time > 0));
    check('Cached-frame profiling performs no additional ray tracing', finite(profileTraces) && renderer.traceCount === profileTraces);

    log('Checking motion-first rendering, including a long-running source clock…');
    Object.assign(renderer.settings,{quality:'interactive',thickness:0,glowStrength:0,fluctuations:0,playback:4000});
    renderer.updateModel();await renderer.rebuild(320,192,1);
    const motionTraces=renderer.traceCount,images=[];
    for(const time of [0,8000,4_000_000,4_008_000]) {
      await renderer.render(time);images.push(await renderer.readHDR());
    }
    const motionStats=images.map(imageStatistics),earlyMotion=imageDifference(images[0],images[1]),lateMotion=imageDifference(images[2],images[3]);
    report.motionFirst={width:320,height:192,samples:1,images:motionStats,earlyMotion,lateMotion};
    check('Motion-first HDR remains finite and visibly emitting',motionStats.every(stats=>stats.finiteValues===stats.values&&stats.litPixels>100));
    check('Motion-first disk moves at startup and after long playback',earlyMotion.changedPixels>10&&lateMotion.changedPixels>10&&earlyMotion.normalizedL1>1e-5&&lateMotion.normalizedL1>1e-5);
    check('Motion-first animation does not retrace geodesics',renderer.traceCount===motionTraces);
    const lightTimes=[];
    for(let i=0;i<30;i++)lightTimes.push(await renderer.render(8000+i*4000/60));
    const lightSorted=[...lightTimes].sort((a,b)=>a-b);
    report.motionFirst.performance={frames:30,medianMS:percentile(lightSorted,.5),p95MS:percentile(lightSorted,.95),
      metric:'Submission-to-completion wall time at 320×192; not an equal-resolution comparison to full material.',frameTimesMS:lightTimes};
    check('Thirty motion-first frames complete with finite timings',lightTimes.every(value=>finite(value)&&value>0));

    // Scientific is the native thin-disk reference, so mode changes require a
    // new geometry map. Source-time changes within that map do not.
    Object.assign(renderer.settings, { appearance: 'scientific', quality:'auto', fluctuations: 0 });
    await renderer.rebuild(480, 320, 1);
    await renderer.render(0);
    const scientificStart = (await renderer.readHDR()).slice();
    await renderer.render(8000);
    const scientificEnd = (await renderer.readHDR()).slice();
    const scientific = imageDifference(scientificStart, scientificEnd);
    const scienceStats = imageStatistics(scientificStart), scienceEndStats = imageStatistics(scientificEnd);
    report.image.scientific = { first: scienceStats, last: scienceEndStats, difference: scientific };
    check('Scientific HDR images are finite and nonblack', scienceStats.finiteValues === scienceStats.values && scienceEndStats.finiteValues === scienceEndStats.values && scienceStats.litPixels > 100);
    check('Steady Scientific emission is time invariant', scientific.compatible && scientific.maxNormalized <= 1e-6, { ...scientific, tolerance: 1e-6 });
    log('Checking the default four-ray Max-fidelity workload…');
    Object.assign(renderer.settings,{quality:'max',appearance:'radiant',thickness:0,glowStrength:0,
      cameraYaw:-.28,cameraPitch:.06,materialStrength:.9,fluctuations:0,playback:4000});
    renderer.updateModel();await renderer.rebuild(240,160,4);await renderer.render(0);
    const maxStart=(await renderer.readHDR()).slice();
    await renderer.render(8000);const maxEnd=await renderer.readHDR();
    const maxFirst=imageStatistics(maxStart),maxLast=imageStatistics(maxEnd),maxMotion=imageDifference(maxStart,maxEnd);
    report.maxFidelity={width:240,height:160,samples:4,first:maxFirst,last:maxLast,motion:maxMotion};
    check('Default Max-fidelity HDR is finite, visibly emitting and animated',
      maxFirst.finiteValues===maxFirst.values&&maxLast.finiteValues===maxLast.values&&
      maxFirst.litPixels>100&&maxMotion.changedPixels>10&&maxMotion.normalizedL1>1e-5);
    check('Default Max-fidelity reference image has no unresolved rays',maxFirst.unresolvedPixels===0&&maxLast.unresolvedPixels===0,
      {first:maxFirst.unresolvedPixels,last:maxLast.unresolvedPixels});
    if(benchmark) {
      const {benchmarkRenderer}=await import('./benchmark.js');
      report.benchmark=await benchmarkRenderer(renderer,log);
      check('Cross-engine benchmark scenarios complete with finite HDR and bounded backlog',report.benchmark.status==='completed');
    }
  } catch (error) {
    report.error = error?.stack || String(error);
    check('Verification completes without an exception', false, { error: error?.message || String(error) });
  } finally {
    try {
      for (const key of Object.keys(renderer.settings)) if (!(key in original.settings)) delete renderer.settings[key];
      Object.assign(renderer.settings, original.settings);
      renderer.updateModel();
      if (original.width > 0 && original.height > 0) await renderer.rebuild(original.width, original.height, original.samples);
    } catch (error) {
      check('Original render settings restored', false, { error: error?.message || String(error) });
    }
    try {
      const error = await renderer.device.popErrorScope();
      if (error) errors.push(error.message);
    } catch (error) { errors.push(error?.message || String(error)); }
    renderer.device.removeEventListener('uncapturederror', onError);
    report.webgpuErrors = errors;
    check('No WebGPU validation errors during verification', errors.length === 0, { errors });
  }
  report.passed = checks.filter(item => item.passed).length;
  report.timingHealth=renderer.timingHealth?.status??null;
  report.failed = checks.length - report.passed;
  report.status = report.failed === 0 ? 'passed' : 'failed';
  report.elapsedMS = performance.now() - started;
  log(`${report.passed}/${checks.length} browser checks passed.`);
  return report;
}
