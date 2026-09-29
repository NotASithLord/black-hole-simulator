/**
 * Average completed-frame intervals, not submission-to-callback latency and
 * never GPU execution time. A coarse backend can deliver several completions
 * together: starting and ending a short window mid-batch invents headroom or
 * overload. One second AND 64 intervals amortize a 100 ms delivery batch while
 * retaining real slow-frame evidence. A second, slow path accepts at least
 * eight intervals after five seconds: fifty 100 ms poll periods bound batch
 * edge error without forcing a 1 FPS workload to wait 64 seconds for evidence.
 * All callbacks still count exactly once.
 *
 * The caller resets this on workload changes and idle wakes, and supplies the
 * generation captured at submission. Old callbacks cannot start a new window.
 * Sparse low-FPS windows can take several seconds; consumers must not reject
 * successive independent windows merely because their durations exceed 3 s.
 */
export class CompletionCadence {
  constructor({minimumDurationMS=1000,minimumIntervals=64}={}) {
    if(!Number.isFinite(minimumDurationMS)||minimumDurationMS<=0||
      !Number.isInteger(minimumIntervals)||minimumIntervals<1) {
      throw new RangeError('Completion cadence requires a positive duration and interval count.');
    }
    this.minimumDurationMS=minimumDurationMS;
    this.minimumIntervals=minimumIntervals;
    this.reset(0);
  }

  reset(generation=this.generation) {
    if(!Number.isInteger(generation)||generation<0) throw new RangeError('A workload generation is required.');
    this.generation=generation;
    this.startAt=null;this.lastAt=null;this.intervals=0;
  }

  record({at,generation}={}) {
    // Optional measurement must not corrupt current evidence or stop rendering
    // when an old workload or an invalid clock value reaches this accumulator.
    if(generation!==this.generation||!Number.isFinite(at)||at<0||
      this.lastAt!==null&&at<this.lastAt) return null;
    this.lastAt=at;
    if(this.startAt===null) {this.startAt=at;return null;}
    this.intervals++;
    const durationMS=at-this.startAt;
    const ordinary=durationMS>=this.minimumDurationMS&&this.intervals>=this.minimumIntervals;
    const slow=durationMS>=5000&&this.intervals>=8;
    if(!ordinary&&!slow) return null;
    const sample={ms:durationMS/this.intervals,at,generation,samples:this.intervals,durationMS};
    this.startAt=at;this.intervals=0;
    return sample;
  }
}
