// BlackHoleDesk WebGPU transport, ported from the native production Metal source.
// Units G=c=M=1. Uniform fields retain the native 176-byte layout. The host may
// allocate a larger uniform buffer. padding is a trace-only row dispatch offset.
// WGSL does not expose Metal's fastMathEnabled=false contract: compensated
// arithmetic is retained, but its accuracy must be measured on each backend.
struct Uniforms {
    resolution: vec2<u32>, time: f32, spin: f32, diskTilt: f32, cameraYaw: f32,
    cameraPitch: f32, cameraDistance: f32, steps: u32, samples: u32, frame: u32,
    observerRadius: f32, verticalFOV: f32, integrationTolerance: f32, maxStep: f32,
    diskInnerRadius: f32, diskOuterRadius: f32, exposure: f32, diskTableCount: u32,
    diskLogRadiusMin: f32, diskLogRadiusStep: f32, massTimeSeconds: f32,
    perturbationAmplitude: f32, temperatureTableCount: u32, temperatureLogMin: f32,
    temperatureLogStep: f32, diagnosticMode: u32, padding: f32, lookYaw: f32,
    lookPitch: f32, appearanceMode: u32, materialStrength: f32, paletteTemperature: f32,
    flowTime: f32, flowLogRadiusMin: f32, flowLogRadiusSpan: f32, flowTimeScale: f32,
    // Browser-only material detail: 0 = lightweight analytic source, 1 = full.
    // The browser does not run the native fluid proxy; this preserves its ABI.
    flowEnabled: u32, diskHeightScale: f32, diskCorrugation: f32, edgeSamples: u32,
    edgeCapacity: u32, materialShutterSeconds: f32, materialTimeSamples: u32,
}
@group(0) @binding(0) var<uniform> params: Uniforms;
@group(0) @binding(1) var<storage, read_write> geometry: array<vec4<f32>>;
@group(0) @binding(2) var<storage, read> diskTable: array<vec4<f32>>;
@group(0) @binding(3) var<storage, read> spectrumTable: array<vec4<f32>>;
@group(0) @binding(4) var radiance: texture_storage_2d<rgba16float, write>;
@group(0) @binding(5) var<storage, read> validationPixels: array<vec4<f32>>;
@group(0) @binding(6) var<storage, read_write> validationOutput: array<vec4<f32>>;
const PI: f32 = 3.14159265358979323846;
const FMAX: f32 = 3.4028234663852886e38;
fn finite(x: f32) -> bool { return abs(x) <= FMAX; }
fn finite2(x: vec2<f32>) -> bool { return all(abs(x) <= vec2<f32>(FMAX)); }
fn finite4(x: vec4<f32>) -> bool { return all(abs(x) <= vec4<f32>(FMAX)); }
struct State { q: vec4<f32>, c: vec2<f32> }
struct Constants { a: f32, xi: f32, eta: f32, energy: f32, b: f32, k: f32 }
struct RayResult {
    state: State, constants: Constants, initialInvariant: f32, invariant: f32,
    localError: f32, minRadius: f32, status: u32, accepted: u32, rejected: u32,
}
struct RKResult { value: State, error: State }
fn add(a: State, b: State, h: f32) -> State { return State(a.q+h*b.q,a.c+h*b.c); }
fn combine(a: State, b: State, ca: f32, cb: f32) -> State { return State(ca*a.q+cb*b.q,ca*a.c+cb*b.c); }
fn derivative(s: State, k: Constants) -> State {
    let u=s.q.x; let mu=s.q.z; let a=k.a; let aa=a*a;
    let d=1.0-2.0*u+aa*u*u;
    var sin2=max(1.0e-12,1.0-mu*mu);
    let polarA=k.eta+k.xi*k.xi+aa;
    if(abs(mu)>0.9 && polarA>aa) {
        let polarB=s.q.w*s.q.w+k.xi*k.xi;
        sin2=max(1.0e-15,2.0*polarB/(polarA+sqrt(max(0.0,polarA*polarA-4.0*aa*polarB))));
    }
    let p=1.0+(aa-a*k.xi)*u*u;
    let phi=-(k.xi/sin2+a*(2.0*u-a*k.xi*u*u)/d);
    let delay=(1.0+aa*u*u)*p/(u*u*d)+a*k.xi-aa*sin2;
    return State(vec4<f32>(s.q.y,k.b*u+3.0*k.k*u*u-2.0*aa*k.eta*u*u*u,
                          s.q.w,k.b*mu-2.0*aa*mu*mu*mu),vec2<f32>(phi,delay));
}
// Dormand-Prince 5(4), with the native direct error-coefficient sum.
fn rk45(y: State, c: Constants, h: f32) -> RKResult {
    let k1=derivative(y,c);
    let k2=derivative(add(y,k1,h*(1.0/5.0)),c);
    let k3=derivative(add(add(y,k1,h*(3.0/40.0)),k2,h*(9.0/40.0)),c);
    let k4=derivative(add(add(add(y,k1,h*(44.0/45.0)),k2,h*(-56.0/15.0)),k3,h*(32.0/9.0)),c);
    let k5=derivative(add(add(add(add(y,k1,h*(19372.0/6561.0)),k2,h*(-25360.0/2187.0)),k3,h*(64448.0/6561.0)),k4,h*(-212.0/729.0)),c);
    let k6=derivative(add(add(add(add(add(y,k1,h*(9017.0/3168.0)),k2,h*(-355.0/33.0)),k3,h*(46732.0/5247.0)),k4,h*(49.0/176.0)),k5,h*(-5103.0/18656.0)),c);
    let result=add(add(add(add(add(y,k1,h*(35.0/384.0)),k3,h*(500.0/1113.0)),k4,h*(125.0/192.0)),k5,h*(-2187.0/6784.0)),k6,h*(11.0/84.0));
    let k7=derivative(result,c);
    var err=combine(k1,k3,35.0/384.0-5179.0/57600.0,500.0/1113.0-7571.0/16695.0);
    err=add(err,k4,125.0/192.0-393.0/640.0);
    err=add(err,k5,-2187.0/6784.0+92097.0/339200.0);
    err=add(err,k6,11.0/84.0-187.0/2100.0);
    err=add(err,k7,-1.0/40.0);
    err.q*=h; err.c*=h;
    return RKResult(result,err);
}
fn invariant(s: State,c: Constants) -> f32 {
    let u=s.q.x; let mu=s.q.z; let aa=c.a*c.a;
    let radial=1.0+c.b*u*u+2.0*c.k*u*u*u-aa*c.eta*u*u*u*u;
    let polar=c.eta+c.b*mu*mu-aa*mu*mu*mu*mu;
    let scaleR=1.0+abs(c.b*u*u)+abs(2.0*c.k*u*u*u)+abs(aa*c.eta*u*u*u*u);
    let scaleP=1.0+abs(c.eta)+abs(c.b*mu*mu)+abs(aa*mu*mu*mu*mu);
    return max(abs(s.q.y*s.q.y-radial)/scaleR,abs(s.q.w*s.q.w-polar)/scaleP);
}
fn initializeRay(pixel: vec2<f32>,u: Uniforms) -> RayResult {
    var o: RayResult;
    let a=clamp(u.spin,0.0,0.998); let r=u.observerRadius;
    let theta=clamp(PI*0.5-u.cameraPitch,0.1,PI-0.1);
    let mu=cos(theta); let st=sin(theta); let sigma=r*r+a*a*mu*mu;
    let delta=r*r-2.0*r+a*a; let A=(r*r+a*a)*(r*r+a*a)-a*a*delta*st*st;
    let lapse=sqrt(sigma*delta/A); let omega=2.0*a*r/A;
    let screen=(pixel-0.5*vec2<f32>(u.resolution))*(2.0*tan(0.5*u.verticalFOV)/f32(u.resolution.y));
    var n=normalize(vec3<f32>(-1.0,screen.y,screen.x));
    let cy=cos(u.lookYaw); let sy=sin(u.lookYaw); let cp=cos(u.lookPitch); let sp=sin(u.lookPitch);
    n=vec3<f32>(cp*n.x-sp*n.y,sp*n.x+cp*n.y,n.z);
    n=vec3<f32>(cy*n.x+sy*n.z,n.y,-sy*n.x+cy*n.z);
    let L=-sqrt(A/sigma)*st*n.z; let E=lapse+omega*L;
    let xi=L/E; let ptheta=-sqrt(sigma)*n.y/E;
    let eta=ptheta*ptheta+mu*mu*(xi*xi/(st*st)-a*a);
    o.constants=Constants(a,xi,eta,E,a*a-eta-xi*xi,eta+(xi-a)*(xi-a));
    o.state=State(vec4<f32>(1.0/r,-n.x*sqrt(sigma*delta)/(E*r*r),mu,-st*n.y*sqrt(sigma)/E),vec2<f32>(u.cameraYaw,0.0));
    o.initialInvariant=invariant(o.state,o.constants);
    o.invariant=o.initialInvariant; o.localError=0.0; o.minRadius=r;
    o.status=4u; o.accepted=0u; o.rejected=0u;
    return o;
}
fn errorNorm(y: State,err: State,c: Constants) -> f32 {
    let angular=max(1.0,sqrt(abs(c.eta)+c.xi*c.xi+c.a*c.a));
    let scale=vec4<f32>(max(0.02,abs(y.q.x)),max(1.0,abs(y.q.y)),1.0,angular);
    let e=abs(err.q)/scale;
    let ec=abs(err.c)/vec2<f32>(max(1.0,abs(y.c.x)),max(1.0,abs(y.c.y)));
    return max(max(max(e.x,e.y),max(e.z,e.w)),max(ec.x,ec.y));
}
fn crossing(old: State,next: State,c: Constants,h: f32,component: u32,crossingValue: f32) -> State {
    let f0=derivative(old,c); let f1=derivative(next,c);
    var lo=0.0; var hi=1.0;
    for(var j=0u;j<14u;j++) {
        let x=0.5*(lo+hi); let x2=x*x; let x3=x2*x;
        let m=(2.0*x3-3.0*x2+1.0)*old.q[component]+(x3-2.0*x2+x)*h*f0.q[component]+
              (-2.0*x3+3.0*x2)*next.q[component]+(x3-x2)*h*f1.q[component]-crossingValue;
        if(m*(old.q[component]-crossingValue)>0.0) { lo=x; } else { hi=x; }
    }
    var x=0.5*(lo+hi); let hit=rk45(old,c,h*x).value;
    let slope=derivative(hit,c).q[component];
    x=clamp(x-(hit.q[component]-crossingValue)/(h*slope),0.0,1.0);
    return rk45(old,c,h*x).value;
}
fn ds(x: f32) -> vec2<f32> { return vec2<f32>(x,0.0); }
fn dn(h: f32,l: f32) -> vec2<f32> { let s=h+l; return vec2<f32>(s,l-(s-h)); }
fn da(a: vec2<f32>,b: vec2<f32>) -> vec2<f32> {
    let s=a.x+b.x; let v=s-a.x;
    return dn(s,(a.x-(s-v))+(b.x-v)+a.y+b.y);
}
fn dm(a: vec2<f32>,b: vec2<f32>) -> vec2<f32> {
    let p=a.x*b.x;
    // WGSL fma may be unfused. Bit splitting obtains exact 12-bit high parts
    // without the overflow risk of multiplying by a floating-point splitter.
    let ah=bitcast<f32>(bitcast<u32>(a.x)&0xfffff000u); let al=a.x-ah;
    let bh=bitcast<f32>(bitcast<u32>(b.x)&0xfffff000u); let bl=b.x-bh;
    let residual=((ah*bh-p)+ah*bl+al*bh)+al*bl;
    return dn(p,residual+a.x*b.y+a.y*b.x+a.y*b.y);
}
fn dd(a: vec2<f32>,b: vec2<f32>) -> vec2<f32> {
    let q=a.x/b.x; let r=da(a,-dm(b,ds(q)));
    return dn(q,(r.x+r.y)/b.x);
}
fn dq(a: vec2<f32>) -> vec2<f32> {
    let q=sqrt(max(a.x,0.0));
    if(q>0.0) { return da(ds(q),dd(da(a,-dm(ds(q),ds(q))),ds(2.0*q))); }
    return ds(0.0);
}
fn df(a: vec2<f32>) -> f32 { return a.x+a.y; }
struct WideConstants { c: Constants, aa: vec2<f32>, b: vec2<f32>, k: vec2<f32>, pcoef: vec2<f32>, ax: vec2<f32> }
struct WideState { u: vec2<f32>, v: vec2<f32>, phi: vec2<f32>, delay: vec2<f32>, polar: vec2<f32> }
struct WideRKResult { value: WideState, error: WideState }
fn widen(c: Constants) -> WideConstants {
    var w: WideConstants; w.c=c;
    w.aa=dm(ds(c.a),ds(c.a)); w.ax=dm(ds(c.a),ds(c.xi));
    w.b=da(da(w.aa,-ds(c.eta)),-dm(ds(c.xi),ds(c.xi)));
    let d=da(ds(c.xi),-ds(c.a));
    w.k=da(ds(c.eta),dm(d,d)); w.pcoef=da(w.aa,-w.ax);
    return w;
}
fn widePotential(q: vec2<f32>,k: WideConstants) -> vec2<f32> {
    let q2=dm(q,q); let p=da(ds(1.0),dm(k.pcoef,q2));
    let d=da(da(ds(1.0),-dm(ds(2.0),q)),dm(k.aa,q2));
    return da(dm(p,p),-dm(dm(d,q2),k.k));
}
fn needsWide(c: Constants) -> bool {
    if(c.b>=0.0 || c.eta<0.0) { return false; }
    let disc=9.0*c.k*c.k+8.0*c.a*c.a*c.eta*c.b;
    if(disc<0.0) { return false; }
    let criticalU=-2.0*c.b/(3.0*c.k+sqrt(disc));
    let horizon=1.0+sqrt(1.0-c.a*c.a);
    if(criticalU<=0.0 || criticalU>=1.0/horizon) { return false; }
    return abs(df(widePotential(ds(criticalU),widen(c))))<0.001;
}
fn wa(a: WideState,b: WideState,h: vec2<f32>) -> WideState {
    return WideState(da(a.u,dm(b.u,h)),da(a.v,dm(b.v,h)),da(a.phi,dm(b.phi,h)),da(a.delay,dm(b.delay,h)),a.polar+df(h)*b.polar);
}
fn wd(s: WideState,k: WideConstants) -> WideState {
    let q2=dm(s.u,s.u); let q3=dm(q2,s.u);
    let acceleration=da(da(dm(k.b,s.u),dm(dm(ds(3.0),k.k),q2)),-dm(dm(dm(ds(2.0),k.aa),ds(k.c.eta)),q3));
    let mu=s.polar.x; let w=s.polar.y; let a=k.c.a;
    var sin2=max(1.0e-12,1.0-mu*mu); let polarA=k.c.eta+k.c.xi*k.c.xi+a*a;
    if(abs(mu)>0.9 && polarA>a*a) {
        let pb=w*w+k.c.xi*k.c.xi;
        sin2=max(1.0e-15,2.0*pb/(polarA+sqrt(max(0.0,polarA*polarA-4.0*a*a*pb))));
    }
    let d=da(da(ds(1.0),-dm(ds(2.0),s.u)),dm(k.aa,q2));
    let p=da(ds(1.0),dm(k.pcoef,q2));
    let phi=-da(dd(dm(ds(a),da(dm(ds(2.0),s.u),-dm(k.ax,q2))),d),dd(ds(k.c.xi),ds(sin2)));
    let delay=da(dd(dm(da(ds(1.0),dm(k.aa,q2)),p),dm(q2,d)),da(k.ax,-dm(k.aa,ds(sin2))));
    return WideState(s.v,acceleration,phi,delay,vec2<f32>(w,df(k.b)*mu-2.0*a*a*mu*mu*mu));
}
fn wrk4(y: WideState,c: WideConstants,h: f32) -> WideState {
    let k1=wd(y,c); let k2=wd(wa(y,k1,ds(h*0.5)),c);
    let k3=wd(wa(y,k2,ds(h*0.5)),c); let k4=wd(wa(y,k3,ds(h)),c);
    let sum=wa(wa(wa(k1,k2,ds(2.0)),k3,ds(2.0)),k4,ds(1.0));
    return wa(y,sum,dd(ds(h),ds(6.0)));
}
fn wstep(y: WideState,c: WideConstants,h: f32) -> WideRKResult {
    let full=wrk4(y,c,h); let fine=wrk4(wrk4(y,c,h*0.5),c,h*0.5);
    let delta=wa(fine,full,ds(-1.0));
    let error=WideState(dd(delta.u,ds(15.0)),dd(delta.v,ds(15.0)),dd(delta.phi,ds(15.0)),dd(delta.delay,ds(15.0)),delta.polar/15.0);
    return WideRKResult(wa(fine,error,ds(1.0)),error);
}
fn narrow(w: WideState) -> State { return State(vec4<f32>(df(w.u),df(w.v),w.polar.x,w.polar.y),vec2<f32>(df(w.phi),df(w.delay))); }
fn wcomponent(w: WideState,component: u32) -> f32 {
    if(component==0u) { return df(w.u); }
    return select(w.polar.y,w.polar.x,component==2u);
}
fn wcross(old: WideState,next: WideState,c: WideConstants,h: f32,component: u32,crossingValue: f32) -> WideState {
    let a=narrow(old); let b=narrow(next); let f0=narrow(wd(old,c)); let f1=narrow(wd(next,c));
    var lo=0.0; var hi=1.0;
    for(var i=0u;i<14u;i++) {
        let x=0.5*(lo+hi); let x2=x*x; let x3=x2*x;
        let value=(2.0*x3-3.0*x2+1.0)*a.q[component]+(x3-2.0*x2+x)*h*f0.q[component]+
                  (-2.0*x3+3.0*x2)*b.q[component]+(x3-x2)*h*f1.q[component]-crossingValue;
        if(value*(a.q[component]-crossingValue)>0.0) { lo=x; } else { hi=x; }
    }
    var x=0.5*(lo+hi); let hit=wstep(old,c,h*x).value;
    let slope=wcomponent(wd(hit,c),component);
    x=clamp(x-(wcomponent(hit,component)-crossingValue)/(h*slope),0.0,1.0);
    return wstep(old,c,h*x).value;
}
fn cylindricalRadius(s: State) -> f32 { return sqrt(max(0.0,1.0-s.q.z*s.q.z))/s.q.x; }
fn diskHeight(rho: f32,phi: f32,u: Uniforms) -> f32 {
    let radial=max(0.0,1.0-sqrt(u.diskInnerRadius/max(rho,u.diskInnerRadius)));
    let t=clamp((u.diskOuterRadius-rho)/(0.2*u.diskOuterRadius),0.0,1.0);
    let closure=t*t*t*(10.0-15.0*t+6.0*t*t);
    if(u.diskCorrugation<=0.0) { return max(u.diskHeightScale,0.0)*radial*closure; }
    let lr=log(max(rho/u.diskInnerRadius,1.0e-10));
    let corrugation=0.65*cos(3.0*phi+2.0*lr)+0.35*cos(7.0*phi-3.0*lr);
    return max(u.diskHeightScale,0.0)*radial*closure*(1.0+clamp(u.diskCorrugation,0.0,0.08)*corrugation);
}
fn diskFaces(s: State,u: Uniforms) -> vec4<f32> {
    let rho=cylindricalRadius(s); let z=s.q.z/s.q.x; let height=diskHeight(rho,s.c.x,u);
    return vec4<f32>(z-height,-z-height,u.diskInnerRadius-rho,rho-u.diskOuterRadius);
}
fn faceMaximum(f: vec4<f32>) -> f32 { return max(max(f.x,f.y),max(f.z,f.w)); }
fn denseState(a: State,b: State,fa: State,fb: State,h: f32,x: f32) -> State {
    let x2=x*x; let x3=x2*x;
    return State((2.0*x3-3.0*x2+1.0)*a.q+(x3-2.0*x2+x)*h*fa.q+(-2.0*x3+3.0*x2)*b.q+(x3-x2)*h*fb.q,
                 (2.0*x3-3.0*x2+1.0)*a.c+(x3-2.0*x2+x)*h*fa.c+(-2.0*x3+3.0*x2)*b.c+(x3-x2)*h*fb.c);
}
struct SurfaceHit { hit: State, found: bool }
struct WideSurfaceHit { hit: WideState, found: bool }
fn finiteDiskHit(old: State,next: State,c: Constants,h: f32,u: Uniforms) -> SurfaceHit {
    let fa=derivative(old,c); let fb=derivative(next,c);
    var previous=diskFaces(old,u);
    if(faceMaximum(previous)<=0.0) { return SurfaceHit(next,false); }
    var earliest=2.0; var first=next;
    for(var segment=1u;segment<=8u;segment++) {
        let left=f32(segment-1u)/8.0; let right=f32(segment)/8.0;
        if(left>=earliest) { break; }
        var point=next;
        if(segment!=8u) { point=denseState(old,next,fa,fb,h,right); }
        let current=diskFaces(point,u);
        for(var face=0u;face<4u;face++) {
            if(previous[face]>0.0 && current[face]<=0.0) {
                var lo=left; var hi=right;
                var lower=rk45(old,c,h*lo).value; var upper=rk45(old,c,h*hi).value;
                for(var recovery=0u;recovery<8u && diskFaces(lower,u)[face]<=0.0 && lo>0.0;recovery++) {
                    lo=max(0.0,lo-0.125); lower=rk45(old,c,h*lo).value;
                }
                for(var recovery=0u;recovery<8u && diskFaces(upper,u)[face]>0.0 && hi<1.0;recovery++) {
                    hi=min(1.0,hi+0.125); upper=rk45(old,c,h*hi).value;
                }
                if(diskFaces(lower,u)[face]<=0.0 || diskFaces(upper,u)[face]>0.0) { continue; }
                for(var j=0u;j<20u;j++) {
                    let mid=0.5*(lo+hi); let candidate=rk45(old,c,h*mid).value;
                    if(diskFaces(candidate,u)[face]>0.0) { lo=mid; } else { hi=mid; }
                }
                let candidate=rk45(old,c,h*hi).value;
                if(faceMaximum(diskFaces(candidate,u))<=2.0e-6*max(1.0,cylindricalRadius(candidate)) && hi<earliest) {
                    earliest=hi; first=candidate;
                }
            }
        }
        previous=current;
    }
    return SurfaceHit(first,earliest<=1.0);
}
fn wideFiniteDiskHit(old: WideState,next: WideState,c: WideConstants,h: f32,u: Uniforms) -> WideSurfaceHit {
    let a=narrow(old); let b=narrow(next); let fa=narrow(wd(old,c)); let fb=narrow(wd(next,c));
    var previous=diskFaces(a,u);
    if(faceMaximum(previous)<=0.0) { return WideSurfaceHit(next,false); }
    var earliest=2.0; var first=next;
    for(var segment=1u;segment<=8u;segment++) {
        let left=f32(segment-1u)/8.0; let right=f32(segment)/8.0;
        if(left>=earliest) { break; }
        var point=b;
        if(segment!=8u) { point=denseState(a,b,fa,fb,h,right); }
        let current=diskFaces(point,u);
        for(var face=0u;face<4u;face++) {
            if(previous[face]>0.0 && current[face]<=0.0) {
                var lo=left; var hi=right;
                var lower=wstep(old,c,h*lo).value; var upper=wstep(old,c,h*hi).value;
                for(var recovery=0u;recovery<8u && diskFaces(narrow(lower),u)[face]<=0.0 && lo>0.0;recovery++) {
                    lo=max(0.0,lo-0.125); lower=wstep(old,c,h*lo).value;
                }
                for(var recovery=0u;recovery<8u && diskFaces(narrow(upper),u)[face]>0.0 && hi<1.0;recovery++) {
                    hi=min(1.0,hi+0.125); upper=wstep(old,c,h*hi).value;
                }
                if(diskFaces(narrow(lower),u)[face]<=0.0 || diskFaces(narrow(upper),u)[face]>0.0) { continue; }
                for(var j=0u;j<20u;j++) {
                    let mid=0.5*(lo+hi); let candidate=wstep(old,c,h*mid).value;
                    if(diskFaces(narrow(candidate),u)[face]>0.0) { lo=mid; } else { hi=mid; }
                }
                let candidate=wstep(old,c,h*hi).value; let s=narrow(candidate);
                if(faceMaximum(diskFaces(s,u))<=2.0e-6*max(1.0,cylindricalRadius(s)) && hi<earliest) {
                    earliest=hi; first=candidate;
                }
            }
        }
        previous=current;
    }
    return WideSurfaceHit(first,earliest<=1.0);
}
fn followWide(initial: RayResult,u: Uniforms,radianceOnly: bool) -> RayResult {
    var o=initial; let c=widen(o.constants);
    let initialU=dd(ds(1.0),ds(u.observerRadius));
    let initialV=dq(widePotential(initialU,c))*select(1.0,-1.0,o.state.q.y<0.0);
    var y=WideState(initialU,initialV,ds(o.state.c.x),ds(0.0),o.state.q.zw);
    let horizon=1.0+sqrt(1.0-c.c.a*c.c.a); let captureU=1.0/(horizon+0.0005);
    let sceneExtent=select(u.diskOuterRadius,length(vec2<f32>(u.diskOuterRadius,1.08*u.diskHeightScale)),u.diskHeightScale>0.0);
    let escapeRadius=select(max(1000.0,2.0*u.observerRadius),max(u.observerRadius,sceneExtent)+0.001,radianceOnly);
    let escapeU=1.0/escapeRadius;
    let radialTolerance=max(1.0e-13,u.integrationTolerance*1.0e-6);
    let angularTolerance=max(3.0e-7,u.integrationTolerance);
    var h=min(0.002,u.maxStep);
    for(var step=0u;step<u.steps;step++) {
        let q=df(y.u); let v=df(y.v);
        if(q>=captureU) { o.status=2u; break; }
        if(q<escapeU && v<0.0) { o.status=3u; break; }
        h=min(h,0.28*max(q,escapeU)/max(abs(v),0.01));
        if(v>0.0) { h=min(h,1.02*(captureU-q)/v); }
        h=min(h,u.maxStep);
        if(u.diskHeightScale>0.0 && q>1.0/sceneExtent && abs(y.polar.x)<0.4) {
            h=min(h,0.08*q/max(abs(v),0.001));
            h=min(h,0.25/max(abs(df(wd(y,c).phi)),0.001));
        }
        if(h<1.0e-9 || !finite(h)) { o.status=5u; break; }
        let advance=wstep(y,c,h); let error=advance.error; var next=advance.value;
        let radialError=max(abs(df(error.u))/max(0.02,abs(df(next.u))),abs(df(error.v))/max(1.0,abs(df(next.v))));
        let angleScale=max(1.0,sqrt(abs(c.c.eta)+c.c.xi*c.c.xi+c.c.a*c.c.a));
        let angularError=max(abs(error.polar.x),abs(error.polar.y)/angleScale);
        let coordinateError=max(abs(df(error.phi))/max(1.0,abs(df(next.phi))),abs(df(error.delay))/max(1.0,abs(df(next.delay))));
        let ratio=max(radialError/radialTolerance,max(angularError/angularTolerance,coordinateError/(angularTolerance*0.1)));
        let valid=finite4(narrow(next).q) && finite2(narrow(next).c) && finite(ratio);
        if(!valid || ratio>1.0) {
            o.rejected++; h*=select(0.25,clamp(0.85*pow(max(ratio,1.0e-6),-0.2),0.15,0.8),valid); continue;
        }
        o.accepted++; o.localError=max(o.localError,max(radialError,max(angularError,coordinateError)));
        let s=narrow(next);
        let radialInv=abs(df(da(dm(next.v,next.v),-widePotential(next.u,c))))/(1.0+abs(df(widePotential(next.u,c))));
        let mu=s.q.z; let polar=c.c.eta+c.c.b*mu*mu-c.c.a*c.c.a*mu*mu*mu*mu;
        let polarInv=abs(s.q.w*s.q.w-polar)/(1.0+abs(c.c.eta)+abs(c.c.b*mu*mu)+c.c.a*c.c.a*mu*mu*mu*mu);
        o.invariant=max(o.invariant,max(radialInv,polarInv)); o.minRadius=min(o.minRadius,1.0/s.q.x);
        if(o.invariant>max(100.0*angularTolerance,3.0e-4) || abs(s.q.z)>1.00002) { y=next; o.status=5u; break; }
        if(u.diskHeightScale>0.0) {
            if(faceMaximum(diskFaces(narrow(y),u))<=0.0) { o.status=5u; break; }
            let beyond=1.0/max(df(y.u),df(next.u))>sceneExtent && df(y.v)*df(next.v)>0.0;
            if(!beyond) {
                let hit=wideFiniteDiskHit(y,next,c,h,u);
                if(hit.found) { y=hit.hit; o.status=1u; break; }
            }
        } else if(y.polar.x*next.polar.x<0.0) {
            let hit=wcross(y,next,c,h,2u,0.0); let r=1.0/df(hit.u);
            if(r>=u.diskInnerRadius && r<=u.diskOuterRadius) { y=hit; o.status=1u; break; }
        }
        if(s.q.x>=captureU) {
            // A captured radiance ray stores only (-2,0,0,0). Its final event
            // coordinates are invisible; diagnostic rays still refine them.
            if(radianceOnly) { y=next; } else { y=wcross(y,next,c,h,0u,captureU); }
            o.status=2u; break;
        }
        if(s.q.x<escapeU && s.q.y<0.0) {
            if(radianceOnly) { y=next; } else { y=wcross(y,next,c,h,0u,escapeU); }
            o.status=3u; break;
        }
        if(c.c.xi==0.0 && y.polar.y*next.polar.y<0.0) {
            var axial=c.c.eta>=0.0;
            if(!axial) { axial=abs(wcross(y,next,c,h,3u,0.0).polar.x)>0.9999; }
            if(axial) { next.phi=da(next.phi,ds(PI)); }
        }
        y=next;
        h*=clamp(0.9*pow(max(ratio,1.0e-6),-0.2),0.5,2.5);
    }
    o.state=narrow(y); return o;
}
fn followRay(pixel: vec2<f32>,u: Uniforms,radianceOnly: bool) -> RayResult {
    var o=initializeRay(pixel,u); let c=o.constants;
    if(u.diskHeightScale>0.0 && faceMaximum(diskFaces(o.state,u))<=0.0) { o.status=5u; return o; }
    if(needsWide(c)) { return followWide(o,u,radianceOnly); }
    let horizon=1.0+sqrt(1.0-c.a*c.a); let captureU=1.0/(horizon+0.0005);
    let sceneExtent=select(u.diskOuterRadius,length(vec2<f32>(u.diskOuterRadius,1.08*u.diskHeightScale)),u.diskHeightScale>0.0);
    let escapeRadius=select(max(1000.0,2.0*u.observerRadius),max(u.observerRadius,sceneExtent)+0.001,radianceOnly);
    let escapeU=1.0/escapeRadius; let tol=max(u.integrationTolerance,3.0e-7);
    var h=min(u.maxStep,0.004); let maxInv=max(100.0*tol,3.0e-4);
    for(var step=0u;step<u.steps;step++) {
        let old=o.state;
        if(old.q.x>=captureU) { o.status=2u; break; }
        if(old.q.x<escapeU && old.q.y<0.0) { o.status=3u; break; }
        h=min(h,0.28*max(old.q.x,escapeU)/max(abs(old.q.y),0.01));
        if(old.q.y>0.0) { h=min(h,1.02*(captureU-old.q.x)/old.q.y); }
        h=min(h,u.maxStep);
        if(u.diskHeightScale>0.0 && old.q.x>1.0/sceneExtent && abs(old.q.z)<0.4) {
            h=min(h,0.08*old.q.x/max(abs(old.q.y),0.001));
            h=min(h,0.25/max(abs(derivative(old,c).c.x),0.001));
        }
        if(h<1.0e-8 || !finite(h)) { o.status=5u; break; }
        let advance=rk45(old,c,h); let error=advance.error; let next=advance.value;
        let e=errorNorm(next,error,c); let ratio=e/tol;
        let valid=finite4(next.q) && finite2(next.c) && finite(e);
        if(!valid || ratio>1.0) {
            o.rejected++; h*=select(0.25,clamp(0.85*pow(max(ratio,1.0e-6),-0.2),0.15,0.8),valid); continue;
        }
        o.accepted++; o.localError=max(o.localError,e);
        o.invariant=max(o.invariant,invariant(next,c)); o.minRadius=min(o.minRadius,1.0/max(next.q.x,1.0e-9));
        o.state=next;
        if(o.invariant>maxInv || abs(next.q.z)>1.00002) { o.status=5u; break; }
        if(u.diskHeightScale>0.0) {
            if(faceMaximum(diskFaces(old,u))<=0.0) { o.state=old; o.status=5u; break; }
            let beyond=1.0/max(old.q.x,next.q.x)>sceneExtent && old.q.y*next.q.y>0.0;
            if(!beyond) {
                let hit=finiteDiskHit(old,next,c,h,u);
                if(hit.found) { o.state=hit.hit; o.status=1u; break; }
            }
        } else if(old.q.z*next.q.z<0.0) {
            let hit=crossing(old,next,c,h,2u,0.0); let r=1.0/hit.q.x;
            if(r>=u.diskInnerRadius && r<=u.diskOuterRadius) { o.state=hit; o.status=1u; break; }
        }
        if(next.q.x>=captureU) {
            // Keep the accepted state for the opaque capture record. All
            // observable diagnostic endpoints retain the original refinement.
            if(!radianceOnly) { o.state=crossing(old,next,c,h,0u,captureU); }
            o.status=2u; break;
        }
        if(next.q.x<escapeU && next.q.y<0.0) {
            o.state=next;
            if(!radianceOnly) { o.state=crossing(old,next,c,h,0u,escapeU); }
            o.status=3u; break;
        }
        if(c.xi==0.0 && old.q.w*next.q.w<0.0) {
            var axial=c.eta>=0.0;
            if(!axial) { axial=abs(crossing(old,next,c,h,3u,0.0).q.z)>0.9999; }
            if(axial) { o.state.c.x+=PI; }
        }
        h*=clamp(0.9*pow(max(ratio,1.0e-6),-0.2),0.5,2.5);
    }
    return o;
}
fn lookupDisk(count: u32,x: f32) -> vec4<f32> {
    let p=clamp(x,0.0,f32(count-1u)); let i=min(u32(p),count-2u);
    return mix(diskTable[i],diskTable[i+1u],p-f32(i));
}
fn lookupSpectrum(count: u32,x: f32) -> vec4<f32> {
    let p=clamp(x,0.0,f32(count-1u)); let i=min(u32(p),count-2u);
    return mix(spectrumTable[i],spectrumTable[i+1u],p-f32(i));
}
fn hash(initial: u32) -> u32 {
    var x=initial; x^=x>>16u; x*=0x7feb352du; x^=x>>15u; x*=0x846ca68bu; return x^(x>>16u);
}
fn random(x: u32) -> f32 { return f32(hash(x)&0x00ffffffu)/16777216.0; }
fn distantStellarField(azimuth: f32,polarCosine: f32) -> vec3<f32> {
    let wrapped=atan2(sin(azimuth),cos(azimuth));
    let coordinate=vec2<f32>((wrapped+PI)/(2.0*PI),clamp(0.5+0.5*polarCosine,0.0,1.0));
    let columns=144; let rows=72;
    let scaled=coordinate*vec2<f32>(f32(columns),f32(rows)); let base=vec2<i32>(floor(scaled));
    var result=vec3<f32>(0.0);
    for(var y=-1;y<=1;y++) { for(var x=-1;x<=1;x++) {
        var cx=(base.x+x)%columns; if(cx<0) { cx+=columns; }
        let cy=clamp(base.y+y,0,rows-1);
        let key=(u32(cx)*0x9e3779b9u)^(u32(cy)*0x85ebca6bu);
        if(random(key^0x68bc21ebu)<0.983) { continue; }
        let center=vec2<f32>(f32(base.x+x),f32(base.y+y))+vec2<f32>(random(key^0x02e5be93u),random(key^0x7f4a7c15u));
        let radius=length(scaled-center); let core=1.0-smoothstep(0.025,0.13,radius);
        let brightness=mix(0.35,1.15,random(key^0x51ed270bu)); let tint=random(key^0x1b873593u);
        result+=core*brightness*mix(vec3<f32>(0.18,0.28,0.55),vec3<f32>(1.0,0.72,0.42),tint);
    }}
    return min(result,vec3<f32>(1.2));
}
struct EmitterMotion { rho: f32, omega: f32, ut: f32, norm: f32, g: f32 }
fn emitterMotion(ray: RayResult,u: Uniforms) -> EmitterMotion {
    let r=1.0/ray.state.q.x; let mu=ray.state.q.z; let a=ray.constants.a;
    let rho=cylindricalRadius(ray.state); let sin2=max(0.0,1.0-mu*mu);
    let sigma=r*r+a*a*mu*mu;
    let gtt=-1.0+2.0*r/sigma; let gtp=-2.0*a*r*sin2/sigma;
    let gpp=(r*r+a*a+2.0*a*a*r*sin2/sigma)*sin2;
    let omega=1.0/(rho*sqrt(rho)+a);
    let velocityMetric=gtt+2.0*omega*gtp+omega*omega*gpp;
    // WGSL constant expressions cannot contain NaN. Reject non-timelike
    // emitters explicitly instead: a nonpositive g is converted to the same
    // unresolved (-5) geometry record by geometryRecord(), never to emission.
    if(!finite(velocityMetric) || !(velocityMetric<0.0)) {
        return EmitterMotion(rho,omega,0.0,0.0,-1.0);
    }
    let ut=inverseSqrt(-velocityMetric);
    return EmitterMotion(rho,omega,ut,ut*ut*velocityMetric,1.0/(ray.constants.energy*ut*(1.0-omega*ray.constants.xi)));
}
fn redshift(ray: RayResult,u: Uniforms) -> f32 {
    if(u.diskHeightScale>0.0) { return emitterMotion(ray,u).g; }
    let r=1.0/ray.state.q.x; let r32=r*sqrt(r); let orbitalSpin=ray.constants.a/r32;
    let omega=1.0/(r32+ray.constants.a); let ut=(1.0+orbitalSpin)/sqrt(1.0-3.0/r+2.0*orbitalSpin);
    return 1.0/(ray.constants.energy*ut*(1.0-omega*ray.constants.xi));
}
fn thermalSpectrum(temperature: f32,u: Uniforms) -> vec3<f32> {
    if(temperature<exp(u.temperatureLogMin)) { return vec3<f32>(0.0); }
    return max(vec3<f32>(0.0),lookupSpectrum(u.temperatureTableCount,(log(temperature)-u.temperatureLogMin)/u.temperatureLogStep).rgb);
}
fn luminance(c: vec3<f32>) -> f32 { return dot(c,vec3<f32>(0.2126729,0.7151522,0.0721750)); }
fn angleDistance(a: f32,b: f32) -> f32 { return abs(atan2(sin(a-b),cos(a-b))); }
fn prescribedEmissivityFluctuation(r: f32,coMovingPhase: f32,footprint: f32,u: Uniforms) -> f32 {
    let radial=clamp((log(r)-log(u.diskInnerRadius))/max(log(u.diskOuterRadius/u.diskInnerRadius),1.0e-6),0.0,1.0);
    let f=max(footprint,0.0); let theta=coMovingPhase;
    let warp=0.31*sin(2.0*theta-10.7*radial)+0.13*sin(5.0*theta+6.1*radial);
    let m0=sin(3.0*theta+7.3*radial+warp); let m1=sin(7.0*theta-16.9*radial+0.6*warp);
    let m2=sin(13.0*theta+29.7*radial+1.4*warp); let m3=sin(21.0*theta-43.1*radial+2.1*warp);
    return clamp(0.42*exp(-3.0*f)*m0+0.27*exp(-7.0*f)*m1+0.19*exp(-13.0*f)*m2+0.12*exp(-21.0*f)*m3,-1.0,1.0);
}
fn materialNoise(p: vec2<f32>,period: i32) -> f32 {
    let cell=vec2<i32>(floor(p)); var q=fract(p); q=q*q*(3.0-2.0*q);
    let x0=((cell.x%period)+period)%period; let x1=(x0+1)%period;
    // Integer bitcasts preserve the native unsigned wrapping of negative rows.
    let row0=bitcast<u32>(cell.y)*0x9e3779b9u; let row1=bitcast<u32>(cell.y+1)*0x9e3779b9u;
    let a=random((u32(x0)*0x85ebca6bu)^row0); let b=random((u32(x1)*0x85ebca6bu)^row0);
    let c=random((u32(x0)*0x85ebca6bu)^row1); let d=random((u32(x1)*0x85ebca6bu)^row1);
    return mix(mix(a,b,q.x),mix(c,d,q.x),q.y);
}
struct MaterialCoordinates {
    logRadius: f32, footprint: f32, dye: f32, shearRate: f32, outerTaper: f32, strength: f32,
}
fn materialCoordinates(logRadius: f32,r32: f32,omega: f32,dye: f32,footprint: f32,u: Uniforms) -> MaterialCoordinates {
    // Invariant throughout the material shutter. Keep the original expression
    // order, including its logarithms of the represented uniform values.
    let radialFraction=(logRadius-log(u.diskInnerRadius))/max(log(u.diskOuterRadius/u.diskInnerRadius),1.0e-6);
    let outerTaper=1.0-smoothstep(0.87,1.0,radialFraction);
    return MaterialCoordinates(logRadius,max(footprint,0.0),clamp(dye,0.0,1.0),
                               1.5*r32*omega*omega,outerTaper,clamp(u.materialStrength,0.0,1.0));
}
fn materialTransmission(coordinates: MaterialCoordinates,phase: f32,emittedTime: f32) -> f32 {
    let lr=coordinates.logRadius; let turns=phase/(2.0*PI);
    let f=coordinates.footprint; let dyeValue=coordinates.dye;
    let warp=materialNoise(vec2<f32>(turns*4.0,lr*5.0),4);
    let n0=materialNoise(vec2<f32>(turns*12.0+3.0*warp,lr*48.0+4.0*dyeValue),12);
    let n1=materialNoise(vec2<f32>(turns*24.0+5.0*warp,lr*103.0+7.0*dyeValue),24);
    let n2=materialNoise(vec2<f32>(turns*48.0+7.0*warp,lr*221.0+11.0*dyeValue),48);
    let winding=max(0.0,abs(coordinates.shearRate*emittedTime)/(2.0*PI)-8.0);
    let ribbons=0.5+0.56*exp(-(48.0+12.0*winding)*f)*(n0-0.5)+0.30*exp(-(103.0+24.0*winding)*f)*(n1-0.5)+0.14*exp(-(221.0+48.0*winding)*f)*(n2-0.5);
    let eddies=materialNoise(vec2<f32>(turns*7.0,lr*12.0),7)-0.5;
    let broad=0.12*exp(-(8.0+4.0*winding)*f)*(warp-0.5);
    let structure=smoothstep(0.27,0.76,ribbons+0.16*exp(-(18.0+7.0*winding)*f)*eddies+broad+0.24*(dyeValue-0.5));
    let material=0.06+0.94*pow(structure,1.4);
    return mix(1.0,material*coordinates.outerTaper,coordinates.strength);
}
fn materialShutterSinc(x: f32) -> f32 {
    // The Taylor branch avoids 0/0 and the sine call for short exposures.
    // Its omitted x^6/5040 term is below 2e-16 at this branch boundary.
    let x2=x*x;
    if(abs(x)<0.01) { return 1.0-x2/6.0+x2*x2/120.0; }
    return clamp(sin(x)/x,-1.0,1.0);
}
fn materialCohortLite(lr: f32,shearRate: f32,phi: f32,omega: f32,age: f32,cohort: i32,
                     f: f32,exposure0: f32,exposure1: f32) -> f32 {
    let seed=2.0*PI*random(bitcast<u32>(cohort)^0x9e3779b9u);
    let phase=phi-omega*age+seed;
    let shear=abs(shearRate*age);
    // Include phase winding in a conservative source-footprint estimate. This
    // low-detail path omits the full path's neighboring ray-map derivatives.
    let width0=(8.0+2.0*shear)*f;
    let width1=(19.0+5.0*shear)*f;
    let filter0=1.0/(1.0+width0*width0);
    let filter1=1.0/(1.0+width1*width1);
    let first=cos(2.0*phase+6.0*lr);
    let second=cos(5.0*phase-14.0*lr+0.7);
    // Coefficients give a [0.08,1] bound before the same outer taper used by
    // the full source. Spatial and shutter filters cannot increase that bound.
    return 0.54+0.30*filter0*exposure0*first+0.16*filter1*exposure1*second;
}
fn materialTransmissionLite(logRadius: f32,r32: f32,phi: f32,emittedTime: f32,
                            omega: f32,shutter: f32,footprint: f32,u: Uniforms) -> f32 {
    // Two broad, periodic modes retain visible rotation at low resolutions.
    // Renew prescribed material with a smooth crossfade between two cohorts;
    // each uses phi-Omega*(retardedTime-birthTime), with the native Kerr Omega.
    // A global source-coordinate lifetime (64 M), independent of radius, keeps
    // differential winding bounded by cohort age instead of application uptime.
    // This artistic renewal is not a solved fluid or thermal evolution model.
    let lifetime=64.0;
    let generation=floor(emittedTime/lifetime);
    let age=emittedTime-generation*lifetime;
    let blend=smoothstep(0.0,1.0,age/lifetime);
    let lr=logRadius-u.diskLogRadiusMin;
    let f=max(footprint,0.0);
    let shearRate=1.5*r32*omega*omega;
    // Analytic rectangular shutter for each cosine. Cohort weights and spatial
    // filters are held at exposure center, avoiding a per-shutter material loop.
    let exposure0=materialShutterSinc(omega*shutter);
    let exposure1=materialShutterSinc(2.5*omega*shutter);
    let previous=materialCohortLite(lr,shearRate,phi,omega,age+lifetime,i32(generation)-1,f,exposure0,exposure1);
    let current=materialCohortLite(lr,shearRate,phi,omega,age,i32(generation),f,exposure0,exposure1);
    let material=mix(previous,current,blend);
    let radialFraction=lr/max(u.flowLogRadiusSpan,1.0e-6);
    let outerTaper=1.0-smoothstep(0.87,1.0,radialFraction);
    return mix(1.0,material*outerTaper,clamp(u.materialStrength,0.0,1.0));
}
fn shadeHit(hit: vec4<f32>,dye: f32,footprint: f32,u: Uniforms) -> vec3<f32> {
    let r=hit.x; let phi=hit.y; let delay=hit.z; let g=hit.w;
    let logRadius=log(r);
    let model=lookupDisk(u.diskTableCount,(logRadius-u.diskLogRadiusMin)/u.diskLogRadiusStep);
    // The steady scientific source has no material phase or shutter dependence.
    if(u.appearanceMode==0u && u.perturbationAmplitude<=0.0) { return thermalSpectrum(g*model.x,u); }
    let r32=r*sqrt(r); let omega=1.0/(r32+clamp(u.spin,0.0,0.998));
    let emittedTime=u.time/max(u.massTimeSeconds,1.0e-6)-delay; let phase=phi-omega*emittedTime;
    var temperature=model.x;
    if(u.perturbationAmplitude>0.0) {
        let amplitude=clamp(u.perturbationAmplitude,0.0,0.2);
        let fluxFactor=1.0+amplitude*prescribedEmissivityFluctuation(r,phase,footprint,u);
        temperature*=pow(max(0.8,fluxFactor),0.25);
    }
    let physical=thermalSpectrum(g*temperature,u);
    if(u.appearanceMode==0u) { return physical; }
    let paletteT=clamp(max(u.paletteTemperature,1000.0)*pow(max(temperature,1.0)/90000.0,1.1),2200.0,18000.0);
    let palette=thermalSpectrum(max(1000.0,g*paletteT),u);
    let color=palette*(luminance(physical)/max(luminance(palette),1.0e-30));
    if(u.materialStrength<=0.0) { return color; }
    let shutter=max(u.materialShutterSeconds,0.0)/max(u.massTimeSeconds,1.0e-6);
    if(u.flowEnabled==0u) {
        return color*materialTransmissionLite(logRadius,r32,phi,emittedTime,omega,shutter,footprint,u);
    }
    var timeSamples=1u;
    if(u.materialShutterSeconds>0.0) { if(u.materialTimeSamples>=4u) { timeSamples=4u; } else if(u.materialTimeSamples>=2u) { timeSamples=2u; } }
    let coordinates=materialCoordinates(logRadius,r32,omega,dye,footprint,u);
    var transmission=0.0;
    for(var sample=0u;sample<timeSamples;sample++) {
        let offset=((f32(sample)+0.5)/f32(timeSamples)-0.5)*shutter; let sourceTime=emittedTime+offset;
        transmission+=materialTransmission(coordinates,phi-omega*sourceTime,sourceTime);
    }
    return color*(transmission/f32(timeSamples));
}
fn geometryRecord(ray: RayResult,u: Uniforms) -> vec4<f32> {
    var value=vec4<f32>(-f32(ray.status),0.0,0.0,0.0);
    if(ray.status==1u) {
        let rho=select(1.0/ray.state.q.x,cylindricalRadius(ray.state),u.diskHeightScale>0.0);
        value=vec4<f32>(rho,ray.state.c,redshift(ray,u));
        if(!finite4(value) || value.w<=0.0) { value=vec4<f32>(-5.0,0.0,0.0,0.0); }
    } else if(ray.status==3u) {
        value=vec4<f32>(-3.0,ray.state.c.x,clamp(ray.state.q.z,-1.0,1.0),0.0);
    }
    return value;
}
// Cached rays use interleaved samples: ((y*width+x)*samples+sample).
@compute @workgroup_size(8,8,1)
fn traceGeometry(@builtin(global_invocation_id) tid: vec3<u32>) {
    let u=params; let gid=vec2<u32>(tid.x,tid.y+u32(max(u.padding,0.0))); let sample=tid.z;
    let samples=max(1u,u.samples);
    if(any(gid>=u.resolution) || sample>=samples) { return; }
    let seed=hash(gid.x+gid.y*u.resolution.x)^hash(u.frame*73u+sample*997u);
    let jitter=vec2<f32>(random(seed),random(seed^0x9e3779b9u));
    let ray=followRay(vec2<f32>(gid)+jitter,u,true);
    geometry[(gid.y*u.resolution.x+gid.x)*samples+sample]=geometryRecord(ray,u);
}
@compute @workgroup_size(8,8,1)
fn shadeGeometry(@builtin(global_invocation_id) tid: vec3<u32>) {
    let u=params; let gid=tid.xy;
    if(any(gid>=u.resolution)) { return; }
    let count=max(1u,u.samples); var color=vec3<f32>(0.0); var unresolved=false;
    // Uniform across this dispatch; steady spectra and a structure-free palette
    // do not consume a material footprint or neighboring geometry records.
    let needsFootprint=u.perturbationAmplitude>0.0 || (u.appearanceMode!=0u && u.materialStrength>0.0);
    for(var sample=0u;sample<count;sample++) {
        let hit=geometry[(gid.y*u.resolution.x+gid.x)*count+sample];
        if(hit.x>0.0) {
            // Browser source detail selects lightweight renewing patterns or
            // the native full analytic material. Both use neutral fluid dye.
            let dye=0.5;
            var footprint=0.0;
            if(needsFootprint) {
                footprint=u.verticalFOV/f32(u.resolution.y)*u.observerRadius/max(hit.x,1.0);
                if(u.flowEnabled!=0u) {
                    for(var axis=0u;axis<2u;axis++) {
                        var neighbor=gid; neighbor[axis]=min(gid[axis]+1u,u.resolution[axis]-1u);
                        let other=geometry[(neighbor.y*u.resolution.x+neighbor.x)*count+sample];
                        if(other.x>0.0) { footprint=max(footprint,max(abs(log(other.x/hit.x)),0.15*angleDistance(other.y,hit.y))); }
                    }
                }
            }
            let sampleColor=shadeHit(hit,dye,footprint,u);
            if(all(abs(sampleColor)<=vec3<f32>(FMAX))) { color+=sampleColor; }
            else { unresolved=true; if(u.diagnosticMode!=0u) { color+=vec3<f32>(2.0,0.0,2.0); } }
        } else if(hit.x==-3.0 && u.appearanceMode!=0u && u.materialStrength>0.0) {
            color+=distantStellarField(hit.y,hit.z);
        } else if(hit.x<=-4.0) {
            unresolved=true; if(u.diagnosticMode!=0u) { color+=vec3<f32>(2.0,0.0,2.0); }
        }
    }
    textureStore(radiance,gid,vec4<f32>(color/f32(count),select(1.0,-1.0,unresolved)));
}
// Native four-record diagnostic ABI, without the radiance-only escape cutoff.
@compute @workgroup_size(64,1,1)
fn validateKerr(@builtin(global_invocation_id) tid: vec3<u32>) {
    let i=tid.x;
    if(i>=arrayLength(&validationPixels)) { return; }
    let r=followRay(validationPixels[i].xy,params,false);
    validationOutput[4u*i]=vec4<f32>(r.constants.xi,r.constants.eta,r.constants.energy,r.initialInvariant);
    validationOutput[4u*i+1u]=vec4<f32>(f32(r.status),1.0/r.state.q.x,r.state.c.x,r.state.c.y);
    validationOutput[4u*i+2u]=vec4<f32>(r.state.q.y,r.state.q.z,r.state.q.w,r.invariant);
    validationOutput[4u*i+3u]=vec4<f32>(f32(r.accepted),f32(r.rejected),r.localError,r.minRadius);
}
// Optional native six-record photosphere diagnostic ABI uses the same bindings.
@compute @workgroup_size(64,1,1)
fn validateSurface(@builtin(global_invocation_id) tid: vec3<u32>) {
    let i=tid.x;
    if(i>=arrayLength(&validationPixels)) { return; }
    let r=followRay(validationPixels[i].xy,params,false);
    validationOutput[6u*i]=vec4<f32>(r.constants.xi,r.constants.eta,r.constants.energy,r.initialInvariant);
    validationOutput[6u*i+1u]=vec4<f32>(f32(r.status),1.0/r.state.q.x,r.state.c.x,r.state.c.y);
    validationOutput[6u*i+2u]=vec4<f32>(r.state.q.y,r.state.q.z,r.state.q.w,r.invariant);
    validationOutput[6u*i+3u]=vec4<f32>(f32(r.accepted),f32(r.rejected),r.localError,r.minRadius);
    let rho=cylindricalRadius(r.state); let z=r.state.q.z/r.state.q.x;
    var emitter=EmitterMotion(rho,0.0,0.0,0.0,0.0); var g=0.0;
    if(r.status==1u) { emitter=emitterMotion(r,params); g=redshift(r,params); }
    validationOutput[6u*i+4u]=vec4<f32>(rho,z,diskHeight(rho,r.state.c.x,params),g);
    validationOutput[6u*i+5u]=vec4<f32>(faceMaximum(diskFaces(r.state,params)),-emitter.norm,emitter.ut,emitter.omega);
}
