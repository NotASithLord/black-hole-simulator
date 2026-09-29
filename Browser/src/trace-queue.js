import {BoundedSubmissionWindow} from './submission-window.js';

// Keep a successor available while the browser delivers the oldest GPU fence.
// Two bounded chunks provide overlap without an unbounded stale-camera backlog.
// `submit` must copy its parameters and return a promise for that submission's
// completion; independent submissions preserve queue.writeBuffer ordering.
export async function traceRows({height, initialRows=8, submit, cancel=()=>false,
  progress=()=>{}, now=()=>performance.now(),pace=null,maxRows=64,targetMS=32}) {
  if(pace) return pacedTraceRows({height,initialRows,submit,cancel,progress,now,pace,maxRows,targetMS});
  if(!Number.isFinite(maxRows)||maxRows<=0)throw new RangeError('Trace row limit must be finite and positive.');
  const rowCap=Math.max(8,Math.min(64,Math.floor(maxRows/8)*8));
  const boundedRows=value=>Math.max(8,Math.min(rowCap,Math.floor(value/8)*8));
  let rows=boundedRows(Number.isFinite(initialRows)?initialRows:8),next=0,completed=0;
  const pending=[],start=now();let primaryFailure=false;
  try {
    while(next<height||pending.length) {
      while(next<height&&pending.length<2) {
        if(cancel()) return false;
        const row=next,count=Math.min(rows,height-row);
        // Attach failure handling immediately, including to the successor we
        // have not awaited yet. A failed queue must not leak rejected promises.
        const done=Promise.resolve(submit(row,count)).then(
          ()=>({ok:true,at:now()}),error=>({ok:false,error}));
        pending.push({end:row+count,done});next+=count;
      }
      const chunk=pending.shift(),result=await chunk.done;
      if(!result.ok) throw result.error;
      completed=chunk.end;
      if(cancel()) return false;
      progress(completed/height);
      // This conservative wall-throughput estimate includes browser delivery
      // latency. It sizes watchdog-safe chunks, not GPU execution-time claims.
      const predicted=completed*8/Math.max(result.at-start,1);
      rows=boundedRows(Math.min(rows*2,Math.max(rows*.5,predicted)));
    }
    return !cancel();
  } catch(error) {
    primaryFailure=true;throw error;
  } finally {
    // Hard cancellation must retire every previously submitted chunk before
    // its caller replaces geometry or uploads a different physical model. A
    // device failure during that drain is still fatal, not ordinary cancellation;
    // preserve an earlier submit/progress/fence error if one already exists.
    const drained=await Promise.allSettled(pending.map(chunk=>chunk.done));
    if(!primaryFailure) for(const result of drained) {
      if(result.status==='rejected') throw result.reason;
      if(!result.value.ok) throw result.value.error;
    }
  }
}

/**
 * Pace real trace chunks while a backend delivers completion notifications.
 * Pacing gives already-submitted GPU work time to finish before the next useful
 * submit polls the device. Unlike a tight eight-submit burst, it can maintain
 * progress even when idle completion notifications arrive only every 100 ms.
 * `pace` must yield (normally about 16 ms); tests inject a deterministic clock.
 */
export async function pacedTraceRows({height,initialRows=8,submit,cancel=()=>false,
  progress=()=>{},now=()=>performance.now(),pace,maxRows=64,targetMS=32}) {
  if(typeof pace!=='function') throw new TypeError('Paced traces require a yielding pace function.');
  if(!Number.isFinite(maxRows)||maxRows<=0||!Number.isFinite(targetMS)||targetMS<=0) {
    throw new RangeError('Trace chunk limits must be finite and positive.');
  }
  const rowCap=Math.max(8,Math.min(64,Math.floor(maxRows/8)*8));
  const boundedRows=value=>Math.max(8,Math.min(rowCap,Math.ceil(value/8)*8));
  let rows=boundedRows(Number.isFinite(initialRows)?initialRows:8),next=0,completed=0;
  const pending=[],window=new BoundedSubmissionWindow(),start=now();
  let primaryFailure=false,asynchronousFailure=null;
  try {
    while(next<height||pending.length) {
      // Completion handlers only mark their chunks. Retire the whole available
      // prefix BEFORE refilling so progress and row growth use all fresh work,
      // rather than repeatedly replenishing the original eight-row estimate.
      while(pending[0]?.settled) {
        const chunk=pending.shift(),result=chunk.result;
        if(!result.ok) throw result.error;
        completed=chunk.end;
        if(cancel()) return false;
        progress(completed/height);
        // This is conservative completed-wall throughput, never GPU execution
        // time. Round to a workgroup tile without pinning a target of 15.9 rows
        // at eight forever. Growth, dispatch height and queued count stay capped.
        const predicted=completed*targetMS/Math.max(result.at-start,1);
        rows=boundedRows(Math.min(rows*2,Math.max(rows*.5,predicted)));
      }
      if(asynchronousFailure) throw asynchronousFailure;
      if(cancel()) return false;
      if(next>=height) {
        if(pending.length) await pending[0].done;
        continue;
      }
      const token=window.tryAcquire({now:now()});
      if(token===null) {
        // No optimistic retirement: a count/age limit waits for a real fence.
        await pending[0].done;
        continue;
      }
      const row=next,count=Math.min(rows,height-row),chunk={end:row+count,settled:false};
      let submitted;
      try {submitted=submit(row,count);} catch(error) {window.release(token);throw error;}
      chunk.done=Promise.resolve(submitted).then(
        ()=>({ok:true,at:now()}),error=>({ok:false,error})).then(result=>{
          chunk.result=result;chunk.settled=true;window.release(token);
          if(!result.ok&&!asynchronousFailure) asynchronousFailure=result.error;
          return result;
        });
      pending.push(chunk);next+=count;
      // One useful submission per pace, never an empty poll or dummy command.
      // The final chunk needs no further pacing; the remaining fence is enough.
      if(next<height) await pace();
    }
    return !cancel();
  } catch(error) {
    primaryFailure=true;throw error;
  } finally {
    // Cancellation and every failure path retain resource ownership until ALL
    // already-submitted work has retired, even if its callback arrived early.
    const drained=await Promise.allSettled(pending.map(chunk=>chunk.done));
    if(!primaryFailure) for(const result of drained) {
      if(result.status==='rejected') throw result.reason;
      if(!result.value.ok) throw result.value.error;
    }
  }
}
