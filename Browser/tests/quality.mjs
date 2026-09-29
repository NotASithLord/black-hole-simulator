import assert from 'node:assert/strict';
import { chooseRenderSize, adaptiveResolutionScale, adaptiveTiming, AdaptiveRetracePolicy, advanceDeadline } from '../src/quality.js';

let checks = 0;
function check(name, condition) { assert.ok(condition, name); checks++; console.log(`PASS ${name}`); }
const interactive = { samples: 1, pixels: 230400, traceBudget: 100, movingBudget: 24, minimumPixels: 4096 };
const max = { samples: 4, pixels: 8294400, traceBudget: 5000 };
const common = { width: 1920, height: 1080, mode: interactive, maxStorageBytes: 256 * 1024 * 1024, maxTextureDimension: 8192 };
const pixels = size => size.width * size.height;
const fits = (size, bytes, dimension) => size.width >= 8 && size.height >= 8 && size.width % 8 === 0 && size.height % 8 === 0
  && size.width <= dimension && size.height <= dimension && pixels(size) * size.samples * 16 <= bytes;

const weak = chooseRenderSize({ ...common, raysPerMS: 1, moving: true });
check('One ray/ms adapter reaches the irreducible 8×8 tile', weak.width === 8 && weak.height === 8 && weak.samples === 1);
const slow = chooseRenderSize({ ...common, raysPerMS: 100, moving: true });
check('Measured motion budget is honored below the bootstrap floor', pixels(slow) <= 100 * 24 && pixels(slow) < 4096);
const unknown = chooseRenderSize({ ...common, raysPerMS: 0 });
check('Uncalibrated adapter starts with bounded bootstrap resolution', pixels(unknown) <= 4096 && pixels(unknown) >= 64);
const fast = chooseRenderSize({ ...common, raysPerMS: 1e9 });
check('Fast adapter respects the mode pixel ceiling', pixels(fast) <= interactive.pixels && pixels(fast) > interactive.pixels * 0.9);
const smaller = chooseRenderSize({ ...common, raysPerMS: 1e9, scale: 0.5 });
check('Linear resolution scale squares the pixel budget', pixels(smaller) <= interactive.pixels * 0.25);
const expandable = { ...interactive, headroomPixels: 2073600 };
const expanded = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 1e9 });
check('Calibrated fast GPU can fill nine times the stationary pixel ceiling without extra samples',
  pixels(expanded) === 2073600 && expanded.samples === 1);
const affordable = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 3000 });
check('Expanded ceiling never raises the calibrated stationary trace-time budget',
  pixels(affordable) <= 3000 * interactive.traceBudget && pixels(affordable) > interactive.pixels);
const expandedMoving = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 1e9, moving: true });
const expandedEnergy = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 1e9, energy: true });
check('Camera motion and energy saving retain the inexpensive base pixel ceiling',
  pixels(expandedMoving) <= interactive.pixels && pixels(expandedEnergy) <= interactive.pixels);
const expandedUnknown = chooseRenderSize({ ...common, mode: expandable });
check('Unknown throughput never spends speculative stationary GPU headroom', pixels(expandedUnknown) <= interactive.minimumPixels);
const expandedScaled = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 1e9, scale: .5 });
check('Adaptive overload reduction applies equally to the expanded pixel budget', pixels(expandedScaled) <= expandable.headroomPixels * .25);
const expandedSmallView = chooseRenderSize({ ...common, mode: expandable, width: 640, height: 360, raysPerMS: 1e9 });
check('Calibrated headroom never renders beyond the supplied viewport', expandedSmallView.width === 640 && expandedSmallView.height === 360);
const expandedLimited = chooseRenderSize({ ...common, mode: expandable, raysPerMS: 1e9, maxStorageBytes: 1024, maxTextureDimension: 8 });
check('Expanded pixel policy still respects an irreducible hard GPU limit', fits(expandedLimited, 1024, 8));
let expandedCases = 0;
for (const samples of [1, 2, 4]) for (const raysPerMS of [0, .01, 97, 3000, 1e9]) {
  for (const moving of [false, true]) for (const energy of [false, true]) {
    const mode = { ...expandable, samples };
    const size = chooseRenderSize({ ...common, mode, raysPerMS, moving, energy, maxTextureDimension: 1024 });
    const ceiling = raysPerMS > 0 && !moving && !energy ? mode.headroomPixels : mode.pixels;
    const costBudget = raysPerMS > 0 ? raysPerMS * (moving ? mode.movingBudget : mode.traceBudget) / size.samples : mode.minimumPixels;
    assert.ok(pixels(size) <= Math.max(64, Math.min(ceiling, costBudget)));
    assert.ok(fits(size, common.maxStorageBytes, 1024));
    expandedCases++;
  }
}
check(`${expandedCases} calibrated headroom combinations preserve work, energy and hard-limit bounds`, true);
const retinaMax = chooseRenderSize({ ...common, width: 7680, height: 4320, mode: max, raysPerMS: 1e9 });
check('Four-sample max quality respects GPU storage budget', fits(retinaMax, common.maxStorageBytes, 8192) && retinaMax.samples === 4);
const maxMoving = chooseRenderSize({ ...common, mode: max, raysPerMS: 1000, moving: true });
check('Camera motion uses one sample and default 24ms budget', maxMoving.samples === 1 && pixels(maxMoving) <= 24000);
for (const [width, height] of [[8192, 8], [8, 8192], [1000000, 1], [1, 1000000]]) {
  const size = chooseRenderSize({ ...common, width, height, raysPerMS: 100, moving: true });
  check(`Extreme viewport ${width}×${height} stays within texture and time bounds`, fits(size, common.maxStorageBytes, 8192) && pixels(size) <= 2400);
}
const tinyLimit = chooseRenderSize({ ...common, maxStorageBytes: 1024, maxTextureDimension: 8, raysPerMS: 1e9 });
check('Smallest legal GPU allocation produces exactly one workgroup', fits(tinyLimit, 1024, 8));
check('Impossible hard limits are rejected', assert.throws(() => chooseRenderSize({ ...common, maxStorageBytes: 1000 }), RangeError) === undefined);
const narrow = chooseRenderSize({ ...common, width: 16000, height: 9000, maxTextureDimension: 1000, raysPerMS: 1e9 });
check('Non-power-of-two texture limit remains workgroup aligned', fits(narrow, common.maxStorageBytes, 1000));

let invariantCases = 0;
for (const width of [8, 73, 720, 3840, 20000]) for (const height of [8, 37, 1080, 20000]) {
  for (const raysPerMS of [0.01, 1, 97, 7000, 1e9]) for (const moving of [false, true]) {
    const size = chooseRenderSize({ ...common, width, height, mode: max, raysPerMS, moving, maxTextureDimension: 2048 });
    assert.ok(fits(size, common.maxStorageBytes, 2048));
    const throughputPixels = raysPerMS * (moving ? 24 : max.traceBudget) / size.samples;
    assert.ok(pixels(size) <= Math.max(64, throughputPixels));
    invariantCases++;
  }
}
check(`${invariantCases} size combinations preserve storage, dimensions and throughput bounds`, true);

check('Severe overload cuts linear resolution by 35%', Math.abs(adaptiveResolutionScale(1, 100, 16) - 0.65) < 1e-12);
check('Moderate overload cuts linear resolution at least 15%', adaptiveResolutionScale(1, 20, 16) <= 0.85);
check('Near-budget noise remains in the deadband', adaptiveResolutionScale(0.7, 16.5, 16) === 0.7 && adaptiveResolutionScale(0.7, 12, 16) === 0.7);
check('Clear headroom increases linear resolution by at most 3%', adaptiveResolutionScale(0.5, 4, 16) > 0.5 && adaptiveResolutionScale(0.5, 4, 16) <= 0.515);
check('Abundant GPU execution headroom permits bounded 10% linear recovery',
  adaptiveResolutionScale(.5, 4, 16, .2, 1, 'gpu') === .55);
check('Moderate GPU headroom retains conservative 3% recovery',
  adaptiveResolutionScale(.5, 8, 16, .2, 1, 'gpu') <= .515);
check('Unknown or completion-only evidence cannot enable accelerated recovery',
  adaptiveResolutionScale(.5, 1, 16, .2, 1, 'unknown') <= .515
  && adaptiveResolutionScale(.5, 1, 16, .2, 1, 'throughput') <= .515);
check('GPU overload correction is unaffected by faster recovery',
  adaptiveResolutionScale(.5, 100, 16, .2, 1, 'gpu') === adaptiveResolutionScale(.5, 100, 16));
let accelerated = .2, conservative = .2, acceleratedSteps = 0, conservativeSteps = 0;
while (accelerated < 1 && acceleratedSteps < 200) {
  // Synthetic cached-frame cost is quadratic in linear resolution. This is a
  // policy simulation, not a measured GPU benchmark or promised recovery time.
  accelerated = adaptiveResolutionScale(accelerated, 2 * accelerated ** 2, 12, .2, 1, 'gpu');
  acceleratedSteps++;
}
while (conservative < 1 && conservativeSteps < 200) {
  conservative = adaptiveResolutionScale(conservative, 2 * conservative ** 2, 12);
  conservativeSteps++;
}
check('Synthetic abundant-headroom recovery takes 17 decisions instead of 55', acceleratedSteps === 17 && conservativeSteps === 55);
let recoveryCases = 0;
for (const costAtFullSize of [1, 5, 12, 20, 100, 400]) {
  let scale = .2;
  for (let i = 0; i < 100; i++) {
    const cost = costAtFullSize * scale ** 2;
    const next = adaptiveResolutionScale(scale, cost, 12, .2, 1, 'gpu');
    assert.ok(next >= .2 && next <= 1);
    if (next > scale) assert.ok(costAtFullSize * next ** 2 < 12);
    scale = next;
    recoveryCases++;
  }
}
check(`${recoveryCases} synthetic GPU cost decisions never grow past the execution budget`, true);
check('Adaptive scale never crosses the requested bounds', adaptiveResolutionScale(0.21, 1000, 16) === 0.2 && adaptiveResolutionScale(0.99, 1, 16) === 1);
check('Missing or invalid timing cannot corrupt resolution', adaptiveResolutionScale(0.7, NaN, 16) === 0.7 && adaptiveResolutionScale(0.7, 0, 16) === 0.7);

const timingContext = { generation: 3, now: 10000, intervalMS: 1000 / 60 };
const completion60 = { generation: 3, at: 9990, samples: 12, ms: 1000 / 60 };
const fastGPU = adaptiveTiming({ ...timingContext, gpu: { generation: 3, at: 9980, ms: 5 }, completion: completion60, queueMS: 80 });
check('Fresh GPU execution cost wins over pipeline completion latency', fastGPU.source === 'gpu' && fastGPU.observedMS === 5
  && adaptiveResolutionScale(1, fastGPU.observedMS, fastGPU.budgetMS) === 1);
const maximumGPU = adaptiveTiming({ ...timingContext, gpuBudgetFraction: .875,
  gpu: { generation: 3, at: 9980, ms: 5 } });
check('Maximum fidelity budgets 87.5% of the target frame interval using execution evidence',
  maximumGPU.source === 'gpu' && maximumGPU.budgetMS === timingContext.intervalMS * .875);
check('Invalid or unbounded GPU budget requests preserve timing headroom',
  adaptiveTiming({ ...timingContext, gpuBudgetFraction: Infinity, gpu: { generation: 3, at: 9980, ms: 5 } }).budgetMS === timingContext.intervalMS * .72
  && adaptiveTiming({ ...timingContext, gpuBudgetFraction: 1, gpu: { generation: 3, at: 9980, ms: 5 } }).budgetMS === timingContext.intervalMS * .9);
check('Maximum fidelity only grows resolution with clear GPU headroom',
  adaptiveResolutionScale(.5, maximumGPU.budgetMS * .7, maximumGPU.budgetMS, .2, 1, 'gpu', true) > .5);
check('Maximum fidelity tolerates ordinary timestamp noise instead of retracing to chase utilization',
  [.76,.9,.99,1.01,1.11].every(fraction=>adaptiveResolutionScale(.5, maximumGPU.budgetMS * fraction, maximumGPU.budgetMS, .2, 1, 'gpu', true) === .5));
check('Maximum fidelity does not infer headroom from completion-only throughput',
  adaptiveResolutionScale(.5, 15, 16, .2, 1, 'throughput', true) === adaptiveResolutionScale(.5, 15, 16));
let fullBudgetCases = 0;
for (const costAtFullSize of [16, 20, 40, 100, 300]) for (const initial of [.2, .5, 1]) {
  let value = initial;
  for (let step = 0; step < 100; step++) {
    const previous = value;
    value = adaptiveResolutionScale(value, costAtFullSize * value ** 2, maximumGPU.budgetMS, .2, 1, 'gpu', true);
    assert.ok(value >= .2 && value <= 1);
    assert.ok(value <= previous * 1.1 + 1e-12);
  }
  const measuredFraction = costAtFullSize * value ** 2 / timingContext.intervalMS;
  assert.ok(measuredFraction >= .65 && measuredFraction <= .98);
  fullBudgetCases++;
}
check(`${fullBudgetCases} synthetic Max-fidelity workloads settle within their stable execution-time band`, true);

const retrace=new AdaptiveRetracePolicy();
const map={width:800,height:600,samples:4};
const candidate={width:880,height:656,samples:4};
const headroom={observedMS:5,budgetMS:15,source:'gpu'};
const retraceRequest={generation:1,evidence:headroom,current:map,next:candidate};
const consider=(request)=>retrace.consider({...request,evidence:{...request.evidence,at:request.evidence.at??request.now}});
check('Cached-map adaptation waits for independent sustained timing windows',
  !consider({...retraceRequest,now:1000})&&!consider({...retraceRequest,now:1500})
  &&!consider({...retraceRequest,now:2200})&&!consider({...retraceRequest,now:3400}));
for(let now=4600;now<15000;now+=1200) assert.equal(consider({...retraceRequest,now}),false);
check('A useful cached-map upgrade waits at least fifteen seconds before spending trace work',consider({...retraceRequest,now:15400}));
retrace.reset(16000);
const expensive={...retraceRequest,traceMS:4000};
for(let now=17200;now<64000;now+=1200) assert.equal(consider({...expensive,now}),false);
check('Expensive maps must amortize the previous trace before an upgrade',consider({...expensive,now:65200}));
retrace.reset(0);
const smallerMap={width:600,height:448,samples:4};
const overload={...retraceRequest,next:smallerMap,evidence:{observedMS:30,budgetMS:15,source:'gpu'}};
check('One overload window cannot discard a stable ray map',!consider({...overload,now:20000}));
check('Changed workload generations discard earlier adaptation votes',!consider({...overload,now:21200,generation:2})
  &&!consider({...overload,now:22400,generation:2})&&consider({...overload,now:23600,generation:2}));
retrace.reset(0);
check('Quantized pixel changes below fifteen percent do not buy an expensive retrace',
  !consider({...retraceRequest,now:20000,next:{width:816,height:608,samples:4}}));
check('Adaptation never requests a lower-sample interactive preview for a stationary scene',
  !consider({...overload,now:21200,next:{...smallerMap,samples:1}}));
check('A changed calibration baseline cannot reverse the requested timing correction',
  !consider({...retraceRequest,now:22400,next:smallerMap}));
retrace.reset(0);
for(const now of [20000,21200]) assert.equal(consider({...overload,now}),false);
check('A long evidence gap discards stale adaptation votes',!consider({...overload,now:28000}));
for(const source of ['gpu','throughput']) {
  retrace.reset(0);
  const request={...overload,evidence:{...overload.evidence,source,at:20000}};
  assert.equal(consider({...request,now:20000}),false);
  assert.equal(consider({...request,now:21200}),false);
  assert.equal(retrace.count,1);
  check(`The same ${source} timing sample cannot vote twice even 1.2 seconds later`,true);
}
retrace.reset(0);
const conservativeUpgrade={...retraceRequest,next:{width:824,height:616,samples:4},minimumPixelChange:.05};
for(const now of [20000,21200,22400]) assert.equal(consider({...conservativeUpgrade,now}),false);
check('Conservative three-percent linear recovery remains possible after sustained headroom and dwell',
  consider({...conservativeUpgrade,now:23600}));
retrace.reset(0);
check('Conservative recovery threshold never permits tiny overload reductions',
  !consider({...overload,minimumPixelChange:.05,next:{width:784,height:568,samples:4},now:20000}));
for(const timestampPeriod of [3000,3600,3750,4000]) {
  retrace.reset(0);
  let approvals=0;
  for(let now=1210;now<=120000;now+=1210) {
    const cost=timestampPeriod/30;
    const evidence=adaptiveTiming({generation:1,now,intervalMS:1000/60,gpuBudgetFraction:.875,
      gpu:{generation:1,at:Math.floor(now/timestampPeriod)*timestampPeriod,ms:cost},
      completion:{generation:1,at:now,ms:cost,samples:12}});
    if(retrace.consider({...overload,now,evidence})) approvals++;
  }
  check(`Sustained ${(30000/timestampPeriod).toFixed(1)} FPS overload can shrink despite sparse GPU timestamps and fallback switching`,approvals>0);
}
const steady60 = adaptiveTiming({ ...timingContext, completion: completion60 });
check('Timestamp-free 60FPS completion throughput keeps full-frame budget', steady60.source === 'throughput'
  && adaptiveResolutionScale(1, steady60.observedMS, steady60.budgetMS) === 1);
check('Max-fidelity timing fraction never discounts timestamp-free completion cadence',
  adaptiveTiming({ ...timingContext, gpuBudgetFraction: .875, completion: completion60 }).budgetMS === timingContext.intervalMS);
const steady20 = adaptiveTiming({ ...timingContext, intervalMS: 50, completion: { generation: 3, at: 9990, samples: 10, ms: 50 } });
check('Deliberately capped 20FPS is not mistaken for GPU overload', adaptiveResolutionScale(1, steady20.observedMS, steady20.budgetMS) === 1);
const slowFrames = adaptiveTiming({ ...timingContext, completion: { generation: 3, at: 9990, samples: 10, ms: 25 } });
check('A genuine completion throughput deficit requests lower resolution', adaptiveResolutionScale(1, slowFrames.observedMS, slowFrames.budgetMS) < 1);
const oldGPU = adaptiveTiming({ ...timingContext, gpu: { generation: 2, at: 9980, ms: 90 }, completion: completion60 });
check('A timestamp from old render resources cannot shrink new resources', oldGPU.source === 'throughput' && oldGPU.observedMS === 1000 / 60);
const expiredGPU = adaptiveTiming({ ...timingContext, gpu: { generation: 3, at: 7000, ms: 90 }, completion: completion60 });
check('Expired GPU timing falls back to current completion throughput', expiredGPU.source === 'throughput');
check('Stale or uninitialized evidence holds resolution',
  adaptiveTiming(timingContext) === null
  && adaptiveTiming({ ...timingContext, completion: { ...completion60, at: 7000 } }) === null
  && adaptiveTiming({ ...timingContext, completion: { ...completion60, generation: 2 } }) === null);
check('Small IPC completion bursts cannot masquerade as sustained throughput',
  adaptiveTiming({ ...timingContext, completion: { ...completion60, samples: 2 } }) === null
  && adaptiveTiming({ ...timingContext, completion: { ...completion60, ms: 0 } }) === null
  && adaptiveTiming({ ...timingContext, completion: { ...completion60, ms: 1 } }) === null);
check('Invalid/future timing is excluded from adaptation',
  adaptiveTiming({ ...timingContext, gpu: { generation: 3, at: 9990, ms: NaN } }) === null
  && adaptiveTiming({ ...timingContext, gpu: { generation: 3, at: 10001, ms: 1 } }) === null
  && adaptiveTiming({ ...timingContext, completion: { ...completion60, samples: Infinity } }) === null);

const frameInterval = 1000 / 60;
let deadline = 0, rendered = 0;
for (let frame = 0; frame < 600; frame++) {
  const now = frame * frameInterval + (frame % 2 ? 0.4 : -0.4);
  if (now >= deadline - 1) { rendered++; deadline = advanceDeadline(now, deadline, frameInterval); }
}
check('Jittered 60Hz requestAnimationFrame cadence retains every due frame', rendered === 600);
check('Ten seconds of cadence has no accumulating scheduling drift', Math.abs(deadline - 600 * frameInterval) < 1e-8);
const lateDeadline = advanceDeadline(50.4, 50, frameInterval);
check('Late submission retains fractional deadline remainder', Math.abs(lateDeadline - (50 + frameInterval)) < 1e-12);
const resumed = advanceDeadline(1234, 100, frameInterval);
check('Long stall skips missed slots without catch-up burst', resumed > 1234 && resumed <= 1234 + frameInterval);
const earlyDeadline = advanceDeadline(99.5, 100, frameInterval);
check('One-ms-early admission advances exactly one scheduled slot', Math.abs(earlyDeadline - (100 + frameInterval)) < 1e-12);
let lowRateDeadline = 0, lowRateFrames = 0;
for (let frame = 0; frame < 600; frame++) {
  const now = frame * frameInterval;
  if (now >= lowRateDeadline - 1) { lowRateFrames++; lowRateDeadline = advanceDeadline(now, lowRateDeadline, 50); }
}
check('Energy-saver 20FPS cadence selects one in three 60Hz frames', lowRateFrames === 200);
console.log(`${checks}/${checks} pure quality and pacing checks passed.`);
