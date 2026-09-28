import Foundation

enum ShaderSource {
    static let code = #"""
    #include <metal_stdlib>
    using namespace metal;

    // G=c=M=1. Scalar fields deliberately match the Swift host ABI.
    struct Uniforms {
        uint2 resolution; float time, spin, diskTilt, cameraYaw, cameraPitch, cameraDistance;
        uint steps, samples, frame;
        float observerRadius, verticalFOV, integrationTolerance, maxStep;
        float diskInnerRadius, diskOuterRadius, exposure;
        uint diskTableCount;
        float diskLogRadiusMin, diskLogRadiusStep, massTimeSeconds, perturbationAmplitude;
        uint temperatureTableCount;
        float temperatureLogMin, temperatureLogStep;
        uint diagnosticMode; float padding, lookYaw, lookPitch;
        uint appearanceMode;
        float materialStrength, paletteTemperature, flowTime;
        float flowLogRadiusMin, flowLogRadiusSpan, flowTimeScale;
        uint flowEnabled;
        float diskHeightScale, diskCorrugation;
        uint edgeSamples, edgeCapacity;
        float materialShutterSeconds;
        uint materialTimeSamples;
    };
    struct State { float4 q; float2 c; }; // (1/r, d(1/r)/dλ, cosθ, d(cosθ)/dλ); (φ, lookback t)
    struct Constants { float a, xi, eta, energy, b, k; };
    struct RayResult {
        State state; Constants constants;
        float initialInvariant, invariant, localError, minRadius;
        uint status, accepted, rejected;
    };
    // Status: 1 opaque disk; 2 horizon; 3 escaped; 4 exhausted budget; 5 numerical failure.
    State add(State a, State b, float h) { return {a.q+h*b.q, a.c+h*b.c}; }
    State combine(State a, State b, float ca, float cb) { return {ca*a.q+cb*b.q,ca*a.c+cb*b.c}; }

    // Carter-separated null equations, differentiated once to pass both radial
    // and polar turning points without sign switches. λ increases into the past.
    // James et al., CQG 32 (2015) 065001, App. A; Gralla & Lupsasca,
    // PRD 101 (2020) 044032. Reversing affine direction reverses t,φ, not E,L,Q.
    State derivative(State s, Constants k) {
        float u=s.q.x, mu=s.q.z, a=k.a, aa=a*a;
        float d=1.-2.*u+aa*u*u;
        float sin2=max(1.e-12,1.-mu*mu);
        // Near the axis, 1−μ² loses most float mantissa bits. The polar first
        // integral also gives w²+ξ²=(η+ξ²+a²)sin²θ−a²sin⁴θ. Its stable smaller
        // quadratic root recovers sin²θ from the well-conditioned momentum w.
        // This regularizes the narrow azimuth peak without projecting the ODE
        // state; invariant drift is still measured and checked independently.
        float polarA=k.eta+k.xi*k.xi+aa;
        if(abs(mu)>.9 && polarA>aa) {
            float polarB=s.q.w*s.q.w+k.xi*k.xi;
            sin2=max(1.e-15,2.*polarB/(polarA+sqrt(max(0.,polarA*polarA-4.*aa*polarB))));
        }
        float p=1.+(aa-a*k.xi)*u*u;
        float phi=-(k.xi/sin2+a*(2.*u-a*k.xi*u*u)/d);
        float delay=(1.+aa*u*u)*p/(u*u*d)+a*k.xi-aa*sin2;
        return {float4(s.q.y,k.b*u+3.*k.k*u*u-2.*aa*k.eta*u*u*u,
                       s.q.w,k.b*mu-2.*aa*mu*mu*mu),float2(phi,delay)};
    }

    // Dormand–Prince 5(4): accept/reject uses an embedded local-error estimate.
    // No invariant projection: residuals remain independent diagnostics.
    State rk45(State y, Constants c, float h, thread State& err) {
        State k1=derivative(y,c);
        State k2=derivative(add(y,k1,h*(1./5.)),c);
        State k3=derivative(add(add(y,k1,h*(3./40.)),k2,h*(9./40.)),c);
        State k4=derivative(add(add(add(y,k1,h*(44./45.)),k2,h*(-56./15.)),k3,h*(32./9.)),c);
        State k5=derivative(add(add(add(add(y,k1,h*(19372./6561.)),k2,h*(-25360./2187.)),k3,h*(64448./6561.)),k4,h*(-212./729.)),c);
        State k6=derivative(add(add(add(add(add(y,k1,h*(9017./3168.)),k2,h*(-355./33.)),k3,h*(46732./5247.)),k4,h*(49./176.)),k5,h*(-5103./18656.)),c);
        State result=add(add(add(add(add(y,k1,h*(35./384.)),k3,h*(500./1113.)),k4,h*(125./192.)),k5,h*(-2187./6784.)),k6,h*(11./84.));
        State k7=derivative(result,c);
        // Sum error coefficients directly: subtracting full states loses precision.
        err=combine(k1,k3,35./384.-5179./57600.,500./1113.-7571./16695.);
        err=add(err,k4,125./192.-393./640.);
        err=add(err,k5,-2187./6784.+92097./339200.);
        err=add(err,k6,11./84.-187./2100.);
        err=add(err,k7,-1./40.);
        err.q*=h; err.c*=h;
        return result;
    }
    float invariant(State s, Constants c) {
        float u=s.q.x, mu=s.q.z, aa=c.a*c.a;
        float radial=1.+c.b*u*u+2.*c.k*u*u*u-aa*c.eta*u*u*u*u;
        float polar=c.eta+c.b*mu*mu-aa*mu*mu*mu*mu;
        float scaleR=1.+abs(c.b*u*u)+abs(2.*c.k*u*u*u)+abs(aa*c.eta*u*u*u*u);
        float scaleP=1.+abs(c.eta)+abs(c.b*mu*mu)+abs(aa*mu*mu*mu*mu);
        return max(abs(s.q.y*s.q.y-radial)/scaleR,abs(s.q.w*s.q.w-polar)/scaleP);
    }
    RayResult initializeRay(float2 pixel, constant Uniforms& u) {
        RayResult o;
        float a=clamp(u.spin,0.,.998), r=u.observerRadius;
        float theta=clamp(M_PI_F*.5-u.cameraPitch,.1,M_PI_F-.1);
        float mu=cos(theta), st=sin(theta), sigma=r*r+a*a*mu*mu;
        float delta=r*r-2.*r+a*a, A=(r*r+a*a)*(r*r+a*a)-a*a*delta*st*st;
        float lapse=sqrt(sigma*delta/A), omega=2.*a*r/A;
        float2 screen=(pixel-.5*float2(u.resolution))*(2.*tan(.5*u.verticalFOV)/float(u.resolution.y));
        // Past-directed spatial direction in the orthonormal ZAMO triad.
        // Screen x points along +eφ, screen y downward along +eθ.
        float3 n=normalize(float3(-1.,screen.y,screen.x));
        float cy=cos(u.lookYaw),sy=sin(u.lookYaw), cp=cos(u.lookPitch),sp=sin(u.lookPitch);
        n=float3(cp*n.x-sp*n.y,sp*n.x+cp*n.y,n.z);
        n=float3(cy*n.x+sy*n.z,n.y,-sy*n.x+cy*n.z);
        // Future photon momentum is -n; its locally measured energy is exactly 1.
        // E=-p_t=α+ω L; L=p_φ; Q=p_θ²+cos²θ(L²/sin²θ-a²E²).
        float L=-sqrt(A/sigma)*st*n.z, E=lapse+omega*L;
        float xi=L/E, ptheta=-sqrt(sigma)*n.y/E;
        float eta=ptheta*ptheta+mu*mu*(xi*xi/(st*st)-a*a);
        o.constants={a,xi,eta,E,a*a-eta-xi*xi,eta+(xi-a)*(xi-a)};
        o.state={float4(1./r,-n.x*sqrt(sigma*delta)/(E*r*r),mu,-st*n.y*sqrt(sigma)/E),float2(u.cameraYaw,0.)};
        o.initialInvariant=invariant(o.state,o.constants);
        o.invariant=o.initialInvariant; o.localError=0.; o.minRadius=r;
        o.status=4; o.accepted=0; o.rejected=0;
        return o;
    }
    float errorNorm(State y, State err, Constants c) {
        float angular=max(1.,sqrt(abs(c.eta)+c.xi*c.xi+c.a*c.a));
        float4 scale=float4(max(.02,abs(y.q.x)),max(1.,abs(y.q.y)),1.,angular);
        float4 e=abs(err.q)/scale;
        float2 ec=abs(err.c)/float2(max(1.,abs(y.c.x)),max(1.,abs(y.c.y)));
        return max(max(max(e.x,e.y),max(e.z,e.w)),max(ec.x,ec.y));
    }

    // Hermite root localization, followed by a fifth-order partial step and
    // Newton correction, avoids linearly interpolating the curved trajectory.
    State crossing(State old, State next, Constants c, float h, uint component, float target) {
        State f0=derivative(old,c), f1=derivative(next,c);
        float lo=0.,hi=1.;
        for(uint j=0;j<14;j++) {
            float x=.5*(lo+hi),x2=x*x,x3=x2*x;
            float m=(2.*x3-3.*x2+1.)*old.q[component]+(x3-2.*x2+x)*h*f0.q[component]+
                    (-2.*x3+3.*x2)*next.q[component]+(x3-x2)*h*f1.q[component]-target;
            if(m*(old.q[component]-target)>0.) lo=x; else hi=x;
        }
        float x=.5*(lo+hi); State error;
        State hit=rk45(old,c,h*x,error);
        float slope=derivative(hit,c).q[component];
        x=clamp(x-(hit.q[component]-target)/(h*slope),0.,1.);
        return rk45(old,c,h*x,error);
    }
    // Two-float compensated arithmetic for ill-conditioned photon whirls.
    // Error-free transforms require fastMathEnabled=false on the host.
    float2 ds(float x) { return float2(x,0.); }
    float2 dn(float h,float l) { float s=h+l; return float2(s,l-(s-h)); }
    float2 da(float2 a,float2 b) {
        float s=a.x+b.x, v=s-a.x;
        return dn(s,(a.x-(s-v))+(b.x-v)+a.y+b.y);
    }
    float2 dm(float2 a,float2 b) {
        float p=a.x*b.x;
        return dn(p,fma(a.x,b.x,-p)+a.x*b.y+a.y*b.x+a.y*b.y);
    }
    float2 dd(float2 a,float2 b) {
        float q=a.x/b.x; float2 r=da(a,-dm(b,ds(q)));
        return dn(q,(r.x+r.y)/b.x);
    }
    float2 dq(float2 a) {
        float q=sqrt(max(a.x,0.));
        return q>0. ? da(ds(q),dd(da(a,-dm(ds(q),ds(q))),ds(2.*q))) : ds(0.);
    }
    float df(float2 a) { return a.x+a.y; }
    struct WideConstants { Constants c; float2 aa,b,k,pcoef,ax; };
    struct WideState { float2 u,v,phi,delay,polar; };
    WideConstants widen(Constants c) {
        WideConstants w; w.c=c;
        w.aa=dm(ds(c.a),ds(c.a)); w.ax=dm(ds(c.a),ds(c.xi));
        w.b=da(da(w.aa,-ds(c.eta)),-dm(ds(c.xi),ds(c.xi)));
        float2 d=da(ds(c.xi),-ds(c.a));
        w.k=da(ds(c.eta),dm(d,d)); w.pcoef=da(w.aa,-w.ax);
        return w;
    }
    float2 widePotential(float2 q,WideConstants k) {
        float2 q2=dm(q,q), p=da(ds(1.),dm(k.pcoef,q2));
        float2 d=da(da(ds(1.),-dm(ds(2.),q)),dm(k.aa,q2));
        return da(dm(p,p),-dm(dm(d,q2),k.k));
    }
    bool needsWide(Constants c) {
        // P(u)=(du/dλ)². A nearly zero exterior minimum causes a long, unstable
        // photon whirl, where a small absolute invariant error amplifies greatly.
        if(c.b>=0. || c.eta<0.) return false;
        float disc=9.*c.k*c.k+8.*c.a*c.a*c.eta*c.b;
        if(disc<0.) return false;
        float criticalU=-2.*c.b/(3.*c.k+sqrt(disc));
        float horizon=1.+sqrt(1.-c.a*c.a);
        if(criticalU<=0. || criticalU>=1./horizon) return false;
        return abs(df(widePotential(ds(criticalU),widen(c))))<.001;
    }
    WideState wa(WideState a,WideState b,float2 h) {
        return {da(a.u,dm(b.u,h)),da(a.v,dm(b.v,h)),
                da(a.phi,dm(b.phi,h)),da(a.delay,dm(b.delay,h)),a.polar+df(h)*b.polar};
    }
    WideState wd(WideState s,WideConstants k) {
        float2 q2=dm(s.u,s.u), q3=dm(q2,s.u);
        float2 acceleration=da(da(dm(k.b,s.u),dm(dm(ds(3.),k.k),q2)),
                               -dm(dm(dm(ds(2.),k.aa),ds(k.c.eta)),q3));
        float mu=s.polar.x, w=s.polar.y, a=k.c.a;
        float sin2=max(1.e-12,1.-mu*mu), polarA=k.c.eta+k.c.xi*k.c.xi+a*a;
        if(abs(mu)>.9 && polarA>a*a) {
            float pb=w*w+k.c.xi*k.c.xi;
            sin2=max(1.e-15,2.*pb/(polarA+sqrt(max(0.,polarA*polarA-4.*a*a*pb))));
        }
        float2 d=da(da(ds(1.),-dm(ds(2.),s.u)),dm(k.aa,q2));
        float2 p=da(ds(1.),dm(k.pcoef,q2));
        float2 phi=-da(dd(dm(ds(a),da(dm(ds(2.),s.u),-dm(k.ax,q2))),d),dd(ds(k.c.xi),ds(sin2)));
        float2 delay=da(dd(dm(da(ds(1.),dm(k.aa,q2)),p),dm(q2,d)),da(k.ax,-dm(k.aa,ds(sin2))));
        return {s.v,acceleration,phi,delay,float2(w,df(k.b)*mu-2.*a*a*mu*mu*mu)};
    }
    WideState wrk4(WideState y,WideConstants c,float h) {
        WideState k1=wd(y,c), k2=wd(wa(y,k1,ds(h*.5)),c);
        WideState k3=wd(wa(y,k2,ds(h*.5)),c), k4=wd(wa(y,k3,ds(h)),c);
        WideState sum=wa(wa(wa(k1,k2,ds(2.)),k3,ds(2.)),k4,ds(1.));
        // Divide in compensated arithmetic: Float(1/6) would reintroduce an
        // O(machine epsilon) secular energy error at every integration step.
        return wa(y,sum,dd(ds(h),ds(6.)));
    }
    WideState wstep(WideState y,WideConstants c,float h,thread WideState& error) {
        WideState full=wrk4(y,c,h);
        WideState fine=wrk4(wrk4(y,c,h*.5),c,h*.5);
        WideState delta=wa(fine,full,ds(-1.));
        error={dd(delta.u,ds(15.)),dd(delta.v,ds(15.)),dd(delta.phi,ds(15.)),dd(delta.delay,ds(15.)),delta.polar/15.};
        return wa(fine,error,ds(1.)); // fifth-order Richardson estimate
    }
    State narrow(WideState w) { return {float4(df(w.u),df(w.v),w.polar.x,w.polar.y),float2(df(w.phi),df(w.delay))}; }
    float wcomponent(WideState w,uint component) {
        if(component==0) return df(w.u);
        return component==2 ? w.polar.x : w.polar.y;
    }
    WideState wcross(WideState old,WideState next,WideConstants c,float h,uint component,float target) {
        State a=narrow(old),b=narrow(next),f0=narrow(wd(old,c)),f1=narrow(wd(next,c));
        float lo=0.,hi=1.;
        for(uint i=0;i<14;i++) {
            float x=.5*(lo+hi),x2=x*x,x3=x2*x;
            float value=(2.*x3-3.*x2+1.)*a.q[component]+(x3-2.*x2+x)*h*f0.q[component]+
                        (-2.*x3+3.*x2)*b.q[component]+(x3-x2)*h*f1.q[component]-target;
            if(value*(a.q[component]-target)>0.) lo=x; else hi=x;
        }
        float x=.5*(lo+hi); WideState error,hit=wstep(old,c,h*x,error);
        float slope=wcomponent(wd(hit,c),component);
        x=clamp(x-(wcomponent(hit,component)-target)/(h*slope),0.,1.);
        return wstep(old,c,h*x,error);
    }
    // Taylor & Reynolds (2018), eq.4 with photosphere z=2H. These are
    // pseudo-cylindrical BL coordinates, not Cartesian proper distances.
    float cylindricalRadius(State s) {
        return sqrt(max(0.,1.-s.q.z*s.q.z))/s.q.x;
    }
    float diskHeight(float rho,float phi,constant Uniforms& u) {
        float radial=max(0.,1.-sqrt(u.diskInnerRadius/max(rho,u.diskInnerRadius)));
        // A finite source cutoff is not a hot vertical cylinder. Close this
        // prescribed annulus smoothly over its outermost 20% in radius. The
        // quintic joins have zero first/second derivatives; the inner pressure
        // profile is untouched. This boundary choice is not solved atmosphere.
        float t=clamp((u.diskOuterRadius-rho)/(.2*u.diskOuterRadius),0.,1.);
        float closure=t*t*t*(10.-15.*t+6.*t*t);
        if(u.diskCorrugation<=0.) return max(u.diskHeightScale,0.)*radial*closure;
        float lr=log(max(rho/u.diskInnerRadius,1.e-10));
        float corrugation=.65*cos(3.*phi+2.*lr)+.35*cos(7.*phi-3.*lr);
        return max(u.diskHeightScale,0.)*radial*closure*(1.+clamp(u.diskCorrugation,0.,.08)*corrugation);
    }
    // An opaque volume is the intersection of four half-spaces. Testing the
    // individual faces catches a complete top-to-bottom transit within one
    // integration step, even if both step endpoints are outside the volume.
    float4 diskFaces(State s,constant Uniforms& u) {
        float rho=cylindricalRadius(s),z=s.q.z/s.q.x,height=diskHeight(rho,s.c.x,u);
        return float4(z-height,-z-height,u.diskInnerRadius-rho,rho-u.diskOuterRadius);
    }
    float faceMaximum(float4 f) { return max(max(f.x,f.y),max(f.z,f.w)); }
    State denseState(State a,State b,State fa,State fb,float h,float x) {
        float x2=x*x,x3=x2*x;
        return { (2.*x3-3.*x2+1.)*a.q+(x3-2.*x2+x)*h*fa.q+
                 (-2.*x3+3.*x2)*b.q+(x3-x2)*h*fb.q,
                 (2.*x3-3.*x2+1.)*a.c+(x3-2.*x2+x)*h*fa.c+
                 (-2.*x3+3.*x2)*b.c+(x3-x2)*h*fb.c };
    }
    bool finiteDiskHit(State old,State next,Constants c,float h,constant Uniforms& u,thread State& hit) {
        State fa=derivative(old,c),fb=derivative(next,c);
        float4 previous=diskFaces(old,u);
        if(faceMaximum(previous)<=0.) return false;
        // Dense subdivisions locate candidate brackets only; every accepted
        // surface root is recomputed on the fifth-order trajectory, not on a
        // straight segment or the cubic interpolation used for the search.
        float earliest=2.; State first=next;
        for(uint segment=1;segment<=8;segment++) {
            float left=float(segment-1)/8.,right=float(segment)/8.;
            // Recovery may expand a bracket beyond this bin. Keep searching
            // all bins that can contain an earlier verified face intersection.
            if(left>=earliest) break;
            State point=segment==8 ? next : denseState(old,next,fa,fb,h,right);
            float4 current=diskFaces(point,u);
            for(uint face=0;face<4;face++) {
                if(previous[face]>0. && current[face]<=0.) {
                    State error;
                    float lo=left,hi=right;
                    State lower=rk45(old,c,h*lo,error),upper=rk45(old,c,h*hi,error);
                    // Cubic dense output only proposes a bracket. Its root
                    // can lie across a subdivision boundary from the actual
                    // high-order trajectory. Recover a real sign bracket by
                    // expanding in adjacent bins instead of discarding entry.
                    for(uint recovery=0;recovery<8 && diskFaces(lower,u)[face]<=0. && lo>0.;recovery++) {
                        lo=max(0.,lo-.125); lower=rk45(old,c,h*lo,error);
                    }
                    for(uint recovery=0;recovery<8 && diskFaces(upper,u)[face]>0. && hi<1.;recovery++) {
                        hi=min(1.,hi+.125); upper=rk45(old,c,h*hi,error);
                    }
                    if(diskFaces(lower,u)[face]<=0. || diskFaces(upper,u)[face]>0.) continue;
                    for(uint j=0;j<20;j++) {
                        float mid=.5*(lo+hi);
                        State candidate=rk45(old,c,h*mid,error);
                        if(diskFaces(candidate,u)[face]>0.) lo=mid; else hi=mid;
                    }
                    State candidate=rk45(old,c,h*hi,error);
                    // Radius-scaled float tolerance accommodates the other
                    // face at a corner without treating visible gaps as solid.
                    if(faceMaximum(diskFaces(candidate,u))<=2.e-6*max(1.,cylindricalRadius(candidate)) && hi<earliest) {
                        earliest=hi; first=candidate;
                    }
                }
            }
            previous=current;
        }
        if(earliest<=1.) { hit=first; return true; }
        return false;
    }
    bool wideFiniteDiskHit(WideState old,WideState next,WideConstants c,float h,constant Uniforms& u,thread WideState& hit) {
        State a=narrow(old),b=narrow(next),fa=narrow(wd(old,c)),fb=narrow(wd(next,c));
        float4 previous=diskFaces(a,u);
        if(faceMaximum(previous)<=0.) return false;
        float earliest=2.; WideState first=next;
        for(uint segment=1;segment<=8;segment++) {
            float left=float(segment-1)/8.,right=float(segment)/8.;
            if(left>=earliest) break;
            float4 current=diskFaces(segment==8 ? b : denseState(a,b,fa,fb,h,right),u);
            for(uint face=0;face<4;face++) {
                if(previous[face]>0. && current[face]<=0.) {
                    WideState error;
                    float lo=left,hi=right;
                    WideState lower=wstep(old,c,h*lo,error),upper=wstep(old,c,h*hi,error);
                    for(uint recovery=0;recovery<8 && diskFaces(narrow(lower),u)[face]<=0. && lo>0.;recovery++) {
                        lo=max(0.,lo-.125); lower=wstep(old,c,h*lo,error);
                    }
                    for(uint recovery=0;recovery<8 && diskFaces(narrow(upper),u)[face]>0. && hi<1.;recovery++) {
                        hi=min(1.,hi+.125); upper=wstep(old,c,h*hi,error);
                    }
                    if(diskFaces(narrow(lower),u)[face]<=0. || diskFaces(narrow(upper),u)[face]>0.) continue;
                    for(uint j=0;j<20;j++) {
                        float mid=.5*(lo+hi);
                        WideState candidate=wstep(old,c,h*mid,error);
                        if(diskFaces(narrow(candidate),u)[face]>0.) lo=mid; else hi=mid;
                    }
                    WideState candidate=wstep(old,c,h*hi,error);
                    State s=narrow(candidate);
                    if(faceMaximum(diskFaces(s,u))<=2.e-6*max(1.,cylindricalRadius(s)) && hi<earliest) {
                        earliest=hi; first=candidate;
                    }
                }
            }
            previous=current;
        }
        if(earliest<=1.) { hit=first; return true; }
        return false;
    }
    RayResult followWide(RayResult o,constant Uniforms& u,bool radianceOnly) {
        WideConstants c=widen(o.constants);
        float2 initialU=dd(ds(1.),ds(u.observerRadius));
        // Exact null normalization for the actual represented constants. This
        // is initialization, not an in-flight constraint projection.
        float2 initialV=dq(widePotential(initialU,c))*(o.state.q.y<0. ? -1. : 1.);
        WideState y={initialU,initialV,ds(o.state.c.x),ds(0.),o.state.q.zw};
        float horizon=1.+sqrt(1.-c.c.a*c.c.a), captureU=1./(horizon+.0005);
        float sceneExtent=u.diskHeightScale>0. ? length(float2(u.diskOuterRadius,1.08*u.diskHeightScale)) : u.diskOuterRadius;
        float escapeRadius=radianceOnly ? max(u.observerRadius,sceneExtent)+.001 : max(1000.,2.*u.observerRadius);
        float escapeU=1./escapeRadius;
        float radialTolerance=max(1.e-13,u.integrationTolerance*1.e-6);
        float angularTolerance=max(3.e-7,u.integrationTolerance);
        float h=min(.002,u.maxStep);
        for(uint step=0;step<u.steps;step++) {
            float q=df(y.u),v=df(y.v);
            if(q>=captureU) { o.status=2; break; }
            if(q<escapeU && v<0.) { o.status=3; break; }
            h=min(h,.28*max(q,escapeU)/max(abs(v),.01));
            if(v>0.) h=min(h,1.02*(captureU-q)/v);
            h=min(h,u.maxStep);
            if(u.diskHeightScale>0. && q>1./sceneExtent && abs(y.polar.x)<.4) {
                h=min(h,.08*q/max(abs(v),.001));
                h=min(h,.25/max(abs(df(wd(y,c).phi)),.001));
            }
            if(h<1.e-9 || !isfinite(h)) { o.status=5; break; }
            WideState error, next=wstep(y,c,h,error);
            float radialError=max(abs(df(error.u))/max(.02,abs(df(next.u))),abs(df(error.v))/max(1.,abs(df(next.v))));
            float angleScale=max(1.,sqrt(abs(c.c.eta)+c.c.xi*c.c.xi+c.c.a*c.c.a));
            float angularError=max(abs(error.polar.x),abs(error.polar.y)/angleScale);
            float coordinateError=max(abs(df(error.phi))/max(1.,abs(df(next.phi))),abs(df(error.delay))/max(1.,abs(df(next.delay))));
            float ratio=max(radialError/radialTolerance,max(angularError/angularTolerance,coordinateError/(angularTolerance*.1)));
            bool valid=all(isfinite(narrow(next).q)) && all(isfinite(narrow(next).c)) && isfinite(ratio);
            if(!valid || ratio>1.) {
                o.rejected++; h*=valid ? clamp(.85*pow(max(ratio,1.e-6),-.2),.15,.8) : .25; continue;
            }
            o.accepted++; o.localError=max(o.localError,max(radialError,max(angularError,coordinateError)));
            State s=narrow(next);
            // Measure radial conservation at the precision actually used.
            float radialInv=abs(df(da(dm(next.v,next.v),-widePotential(next.u,c))))/(1.+abs(df(widePotential(next.u,c))));
            float mu=s.q.z, polar=c.c.eta+c.c.b*mu*mu-c.c.a*c.c.a*mu*mu*mu*mu;
            float polarInv=abs(s.q.w*s.q.w-polar)/(1.+abs(c.c.eta)+abs(c.c.b*mu*mu)+c.c.a*c.c.a*mu*mu*mu*mu);
            o.invariant=max(o.invariant,max(radialInv,polarInv)); o.minRadius=min(o.minRadius,1./s.q.x);
            if(o.invariant>max(100.*angularTolerance,3.e-4) || abs(s.q.z)>1.00002) { y=next; o.status=5; break; }
            if(u.diskHeightScale>0.) {
                WideState hit;
                if(faceMaximum(diskFaces(narrow(y),u))<=0.) { o.status=5; break; }
                bool beyond=1./max(df(y.u),df(next.u))>sceneExtent && df(y.v)*df(next.v)>0.;
                if(!beyond && wideFiniteDiskHit(y,next,c,h,u,hit)) { y=hit; o.status=1; break; }
            } else if(y.polar.x*next.polar.x<0.) {
                WideState hit=wcross(y,next,c,h,2,0.); float r=1./df(hit.u);
                if(r>=u.diskInnerRadius && r<=u.diskOuterRadius) { y=hit; o.status=1; break; }
            }
            if(s.q.x>=captureU) { y=wcross(y,next,c,h,0,captureU); o.status=2; break; }
            if(s.q.x<escapeU && s.q.y<0.) {
                y=radianceOnly ? next : wcross(y,next,c,h,0,escapeU); o.status=3; break;
            }
            if(c.c.xi==0. && y.polar.y*next.polar.y<0.) {
                bool axial=c.c.eta>=0.;
                if(!axial) axial=abs(wcross(y,next,c,h,3,0.).polar.x)>.9999;
                if(axial) next.phi=da(next.phi,ds(M_PI_F));
            }
            y=next;
            h*=clamp(.9*pow(max(ratio,1.e-6),-.2),.5,2.5);
        }
        o.state=narrow(y); return o;
    }
    RayResult followRay(float2 pixel, constant Uniforms& u,bool radianceOnly) {
        RayResult o=initializeRay(pixel,u); Constants c=o.constants;
        // A photosphere-only renderer cannot describe a camera immersed in an
        // opaque atmosphere; report this unsupported state instead of emitting
        // from an invented boundary at the observer.
        if(u.diskHeightScale>0. && faceMaximum(diskFaces(o.state,u))<=0.) { o.status=5; return o; }
        if(needsWide(c)) return followWide(o,u,radianceOnly);
        float horizon=1.+sqrt(1.-c.a*c.a), captureU=1./(horizon+0.0005);
        // The supported observer domain is r>=12M, outside the entire Kerr
        // spherical-photon region (r<=4M for |a|<=1). An outgoing ray beyond
        // both the observer and finite disk cannot turn back to an emitter.
        // Radiant maps its deliberately faint procedural environment at this
        // finite escape surface; the direct validation path still follows to
        // 1000M.  This does not stand in for a physical far-field sky model.
        float sceneExtent=u.diskHeightScale>0. ? length(float2(u.diskOuterRadius,1.08*u.diskHeightScale)) : u.diskOuterRadius;
        float escapeRadius=radianceOnly ? max(u.observerRadius,sceneExtent)+.001 : max(1000.,2.*u.observerRadius);
        float escapeU=1./escapeRadius;
        float tol=max(u.integrationTolerance,3.e-7);
        float h=min(u.maxStep,.004), maxInv=max(100.*tol,3.e-4);
        for(uint step=0;step<u.steps;step++) {
            State old=o.state;
            if(old.q.x>=captureU) { o.status=2; break; }
            if(old.q.x<escapeU && old.q.y<0.) { o.status=3; break; }
            // Limit fractional radial changes for accurate time integration at
            // large r; keep RK stages above the Boyer–Lindquist coordinate horizon.
            h=min(h,.28*max(old.q.x,escapeU)/max(abs(old.q.y),.01));
            if(old.q.y>0.) h=min(h,1.02*(captureU-old.q.x)/old.q.y);
            h=min(h,u.maxStep);
            if(u.diskHeightScale>0. && old.q.x>1./sceneExtent && abs(old.q.z)<.4) {
                h=min(h,.08*old.q.x/max(abs(old.q.y),.001));
                h=min(h,.25/max(abs(derivative(old,c).c.x),.001));
            }
            if(h<1.e-8 || !isfinite(h)) { o.status=5; break; }
            State error; State next=rk45(old,c,h,error);
            float e=errorNorm(next,error,c), ratio=e/tol;
            bool valid=all(isfinite(next.q)) && all(isfinite(next.c)) && isfinite(e);
            if(!valid || ratio>1.) {
                o.rejected++; h*=valid ? clamp(.85*pow(max(ratio,1.e-6),-.2),.15,.8) : .25;
                continue;
            }
            o.accepted++; o.localError=max(o.localError,e);
            o.invariant=max(o.invariant,invariant(next,c));
            o.minRadius=min(o.minRadius,1./max(next.q.x,1.e-9));
            o.state=next;
            if(o.invariant>maxInv || abs(next.q.z)>1.00002) { o.status=5; break; }
            if(u.diskHeightScale>0.) {
                State hit;
                if(faceMaximum(diskFaces(old,u))<=0.) { o.state=old; o.status=5; break; }
                bool beyond=1./max(old.q.x,next.q.x)>sceneExtent && old.q.y*next.q.y>0.;
                if(!beyond && finiteDiskHit(old,next,c,h,u,hit)) { o.state=hit; o.status=1; break; }
            } else if(old.q.z*next.q.z<0.) {
                State hit=crossing(old,next,c,h,2,0.);
                float r=1./hit.q.x;
                if(r>=u.diskInnerRadius && r<=u.diskOuterRadius) {
                    o.state=hit; o.status=1; break;
                }
            }
            if(next.q.x>=captureU) {
                o.state=crossing(old,next,c,h,0,captureU); o.status=2; break;
            }
            if(next.q.x<escapeU && next.q.y<0.) {
                o.state=radianceOnly ? next : crossing(old,next,c,h,0,escapeU); o.status=3; break;
            }
            // At exactly Lz=0 the BL azimuth jumps by π at an axis crossing.
            // η>=0 has only axial polar turns. Vortical η<0 rays also possess
            // an interior turn, so locate that turn before selecting the chart.
            // Nonzero ξ already acquires its continuous π sweep in dφ/dλ.
            if(c.xi==0. && old.q.w*next.q.w<0.) {
                bool axial=c.eta>=0.;
                if(!axial) axial=abs(crossing(old,next,c,h,3,0.).q.z)>.9999;
                if(axial) o.state.c.x+=M_PI_F;
            }
            h*=clamp(.9*pow(max(ratio,1.e-6),-.2),.5,2.5);
        }
        return o;
    }
    float4 lookup(device const float4* values, uint count, float x) {
        float p=clamp(x,0.,float(count-1)); uint i=min(uint(p),count-2);
        return mix(values[i],values[i+1],p-float(i));
    }
    uint hash(uint x) { x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; return x^(x>>16); }
    float random(uint x) { return float(hash(x)&0x00ffffffu)/16777216.; }
    // A sparse, static distant field in celestial coordinates.  It is sampled
    // only after a traced ray has escaped, so capture and disk occultation
    // remain entirely determined by the Kerr transport result.
    float3 distantStellarField(float azimuth,float polarCosine) {
        float wrapped=atan2(sin(azimuth),cos(azimuth));
        float2 coordinate=float2((wrapped+M_PI_F)/(2.*M_PI_F),clamp(.5+.5*polarCosine,0.,1.));
        constexpr int columns=144, rows=72;
        float2 scaled=coordinate*float2(columns,rows);
        int2 base=int2(floor(scaled));
        float3 result=0.;
        // The small neighboring search makes every point continuous across
        // cell boundaries while the hash itself keeps the sky time-invariant.
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
            int cx=(base.x+x)%columns; if(cx<0) cx+=columns;
            int cy=clamp(base.y+y,0,rows-1);
            uint key=uint(cx)*0x9e3779b9u^uint(cy)*0x85ebca6bu;
            if(random(key^0x68bc21ebu)<.983) continue;
            float2 center=float2(float(base.x+x),float(base.y+y))+float2(random(key^0x02e5be93u),random(key^0x7f4a7c15u));
            float radius=length(scaled-center);
            // Use an explicit inverse of the ordinary increasing smoothstep:
            // reversed smoothstep edges are not a portable Metal contract.
            float core=1.-smoothstep(.025,.13,radius);
            float brightness=mix(.35,1.15,random(key^0x51ed270bu));
            float tint=random(key^0x1b873593u);
            result+=core*brightness*mix(float3(.18,.28,.55),float3(1.,.72,.42),tint);
        }
        return min(result,float3(1.2));
    }
    struct EmitterMotion { float rho,omega,ut,norm,g; };
    EmitterMotion emitterMotion(RayResult ray,constant Uniforms& u) {
        float r=1./ray.state.q.x,mu=ray.state.q.z,a=ray.constants.a;
        float rho=cylindricalRadius(ray.state),sin2=max(0.,1.-mu*mu);
        float sigma=r*r+a*a*mu*mu;
        float gtt=-1.+2.*r/sigma,gtp=-2.*a*r*sin2/sigma;
        float gpp=(r*r+a*a+2.*a*a*r*sin2/sigma)*sin2;
        float omega=1./(rho*sqrt(rho)+a);
        float velocityMetric=gtt+2.*omega*gtp+omega*omega*gpp;
        // Cylindrical rotation away from the mid-plane is a prescribed
        // pressure-supported velocity field, not a circular geodesic.
        // Its normalization must use the metric at the actual photosphere.
        float ut=velocityMetric<0. ? rsqrt(-velocityMetric) : NAN;
        return {rho,omega,ut,ut*ut*velocityMetric,
                1./(ray.constants.energy*ut*(1.-omega*ray.constants.xi))};
    }
    float redshift(RayResult ray,constant Uniforms& u) {
        if(u.diskHeightScale>0.) return emitterMotion(ray,u).g;
        float r=1./ray.state.q.x;
        // E_obs=1 by camera initialization, E_em=E*u_em^t*(1-Ω ξ).
        float r32=r*sqrt(r), orbitalSpin=ray.constants.a/r32;
        float omega=1./(r32+ray.constants.a);
        float ut=(1.+orbitalSpin)/sqrt(1.-3./r+2.*orbitalSpin);
        return 1./(ray.constants.energy*ut*(1.-omega*ray.constants.xi));
    }
    float3 thermalSpectrum(float temperature, constant Uniforms& u,
                           device const float4* spectrum) {
        if(temperature<exp(u.temperatureLogMin)) return float3(0.);
        return max(float3(0.),lookup(spectrum,u.temperatureTableCount,
                   (log(temperature)-u.temperatureLogMin)/u.temperatureLogStep).rgb);
    }
    float luminance(float3 c) { return dot(c,float3(.2126729,.7151522,.0721750)); }
    float angleDistance(float a,float b) { return abs(atan2(sin(a-b),cos(a-b))); }
    // A bounded, deterministic pseudo-stochastic field in co-moving disk
    // coordinates. It is deliberately a prescribed emissivity modulation,
    // rather than a change to the Page--Thorne mean flux, circular velocity,
    // photosphere, or Kerr ray paths. Each term is 2π-periodic in phase, so a
    // feature is transported by the existing Ω(r) differential rotation. The
    // footprint damping prevents the short modes from becoming pixel flicker
    // once shear has made them unresolved.
    float prescribedEmissivityFluctuation(float r,float coMovingPhase,float footprint,
                                          constant Uniforms& u) {
        float radial=(log(r)-log(u.diskInnerRadius))/max(log(u.diskOuterRadius/u.diskInnerRadius),1.e-6);
        radial=clamp(radial,0.,1.);
        float f=max(footprint,0.);
        float theta=coMovingPhase;
        float warp=.31*sin(2.*theta-10.7*radial)+.13*sin(5.*theta+6.1*radial);
        float m0=sin(3.*theta+7.3*radial+warp);
        float m1=sin(7.*theta-16.9*radial+.6*warp);
        float m2=sin(13.*theta+29.7*radial+1.4*warp);
        float m3=sin(21.*theta-43.1*radial+2.1*warp);
        // Coefficients sum to one before filtering, establishing an explicit
        // [-1,1] source-field bound independent of GPU/vendor noise.
        return clamp(.42*exp(-3.*f)*m0 + .27*exp(-7.*f)*m1 +
                     .19*exp(-13.*f)*m2 + .12*exp(-21.*f)*m3,-1.,1.);
    }
    float materialNoise(float2 p,int period) {
        int2 cell=int2(floor(p)); float2 q=fract(p);
        q=q*q*(3.-2.*q);
        int x0=((cell.x%period)+period)%period, x1=(x0+1)%period;
        uint row0=uint(cell.y)*0x9e3779b9u, row1=uint(cell.y+1)*0x9e3779b9u;
        float a=random(uint(x0)*0x85ebca6bu^row0), b=random(uint(x1)*0x85ebca6bu^row0);
        float c=random(uint(x0)*0x85ebca6bu^row1), d=random(uint(x1)*0x85ebca6bu^row1);
        return mix(mix(a,b,q.x),mix(c,d,q.x),q.y);
    }
    float materialTransmission(float r,float phase,float emittedTime,float dye,float footprint,
                               constant Uniforms& u) {
        // Intrinsic source coordinates make every lensed image see the same
        // rotating pattern at its own retarded emission time. The Eulerian
        // fluid dye is already advected by its solver; never orbit-shift it a
        // second time here. It is held fixed during the material-only shutter.
        float lr=log(r), turns=phase/(2.*M_PI_F), f=max(footprint,0.);
        float dyeValue=clamp(dye,0.,1.);
        float warp=materialNoise(float2(turns*4.,lr*5.),4);
        float n0=materialNoise(float2(turns*12.+3.*warp,lr*48.+4.*dyeValue),12);
        float n1=materialNoise(float2(turns*24.+5.*warp,lr*103.+7.*dyeValue),24);
        float n2=materialNoise(float2(turns*48.+7.*warp,lr*221.+11.*dyeValue),48);

        // Differential rotation increases the radial frequency of a pattern:
        // dOmega/d(log r) = -1.5 r^(3/2)/(r^(3/2)+a)^2. Include the unresolved
        // winding in the existing mapped-footprint filter. The first eight
        // turns retain the original look; this is an antialiasing estimate,
        // not numerical viscosity or a change to the emitter's orbital speed.
        float r32=r*sqrt(r),omega=1./(r32+clamp(u.spin,0.,.998));
        float winding=max(0.,abs(1.5*r32*omega*omega*emittedTime)/(2.*M_PI_F)-8.);
        float ribbons=.5+.56*exp(-(48.+12.*winding)*f)*(n0-.5)+
                           .30*exp(-(103.+24.*winding)*f)*(n1-.5)+
                           .14*exp(-(221.+48.*winding)*f)*(n2-.5);
        float eddies=materialNoise(float2(turns*7.,lr*12.),7)-.5;
        // A modest broad component makes orbital motion readable without
        // replacing the narrow, sheared filaments with isolated bright blobs.
        float broad=.12*exp(-(8.+4.*winding)*f)*(warp-.5);
        float structure=smoothstep(.27,.76,ribbons+.16*exp(-(18.+7.*winding)*f)*eddies+
                                   broad+.24*(dyeValue-.5));
        float material=.06+.94*pow(structure,1.4);
        float radialFraction=(lr-log(u.diskInnerRadius))/max(log(u.diskOuterRadius/u.diskInnerRadius),1.e-6);
        float outerTaper=1.-smoothstep(.87,1.,radialFraction);
        return mix(1.,material*outerTaper,clamp(u.materialStrength,0.,1.));
    }

    // One source/material evaluation is shared by the direct ray path and the
    // cached-geodesic path. The optical transfer stays independent of the art.
    // hit=(emission radius, BL azimuth, lookback coordinate time, frequency ratio).
    float3 shadeHit(float4 hit,float dye,float footprint,constant Uniforms& u,
                    device const float4* disk,device const float4* spectrum) {
        float r=hit.x, phi=hit.y, delay=hit.z, g=hit.w;
        float4 model=lookup(disk,u.diskTableCount,(log(r)-u.diskLogRadiusMin)/u.diskLogRadiusStep);
        float omega=1./(r*sqrt(r)+clamp(u.spin,0.,.998));
        float emittedTime=u.time/max(u.massTimeSeconds,1.e-6)-delay;
        float phase=phi-omega*emittedTime;
        float temperature=model.x;
        // Optional prescribed flux perturbation, evaluated at the actual
        // retarded emission event. The field is coherent and advected by the
        // same Kerr Ω(r) used for the mean emitter; it changes only local
        // emissivity. Zero exactly restores the steady Page–Thorne source.
        if(u.perturbationAmplitude>0.) {
            float amplitude=clamp(u.perturbationAmplitude,0.,.2);
            float fluxFactor=1.+amplitude*prescribedEmissivityFluctuation(r,phase,footprint,u);
            // T_eff^4 tracks bolometric surface flux. This does not prescribe
            // a causal GRMHD temperature history; the unperturbed table stays
            // the physical mean source.
            temperature*=pow(max(.8,fluxFactor),.25);
        }
        // g³ Bν(ν/g,T)=Bν(ν,gT): this includes spectral shift AND beaming.
        // In particular, there is no extra g³ multiplier after this evaluation.
        float3 physical=thermalSpectrum(g*temperature,u,spectrum);
        if(u.appearanceMode==0) return physical;

        // Explicitly artistic emission palette, NOT a cooler physical disk:
        // remap local thermal color into visible embers/ivory. The spectrum at
        // g*T_palette supplies chromaticity only; original received luminance
        // retains the physical radiance and Doppler brightness asymmetry.
        float paletteT=clamp(max(u.paletteTemperature,1000.)*pow(max(temperature,1.)/90000.,1.1),2200.,18000.);
        // At extreme redshift a palette blackbody becomes numerically black,
        // even while the true hotter source is visible. This is chromaticity,
        // not radiometry: retain an ember color below 1000 K rather than
        // silently erasing the correctly calculated physical luminance.
        float3 palette=thermalSpectrum(max(1000.,g*paletteT),u,spectrum);
        float3 color=palette*(luminance(physical)/max(luminance(palette),1.e-30));

        if(u.materialStrength<=0.) return color;
        // Centered physical exposure in BL seconds at infinity. Only prescribed
        // analytic material attenuation is averaged; the spectral source,
        // Eulerian fluid snapshot, camera, geometry and exact ray delay remain
        // fixed. This is not full spacetime/GRMHD motion blur.
        uint timeSamples=u.materialShutterSeconds>0. ?
                         (u.materialTimeSamples>=4 ? 4u : (u.materialTimeSamples>=2 ? 2u : 1u)) : 1u;
        float shutter=max(u.materialShutterSeconds,0.)/max(u.massTimeSeconds,1.e-6);
        float transmission=0.;
        for(uint sample=0;sample<timeSamples;sample++) {
            float offset=((float(sample)+.5)/float(timeSamples)-.5)*shutter;
            float sourceTime=emittedTime+offset;
            transmission+=materialTransmission(r,phi-omega*sourceTime,sourceTime,dye,footprint,u);
        }
        return color*(transmission/float(timeSamples));
    }
    kernel void traceKerr(texture2d<float,access::write> out [[texture(0)]],
                          constant Uniforms& u [[buffer(0)]],
                          device const float4* disk [[buffer(1)]],
                          device const float4* spectrum [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if(any(gid>=u.resolution)) return;
        float3 color=0.; bool unresolved=false;
        for(uint sample=0;sample<max(1u,u.samples);sample++) {
            uint seed=hash(gid.x+gid.y*u.resolution.x)^hash(u.frame*73u+sample*997u);
            float2 jitter=float2(random(seed),random(seed^0x9e3779b9u));
            RayResult ray=followRay(float2(gid)+jitter,u,true);
            unresolved|=ray.status>=4;
            if(ray.status==1) {
                float r=u.diskHeightScale>0. ? cylindricalRadius(ray.state) : 1./ray.state.q.x;
                float footprint=u.verticalFOV/float(u.resolution.y)*u.observerRadius/max(r,1.);
                float3 sampleColor=shadeHit(float4(r,ray.state.c,redshift(ray,u)),.5,footprint,u,disk,spectrum);
                if(all(isfinite(sampleColor))) color+=sampleColor;
                else { unresolved=true; if(u.diagnosticMode!=0) color+=float3(2.,0.,2.); }
            } else if(ray.status>=4 && u.diagnosticMode!=0) color+=float3(2.,0.,2.);
        }
        out.write(float4(color/float(max(1u,u.samples)),unresolved ? -1. : 1.),gid);
    }

    // Geometry is invariant while the camera/metric/boundaries stay fixed.
    // Keeping the full emitter coordinates and g allows real-time material
    // evolution without retracing Kerr geodesics or replacing them by a warp.
    // Dispatch uint3(width,height,samples); each slice is one jittered ray.
    float4 geometryRecord(RayResult ray,constant Uniforms& u) {
        float4 value=float4(-float(ray.status),0.,0.,0.);
        if(ray.status==1) {
            float rho=u.diskHeightScale>0. ? cylindricalRadius(ray.state) : 1./ray.state.q.x;
            value=float4(rho,ray.state.c,redshift(ray,u));
            if(!all(isfinite(value)) || value.w<=0.) value=float4(-5.,0.,0.,0.);
        } else if(ray.status==3) {
            // Escaped records do not need disk coordinates.  Reuse their free
            // channels for the ray's stable celestial direction at escape.
            value=float4(-3.,ray.state.c.x,clamp(ray.state.q.z,-1.,1.),0.);
        }
        return value;
    }
    kernel void traceGeometry(texture2d_array<float,access::write> mapping [[texture(0)]],
                              constant Uniforms& u [[buffer(0)]],uint3 tid [[thread_position_in_grid]]) {
        uint2 gid=tid.xy; uint sample=tid.z;
        if(any(gid>=u.resolution) || sample>=max(1u,u.samples) || sample>=mapping.get_array_size()) return;
        uint seed=hash(gid.x+gid.y*u.resolution.x)^hash(u.frame*73u+sample*997u);
        float2 jitter=float2(random(seed),random(seed^0x9e3779b9u));
        RayResult ray=followRay(float2(gid)+jitter,u,true);
        mapping.write(geometryRecord(ray,u),gid,sample);
    }
    bool geometryEdge(float4 a,float4 b) {
        if((a.x>0.)!=(b.x>0.)) return true;
        if(a.x<=0.) return a.x!=b.x;
        return abs(log(a.x/b.x))>.10 || abs(a.w-b.w)>.12;
    }
    kernel void markGeometryEdges(texture2d_array<float,access::read> mapping [[texture(0)]],
                                  texture2d<uint,access::write> edgeLookup [[texture(1)]],
                                  constant Uniforms& u [[buffer(0)]],
                                  device uint2* edgePixels [[buffer(1)]],
                                  device atomic_uint* counter [[buffer(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if(any(gid>=u.resolution)) return;
        uint slot=0;
        if(u.edgeSamples>0 && u.edgeCapacity>0) {
            bool edge=false;
            uint samples=min(max(1u,u.samples),mapping.get_array_size());
            float4 center=mapping.read(gid,0);
            for(uint sample=0;sample<samples && !edge;sample++) {
                float4 local=mapping.read(gid,sample);
                edge=geometryEdge(center,local);
                for(uint axis=0;axis<2 && !edge;axis++) {
                    for(int offset=-2;offset<=2;offset++) {
                        if(offset==0) continue;
                        int2 neighbor=int2(gid); neighbor[axis]+=offset;
                        if(any(neighbor<0) || any(neighbor>=int2(u.resolution))) continue;
                        if(geometryEdge(local,mapping.read(uint2(neighbor),sample))) { edge=true; break; }
                    }
                }
            }
            if(edge) {
                uint index=atomic_fetch_add_explicit(counter,1u,memory_order_relaxed);
                if(index<u.edgeCapacity) { edgePixels[index]=gid; slot=index+1; }
            }
        }
        edgeLookup.write(uint4(slot,0,0,0),gid);
    }
    kernel void refineGeometryEdges(constant Uniforms& u [[buffer(0)]],
                                    device const uint2* edgePixels [[buffer(1)]],
                                    device float4* edgeHits [[buffer(2)]],
                                    device atomic_uint* counter [[buffer(3)]],
                                    uint2 tid [[thread_position_in_grid]]) {
        uint index=tid.x,sample=tid.y;
        if(index>=min(atomic_load_explicit(counter,memory_order_relaxed),u.edgeCapacity) || sample>=u.edgeSamples) return;
        uint nx=u.edgeSamples>=8 ? 4u : 2u;
        uint ny=(u.edgeSamples+nx-1)/nx;
        float2 jitter=(float2(sample%nx,sample/nx)+.5)/float2(nx,ny);
        RayResult ray=followRay(float2(edgePixels[index])+jitter,u,true);
        edgeHits[index*u.edgeSamples+sample]=geometryRecord(ray,u);
    }
    kernel void shadeGeometry(texture2d_array<float,access::read> mapping [[texture(0)]],
                              texture2d<float,access::sample> flow [[texture(1)]],
                              texture2d<float,access::write> out [[texture(2)]],
                              texture2d<uint,access::read> edgeLookup [[texture(3)]],
                              constant Uniforms& u [[buffer(0)]],
                              device const float4* disk [[buffer(1)]],
                              device const float4* spectrum [[buffer(2)]],
                              device const float4* edgeHits [[buffer(3)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if(any(gid>=u.resolution)) return;
        constexpr sampler flowSampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
        float3 color=0.; bool unresolved=false;
        uint count=min(max(1u,u.samples),mapping.get_array_size());
        uint edgeSlot=u.edgeSamples>0 ? edgeLookup.read(gid).x : 0;
        if(edgeSlot>u.edgeCapacity) edgeSlot=0;
        if(edgeSlot>0) count=u.edgeSamples;
        for(uint sample=0;sample<count;sample++) {
            float4 hit=edgeSlot>0 ? edgeHits[(edgeSlot-1)*u.edgeSamples+sample] : mapping.read(gid,sample);
            if(hit.x>0.) {
                float dye=.5;
                if(u.flowEnabled!=0 && u.appearanceMode!=0) {
                    float2 uv=float2(hit.y/(2.*M_PI_F),(log(hit.x)-u.flowLogRadiusMin)/max(u.flowLogRadiusSpan,1.e-6));
                    // A GPU fluid proxy supplies instantaneous dye, not a
                    // GRMHD temperature field or a retarded field history.
                    dye=flow.sample(flowSampler,uv).x;
                }
                float footprint=u.verticalFOV/float(u.resolution.y)*u.observerRadius/max(hit.x,1.);
                for(uint axis=0;axis<2;axis++) {
                    uint2 neighbor=gid; neighbor[axis]=min(gid[axis]+1,u.resolution[axis]-1);
                    float4 other=mapping.read(neighbor,edgeSlot>0 ? 0u : sample);
                    if(other.x>0.) footprint=max(footprint,max(abs(log(other.x/hit.x)),.15*angleDistance(other.y,hit.y)));
                }
                float3 sampleColor=shadeHit(hit,dye,footprint,u,disk,spectrum);
                if(all(isfinite(sampleColor))) color+=sampleColor;
                else { unresolved=true; if(u.diagnosticMode!=0) color+=float3(2.,0.,2.); }
            } else if(hit.x==-3. && u.appearanceMode!=0 && u.materialStrength>0.) {
                // This is never a screen-space backdrop: only an integrated
                // status-3 escape ray can reveal the static distant field.
                color+=distantStellarField(hit.y,hit.z);
            } else if(hit.x<=-4.) {
                unresolved=true;
                if(u.diagnosticMode!=0) color+=float3(2.,0.,2.);
            }
        }
        out.write(float4(color/float(max(count,1u)),unresolved ? -1. : 1.),gid);
    }
    // Deterministic GPU validation runs exactly the production integrator.
    // Four float4 output records per ray, documented by the CPU test harness.
    kernel void validateKerr(constant Uniforms& u [[buffer(0)]],
                             device const float4* pixels [[buffer(1)]],
                             device float4* output [[buffer(2)]],
                             constant uint& count [[buffer(3)]],uint i [[thread_position_in_grid]]) {
        if(i>=count) return;
        RayResult r=followRay(pixels[i].xy,u,false);
        output[4*i+0]=float4(r.constants.xi,r.constants.eta,r.constants.energy,r.initialInvariant);
        output[4*i+1]=float4(float(r.status),1./r.state.q.x,r.state.c.x,r.state.c.y);
        output[4*i+2]=float4(r.state.q.y,r.state.q.z,r.state.q.w,r.invariant);
        output[4*i+3]=float4(float(r.accepted),float(r.rejected),r.localError,r.minRadius);
    }
    // Extended diagnostics keep the legacy validateKerr ABI unchanged.
    // Six records: legacy four; (rho,z,H,g); (Fmax,-u.u,u^t,Omega).
    kernel void validateSurface(constant Uniforms& u [[buffer(0)]],
                                device const float4* pixels [[buffer(1)]],
                                device float4* output [[buffer(2)]],
                                constant uint& count [[buffer(3)]],uint i [[thread_position_in_grid]]) {
        if(i>=count) return;
        RayResult r=followRay(pixels[i].xy,u,false);
        output[6*i+0]=float4(r.constants.xi,r.constants.eta,r.constants.energy,r.initialInvariant);
        output[6*i+1]=float4(float(r.status),1./r.state.q.x,r.state.c.x,r.state.c.y);
        output[6*i+2]=float4(r.state.q.y,r.state.q.z,r.state.q.w,r.invariant);
        output[6*i+3]=float4(float(r.accepted),float(r.rejected),r.localError,r.minRadius);
        float rho=cylindricalRadius(r.state),z=r.state.q.z/r.state.q.x;
        EmitterMotion emitter={rho,0.,0.,0.,0.};
        if(r.status==1) emitter=emitterMotion(r,u);
        output[6*i+4]=float4(rho,z,diskHeight(rho,r.state.c.x,u),r.status==1 ? redshift(r,u) : 0.);
        output[6*i+5]=float4(faceMaximum(diskFaces(r.state,u)),-emitter.norm,emitter.ut,emitter.omega);
    }
    kernel void accumulate(texture2d<float,access::read> current [[texture(0)]],
                           texture2d<float,access::read> previous [[texture(1)]],
                           texture2d<float,access::write> output [[texture(2)]],
                           constant uint& historyCount [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=current.get_width() || gid.y>=current.get_height()) return;
        float4 now=float4(current.read(gid));
        // Alpha in history stores the valid frame count per pixel, rather than
        // averaging unresolved black samples into the radiance estimate.
        float4 old=historyCount==0 ? float4(0.) : previous.read(gid);
        if(now.a<0.) { output.write(old,gid); return; }
        float weight=1./(old.a+1.);
        float3 mean=mix(old.rgb,now.rgb,weight);
        output.write(float4(mean,min(old.a+1.,65535.)),gid);
    }
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut fullscreenVertex(uint id [[vertex_id]]) {
        float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
        VOut o; o.position=float4(p[id],0,1); o.uv=float2(p[id].x*.5+.5,.5-p[id].y*.5); return o;
    }
    fragment float4 presentFragment(VOut in [[stage_in]],texture2d<float> image [[texture(0)]],constant float& exposure [[buffer(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float3 c=max(float3(0.),float3(image.sample(s,in.uv).rgb))*exposure;
        // Common-factor compression preserves RGB ratios and bounds every
        // channel below one, avoiding blue-channel clipping in the drawable.
        return float4(c/(1.+max(c.r,max(c.g,c.b))),1.);
    }
    """#
}
