import {KerrRenderer,defaults,modes} from './renderer.js';
import {chooseRenderSize,adaptiveResolutionScale,adaptiveTiming,AdaptiveRetracePolicy,advanceDeadline} from './quality.js';
import {runtimeInfo} from './diagnostics.js';

const $=id=>document.getElementById(id), canvas=$('universe');
const params=new URLSearchParams(location.search),benchmarking=params.has('benchmark'),testing=params.has('test')||benchmarking;
let buildIdentity=null;
const renderer=new KerrRenderer(canvas,message=>$('status').textContent=message);
const s=renderer.settings;
let stopped=false,paused=false,revision=0,hardRevision=0,dirty=true,lastChange=0,refined=false,busy=false,needsPresent=true;
let lastTime=performance.now(),nextFrame=0,lastHUD=0,lastAdapt=0,lastTiming=0,frames=0,fps=0,scale=1;
let lastCameraTime=lastTime;
let viewport={width:innerWidth,height:innerHeight};
let pageVisible=!document.hidden;
let verifying=false;
let loopReady=false,tickRunning=false,frameRequest=null,refinementTimer=null;
let calibrationRate=0,drag=null;const keys=new Set();
let rayMapCalibrationRate=0,pendingQualitySize=null;
const retracePolicy=new AdaptiveRetracePolicy();

function lockVerificationInput(locked) {
  verifying=locked;keys.clear();drag=null;
  for(const id of ['toolbar','panel','universe']) $(id).inert=locked;
  if(locked) cancelScheduledWork();else wake();
}

function sourceAnimated() {
  return !paused&&s.rotation&&s.appearance!=='scientific'&&(s.materialStrength>0||s.fluctuations>0);
}
function cameraAnimated() {return keys.size>0||(s.passage&&!paused);}
function cancelRefinement() {
  if(refinementTimer!==null) {clearTimeout(refinementTimer);refinementTimer=null;}
}
function cancelScheduledWork() {
  if(frameRequest!==null) {cancelAnimationFrame(frameRequest);frameRequest=null;}
  cancelRefinement();
}
function scheduleFrame() {
  if(!loopReady||stopped||verifying||!pageVisible||document.hidden||tickRunning||frameRequest!==null) return;
  frameRequest=requestAnimationFrame(tick);
}
function wake() {
  // Input can arrive while awaiting a trace. State changes are coalesced there;
  // the running tick alone schedules its successor, so loops never overlap.
  if(!loopReady||stopped||verifying||!pageVisible||document.hidden) return;
  cancelRefinement();
  if(!tickRunning&&frameRequest===null) {
    lastCameraTime=performance.now();
    // Old GPU samples must not trigger a refinement loop after an idle period.
    renderer.resetTiming?.();
    lastTiming=renderer.timingSerial??0;lastAdapt=lastCameraTime;
    retracePolicy.reset(lastCameraTime);
    nextFrame=0;
  }
  scheduleFrame();
}
function scheduleNext() {
  if(!loopReady||stopped||verifying||!pageVisible||document.hidden) {cancelScheduledWork();return;}
  if(dirty||needsPresent||sourceAnimated()||cameraAnimated()) {scheduleFrame();return;}
  if(!refined&&!drag) {
    const delay=lastChange+250-performance.now();
    if(delay<=0) scheduleFrame();
    else if(refinementTimer===null) {
      // One event after input settles replaces continuous idle rAF polling.
      refinementTimer=setTimeout(()=>{refinementTimer=null;scheduleFrame();},delay);
    }
    return;
  }
  lastTiming=renderer.timingSerial??0;lastAdapt=performance.now();
}

function settleSourceClock(now=performance.now()) {
  // Settle with the old playback/pause state before a control changes it.
  // This also handles controls arriving while a GPU ray map is in flight.
  renderer.core?.advance_clock(Math.max(0,(now-lastTime)/1000),s.playback,pageVisible&&!paused&&s.rotation?1:0);
  lastTime=now;
}

async function report(value) {
  if(testing) try {await fetch('/__report',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({...value,environment:value.environment??runtimeInfo(renderer),build:buildIdentity})});} catch {}
}
function fail(error) {
  if(stopped) return;stopped=true;
  cancelScheduledWork();
  const message=error?.message||String(error);
  $('loading').hidden=false;$('loading').classList.add('error');
  $('loading').querySelector('h1').textContent='Unable to continue rendering';
  $('loading').querySelector('.spinner').hidden=true;$('status').textContent=message;$('retry').hidden=false;
  report({status:'failed',error:message,stack:error?.stack,date:new Date().toISOString()});
}
renderer.onError=fail;
window.addEventListener('error',e=>fail(e.error||e.message));
window.addEventListener('unhandledrejection',e=>fail(e.reason));
$('retry').onclick=()=>location.reload();
function invalidate(hard=false,interaction=true) {
  revision++;if(hard) hardRevision++;dirty=true;refined=false;pendingQualitySize=null;
  if(interaction) lastChange=performance.now();
  needsPresent=true;wake();
}
function sizeCanvas() {
  const dpr=Math.min(devicePixelRatio||1,modes[s.quality].maxDPR??2),limit=renderer.device?.limits.maxTextureDimension2D||8192;
  const width=Math.min(limit,Math.max(8,Math.floor(innerWidth*dpr))),height=Math.min(limit,Math.max(8,Math.floor(innerHeight*dpr)));
  if(viewport.width!==width||viewport.height!==height) {viewport={width,height};invalidate(true);}
  if(!modes[s.quality].lite) presentSize({width,height});
}
function presentSize({width,height}) {
  if(canvas.width!==width||canvas.height!==height) {canvas.width=width;canvas.height=height;needsPresent=true;}
}
function dimensions(moving=false,resolutionScale=scale,raysPerMS=calibrationRate) {
  return chooseRenderSize({...viewport,mode:modes[s.quality],raysPerMS,moving,energy:s.energy,scale:resolutionScale,
    maxStorageBytes:renderer.device.limits.maxStorageBufferBindingSize,
    maxTextureDimension:renderer.device.limits.maxTextureDimension2D});
}
function bindValue(id,key,geometry=false,convert=Number,event='input') {
  $(id).addEventListener(event,()=>{
    if(id==='playback') settleSourceClock();
    s[key]=convert($(id).value);
    needsPresent=true;
    if(geometry) invalidate(true);
    if(id==='quality') {scale=1;sizeCanvas();}
    if(id==='exposure') $('exposureValue').textContent=`${s.exposureEV>=0?'+':''}${s.exposureEV.toFixed(1)} EV`;
    if(id==='tint') $('tintValue').textContent=`${s.paletteTemperature} K`;
    if(id==='spin') $('spinValue').textContent=s.spin.toFixed(3);
    wake();
  });
}
bindValue('quality','quality',true,String,'change');bindValue('appearance','appearance',true,String,'change');
bindValue('exposure','exposureEV');bindValue('tint','paletteTemperature');bindValue('structure','materialStrength');
bindValue('glow','glowStrength');bindValue('fluctuations','fluctuations');bindValue('playback','playback',false,Number,'change');
bindValue('spin','spin',true);bindValue('mass','mass',true,Number,'change');bindValue('accretion','accretion',true,Number,'change');bindValue('thickness','thickness',true);
for(const [id,key] of [['rotate','rotation'],['camera','passage'],['energy','energy'],['diagnostic','diagnosticMode']]) $(id).onchange=()=>{if(id==='rotate') settleSourceClock();s[key]=$(id).checked;needsPresent=true;nextFrame=0;if(id==='camera') invalidate();if(id==='energy') invalidate(true);wake();};
function togglePause() {settleSourceClock();paused=!paused;$('pause').textContent=paused?'Resume':'Pause';needsPresent=true;nextFrame=0;wake();}
$('pause').onclick=togglePause;
$('details').onclick=()=>{$('panel').hidden=!$('panel').hidden;$('details').setAttribute('aria-expanded',String(!$('panel').hidden));};
$('hudToggle').onclick=()=>{$('hud').hidden=!$('hud').hidden;$('hudToggle').setAttribute('aria-pressed',String(!$('hud').hidden));};
$('fullscreen').onclick=async()=>{try {if(document.fullscreenElement) await document.exitFullscreen();else await document.documentElement.requestFullscreen();} catch(error) {$('phase').textContent=error.message;}};
function resetCamera() {for(const key of ['cameraYaw','cameraPitch','cameraDistance','fov','lookYaw','lookPitch']) s[key]=defaults[key];invalidate();}
$('reset').onclick=resetCamera;
canvas.addEventListener('contextmenu',e=>e.preventDefault());
canvas.addEventListener('pointerdown',e=>{canvas.focus();canvas.setPointerCapture(e.pointerId);drag={x:e.clientX,y:e.clientY,look:e.button===2};cancelRefinement();});
canvas.addEventListener('pointermove',e=>{
  if(!drag) return;const dx=e.clientX-drag.x,dy=e.clientY-drag.y;drag.x=e.clientX;drag.y=e.clientY;
  if(drag.look) {s.lookYaw+=dx*.002;s.lookPitch=Math.max(-1.2,Math.min(1.2,s.lookPitch+dy*.002));}
  else {s.cameraYaw-=dx*.004;s.cameraPitch=Math.max(-1.4,Math.min(1.4,s.cameraPitch+dy*.003));}
  invalidate();
});
canvas.addEventListener('pointerup',()=>{drag=null;lastChange=performance.now();wake();});
canvas.addEventListener('pointercancel',()=>{drag=null;wake();});
canvas.addEventListener('wheel',e=>{e.preventDefault();s.fov=Math.max(.12,Math.min(1.4,s.fov*Math.exp(e.deltaY*.001)));invalidate();},{passive:false});
window.addEventListener('keydown',e=>{
  if(verifying) return;
  if(['INPUT','SELECT','BUTTON'].includes(e.target.tagName)) return;
  const key=e.key.toLowerCase();
  if(['w','a','s','d','q','e'].includes(key)) {keys.add(key);e.preventDefault();wake();}
  if(e.repeat)return;
  if(key===' ') {e.preventDefault();togglePause();}
  if(key==='h') $('hudToggle').click();if(key==='r') resetCamera();
});
window.addEventListener('keyup',e=>{if(keys.delete(e.key.toLowerCase())) {lastChange=performance.now();wake();}});
window.addEventListener('blur',()=>{const changed=keys.size>0||drag;keys.clear();drag=null;if(changed) wake();});
window.addEventListener('resize',sizeCanvas);
document.addEventListener('visibilitychange',()=>{
  settleSourceClock();lastCameraTime=lastTime;pageVisible=!document.hidden;keys.clear();drag=null;
  if(pageVisible) {needsPresent=true;wake();} else cancelScheduledWork();
});
function cameraMotion(dt) {
  let changed=false;
  if(s.passage&&!paused) {s.cameraYaw+=dt*.035;changed=true;}
  for(const key of keys) {
    if(key==='w') s.cameraDistance=Math.max(8,s.cameraDistance*Math.exp(-dt*.4));
    if(key==='s') s.cameraDistance=Math.min(350,s.cameraDistance*Math.exp(dt*.4));
    if(key==='a') s.cameraYaw+=dt*.3;if(key==='d') s.cameraYaw-=dt*.3;
    if(key==='q') s.cameraPitch=Math.max(-1.4,s.cameraPitch-dt*.2);if(key==='e') s.cameraPitch=Math.min(1.4,s.cameraPitch+dt*.2);
    changed=true;
  }
  if(changed) invalidate();
}
function updateHUD(now) {
  if(now-lastHUD<500)return;
  fps=frames*1000/(now-lastHUD);frames=0;lastHUD=now;
  const mode=modes[s.quality],info=renderer.adapter.info??{};
  $('device').textContent=info.description||[info.vendor,info.architecture].filter(Boolean).join(' · ')||'WebGPU hardware adapter';
  $('resolution').textContent=`${renderer.width} × ${renderer.height} · ${renderer.samples} rays/pixel · ${s.quality==='interactive'?'Motion first':s.quality}`;
  $('timing').textContent=`${fps.toFixed(0)} FPS · ${renderer.queries?renderer.gpuMS.toFixed(2)+' ms GPU':renderer.queueMS.toFixed(2)+' ms queue (estimated)'}`;
  $('workload').textContent=`${(renderer.width*renderer.height*renderer.samples/1e6).toFixed(2)} M cached rays · last trace ${renderer.traceMS.toFixed(0)} ms · maps ${renderer.traceCount}`;
  $('physical').textContent=`a/M ${s.spin.toFixed(3)} · M ${(s.mass/1e8).toFixed(1)} × 10⁸ M☉ · ISCO ${renderer.meta[0].toFixed(3)} M`;
  $('numerical').textContent=`ε ${mode.tolerance.toExponential(0)} · ≤${mode.steps} steps · ${s.playback.toLocaleString()}× clock`;
  if(!busy) $('phase').textContent=paused?'Source paused':s.energy?'Energy saver · capped at 20 FPS':refined?'Ray map cached · source animating':'Interactive preview';
}
async function tick(now) {
  frameRequest=null;
  if(stopped||verifying||!pageVisible||document.hidden||tickRunning)return;
  tickRunning=true;
  try {
    // Camera cadence includes awaited trace work. The source clock also settles
    // after tracing and at controls, so it cannot serve as the camera timestamp.
    const elapsed=Math.max(0,(now-lastCameraTime)/1000);lastCameraTime=now;settleSourceClock(now);
    // Dampen camera input after a stall, but preserve the physical source
    // clock's elapsed visible time, including time spent retracing geometry.
    cameraMotion(Math.min(.1,elapsed));
    const moving=!!drag||keys.size>0||(s.passage&&!paused)||now-lastChange<250;
    if(dirty||(!moving&&!refined)) {
      busy=true;const token=revision,hardToken=hardRevision;renderer.updateModel();
      const qualityOnly=!!pendingQualitySize&&!moving;
      const sizingRate=qualityOnly?rayMapCalibrationRate:calibrationRate;
      const d=qualityOnly?pendingQualitySize:dimensions(moving);
      // Finish one immutable low-resolution camera snapshot while drag input
      // continues. Cancel only incompatible model/layout changes, not every
      // pointer event; otherwise a moving camera never displays a new image.
      const complete=await renderer.rebuild(d.width,d.height,d.samples,p=>{$('phase').textContent=`Tracing ${Math.round(p*100)}% · ${d.width} × ${d.height}`;},()=>hardToken!==hardRevision||stopped||document.hidden);
      busy=false;if(!complete||hardToken!==hardRevision||stopped) return;
      dirty=token!==revision;refined=!moving&&!dirty;needsPresent=true;
      if(!dirty) pendingQualitySize=null;
      rayMapCalibrationRate=sizingRate;
      // Resolution feedback must use the baseline that sized the current map,
      // not a differently sized retrace's throughput; otherwise it moves its
      // own target and can alternate between high and low resolutions forever.
      if(!qualityOnly) calibrationRate=calibrationRate>0?calibrationRate*.7+renderer.raysPerMS*.3:renderer.raysPerMS;
      retracePolicy.reset(performance.now());
      lastAdapt=performance.now();lastTiming=renderer.timingSerial;
      if(modes[s.quality].lite) presentSize(d);
    }
    const interval=1000/(s.energy?20:modes[s.quality].fps);
    const drawNow=performance.now();
    // Keep source time continuous through ray-map work, without double counting
    // it next frame. Hidden time and explicit pause remain excluded.
    settleSourceClock(drawNow);
    const animated=sourceAnimated();
    if((needsPresent||animated)&&drawNow>=nextFrame-1) {
      const submitted=await renderer.render(renderer.core.clock_seconds(),{wait:false});
      if(submitted!==null) {frames++;needsPresent=false;nextFrame=advanceDeadline(drawNow,nextFrame,interval);}
    }
    updateHUD(performance.now());
    // Use actual shader+camera time where available. Trace cost is calibrated
    // separately; cached shading must never masquerade as fresh-ray throughput.
    if(animated&&!moving&&drawNow-lastAdapt>1200&&renderer.timingSerial-lastTiming>=8) {
      const evidence=adaptiveTiming({now:drawNow,intervalMS:interval,generation:renderer.timingGeneration,
        gpu:renderer.gpuTiming,completion:renderer.completionTiming,
        gpuBudgetFraction:s.energy ? .72 : modes[s.quality].gpuBudgetFraction});
      if(evidence) {
        const next=adaptiveResolutionScale(scale,evidence.observedMS,evidence.budgetMS,.2,1,evidence.source,s.quality==='max'&&!s.energy);
        const d=dimensions(false,next,rayMapCalibrationRate);
        if(retracePolicy.consider({now:drawNow,generation:renderer.timingGeneration,evidence,
          current:renderer,next:d,traceMS:renderer.traceMS,
          // Conservative modes recover by only 3% in linear resolution. Their
          // ~6% pixel step still requires the same long upgrade dwell/evidence.
          minimumPixelChange:s.quality==='max'&&!s.energy&&evidence.source==='gpu'?.15:.05})) {
          scale=next;
          // This is a stationary resource change, not camera input. Preserve
          // the chosen four-sample map and never insert a tiny moving preview.
          invalidate(false,false);pendingQualitySize=d;
        }
        lastAdapt=drawNow;lastTiming=renderer.timingSerial;
      }
    }
  } catch(error) {fail(error);}
  finally {tickRunning=false;scheduleNext();}
}
async function start() {
  await renderer.init();if(stopped)return;sizeCanvas();
  renderer.status('Calibrating real ray-tracing throughput…');
  const probe=chooseRenderSize({...viewport,mode:{samples:1,pixels:32768,minimumPixels:32768},
    maxStorageBytes:renderer.device.limits.maxStorageBufferBindingSize,maxTextureDimension:renderer.device.limits.maxTextureDimension2D});
  await renderer.rebuild(probe.width,probe.height,1);if(stopped)return;
  if(modes[s.quality].lite) presentSize(probe);
  await renderer.render(0);if(stopped)return;
  calibrationRate=renderer.raysPerMS;
  $('loading').hidden=true;
  if(testing) {
    try {const response=await fetch('./build.json');if(response.ok)buildIdentity=await response.json();} catch {}
    $('testResults').hidden=false;
    const log=message=>{$('testLog').textContent+=message+'\n';};
    log('Running real WebGPU checks…');
    const {verify}=await import('./verify.js');let result;
    // Verification temporarily owns the model; do not allow controls to mutate
    // test inputs and then disagree with the settings restored by the suite.
    lockVerificationInput(true);
    try {result=await verify(renderer,log,{benchmark:benchmarking});} finally {lockVerificationInput(false);}
    result.build=buildIdentity;
    await report(result);log(`Verification: ${result.status}`);
    // The verification URL is still an interactive demo after the suite. Do
    // not strand the user on a static benchmark image with inert controls.
    $('testResults').dataset.result=result.status;
    $('testDone').hidden=false;
    $('testDone').onclick=()=>{$('testResults').hidden=true;canvas.focus();};
    $('testDownload').hidden=false;
    $('testDownload').onclick=()=>{
      const url=URL.createObjectURL(new Blob([JSON.stringify(result,null,2)],{type:'application/json'}));
      const link=document.createElement('a');link.href=url;
      link.download=`black-hole-${result.environment.engine}-${buildIdentity?.sourceDigest?.slice(0,16)||'unversioned'}.json`;
      link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
    };
    dirty=true;refined=false;
  }
  lastTime=performance.now();lastCameraTime=lastTime;lastHUD=lastTime;loopReady=true;wake();
}
start().catch(fail);
