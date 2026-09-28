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
 * Fast overload correction in linear resolution, with restrained recovery.
 * Only actual GPU execution evidence may use the faster, 10% recovery path;
 * it requires >64% spare budget. Under a quadratic pixel-cost model the step
 * leaves >56% headroom; actual new cost must still be measured. Completion
 * cadence cannot prove that spare capacity.
 */
export function adaptiveResolutionScale(current, observedMS, budgetMS, minimum = 0.2, maximum = 1, timingSource = 'throughput') {
  if (!Number.isFinite(minimum) || minimum <= 0 || !Number.isFinite(maximum) || maximum < minimum) {
    throw new RangeError('Invalid adaptive resolution range.');
  }
  const value = clamp(finitePositive(current, maximum), minimum, maximum);
  if (!Number.isFinite(observedMS) || observedMS <= 0 || !Number.isFinite(budgetMS) || budgetMS <= 0) return value;
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
export function adaptiveTiming({ generation, now, intervalMS, gpu, completion, maxAgeMS = 2000 } = {}) {
  if (generation === undefined || generation === null || !Number.isFinite(now)
    || !Number.isFinite(intervalMS) || intervalMS <= 0 || !Number.isFinite(maxAgeMS) || maxAgeMS <= 0) return null;
  const fresh = sample => sample && sample.generation === generation && Number.isFinite(sample.at)
    && sample.at <= now && now - sample.at <= maxAgeMS;
  if (fresh(gpu) && Number.isFinite(gpu.ms) && gpu.ms > 0) {
    return { observedMS: gpu.ms, budgetMS: intervalMS * 0.72, source: 'gpu' };
  }
  if (fresh(completion) && Number.isInteger(completion.samples) && completion.samples >= 8
    && Number.isFinite(completion.ms) && completion.ms > 0
    && Number.isFinite(completion.ms * completion.samples) && completion.ms * completion.samples >= 100) {
    return { observedMS: completion.ms, budgetMS: intervalMS, source: 'throughput' };
  }
  return null;
}
