/**
 * Measure host delivery of completed GPU work, not hardware execution time.
 * A few initialized four-byte copies distinguish prompt notifications from a
 * coarse completion poll without selecting policy by browser name. Contention
 * can also inflate the result, so it is only a scheduling hint. Never subtract
 * this latency from trace measurements or issue these copies during rendering.
 */
export async function measureCompletionDelivery(device,{now=()=>performance.now(),samples=3,thresholdMS=40}={}) {
  if(!Number.isInteger(samples)||samples<1||samples>9||
    !Number.isFinite(thresholdMS)||thresholdMS<=0||typeof now!=='function') {
    throw new RangeError('Completion probe requires 1–9 samples and a positive finite threshold.');
  }
  let previousTime=null;
  const clock=()=>{
    const value=now();
    if(!Number.isFinite(value)||previousTime!==null&&value<previousTime) {
      throw new RangeError('Completion probe requires a finite monotonic clock.');
    }
    previousTime=value;
    return value;
  };
  let source,destination;
  const latenciesMS=[];
  try {
    source=device.createBuffer({label:'Completion delivery probe source',size:4,
      usage:GPUBufferUsage.COPY_SRC|GPUBufferUsage.COPY_DST});
    destination=device.createBuffer({label:'Completion delivery probe destination',size:4,
      usage:GPUBufferUsage.COPY_DST});
    device.queue.writeBuffer(source,0,new Uint32Array([0x4b455252]));
    for(let index=0;index<samples;index++) {
      const encoder=device.createCommandEncoder({label:'Completion delivery probe'});
      encoder.copyBufferToBuffer(source,0,destination,0,4);
      const command=encoder.finish(),start=clock();
      device.queue.submit([command]);
      await device.queue.onSubmittedWorkDone();
      const elapsed=clock()-start;
      if(!Number.isFinite(elapsed)||elapsed<0) throw new RangeError('Completion probe elapsed time must be finite and nonnegative.');
      latenciesMS.push(elapsed);
    }
    const ordered=[...latenciesMS].sort((a,b)=>a-b),middle=Math.floor(ordered.length/2);
    const medianMS=ordered.length%2?ordered[middle]:(ordered[middle-1]+ordered[middle])/2;
    return {latenciesMS,medianMS,minMS:ordered[0],maxMS:ordered.at(-1),
      coarseCompletion:medianMS>=thresholdMS};
  } finally {
    destination?.destroy();source?.destroy();
  }
}
