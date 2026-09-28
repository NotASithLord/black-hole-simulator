import assert from 'node:assert/strict';
import {benchmarkRenderer, summarize} from '../src/benchmark.js';
import {engineFromUserAgent, runtimeInfo} from '../src/diagnostics.js';
import {defaults} from '../src/renderer.js';

// Exercise the actual benchmark controller with a deterministic renderer/DOM.
// No browser is opened; no WebGPU call, shader execution or GPU timing occurs.
const descriptors = new Map(['document', 'performance', 'requestAnimationFrame',
  'cancelAnimationFrame', 'navigator', 'isSecureContext'].map(name =>
  [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
const install = (name, value) => Object.defineProperty(globalThis, name,
  {value, writable: true, configurable: true});
const flush = () => new Promise(resolve => setImmediate(resolve));
let passed = 0, failed = 0;
async function test(name, callback) {
  try { await callback(); passed++; console.log(`PASS ${name}`); }
  catch (error) { failed++; console.error(`FAIL ${name}: ${error.stack}`); }
}

function host(options = {}) {
  let now = 1000, nextFrame = 1, requested = 0;
  const callbacks = new Map(), listeners = new Map();
  const document = {
    hidden: !!options.initiallyHidden,
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    removeEventListener(name, callback) { listeners.get(name)?.delete(callback); },
    setHidden(hidden) {
      this.hidden = hidden;
      for (const callback of [...(listeners.get('visibilitychange') || [])]) callback();
    },
  };
  install('document', document);
  install('performance', {now: () => now});
  install('requestAnimationFrame', callback => {
    const id = nextFrame++;
    callbacks.set(id, callback);
    requested++;
    // Hiding after registration mimics the browser ceasing future callbacks.
    if (requested === options.hideAtRequestedFrame) queueMicrotask(() => document.setHidden(true));
    return id;
  });
  install('cancelAnimationFrame', id => callbacks.delete(id));
  const originalSettings = {...defaults, spin: .65, exposureEV: 1.25,
    paletteTemperature: 5200, passage: true, cameraYaw: .91};
  const original = {settings: {...originalSettings}, width: 72, height: 48,
    samples: 2, canvasWidth: 997, canvasHeight: 613};
  const events = [], rebuilds = [], renders = [], snapshots = [];
  let measured = 0, asynchronous = 0, reads = 0, drains = 0;
  const faults = {
    render: new Error('injected render failure'), drain: new Error('injected queue drain failure'),
    restore: new Error('injected restoration rebuild failure'),
  };
  const renderer = {
    settings: originalSettings, width: original.width, height: original.height,
    samples: original.samples, canvas: {width: original.canvasWidth, height: original.canvasHeight},
    queries: options.timestamps === false ? undefined : {}, traceCount: 7,
    pendingFrames: 0, traceMS: 0, gpuMS: 0, emissionMS: 0, presentationMS: 0,
    device: {queue: {async onSubmittedWorkDone() {
      events.push('drain'); drains++;
      if (options.drainFailures?.includes(drains)) throw faults.drain;
      renderer.pendingFrames = 0; now += .25;
    }}},
    updateModel() { events.push('model'); },
    async rebuild(width, height, samples) {
      events.push('rebuild');
      rebuilds.push({width, height, samples, settings: {...this.settings},
        canvasWidth: this.canvas.width, canvasHeight: this.canvas.height});
      if (options.restoreError && width === original.width && height === original.height) throw faults.restore;
      Object.assign(this, {width, height, samples, traceMS: 2.5}); now += 2.5;
      this.traceCount++;
      if (options.rebuildError && rebuilds.length === 1) throw new Error('injected rebuild failure');
      return true;
    },
    async render(time, settings = {}) {
      const isAsync = settings.wait === false;
      renders.push({time, settings: {...settings}, width: this.width, height: this.height,
        canvasWidth: this.canvas.width, canvasHeight: this.canvas.height, source: {...this.settings}});
      events.push(isAsync ? 'async-render' : 'wait-render'); now += isAsync ? .03 : .8;
      if (settings.measure) {
        measured++;
        if (options.retrace && measured === 1) this.traceCount++;
        if (options.renderError && measured === 1) throw faults.render;
        if (options.hideAtMeasured === measured) document.setHidden(true);
      }
      if (options.hideAtWarmup && renders.length === 1) document.setHidden(true);
      this.gpuMS = .6; this.emissionMS = .35; this.presentationMS = .25;
      if (settings.measure) {
        for (const key of ['gpuMS', 'emissionMS', 'presentationMS']) {
          if (Object.hasOwn(options.timings || {}, key)) this[key] = options.timings[key];
        }
      }
      if (isAsync) {
        asynchronous++;
        if (options.asyncError && asynchronous === 1) throw new Error('injected async failure');
        if (options.dropAll || (options.singleAccepted && asynchronous !== 1) || asynchronous % 3 === 0) {
          this.pendingFrames = 2; return null;
        }
        this.pendingFrames = options.excessBacklog ? 3 : asynchronous % 3;
        return Object.hasOwn(options.timings || {}, 'submission') ? options.timings.submission : .03;
      }
      this.pendingFrames = 0;
      return settings.measure && Object.hasOwn(options.timings || {}, 'wall') ? options.timings.wall : .8;
    },
    async readHDR() {
      reads++;
      const values = new Float32Array(this.width * this.height * 4);
      for (let index = 0; index < values.length; index += 4) {
        values[index] = options.emptyHDR ? 0 : .5; values[index + 3] = 1;
      }
      values[3] = -1;
      if (options.nonfiniteHDR) values[0] = Infinity;
      snapshots.push(values); return values;
    },
  };
  async function run() {
    let settled = false, value, error;
    const promise = benchmarkRenderer(renderer).then(result => {value = result; settled = true;},
      reason => {error = reason; settled = true;});
    let hiddenWaits = 0, stalledWhileHidden = false;
    for (let turn = 0; !settled && turn < 1000; turn++) {
      await flush();
      if (settled) break;
      if (document.hidden) {
        // A hidden browser is allowed to suspend rAF indefinitely. Rescue the
        // test only to settle an incorrect runner and restore global state.
        if (++hiddenWaits === 8) { stalledWhileHidden = true; document.setHidden(false); }
      } else if (callbacks.size) {
        const [id, callback] = callbacks.entries().next().value;
        callbacks.delete(id); now += 1000 / 60;
        await callback(now);
      }
    }
    assert.ok(settled, 'Benchmark controller did not settle');
    await promise;
    return {value, error, stalledWhileHidden};
  }
  function assertUIRestored() {
    assert.deepEqual(renderer.settings, original.settings);
    assert.equal(renderer.canvas.width, original.canvasWidth);
    assert.equal(renderer.canvas.height, original.canvasHeight);
    assert.equal(callbacks.size, 0, 'No benchmark frame remains scheduled');
    assert.equal(listeners.get('visibilitychange')?.size || 0, 0, 'Visibility listener cleaned up');
  }
  function assertRestored() {
    assertUIRestored();
    assert.equal(renderer.width, original.width); assert.equal(renderer.height, original.height);
    assert.equal(renderer.samples, original.samples);
    assert.equal(renderer.pendingFrames, 0, 'Submitted work drained before restoration');
  }
  return {run, renderer, original, rebuilds, renders, events, snapshots, faults, assertRestored, assertUIRestored,
    get measured() {return measured;}, get asynchronous() {return asynchronous;}, get reads() {return reads;}};
}

try {
  await test('Summary filters nonfinite values without mutating input and records exact finite count', () => {
    const values = [4, NaN, 1, Infinity, 3, -Infinity, 2];
    assert.deepEqual(summarize(values), {count: 4, minimum: 1, median: 3, p95: 4, maximum: 4});
    assert.deepEqual(values, [4, NaN, 1, Infinity, 3, -Infinity, 2]);
    assert.equal(summarize([]), null); assert.equal(summarize([NaN, Infinity]), null);
  });

  await test('Production benchmark fixes both source and presentation workloads, counts samples, and restores state', async () => {
    const fixture = host(), {value, error} = await fixture.run();
    assert.ifError(error); assert.equal(value.status, 'completed');
    assert.deepEqual(value.scenarios.map(({name, width, height, samples}) => [name, width, height, samples]), [
      ['motion-320', 320, 192, 1], ['motion-640', 640, 384, 1],
      ['full-source-320', 320, 192, 1], ['full-source-glow-320', 320, 192, 1],
      ['scientific-320', 320, 192, 1], ['finite-height-320', 320, 192, 1],
    ]);
    assert.equal(fixture.measured, 240); assert.equal(fixture.reads, 6);
    for (const scene of value.scenarios) {
      assert.equal(scene.cachedWallMS.count, 40); assert.equal(scene.gpuMS.count, 40);
      assert.equal(scene.emissionMS.count, 40); assert.equal(scene.presentationMS.count, 40);
      assert.equal(scene.nonfinite, 0); assert.equal(scene.unresolved, 1);
      assert.equal(scene.lit, scene.width * scene.height); assert.equal(scene.completedBacklog, 0);
      assert.equal(scene.rayMapBytes, scene.width * scene.height * 16);
    }
    assert.deepEqual(value.cameraTraces.map(trace => trace.pitch), [.06, .2, .6, 1.1, .06]);
    assert.ok(value.cameraTraces.every(trace => trace.rays === 160 * 96));
    assert.deepEqual(value.resizeCycles.map(({width, height, glow}) => [width, height, glow]),
      [[320, 192, 0], [8, 8, .28], [512, 256, 0], [320, 192, .28], [8, 8, 0], [320, 192, .28]]);
    for (const call of fixture.renders) {
      assert.equal(call.canvasWidth, call.width, 'Presentation width must match fixed scenario width');
      assert.equal(call.canvasHeight, call.height, 'Presentation height must match fixed scenario height');
      assert.equal(call.source.exposureEV, 0); assert.equal(call.source.paletteTemperature, 6800);
      assert.equal(call.source.passage, false);
    }
    assert.equal(value.cadence.callbacks, 120); assert.equal(value.cadence.submitted, 80);
    assert.equal(value.cadence.dropped, 40); assert.equal(value.cadence.peakBacklog, 2);
    assert.equal(value.cadence.submissionMS.count, 80); assert.equal(value.cadence.callbackIntervalMS.count, 119);
    assert.ok(Number.isFinite(value.cadence.submittedFramesPerSecond));
    assert.ok(value.cadence.submittedFramesPerSecond > 0);
    assert.equal(fixture.rebuilds.length, 18); fixture.assertRestored();
  });

  await test('Absent optional timestamps leave GPU summaries null while retaining all wall samples', async () => {
    const fixture = host({timestamps: false}), {value, error} = await fixture.run();
    assert.ifError(error);
    for (const scene of value.scenarios) {
      assert.equal(scene.cachedWallMS.count, 40); assert.equal(scene.gpuMS, null);
      assert.equal(scene.emissionMS, null); assert.equal(scene.presentationMS, null);
    }
    fixture.assertRestored();
  });

  await test('All-dropped cadence reports zero throughput, not negative or nonfinite FPS', async () => {
    const fixture = host({dropAll: true}), {value, error} = await fixture.run();
    assert.ifError(error); assert.equal(value.cadence.submitted, 0); assert.equal(value.cadence.dropped, 120);
    assert.equal(value.cadence.submissionMS, null); assert.equal(value.cadence.submittedFramesPerSecond, 0);
    fixture.assertRestored();
  });

  await test('One accepted cadence submission cannot produce a fictitious frame interval', async () => {
    const fixture = host({singleAccepted: true}), {value, error} = await fixture.run();
    assert.ifError(error); assert.equal(value.cadence.submitted, 1); assert.equal(value.cadence.dropped, 119);
    assert.equal(value.cadence.submissionMS.count, 1); assert.equal(value.cadence.submittedFramesPerSecond, 0);
    fixture.assertRestored();
  });

  for (const metric of ['wall', 'gpuMS', 'emissionMS', 'presentationMS', 'submission']) {
    for (const invalid of [NaN, Infinity, -.1]) {
      await test(`${metric} rejects ${String(invalid)} timing rather than filtering it out of a completed report`, async () => {
        const fixture = host({timings: {[metric]: invalid}}), {error} = await fixture.run();
        assert.ok(error, 'An invalid timing must fail the benchmark');
        assert.match(error.message, metric === 'submission' ? /Invalid asynchronous submission timing/ : /invalid timing sample/);
        fixture.assertRestored();
      });
    }
  }

  await test('Quantized zero-duration samples remain valid in wall, GPU and submission summaries', async () => {
    const fixture = host({timings: {wall: 0, gpuMS: 0, emissionMS: 0, presentationMS: 0, submission: 0}});
    const {value, error} = await fixture.run(); assert.ifError(error);
    for (const scene of value.scenarios) {
      for (const key of ['cachedWallMS', 'gpuMS', 'emissionMS', 'presentationMS']) {
        assert.equal(scene[key].count, 40); assert.equal(scene[key].minimum, 0); assert.equal(scene[key].maximum, 0);
      }
    }
    assert.equal(value.cadence.submissionMS.count, 80); assert.equal(value.cadence.submissionMS.maximum, 0);
    fixture.assertRestored();
  });

  await test('Cleanup-only queue failure is surfaced after CPU settings and canvas restoration', async () => {
    const fixture = host({drainFailures: [2]}), {error} = await fixture.run();
    assert.equal(error, fixture.faults.drain);
    fixture.assertUIRestored();
    assert.equal(fixture.rebuilds.at(-1).width, fixture.original.width, 'Restoration still attempted after drain rejection');
  });

  await test('Queue failure during cadence completion survives repeated cleanup failure', async () => {
    const fixture = host({drainFailures: [1, 2]}), {error} = await fixture.run();
    assert.equal(error, fixture.faults.drain); fixture.assertUIRestored();
  });

  await test('Original render error survives both queue-drain and GPU restoration failures', async () => {
    const fixture = host({renderError: true, drainFailures: [1], restoreError: true});
    const {error} = await fixture.run();
    assert.equal(error, fixture.faults.render, 'Cleanup must not mask the initiating workload error');
    fixture.assertUIRestored();
    assert.equal(fixture.rebuilds.at(-1).width, fixture.original.width, 'GPU restoration attempted even after drain rejection');
  });

  await test('Restoration-only GPU failure is surfaced without losing CPU settings or canvas size', async () => {
    const fixture = host({restoreError: true}), {error} = await fixture.run();
    assert.equal(error, fixture.faults.restore); fixture.assertUIRestored();
  });

  for (const [name, options, pattern] of [
    ['Rebuild errors', {rebuildError: true}, /rebuild failure/],
    ['Measured render errors', {renderError: true}, /render failure/],
    ['Asynchronous submission errors', {asyncError: true}, /async failure/],
    ['Unexpected cached-geometry retracing', {retrace: true}, /retraced geometry/],
    ['Nonfinite HDR', {nonfiniteHDR: true}, /invalid or empty HDR/],
    ['Empty HDR', {emptyHDR: true}, /invalid or empty HDR/],
    ['GPU backlog greater than two', {excessBacklog: true}, /backlog exceeded two/],
    ['Initially hidden document', {initiallyHidden: true}, /keep this tab visible/],
    ['Hiding during warmup', {hideAtWarmup: true}, /keep this tab visible/],
    ['Hiding during measured rendering', {hideAtMeasured: 5}, /keep this tab visible/],
    ['Hiding with animation callbacks suspended', {hideAtRequestedFrame: 4}, /hidden during cadence/],
  ]) {
    await test(`${name} abort the benchmark and restore settings/resources`, async () => {
      const fixture = host(options), {error, stalledWhileHidden} = await fixture.run();
      assert.ok(error, 'Expected benchmark failure'); assert.match(error.message, pattern);
      assert.equal(stalledWhileHidden, false, 'Hidden cancellation must not depend on another animation callback');
      if (options.hideAtWarmup) assert.equal(fixture.renders.length, 1, 'No extra warmup work after hiding');
      fixture.assertRestored();
    });
  }

  await test('Engine reporting handles Chromium/Edge/Firefox/Safari token overlap and iOS variants', () => {
    const cases = [
      ['Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36', 'chromium'],
      ['Mozilla/5.0 AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0', 'chromium'],
      ['Mozilla/5.0 AppleWebKit/537.36 Chromium/140.0.0.0 Safari/537.36', 'chromium'],
      ['Mozilla/5.0 Gecko/20100101 Firefox/145.0', 'gecko'],
      ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15', 'webkit'],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 CriOS/140.0.0.0 Mobile/15E148 Safari/604.1', 'webkit'],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 FxiOS/145.0 Mobile/15E148 Safari/605.1.15', 'webkit'],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 EdgiOS/140.0 Mobile/15E148 Safari/605.1.15', 'webkit'],
      ['', 'unknown'], ['unrecognized agent', 'unknown'],
    ];
    for (const [userAgent, expected] of cases) assert.equal(engineFromUserAgent(userAgent), expected, userAgent);
  });

  await test('Runtime report preserves disclosed capabilities and does not invent absent adapter fields', () => {
    install('navigator', {userAgent: 'AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15', gpu: {}});
    install('isSecureContext', true);
    const limits = {maxStorageBufferBindingSize: 128 * 1024 * 1024, maxBufferSize: 256 * 1024 * 1024,
      maxTextureDimension2D: 8192, maxComputeInvocationsPerWorkgroup: 256, maxComputeWorkgroupsPerDimension: 65535};
    const report = runtimeInfo({adapter: {info: {vendor: 'test vendor'}, features: new Set(['timestamp-query', 'shader-f16'])},
      device: {limits}, queries: {}, startupMS: 123});
    assert.equal(report.engine, 'webkit'); assert.equal(report.secureContext, true); assert.equal(report.webgpu, true);
    assert.equal(report.adapter.vendor, 'test vendor'); assert.equal(report.adapter.device, 'undisclosed');
    assert.deepEqual(report.features, ['shader-f16', 'timestamp-query']); assert.deepEqual(report.deviceLimits, limits);
    assert.equal(report.timestampQuery, true); assert.equal(report.startupMS, 123);
    assert.ok(Number.isFinite(Date.parse(report.date)));
    const absent = runtimeInfo();
    assert.equal(absent.adapter, null); assert.equal(absent.deviceLimits, null);
    assert.deepEqual(absent.features, []); assert.equal(absent.timestampQuery, false); assert.equal(absent.startupMS, null);
  });
} finally {
  for (const [name, descriptor] of descriptors) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete globalThis[name];
  }
}
console.log(`${passed}/${passed + failed} benchmark/diagnostic host checks passed (CPU controller tests only).`);
if (failed) process.exitCode = 1;
