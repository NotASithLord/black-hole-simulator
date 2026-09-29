const HARD_PENDING_LIMIT=8;

/**
 * Bound useful GPU work without treating delayed browser notifications as GPU
 * execution time. Some backends deliver completion promises on a coarse poll;
 * two promises can then represent two finished jobs, not a busy device.
 *
 * Eight notification slots cover a 100 ms poll at 60 Hz. This trades a larger
 * worst-case backlog than a two-slot queue for continuous useful submissions.
 * A valid execution-time estimate narrows that window, and the age watchdog
 * stops new work if notifications stop arriving. Neither timer retires work:
 * every token must stay owned until its real completion (or a submit failure).
 * Callers still drain submitted work before replacing its resources.
 */
export class BoundedSubmissionWindow {
  constructor({maxPending=8,maxAgeMS=250,maxQueuedGPUTimeMS=80}={}) {
    if(!Number.isInteger(maxPending)||maxPending<1||
      !Number.isFinite(maxAgeMS)||maxAgeMS<=0||
      !Number.isFinite(maxQueuedGPUTimeMS)||maxQueuedGPUTimeMS<=0) {
      throw new RangeError('Submission limits must be finite and positive.');
    }
    this.maxPending=Math.min(maxPending,HARD_PENDING_LIMIT);
    this.maxAgeMS=maxAgeMS;
    this.maxQueuedGPUTimeMS=maxQueuedGPUTimeMS;
    this.submissions=new Map();this.nextToken=1;
  }

  get pending() {return this.submissions.size;}

  capacity(gpuMS=0) {
    // A caller may supply only validated GPU execution time for this workload,
    // never queue completion latency. Missing, zero and invalid queries leave
    // the finite startup window in place instead of falsely diagnosing overload.
    return Number.isFinite(gpuMS)&&gpuMS>0?
      Math.max(1,Math.min(this.maxPending,Math.floor(this.maxQueuedGPUTimeMS/gpuMS))):
      this.maxPending;
  }

  oldestAge(now) {
    if(!Number.isFinite(now)) throw new RangeError('A finite monotonic time is required.');
    const oldest=this.submissions.values().next();
    return oldest.done?0:Math.max(0,now-oldest.value);
  }

  tryAcquire({now=performance.now(),gpuMS=0}={}) {
    const age=this.oldestAge(now);
    if(this.pending>=this.capacity(gpuMS)||this.pending&&age>=this.maxAgeMS) return null;
    const token=this.nextToken++;
    this.submissions.set(token,now);
    return token;
  }

  release(token) {
    // Deliberately idempotent: error/finally paths must not decrement a counter
    // twice or accidentally release a newer job after a workload change.
    return this.submissions.delete(token);
  }
}
