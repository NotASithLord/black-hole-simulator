import assert from 'node:assert/strict';
import {KerrRenderer} from '../src/renderer.js';

// Run the actual application module against a minimal DOM and deterministic
// animation clock. Renderer boundaries are stubbed: no browser is launched,
// no GPU API is invoked, and no shader execution is claimed by these checks.
const names=['document','window','location','innerWidth','innerHeight','devicePixelRatio','performance','requestAnimationFrame','cancelAnimationFrame','setTimeout','clearTimeout'];
const saved=new Map(names.map(name=>[name,Object.getOwnPropertyDescriptor(globalThis,name)]));
const methods=['init','updateModel','rebuild','render'];
const originals=new Map(methods.map(name=>[name,KerrRenderer.prototype[name]]));
let now=1000,renderer,holdNextTrace=false,pendingTrace,traceRate=2000;
const raf=[],timers=new Map(),renderCalls=[],traceCalls=[],clockCalls=[];
let scheduledID=0;
let passed=0;
const check=(name,test)=>{test();passed++;console.log(`PASS ${name}`);};
const flush=()=>new Promise(resolve=>setImmediate(resolve));

class Element {
  constructor(id='') {this.id=id;this.tagName='DIV';this.value='';this.checked=false;this.hidden=false;this.textContent='';this.width=0;this.height=0;this.dataset={};this.listeners=new Map();this.children=new Map();this.classList={add(){}};}
  addEventListener(name,listener) {const listeners=this.listeners.get(name)||[];listeners.push(listener);this.listeners.set(name,listeners);}
  dispatch(name,properties={}) {
    const event={target:this,preventDefault(){},...properties};
    this[`on${name}`]?.(event);
    for(const listener of this.listeners.get(name)||[]) listener(event);
  }
  click(){this.dispatch('click');}
  focus(){}
  setPointerCapture(){}
  setAttribute(){}
  querySelector(selector){if(!this.children.has(selector))this.children.set(selector,new Element(selector));return this.children.get(selector);}
}
const elements=new Map();
const element=id=>{if(!elements.has(id))elements.set(id,new Element(id));return elements.get(id);};
const documentMock=new Element('document');
documentMock.getElementById=element;documentMock.hidden=false;
documentMock.documentElement={async requestFullscreen(){}};
const windowMock=new Element('window');
const install=(name,value)=>Object.defineProperty(globalThis,name,{value,writable:true,configurable:true});
for(const [name,value] of Object.entries({
  document:documentMock,window:windowMock,location:{search:'',reload(){}},innerWidth:1280,innerHeight:800,devicePixelRatio:2,
  performance:{now:()=>now},
  requestAnimationFrame:callback=>{const id=++scheduledID;raf.push({id,callback});return id;},
  cancelAnimationFrame:id=>{const index=raf.findIndex(entry=>entry.id===id);if(index>=0)raf.splice(index,1);},
  setTimeout:(callback,delay=0)=>{const id=++scheduledID;timers.set(id,{callback,due:now+delay});return id;},
  clearTimeout:id=>timers.delete(id),
})) install(name,value);

KerrRenderer.prototype.init=async function(){
  renderer=this;
  this.device={limits:{maxTextureDimension2D:8192,maxStorageBufferBindingSize:128*1024*1024}};
  this.adapter={info:{description:'Host test adapter'}};
  this.meta=new Float64Array([2.80014129]);
  let seconds=0;
  this.core={
    advance_clock(elapsed,rate,active){clockCalls.push({elapsed,rate,active});if(active)seconds+=elapsed*rate;return seconds;},
    clock_seconds(){return seconds;},
  };
};
KerrRenderer.prototype.updateModel=function(){};
KerrRenderer.prototype.rebuild=async function(width,height,samples=1,progress=()=>{},cancel=()=>false){
  const call={width,height,samples,cancel,cameraYaw:this.settings.cameraYaw};traceCalls.push(call);
  this.width=width;this.height=height;this.samples=samples;
  if(holdNextTrace){
    holdNextTrace=false;
    await new Promise(resolve=>{pendingTrace={...call,resolve};});
    pendingTrace=undefined;
  }
  call.completed=!cancel();
  if(!call.completed)return false;
  this.traceMS=20;this.raysPerMS=traceRate;this.traceCount++;
  progress(1);return true;
};
KerrRenderer.prototype.render=async function(time,options){
  renderCalls.push({time,options,quality:this.settings.quality});this.frame++;return 0.5;
};

function advanceTime(elapsed){
  now+=elapsed;
  for(const [id,timer] of [...timers]) if(timer.due<=now) {timers.delete(id);timer.callback();}
}
async function step(elapsed=20){
  advanceTime(elapsed);
  assert.equal(raf.length,1,'Application must keep exactly one animation loop scheduled');
  return raf.shift().callback(now);
}
async function idle(elapsed=1000){advanceTime(elapsed);await flush();}
function move(x,y=100){element('universe').dispatch('pointermove',{clientX:x,clientY:y});}

try {
  await import('../src/main.js');
  await flush();
  check('Motion-first startup calibrates, presents, and schedules the interactive loop',()=>{
    assert.equal(renderer.settings.quality,'interactive');assert.equal(renderer.settings.glowStrength,0);
    assert.equal(traceCalls.length,1);assert.equal(renderCalls.length,1);assert.equal(raf.length,1);
    assert.equal(element('loading').hidden,true);
    assert.ok(element('universe').width*element('universe').height<=32768);
  });
  await step(16);await step(16);
  check('Interactive frames submit without a per-frame CPU/GPU wait',()=>{
    assert.ok(renderCalls.length>=3);
    assert.ok(renderCalls.slice(1).every(call=>call.options?.wait===false));
    assert.ok(renderer.width*renderer.height<=230400);
    assert.equal(element('universe').width,renderer.width);
    assert.equal(element('universe').height,renderer.height);
  });

  element('universe').dispatch('pointerdown',{clientX:100,clientY:100,pointerId:1,button:0});
  move(110);
  holdNextTrace=true;
  const rendersBeforeDrag=renderCalls.length,sourceBeforeTrace=renderer.core.clock_seconds();
  const tracing=step(16);await flush();
  assert.ok(pendingTrace,'Drag starts a trace');
  const trace= pendingTrace;
  for(const x of [120,130,140]){now+=10;move(x);assert.equal(trace.cancel(),false);assert.equal(raf.length,0,'Input during a trace cannot start an overlapping loop');}
  trace.resolve();await tracing;
  check('Continuous drag publishes completed camera snapshots instead of starving them',()=>{
    assert.equal(traceCalls.at(-1).completed,true);
    assert.equal(renderCalls.length,rendersBeforeDrag+1);
    assert.notEqual(trace.cameraYaw,renderer.settings.cameraYaw);
    assert.equal(raf.length,1);
  });
  const expectedTraceClock=sourceBeforeTrace+(16+30)/1000*renderer.settings.playback;
  const afterTrace=renderer.core.clock_seconds();
  await step(16);
  check('Visible time spent rebuilding advances source time exactly once',()=>{
    assert.ok(Math.abs(afterTrace-expectedTraceClock)<1e-8);
    assert.ok(Math.abs(renderer.core.clock_seconds()-(expectedTraceClock+16/1000*renderer.settings.playback))<1e-8);
  });

  move(150);holdNextTrace=true;
  const rendersBeforeHard=renderCalls.length;
  const hardTrace=step(20);await flush();
  assert.ok(pendingTrace);
  element('spin').value='0.9';element('spin').dispatch('input');
  const hardCancelled=pendingTrace.cancel();
  pendingTrace.resolve();await hardTrace;
  check('Physical model changes cancel incompatible in-flight geometry',()=>{
    assert.equal(hardCancelled,true);assert.equal(traceCalls.at(-1).completed,false);
    assert.equal(renderCalls.length,rendersBeforeHard);
  });
  await step(20);
  check('The loop recovers and presents after a cancelled physical revision',()=>{
    assert.equal(traceCalls.at(-1).completed,true);assert.equal(renderCalls.length,rendersBeforeHard+1);
  });

  element('universe').dispatch('pointerup');await step(300);
  element('pause').click();await step(20);
  const pausedRenders=renderCalls.length,pausedTraces=traceCalls.length,pausedClock=renderer.core.clock_seconds();
  await idle(1000);
  check('Settled pause schedules no frame callbacks, timers, renders or source updates',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
    assert.equal(renderCalls.length,pausedRenders);assert.equal(traceCalls.length,pausedTraces);
    assert.equal(renderer.core.clock_seconds(),pausedClock);
  });
  element('exposure').value='1.2';element('exposure').dispatch('input');
  await step(20);
  const adjustedRenders=renderCalls.length;
  await idle(1000);
  check('A lighting adjustment while paused redraws once and returns to idle',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
    assert.equal(adjustedRenders,pausedRenders+1);assert.equal(renderCalls.length,adjustedRenders);
    assert.equal(traceCalls.length,pausedTraces);assert.equal(renderer.settings.exposureEV,1.2);
    assert.equal(renderer.core.clock_seconds(),pausedClock);
  });
  element('pause').click();await step(20);
  check('Resume restores source animation',()=>{
    assert.equal(renderCalls.length,adjustedRenders+1);assert.ok(renderer.core.clock_seconds()>pausedClock);
  });

  const beforeHidden=renderer.core.clock_seconds(),hiddenRenders=renderCalls.length;
  documentMock.hidden=true;documentMock.dispatch('visibilitychange');await idle(1000);
  check('Hidden document has no scheduled animation or refinement callbacks',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);assert.equal(renderCalls.length,hiddenRenders);
  });
  documentMock.hidden=false;documentMock.dispatch('visibilitychange');await step(16);
  check('Background time is excluded from both rendering and the source clock',()=>{
    assert.equal(renderCalls.length,hiddenRenders+1);
    assert.ok(Math.abs(renderer.core.clock_seconds()-beforeHidden-16/1000*renderer.settings.playback)<1e-8);
  });

  element('universe').dispatch('pointerdown',{clientX:200,clientY:100,pointerId:2,button:0});
  move(210);holdNextTrace=true;
  const beforeMidTracePause=renderer.core.clock_seconds(),pauseRate=renderer.settings.playback;
  const pausingTrace=step(20);await flush();assert.ok(pendingTrace);
  now+=30;element('pause').click();
  now+=50;pendingTrace.resolve();await pausingTrace;
  check('Pausing during a rebuild preserves visible time up to the pause',()=>{
    assert.ok(Math.abs(renderer.core.clock_seconds()-beforeMidTracePause-50/1000*pauseRate)<1e-8);
  });
  element('universe').dispatch('pointerup');element('pause').click();await step(300);

  element('universe').dispatch('pointerdown',{clientX:220,clientY:100,pointerId:3,button:0});
  move(230);holdNextTrace=true;
  const beforeRateChange=renderer.core.clock_seconds(),oldRate=renderer.settings.playback;
  const changingRateTrace=step(20);await flush();assert.ok(pendingTrace);
  now+=15;element('playback').value='1000';element('playback').dispatch('change');
  now+=25;pendingTrace.resolve();await changingRateTrace;
  check('Playback changes during a rebuild integrate the old and new rates separately',()=>{
    const expected=beforeRateChange+35/1000*oldRate+25/1000*1000;
    assert.ok(Math.abs(renderer.core.clock_seconds()-expected)<1e-8);
  });

  element('universe').dispatch('pointerup');await step(300);
  element('camera').checked=true;element('camera').dispatch('change');
  const passageYaw=renderer.settings.cameraYaw;
  holdNextTrace=true;const passageTrace=step(20);await flush();assert.ok(pendingTrace);
  now+=40;pendingTrace.resolve();await passageTrace;await step(20);
  check('Camera passage includes elapsed time spent awaiting a ray map',()=>{
    assert.ok(Math.abs(renderer.settings.cameraYaw-passageYaw-.035*.080)<1e-10);
  });
  const yawBeforeHidden=renderer.settings.cameraYaw;
  documentMock.hidden=true;documentMock.dispatch('visibilitychange');await idle(1000);
  documentMock.hidden=false;documentMock.dispatch('visibilitychange');await step(16);
  check('Camera passage excludes hidden time when the tab becomes visible',()=>{
    assert.ok(Math.abs(renderer.settings.cameraYaw-yawBeforeHidden-.035*.016)<1e-10);
  });
  element('camera').checked=false;element('camera').dispatch('change');await step(20);
  windowMock.dispatch('keydown',{key:'w',repeat:false,target:element('universe')});
  const distanceBeforeFlight=renderer.settings.cameraDistance;
  holdNextTrace=true;const flightTrace=step(20);await flush();assert.ok(pendingTrace);
  now+=40;pendingTrace.resolve();await flightTrace;await step(20);
  windowMock.dispatch('keyup',{key:'w',target:element('universe')});
  check('Keyboard flight includes elapsed time spent awaiting a ray map',()=>{
    assert.ok(Math.abs(renderer.settings.cameraDistance-distanceBeforeFlight*Math.exp(-.4*.080))<1e-10);
  });
  await step(300);
  renderer.adapter={};
  element('appearance').value='scientific';element('appearance').dispatch('change');
  await step(600);
  const scientificRenders=renderCalls.length,scientificTraces=traceCalls.length,scientificClock=renderer.core.clock_seconds();
  await idle(5000);
  check('Steady Scientific appearance sleeps without polling despite active source rotation',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
    assert.equal(renderCalls.length,scientificRenders);assert.equal(traceCalls.length,scientificTraces);
    assert.equal(renderer.settings.rotation,true);
  });
  check('Privacy-restricted adapter information falls back without stopping the app',()=>{
    assert.equal(element('device').textContent,'WebGPU hardware adapter');
    assert.equal(element('loading').hidden,true);
  });
  renderer.timingSerial=1000;renderer.gpuMS=100;renderer.queueMS=100;
  element('exposure').value='0.7';element('exposure').dispatch('input');
  await step(20);await idle(5000);
  check('Old GPU timing cannot trigger a static-scene refinement loop after idle',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
    assert.equal(traceCalls.length,scientificTraces);assert.equal(renderCalls.length,scientificRenders+1);
  });
  check('A sleeping Scientific scene settles its visible source time exactly once on wake',()=>{
    assert.ok(Math.abs(renderer.core.clock_seconds()-scientificClock-5.02*renderer.settings.playback)<1e-8);
  });
  element('appearance').value='radiant';element('appearance').dispatch('change');
  element('structure').value='0';element('structure').dispatch('input');
  element('fluctuations').value='0';element('fluctuations').dispatch('input');
  await step(300);await idle(1000);
  check('Radiant appearance with no time-varying material also sleeps',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  element('rotate').checked=false;element('rotate').dispatch('change');
  element('structure').value='0.9';element('structure').dispatch('input');
  element('fluctuations').value='0.06';element('fluctuations').dispatch('input');
  await step(20);
  const frozenClock=renderer.core.clock_seconds();
  await idle(2000);
  check('Rotation disabled remains idle and preserves the frozen phase',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);assert.equal(renderer.core.clock_seconds(),frozenClock);
  });
  element('spin').value='0.8';element('spin').dispatch('input');
  await step(16);
  check('A static geometry edit uses one delayed refinement event instead of frame polling',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,1);
  });
  await idle(100);
  assert.equal(raf.length,0);assert.equal(timers.size,1);
  await step(150);
  check('The delayed refinement completes once and returns to sleep',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  innerWidth=900;windowMock.dispatch('resize');await step(300);
  check('Resizing a sleeping scene wakes exactly one settled redraw',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
    assert.ok(renderer.width>0&&renderer.height>0);
  });
  documentMock.hidden=true;documentMock.dispatch('visibilitychange');
  element('exposure').value='1';element('exposure').dispatch('input');await idle(1000);
  check('Controls while hidden leave work pending without scheduling callbacks',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  const beforeVisibleRedraw=renderCalls.length;
  documentMock.hidden=false;documentMock.dispatch('visibilitychange');await step(20);
  check('Visibility restores pending static presentation and then sleeps again',()=>{
    assert.equal(renderCalls.length,beforeVisibleRedraw+1);assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  await idle(5000);
  const sleepingDistance=renderer.settings.cameraDistance;
  windowMock.dispatch('keydown',{key:'w',repeat:false,target:element('universe')});await step(20);
  check('Keyboard flight wakes a static scene without applying old idle time to the camera',()=>{
    assert.ok(Math.abs(renderer.settings.cameraDistance-sleepingDistance*Math.exp(-.4*.020))<1e-10);
  });
  windowMock.dispatch('keyup',{key:'w',target:element('universe')});await step(300);
  check('Releasing the last camera key returns a frozen scene to zero callbacks',()=>{
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  traceRate=50_000;innerWidth=2560;innerHeight=1440;
  windowMock.dispatch('resize');await step(16);await step(300);
  check('Calibrated fast hardware refines beyond the former Motion-first ceiling',()=>{
    assert.ok(renderer.width*renderer.height>230400);
    assert.ok(renderer.width*renderer.height<=2073600);
    assert.equal(element('universe').width,renderer.width);
    assert.equal(element('universe').height,renderer.height);
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  const beforeEnergy=traceCalls.length;
  element('energy').checked=true;element('energy').dispatch('change');await step(16);await step(300);
  check('Energy saver immediately rebuilds a bounded smaller map even from a sleeping scene',()=>{
    assert.ok(traceCalls.length>beforeEnergy);
    assert.ok(renderer.width*renderer.height<=230400);
    assert.equal(renderer.settings.energy,true);
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  element('energy').checked=false;element('energy').dispatch('change');await step(16);await step(300);
  check('Leaving energy saver restores measured stationary headroom',()=>{
    assert.ok(renderer.width*renderer.height>230400);
    assert.ok(renderer.width*renderer.height<=2073600);
  });
  element('universe').dispatch('wheel',{deltaY:1});holdNextTrace=true;
  const energyTrace=step(16);await flush();assert.ok(pendingTrace);
  element('energy').checked=true;element('energy').dispatch('change');
  const energyCancelled=pendingTrace.cancel();pendingTrace.resolve();await energyTrace;
  await step(300);
  check('Changing energy policy retires an incompatible in-flight map before replacement',()=>{
    assert.equal(energyCancelled,true);
    assert.ok(renderer.width*renderer.height<=230400);
    assert.equal(traceCalls.at(-1).completed,true);
    assert.equal(raf.length,0);assert.equal(timers.size,0);
  });
  assert.equal(element('loading').hidden,true,element('status').textContent);
  console.log(`${passed}/${passed} actual-application host integration checks passed; no browser or GPU execution was performed.`);
} finally {
  for(const [name,value] of originals) KerrRenderer.prototype[name]=value;
  for(const [name,descriptor] of saved) {
    if(descriptor)Object.defineProperty(globalThis,name,descriptor);else delete globalThis[name];
  }
}
