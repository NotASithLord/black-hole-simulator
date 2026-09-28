// Production-renderer benchmarks. No software/WebGL substitute and no browser
// flags. Results are workload-specific observations, not guaranteed display FPS.
export function summarize(values) {
  const sorted=values.filter(Number.isFinite).sort((a,b)=>a-b);
  if(!sorted.length) return null;
  const at=q=>sorted[Math.min(sorted.length-1,Math.floor(q*sorted.length))];
  return {count:sorted.length,minimum:sorted[0],median:at(.5),p95:at(.95),maximum:sorted.at(-1)};
}

export async function benchmarkRenderer(renderer,log=()=>{}) {
  const original={settings:{...renderer.settings},width:renderer.width,height:renderer.height,samples:renderer.samples,
    canvasWidth:renderer.canvas.width,canvasHeight:renderer.canvas.height};
  const results={scope:'Real production WebGPU; fixed-workload comparisons, no UA-specific tuning',
    timingNotes:'Wall timings include browser scheduling. GPU timestamps are optional and may be quantized. rAF throughput counts submitted frames, not compositor-confirmed display frames.',
    scenarios:[],cameraTraces:[],resizeCycles:[],cadence:null};
  const base={spin:.82,mass:1e8,accretion:.1,outerRadius:30,cameraYaw:-.28,cameraPitch:.06,
    cameraDistance:80,fov:.48,lookYaw:0,lookPitch:0,thickness:0,appearance:'radiant',quality:'interactive',
    rotation:true,playback:4000,energy:false,materialStrength:.9,glowStrength:0,fluctuations:0,diagnosticMode:false,
    exposureEV:0,paletteTemperature:6800,passage:false};
  const scenarios=[
    {name:'motion-320',width:320,height:192},
    {name:'motion-640',width:640,height:384},
    {name:'full-source-320',width:320,height:192,quality:'auto'},
    {name:'full-source-glow-320',width:320,height:192,quality:'auto',glowStrength:.28},
    {name:'scientific-320',width:320,height:192,quality:'auto',appearance:'scientific'},
    {name:'finite-height-320',width:320,height:192,thickness:.75},
  ];
  function visible() {
    if(document.hidden) throw new Error('Benchmark interrupted: keep this tab visible for comparable timings.');
  }
  let originalError;
  try {
    for(const scene of scenarios) {
      visible();log(`Benchmark: ${scene.name}…`);
      const {name,width,height,...settings}=scene;
      Object.assign(renderer.settings,base,settings);renderer.updateModel();
      renderer.canvas.width=width;renderer.canvas.height=height;
      const begin=performance.now();await renderer.rebuild(width,height,1);
      const traceWallMS=performance.now()-begin;
      for(let i=0;i<8;i++) {visible();await renderer.render(8000+i*4000/60);}
      const traces=renderer.traceCount,wall=[],gpu=[],emission=[],presentation=[];
      const observedWork=[];
      for(let i=0;i<40;i++) {
        visible();wall.push(await renderer.render(9000+i*4000/60,{measure:true}));
        if(renderer.queries) {gpu.push(renderer.gpuMS);emission.push(renderer.emissionMS);presentation.push(renderer.presentationMS);}
        observedWork.push(renderer.pendingFrames);
      }
      if([wall,gpu,emission,presentation].some(values=>values.some(value=>!Number.isFinite(value)||value<0)))
        throw new Error(`${name}: invalid timing sample`);
      if(renderer.traceCount!==traces) throw new Error(`${name}: cached animation unexpectedly retraced geometry`);
      const pixels=await renderer.readHDR();let nonfinite=0,unresolved=0,lit=0;
      for(let i=0;i<pixels.length;i+=4) {
        if(![pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]].every(Number.isFinite))nonfinite++;
        if(pixels[i+3]<0)unresolved++;
        if(Math.max(pixels[i],pixels[i+1],pixels[i+2])>1e-6)lit++;
      }
      results.scenarios.push({name,width,height,presentationWidth:renderer.canvas.width,presentationHeight:renderer.canvas.height,samples:1,traceWallMS,traceMS:renderer.traceMS,
        cachedWallMS:summarize(wall),gpuMS:summarize(gpu),emissionMS:summarize(emission),presentationMS:summarize(presentation),
        pixels:width*height,nonfinite,unresolved,lit,completedBacklog:Math.max(...observedWork),rayMapBytes:width*height*16});
      if(nonfinite||!lit) throw new Error(`${name}: invalid or empty HDR output`);
    }

    log('Benchmark: moving camera and resizing…');
    Object.assign(renderer.settings,base);renderer.updateModel();
    renderer.canvas.width=160;renderer.canvas.height=96;
    for(const pitch of [.06,.2,.6,1.1,.06]) {
      visible();renderer.settings.cameraPitch=pitch;
      const begin=performance.now();await renderer.rebuild(160,96,1);await renderer.render(10000);
      results.cameraTraces.push({pitch,wallMS:performance.now()-begin,traceMS:renderer.traceMS,rays:160*96});
    }
    // Repeated dimensions and glow transitions exercise resource retirement,
    // warm reuse and minimum-size pyramids, not just the fast steady state.
    for(const [width,height] of [[320,192],[8,8],[512,256],[320,192],[8,8],[320,192]]) {
      visible();renderer.settings.glowStrength=results.resizeCycles.length%2?.28:0;
      renderer.canvas.width=width;renderer.canvas.height=height;
      const begin=performance.now();await renderer.rebuild(width,height,1);await renderer.render(11000);
      results.resizeCycles.push({width,height,glow:renderer.settings.glowStrength,wallMS:performance.now()-begin});
    }
    renderer.settings.glowStrength=0;
    log('Benchmark: 120 animation-frame callbacks with bounded asynchronous submissions…');
    const gaps=[],submissionCosts=[];let callbacks=0,submitted=0,dropped=0,peakBacklog=0,last=0,first=0,firstAccepted=0,lastAccepted=0;
    await new Promise((resolve,reject)=>{
      let ended=false,frameId;
      const cleanup=()=>{document.removeEventListener('visibilitychange',onVisibility);if(frameId!==undefined)cancelAnimationFrame(frameId);};
      const finish=error=>{if(ended)return;ended=true;cleanup();error?reject(error):resolve();};
      const onVisibility=()=>{if(document.hidden)finish(new Error('Benchmark interrupted: tab became hidden during cadence measurement.'));};
      async function frame(now) {
        try {
          if(ended)return;
          visible();if(callbacks===0)first=now;else gaps.push(now-last);last=now;
          const cost=await renderer.render(12000+callbacks*4000/60,{wait:false});
          if(ended)return;
          if(cost!==null&&(!Number.isFinite(cost)||cost<0))throw new Error('Invalid asynchronous submission timing');
          if(cost===null)dropped++;else {if(submitted===0)firstAccepted=now;lastAccepted=now;submitted++;submissionCosts.push(cost);}
          peakBacklog=Math.max(peakBacklog,renderer.pendingFrames);
          if(++callbacks<120)frameId=requestAnimationFrame(frame);else finish();
        } catch(error) {finish(error);}
      }
      document.addEventListener('visibilitychange',onVisibility);
      frameId=requestAnimationFrame(frame);
    });
    await renderer.device.queue.onSubmittedWorkDone();
    results.cadence={callbacks,submitted,dropped,peakBacklog,callbackIntervalMS:summarize(gaps),submissionMS:summarize(submissionCosts),
      elapsedMS:last-first,submittedFramesPerSecond:submitted>1?(submitted-1)*1000/Math.max(lastAccepted-firstAccepted,1):0,targetResolution:[320,192]};
    if(peakBacklog>2)throw new Error('Asynchronous GPU backlog exceeded two frames');
    results.status='completed';
  } catch(error) {
    originalError=error;throw error;
  } finally {
    let cleanupError;
    try {await renderer.device.queue.onSubmittedWorkDone();} catch(error) {cleanupError=error;}
    Object.assign(renderer.settings,original.settings);
    renderer.canvas.width=original.canvasWidth;renderer.canvas.height=original.canvasHeight;
    try {
      renderer.updateModel();
      if(original.width&&original.height)await renderer.rebuild(original.width,original.height,original.samples);
    } catch(error) {cleanupError??=error;}
    // Restore CPU/UI state even after device loss. Keep the original workload
    // failure if cleanup also fails, rather than replacing the useful cause.
    if(cleanupError&&!originalError)throw cleanupError;
  }
  return results;
}
