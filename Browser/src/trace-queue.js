// Keep a successor available while the browser delivers the oldest GPU fence.
// Two bounded chunks provide overlap without an unbounded stale-camera backlog.
// `submit` must copy its parameters and return a promise for that submission's
// completion; independent submissions preserve queue.writeBuffer ordering.
export async function traceRows({height, initialRows=8, submit, cancel=()=>false,
  progress=()=>{}, now=()=>performance.now()}) {
  const boundedRows=value=>Math.max(8,Math.min(64,Math.floor(value/8)*8));
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
