// Pure workload and cadence policy; no browser, GPU or clock side effects.
const finitePositive = (value, fallback) => Number.isFinite(value) && value > 0 ? value : fallback;
const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
const tileFloor = value => Math.floor(value / 8) * 8;

/**
 * Choose one bounded GPU ray map. Width/height describe the already DPR-capped
 * canvas. A known throughput always wins over bootstrap minimumPixels: weak
 * adapters may go as low as a single 8×8 workgroup. That irreducible tile can
 * exceed an exceptionally small time budget; it never exceeds hard GPU limits.
 * Modes may opt into a larger calibrated stationary ceiling with headroomPixels.
 * It changes resolution only, not samples or transport accuracy. Camera motion,
 * unknown throughput and energy saving retain the mode's inexpensive base cap.
 */
export function chooseRenderSize({
  width, height, mode = {}, raysPerMS = 0, moving = false, energy = false, scale = 1,
  maxStorageBytes = 128 * 1024 * 1024, maxTextureDimension = 8192,
} = {}) {
  const sourceWidth = Math.max(8, finitePositive(width, 8));
  const sourceHeight = Math.max(8, finitePositive(height, 8));
  const samples = moving ? 1 : Math.max(1, Math.floor(finitePositive(mode.samples, 1)));
  const maximumAxis = tileFloor(finitePositive(maxTextureDimension, 8192));
  const storageBytes = finitePositive(maxStorageBytes, 128 * 1024 * 1024);
  // Keep ten percent storage headroom. At the smallest legal allocation, a full
  // tile is allowed even when the reserve would otherwise disallow all work.
  const hardMemoryPixels = Math.floor(storageBytes / (16 * samples));
  if (maximumAxis < 8 || hardMemoryPixels < 64) {
    throw new RangeError('GPU limits cannot fit a single 8×8 ray workgroup.');
  }
  const memoryPixels = Math.max(64, Math.floor(hardMemoryPixels * 0.9));
  const budget = finitePositive(moving ? mode.movingBudget : mode.traceBudget, moving ? 24 : 100);
  const calibrated = Number.isFinite(raysPerMS) && raysPerMS > 0;
  const measuredPixels = calibrated
    ? raysPerMS * budget / samples
    : finitePositive(mode.minimumPixels, 4096);
  const basePixels = finitePositive(mode.pixels, sourceWidth * sourceHeight);
  const modePixels = calibrated && !moving && !energy
    ? Math.max(basePixels, finitePositive(mode.headroomPixels, basePixels))
    : basePixels;
  const resolutionScale = clamp(finitePositive(scale, 1), 0.001, 1);
  const desiredPixels = Math.min(
    sourceWidth * sourceHeight,
    modePixels,
    measuredPixels,
  ) * resolutionScale * resolutionScale;
  const pixelLimit = Math.max(64, Math.min(memoryPixels, Math.floor(desiredPixels)));
  const fit = Math.min(1, Math.sqrt(pixelLimit / (sourceWidth * sourceHeight)),
    maximumAxis / sourceWidth, maximumAxis / sourceHeight);
  let renderWidth = Math.max(8, tileFloor(sourceWidth * fit));
  let renderHeight = Math.max(8, tileFloor(sourceHeight * fit));

  // For an extreme aspect ratio, lifting the short side to one workgroup can
  // exceed the pixel budget. Reduce its long side as well; never raise the
  // budget to preserve aspect ratio. Quantization at this size is unavoidable.
  if (renderWidth * renderHeight > pixelLimit) {
    if (renderWidth >= renderHeight) renderWidth = Math.max(8, tileFloor(pixelLimit / renderHeight));
    else renderHeight = Math.max(8, tileFloor(pixelLimit / renderWidth));
  }
  return { width: renderWidth, height: renderHeight, samples };
}

/**
 * Bounded correction in linear resolution. Ordinary modes retain restrained
 * recovery; Max fidelity spends clear GPU execution headroom on useful pixels.
 * Both require measured execution evidence for faster recovery. Completion
 * cadence cannot prove spare device time, so it keeps the conservative policy.
 */
export function adaptiveResolutionScale(current, observedMS, budgetMS, minimum = 0.2, maximum = 1, timingSource = 'throughput', maximizeFidelity = false) {
  if (!Number.isFinite(minimum) || minimum <= 0 || !Number.isFinite(maximum) || maximum < minimum) {
    throw new RangeError('Invalid adaptive resolution range.');
  }
  const value = clamp(finitePositive(current, maximum), minimum, maximum);
  if (!Number.isFinite(observedMS) || observedMS <= 0 || !Number.isFinite(budgetMS) || budgetMS <= 0) return value;
  // A cached ray map can take seconds to replace. Chasing a narrow utilization
  // band would sacrifice animation continuity for ordinary timestamp noise.
  // Keep the execution-budget target, but act only on clear headroom/overload;
  // the retrace policy below also requires sustained, materially useful change.
  if (maximizeFidelity && timingSource === 'gpu') {
    if (observedMS >= budgetMS * 0.75 && observedMS <= budgetMS * 1.12) return value;
    const correction = Math.sqrt(budgetMS / observedMS);
    return clamp(value * clamp(correction, 0.65, 1.10), minimum, maximum);
  }
  if (observedMS > budgetMS * 1.12) {
    // Pixel cost scales approximately with the square of linear resolution.
    // Bound a correction to 15–35% to react promptly without collapsing detail.
    const factor = clamp(Math.sqrt(budgetMS / observedMS) * 0.95, 0.65, 0.85);
    return clamp(value * factor, minimum, maximum);
  }
  if (observedMS < budgetMS * 0.72) {
    if (timingSource === 'gpu' && observedMS < budgetMS * 0.36) {
      return clamp(value * 1.1, minimum, maximum);
    }
    const factor = 1 + Math.min(0.03, 0.04 * (budgetMS / observedMS - 1));
    return clamp(value * factor, minimum, maximum);
  }
  return value;
}

/**
 * A shading-cost correction is not itself permission to retrace expensive
 * geometry. Require consecutive independent timing windows, a useful pixel
 * difference and enough stable animation to amortize the last map build.
 * Reset after a rebuild or an idle wake; never carry evidence across workloads.
 */
export class AdaptiveRetracePolicy {
  constructor() { this.reset(0); }
  reset(now) {
    this.rebuiltAt=now;
    this.generation=null;
    this.direction=0;
    this.count=0;
    this.lastSampleAt=-Infinity;
    this.lastEvidenceAt=-Infinity;
  }
  consider({now,generation,evidence,current,next,traceMS=0,minimumPixelChange=0.15}) {
    if (!Number.isFinite(now)||!evidence||!Number.isFinite(evidence.at)||evidence.at>now||!current||!next) return false;
    const currentPixels=current.width*current.height,nextPixels=next.width*next.height;
    const ratio=nextPixels/currentPixels;
    const direction=ratio<1?-1:1;
    const threshold=clamp(finitePositive(minimumPixelChange,0.15),direction<0?0.15:0.05,0.5);
    if (!Number.isFinite(ratio)||ratio<=0||current.samples!==next.samples||Math.abs(ratio-1)<threshold) {
      this.count=0;this.direction=0;return false;
    }
    // Reject a proposed size that contradicts the measured shading correction.
    // This also protects callers from accidentally changing its sizing baseline.
    if ((direction<0&&evidence.observedMS<=evidence.budgetMS)
      ||(direction>0&&evidence.observedMS>=evidence.budgetMS)) {
      this.count=0;this.direction=0;return false;
    }
    if (generation!==this.generation||direction!==this.direction||now-this.lastSampleAt>3000) {
      this.generation=generation;this.direction=direction;this.count=0;this.lastSampleAt=-Infinity;
      this.lastEvidenceAt=-Infinity;
    }
    // Repeated frames from one evidence window cannot establish persistence.
    // Timestamp queries are sparse at low FPS; fresh completion evidence may
    // continue the same correction direction between GPU samples. Resetting on
    // that source switch would prevent a severely overloaded map from shrinking.
    if (now-this.lastSampleAt<1000||evidence.at<=this.lastEvidenceAt) return false;
    this.lastSampleAt=now;this.lastEvidenceAt=evidence.at;this.count++;
    const cost=Math.max(0,Number.isFinite(traceMS)?traceMS:0);
    const cooldown=direction<0?Math.max(5000,Math.min(30000,cost*6))
      :Math.max(15000,Math.min(60000,cost*12));
    return this.count>=(direction<0?3:4)&&now-this.rebuiltAt>=cooldown;
  }
}

/**
 * Call once when submitting a due frame, including one admitted up to 1ms early
 * for rAF jitter. Returns the next deadline on the same cadence, skipping missed
 * slots after a stall. It does not schedule catch-up renders or reset phase to
 * now, so slightly late frames do not permanently lower the requested FPS.
 */
export function advanceDeadline(now, deadline, interval) {
  if (!Number.isFinite(now)) throw new RangeError('Frame time must be finite.');
  if (!Number.isFinite(interval) || interval <= 0) throw new RangeError('Frame interval must be positive.');
  if (!Number.isFinite(deadline)) return now + interval;
  const missed = Math.max(0, Math.floor((now - deadline) / interval));
  return deadline + (missed + 1) * interval;
}

/**
 * Select evidence for resolution adaptation, never per-frame queue latency.
 * GPU timestamps describe execution cost and get a headroom budget. Completion
 * throughput describes paced output and must use the entire frame interval.
 * The caller owns a workload generation, changed when render resources or cost
 * settings change, and captures that generation at submission (not callback).
 *
 * gpu: { ms, generation, at } for one timestamped frame.
 * completion: { ms, samples, generation, at }; ms is mean completed-frame interval,
 * samples counts the intervals in that window, not pending/submitted frames.
 * All times are monotonic milliseconds; `at` is sample/window completion time.
 * Return null until current, sufficiently sampled evidence exists.
 */
export function adaptiveTiming({ generation, now, intervalMS, gpu, completion, maxAgeMS = 2000, gpuBudgetFraction = 0.72 } = {}) {
  if (generation === undefined || generation === null || !Number.isFinite(now)
    || !Number.isFinite(intervalMS) || intervalMS <= 0 || !Number.isFinite(maxAgeMS) || maxAgeMS <= 0) return null;
  const fresh = sample => sample && sample.generation === generation && Number.isFinite(sample.at)
    && sample.at <= now && now - sample.at <= maxAgeMS;
  if (fresh(gpu) && Number.isFinite(gpu.ms) && gpu.ms > 0) {
    // Preserve safety headroom even if a caller supplies an invalid policy.
    const fraction = clamp(finitePositive(gpuBudgetFraction, 0.72), 0.1, 0.9);
    return { observedMS: gpu.ms, budgetMS: intervalMS * fraction, source: 'gpu', at: gpu.at };
  }
  if (fresh(completion) && Number.isInteger(completion.samples) && completion.samples >= 8
    && Number.isFinite(completion.ms) && completion.ms > 0
    && Number.isFinite(completion.ms * completion.samples) && completion.ms * completion.samples >= 100) {
    return { observedMS: completion.ms, budgetMS: intervalMS, source: 'throughput', at: completion.at };
  }
  return null;
}
