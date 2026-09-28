#!/usr/bin/env python3
"""Independent binary64 Kerr reference and GPU regression checks (stdlib only).

The renderer evolves reciprocal radius and cos(theta). This reference instead
evolves Boyer–Lindquist r and theta using their differentiated first integrals,
with an independent Dormand–Prince implementation and much tighter tolerances.
It is not a proof of physical accuracy and is not a GRMHD disk simulation.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import time
import struct

ROOT = Path(__file__).resolve().parents[1]
PI = math.pi


def isco(a):
    z1 = 1 + (1 - a*a)**(1/3) * ((1+a)**(1/3) + (1-a)**(1/3))
    z2 = math.sqrt(3*a*a + z1*z1)
    return 3 + z2 - math.sqrt(max(0, (3-z1)*(3+z1+2*z2)))


def metric(r, th, a):
    s2 = math.sin(th)**2
    sigma = r*r + a*a*math.cos(th)**2
    delta = r*r - 2*r + a*a
    biga = (r*r+a*a)**2 - a*a*delta*s2
    return (-1+2*r/sigma, -2*a*r*s2/sigma,
            sigma/delta, sigma, biga*s2/sigma)


def camera(case):
    """Construct a future null vector from a past-pointing local screen ray.

    Compute constants by metric contractions, not the renderer's direct formula.
    The frame is a ZAMO, with zero physical velocity relative to that tetrad.
    """
    a = case['spin']
    r = case['cameraDistance']
    th = PI/2-case['cameraPitch']
    w, h = case['resolution']
    px, py = case['pixel']
    f = 2*math.tan(case['fov']/2)
    raw = [-1, (py/h-.5)*f, (px/w-.5)*f*w/h]
    norm = math.sqrt(sum(x*x for x in raw))
    nr, nth, nphi = [x/norm for x in raw]
    # Local camera rotations preserve the orthonormal tetrad and do not create a
    # physical velocity. A velocity would instead require a Lorentz transform.
    lp, ly = case.get('lookPitch',0), case.get('lookYaw',0)
    nr,nth = math.cos(lp)*nr-math.sin(lp)*nth, math.sin(lp)*nr+math.cos(lp)*nth
    nr,nphi = math.cos(ly)*nr+math.sin(ly)*nphi, -math.sin(ly)*nr+math.cos(ly)*nphi
    gtt, gtp, grr, gthth, gpp = metric(r, th, a)
    omega = -gtp/gpp
    lapse = math.sqrt(-gtt + gtp*gtp/gpp)
    p = [1/lapse, -nr/math.sqrt(grr), -nth/math.sqrt(gthth),
         omega/lapse-nphi/math.sqrt(gpp)]
    energy = -(gtt*p[0]+gtp*p[3])
    angular = gtp*p[0]+gpp*p[3]
    polar = gthth*p[2]
    xi = angular/energy
    if abs(xi)<1e-12:
        xi=0.0
    eta = (polar/energy)**2 + math.cos(th)**2*(xi*xi/math.sin(th)**2-a*a)
    null = gtt*p[0]**2+2*gtp*p[0]*p[3]+grr*p[1]**2+gthth*p[2]**2+gpp*p[3]**2
    sigma = gthth
    initial = [r, -p[1]*sigma/energy, th, -p[2]*sigma/energy,
               case.get('cameraYaw', 0), 0]
    return xi, eta, energy, null, initial


def metal_input_case(case):
    """Use the exact values transmitted through the Metal binary32 ABI.

    It would be a different initial-value problem to compare near-critical rays
    using unrounded JSON doubles when the actual GPU receives Float uniforms.
    All subsequent reference calculations remain binary64.
    """
    def f32(value):
        return struct.unpack('f',struct.pack('f',value))[0]
    result=dict(case)
    for key in ['spin','cameraDistance','cameraPitch','cameraYaw','fov','lookYaw','lookPitch']:
        if key in result:
            result[key]=f32(result[key])
    result['pixel']=[f32(x) for x in result['pixel']]
    return result


def potentials(r, th, a, xi, eta):
    p = r*r+a*a-a*xi
    delta = r*r-2*r+a*a
    k = eta+(xi-a)**2
    radial = p*p-delta*k
    polar = eta+a*a*math.cos(th)**2-(xi*xi/math.tan(th)**2 if xi else 0)
    return radial, polar


def derivative(y, a, xi, eta):
    r, vr, th, vth, phi, delay = y
    sn, cs = math.sin(th), math.cos(th)
    delta = r*r-2*r+a*a
    p = r*r+a*a-a*xi
    k = eta+(xi-a)**2
    return [vr, 2*r*p-(r-1)*k, vth,
            -a*a*cs*sn+(xi*xi*cs/(sn**3) if xi else 0),
            -((xi/(sn*sn) if xi else 0)-a+a*p/delta),
            (r*r+a*a)*p/delta+a*xi-a*a*sn*sn]


# Dormand–Prince 5(4), binary64 throughout. No renderer coefficients imported.
A = [[], [1/5], [3/40, 9/40], [44/45, -56/15, 32/9],
     [19372/6561, -25360/2187, 64448/6561, -212/729],
     [9017/3168, -355/33, 46732/5247, 49/176, -5103/18656],
     [35/384, 0, 500/1113, 125/192, -2187/6784, 11/84]]
B5 = A[6]+[0]
B4 = [5179/57600, 0, 7571/16695, 393/640, -92097/339200, 187/2100, 1/40]


def step(y, h, a, xi, eta):
    stages = []
    for coeff in A:
        q = [y[j]+h*sum(c*k[j] for c, k in zip(coeff, stages)) for j in range(6)]
        stages.append(derivative(q, a, xi, eta))
    hi = [y[j]+h*sum(c*k[j] for c, k in zip(B5, stages)) for j in range(6)]
    err = [h*sum((c-d)*k[j] for c, d, k in zip(B5, B4, stages)) for j in range(6)]
    return hi, err


def crossing(y, h, a, xi, eta, axis, target):
    """Locate an event by bisecting and reintegrating the accepted step."""
    lo, hi = 0., h
    sign = y[axis]-target
    for _ in range(36):
        mid = (lo+hi)*.5
        q, _ = step(y, mid, a, xi, eta)
        if (q[axis]-target)*sign > 0:
            lo = mid
        else:
            hi = mid
    return step(y, (lo+hi)*.5, a, xi, eta)[0]


def trace(a, xi, eta, initial, tol=2e-11, disk_outer=0,
          escape_radius=100, max_lambda=15, capture_radius=None):
    y = list(initial)
    horizon = 1+math.sqrt(1-a*a)
    capture_radius = capture_radius or horizon*1.002
    inner = isco(a)
    h, affine, accepted, rejected = min(.002, .015/y[0]), 0., 0, 0
    maximum_invariant, minimum_radius = 0., y[0]
    crossings = []
    while accepted < 100000 and affine < max_lambda:
        # Protect coordinate singularities before evaluating RK intermediate stages.
        h = min(h, .06*y[0]/max(1, abs(y[1])),
                .08/max(1, abs(y[3])),
                .18*max(y[0]-horizon, .00001)/max(1, -y[1]))
        if xi:
            h=min(h,.15*max(.00001,min(abs(y[2]),abs(PI-y[2])))/max(1,abs(y[3])))
        q, errors = step(y, h, a, xi, eta)
        scales = [max(1,abs(y[j]),abs(q[j])) for j in range(6)]
        error = max(abs(e)/(tol*s) for e,s in zip(errors,scales))
        if not all(math.isfinite(x) for x in q):
            raise ArithmeticError('Non-finite reference trajectory')
        if error > 1:
            h *= max(.1, .9*error**(-.2))
            rejected += 1
            continue
        accepted += 1
        affine += h
        # For exact Lz=0 a ray crosses the axis. Boyer–Lindquist θ reverses and
        # φ jumps by π; this is a chart change, not physical bending or clipping.
        if xi==0 and (q[2]<0 or q[2]>PI):
            q[2]=abs(q[2]) if q[2]<0 else 2*PI-q[2]
            q[3]=-q[3]
            q[4]+=PI
        minimum_radius = min(minimum_radius, q[0])
        radial, polar = potentials(q[0],q[2],a,xi,eta)
        p = q[0]**2+a*a-a*xi
        d = q[0]**2-2*q[0]+a*a
        k = eta+(xi-a)**2
        residual = max(abs(q[1]**2-radial)/(1+p*p+abs(d*k)),
                       abs(q[3]**2-polar)/(1+abs(eta)+a*a+(xi*xi/math.sin(q[2])**2 if xi else 0)))
        maximum_invariant = max(maximum_invariant, residual)
        status = 0
        if (y[2]-PI/2)*(q[2]-PI/2) < 0:
            hit = crossing(y,h,a,xi,eta,2,PI/2)
            crossings.append(hit)
            if inner < hit[0] < disk_outer:
                q, status = hit, 1
        if not status and q[0] < capture_radius:
            q, status = crossing(y,h,a,xi,eta,0,capture_radius), 2
        if not status and q[0] > escape_radius and q[1] > 0:
            q, status = crossing(y,h,a,xi,eta,0,escape_radius), 3
        y = q
        if status:
            return dict(status=status, state=y, accepted=accepted,rejected=rejected,
                        invariant=maximum_invariant, minRadius=minimum_radius,
                        crossings=crossings, affine=affine)
        h *= min(3., max(.2, .9*max(error,1e-16)**(-.2)))
    return dict(status=4,state=y,accepted=accepted,rejected=rejected,
                invariant=maximum_invariant,minRadius=minimum_radius,
                crossings=crossings,affine=affine)


def from_constants(a, xi, eta, radius=50, theta=PI/2, polar_sign=1):
    rr, tt = potentials(radius, theta, a, xi, eta)
    return [radius, -math.sqrt(rr), theta, polar_sign*math.sqrt(max(0,tt)), 0, 0]


def quadrature_pair(function, left, right, atol=1e-10):
    """Independent adaptive Simpson quadrature for a pair of scalar integrals."""
    def simpson(l,r,fl,fm,fr):
        return tuple((r-l)/6*(fl[j]+4*fm[j]+fr[j]) for j in range(2))
    def recurse(l,r,fl,fm,fr,whole,tol,depth):
        m=(l+r)/2
        f1,f3=function((l+m)/2),function((m+r)/2)
        first,second=simpson(l,m,fl,f1,fm),simpson(m,r,fm,f3,fr)
        delta=tuple(first[j]+second[j]-whole[j] for j in range(2))
        if depth==0 or max(abs(x) for x in delta)<15*tol:
            return tuple(first[j]+second[j]+delta[j]/15 for j in range(2))
        q1=recurse(l,m,fl,f1,fm,first,tol/2,depth-1)
        q2=recurse(m,r,fm,f3,fr,second,tol/2,depth-1)
        return tuple(q1[j]+q2[j] for j in range(2))
    f0,fm,f1=function(left),function((left+right)/2),function(right)
    return recurse(left,right,f0,fm,f1,simpson(left,right,f0,fm,f1),atol,26)


def equatorial_escape(a,xi,observer=36,outer=1000,phi0=.17,atol=1e-9):
    """No trajectory marching: integrate exactly factored radial potential.

    Q=0 gives R=r(r³+(a²−xi²)r+2(xi−a)²). Its three cubic roots
    give a cancellation-resistant potential, and r=r_turn+x² removes the
    square-root turning-point singularity. This is the high-accuracy reference
    for ill-conditioned, many-winding equatorial shadow-boundary rays.
    """
    b=a*a-xi*xi
    k=(xi-a)**2
    size=math.sqrt(-b/3)
    angle=math.acos(max(-1,min(1,-k/(size**3))))/3
    negative,inner,turn=sorted(2*size*math.cos(angle-2*j*PI/3) for j in range(3))
    def f(x):
        r=turn+x*x
        common=2/math.sqrt(r*(r-inner)*(r-negative))
        delta=r*r-2*r+a*a
        p=r*r+a*a-a*xi
        return (common*(xi-a+a*p/delta),
                common*((r*r+a*a)*p/delta+a*xi-a*a))
    near=quadrature_pair(f,0,math.sqrt(observer-turn),atol)
    far=quadrature_pair(f,math.sqrt(observer-turn),math.sqrt(outer-turn),atol)
    return phi0-2*near[0]-far[0],2*near[1]+far[1],turn


def check(results, name, ok, detail):
    results.append((name, bool(ok), detail))
    print(('PASS ' if ok else 'FAIL ')+name+': '+detail)


def analytic_checks(results, cases):
    nulls = [abs(camera(c)[3]) for c in cases]
    check(results, 'Finite-radius ZAMO null tetrad', max(nulls)<3e-14,
          f'{len(cases)} rays; max |g(p,p)|={max(nulls):.3g}')
    horizon = 2
    bcrit = 3*math.sqrt(3)
    sides = []
    for factor in [1-1e-6,1+1e-6]:
        b = bcrit*factor
        q = trace(0,b,0,from_constants(0,b,0),tol=2e-12,escape_radius=50)
        sides.append(q['status'])
    check(results,'Schwarzschild analytic shadow boundary', sides == [2,3],
          f'bcrit=3√3={bcrit:.12f} M; bcrit×(1±10⁻⁶) gives {sides} (2=capture,3=escape)')
    sph_resid, dynamics = [], []
    for a in [.3,.6,.9,.998]:
        rlo = 2*(1+math.cos(2/3*math.acos(-a)))
        rhi = 2*(1+math.cos(2/3*math.acos(a)))
        for f in [.15,.35,.65,.85]:
            r = rlo+(rhi-rlo)*f
            xi = -(r**3-3*r*r+a*a*r+a*a)/(a*(r-1))
            eta = -r**3*(r**3-6*r*r+9*r-4*a*a)/(a*a*(r-1)**2)
            rr, _ = potentials(r,PI/2,a,xi,eta)
            ddy = derivative([r,0,PI/2,math.sqrt(eta),0,0],a,xi,eta)[1]
            sph_resid.append(max(abs(rr)/(1+r**4),abs(ddy)/(1+r**3)))
            # Radially scaling screen impact parameters moves across the analytic
            # spherical-photon critical curve at an equatorial distant observer.
            status=[]
            for scale in [1-1e-5,1+1e-5]:
                sx, se = xi*scale, eta*scale*scale
                q = trace(a,sx,se,from_constants(a,sx,se),tol=1e-12,escape_radius=50)
                status.append(q['status'])
            dynamics.append(status==[2,3])
    check(results,'Kerr spherical-photon analytic boundary',max(sph_resid)<1e-12 and all(dynamics),
          f'{len(sph_resid)} analytical photon spheres, spins .3–.998; max R/R′ residual={max(sph_resid):.3g}; '
          f'{sum(dynamics)}/{len(dynamics)} capture/escape brackets correct at ±10⁻⁵')
    b = 1000
    # Keep r/b=10: r-coordinate second-order integration at r/b=1000 suffers
    # cancellation of O(r^4) radial terms even in binary64. The omitted cubic
    # deflection and finite-endpoint curvature terms here are below 2e-7 rad.
    outer=10000
    q = trace(0,b,0,from_constants(0,b,0,radius=outer),tol=2e-14,escape_radius=outer)
    deflection=abs(q['state'][4])-PI+2*math.asin(b/outer)
    approx=4/b+15*PI/(4*b*b)
    check(results,'Weak-field light deflection',q['status']==3 and abs(deflection-approx)<2e-7,
          f'b=1000 M, finite endpoints r=10000 M; measured α={deflection:.11g} rad; '
          f'4/b+15π/(4b²)={approx:.11g}; residual={abs(deflection-approx):.3g} rad (expected higher-order/finite-radius terms)')
    check(results,'Exact prograde ISCO endpoints',abs(isco(0)-6)<1e-14 and abs(isco(.998)-1.236970655)<1e-8,
          f'rISCO(a=0)={isco(0):.9f}; rISCO(a=.998)={isco(.998):.9f} M')
    # Frequency transfer is checked both by scalar contractions and circular-orbit
    # closed form. The emitted future ray has E=1 and L=xi after normalization.
    shifts=[]
    for a in [0,.6,.998]:
        for r in [isco(a)*1.1,10,30]:
            gtt,gtp,_,_,gpp=metric(r,PI/2,a)
            omega=1/(r**1.5+a)
            ut=1/math.sqrt(-(gtt+2*gtp*omega+gpp*omega*omega))
            closed=(1+a/r**1.5)/math.sqrt(1-3/r+2*a/r**1.5)
            shifts.append(abs(ut-closed)/ut)
    check(results,'Circular emitter frequency contraction',max(shifts)<2e-14,
          f'max uᵗ discrepancy={max(shifts):.3g}; g=1/[E_camera uᵗ(1−Ωξ)]')
    # I_nu/nu³ is invariant. Shifting a Planck spectrum means B_nu(gT), with no
    # additional g³ brightness multiplier. Integrating frequency yields g⁴.
    spectral=[]
    for freq in [2e14,5e14,9e14]:
        for temp in [3000,7000,25000]:
            for g in [.3,.75,1.2,2.]:
                def planck(n,t):
                    return n**3/math.expm1(4.799243073e-11*n/t)
                lhs=planck(freq,g*temp)
                rhs=g**3*planck(freq/g,temp)
                spectral.append(abs(lhs-rhs)/max(lhs,rhs))
    check(results,'Invariant blackbody spectral transfer',max(spectral)<1e-13,
          f'{len(spectral)} samples; max relative |Bν(gT)−g³Bν(ν/g,T)|={max(spectral):.3g}')


def reference_cases(results, cases):
    references={}
    invariants=[]
    for original in cases:
        c=metal_input_case(original)
        xi,eta,energy,null,y=camera(c)
        q=trace(c['spin'],xi,eta,y,tol=2e-13,disk_outer=c['diskOuter'],escape_radius=1000,
                capture_radius=1+math.sqrt(1-c['spin']**2)+.0005)
        if c.get('expectedStatus')==3:
            phi,delay,turn=equatorial_escape(c['spin'],xi,c['cameraDistance'],1000,c['cameraYaw'])
            q['state'][4],q['state'][5],q['minRadius']=phi,delay,turn
            q['referenceMethod']='factored equatorial radial quadrature, exact binary32 ABI inputs'
            original_xi=camera(original)[0]
            original_phi=equatorial_escape(original['spin'],original_xi,original['cameraDistance'],1000,original['cameraYaw'])[0]
            q['inputQuantizationAzimuth']=abs(math.remainder(phi-original_phi,2*PI))
        references[c['id']]={**q,'xi':xi,'eta':eta,'energy':energy}
        invariants.append(q['invariant'])
    resolved=sum(q['status'] in [1,2,3] for q in references.values())
    check(results,'Binary64 reference geodesic conservation',resolved==len(cases) and max(invariants)<2e-7,
          f'{resolved}/{len(cases)} rays resolved; max normalized radial/polar invariant residual={max(invariants):.3g}')
    hits=[(c,references[c['id']]) for c in cases if references[c['id']]['status']==1]
    chosen=hits[::max(1,len(hits)//8)][:8]
    conv=[]
    for c,q in chosen:
        c=metal_input_case(c)
        xi,eta,_,_,y=camera(c)
        tight=trace(c['spin'],xi,eta,y,tol=2e-14,disk_outer=c['diskOuter'],escape_radius=1000,
                    capture_radius=1+math.sqrt(1-c['spin']**2)+.0005)
        diff=max(abs(tight['state'][j]-q['state'][j])/max(1,abs(tight['state'][j])) for j in [0,4,5])
        conv.append(diff)
    check(results,'Independent reference convergence',bool(conv) and max(conv)<2e-6,
          f'{len(conv)} disk hits at tolerances 2×10⁻¹³ and 2×10⁻¹⁴; max relative r/φ/delay change={max(conv,default=0):.3g}')
    quadrature_errors=[]
    for c in cases:
        if c.get('expectedStatus')==3:
            c=metal_input_case(c)
            ref=references[c['id']]
            phi,delay,_=equatorial_escape(c['spin'],ref['xi'],c['cameraDistance'],1000,c['cameraYaw'],atol=1e-11)
            quadrature_errors.append(max(abs(phi-ref['state'][4]),abs(delay-ref['state'][5])))
    if quadrature_errors:
        check(results,'Many-winding equatorial reference convergence',max(quadrature_errors)<1e-7,
              f'{len(quadrature_errors)} escaping critical rays; factored cubic potential quadrature '
              f'at absolute tolerances 10⁻⁹ and 10⁻¹¹; max φ/delay change={max(quadrature_errors):.3g}')
    delays=[q['state'][5] for _,q in hits]
    check(results,'Past-light-cone disk events',bool(delays) and min(delays)>0,
          f'{len(hits)} first opaque disk hits; positive travel delays {min(delays,default=0):.6g}–{max(delays,default=0):.6g} GM/c³')
    return references


def compare_gpu(results, gpu, references, label='GPU'):
    ids=[case['id'] for case in gpu['cases']]
    check(results,label+' diagnostic coverage',len(ids)==len(references) and set(ids)==set(references),
          f'{len(set(ids))}/{len(references)} unique requested rays; complete manifest required')
    statuses=[]
    constants=[]
    radii=[]
    phis=[]
    delays=[]
    invariants=[]
    mismatches=[]
    boundary=[]
    escape_angles=[]
    critical_initial_offsets=[]
    for item in gpu['cases']:
        ref=references[item['id']]
        p=item['result']
        if len(p)!=16 or not all(math.isfinite(x) for x in p):
            raise AssertionError('GPU diagnostic must contain 16 finite floats: '+item['id'])
        status=int(round(p[4]))
        statuses.append(status==ref['status'])
        if status!=ref['status']:
            mismatches.append(f"{item['id']}: CPU {ref['status']} GPU {status}")
        if 'expectedStatus' in item:
            boundary.append(status==item['expectedStatus'] and ref['status']==item['expectedStatus'])
        constants.extend(abs(p[j]-v)/max(1,abs(v)) for j,v in enumerate([ref['xi'],ref['eta'],ref['energy']]))
        invariants.append(abs(p[11]))
        if status==1 and ref['status']==1:
            radii.append(abs(p[5]-ref['state'][0])/max(1,ref['state'][0]))
            phis.append(abs(math.remainder(p[6]-ref['state'][4],2*PI)))
            delays.append(abs(p[7]-ref['state'][5])/max(1,ref['state'][5]))
        if status==3 and ref['status']==3:
            target_phi=ref['state'][4]
            if item.get('expectedStatus')==3:
                # Ill-conditioned, many-winding rays need the SAME actual
                # conserved constants to test the propagator. The camera's
                # Float xi/eta mapping is independently checked above; its
                # amplified endpoint displacement is reported separately here.
                actual=metal_input_case(item)
                target_phi,_,_=equatorial_escape(actual['spin'],p[0],actual['cameraDistance'],1000,actual['cameraYaw'])
                critical_initial_offsets.append(abs(math.remainder(target_phi-ref['state'][4],2*PI)))
            theta=math.acos(max(-1,min(1,p[9])))
            dot=(math.cos(theta)*math.cos(ref['state'][2])+
                 math.sin(theta)*math.sin(ref['state'][2])*math.cos(p[6]-target_phi))
            escape_angles.append(math.acos(max(-1,min(1,dot))))
    check(results,label+' finite-radius camera constants',max(constants,default=1)<1e-5,
          f'{len(statuses)} actual Metal rays; max relative ξ/η/E error={max(constants,default=1):.3g}')
    check(results,label+' capture / disk / escape classification',all(statuses) and bool(statuses),
          f'{sum(statuses)}/{len(statuses)} agrees with binary64 reference'+('; '+', '.join(mismatches[:8]) if mismatches else ''))
    check(results,label+' disk intersection positions',bool(radii) and max(radii)<.002 and max(phis)<.005,
          f'{len(radii)} comparable opaque hits; max relative radius error={max(radii,default=1):.3g}; max azimuth error={max(phis,default=1):.3g} rad')
    check(results,label+' retarded emission time',bool(delays) and max(delays)<.002,
          f'max relative travel-time error={max(delays,default=1):.3g}')
    check(results,label+' null invariants',bool(invariants) and max(invariants)<.003,
          f'max shader-reported normalized radial/polar residual={max(invariants,default=1):.3g}')
    if boundary:
        check(results,label+' analytic critical shadow brackets',all(boundary),
              f'{sum(boundary)}/{len(boundary)} Schwarzschild/Kerr equatorial capture/escape rays correct at ±10⁻⁴ of critical ξ')
    if escape_angles:
        check(results,label+' escaping celestial direction',max(escape_angles)<.01,
              f'{len(escape_angles)} escaping rays at r=1000 M; max direction error={max(escape_angles):.3g} rad. '
              'Critical propagator checked with identical actual GPU ξ/η; '
              f'camera-constant rounding separately shifts critical direction by up to {max(critical_initial_offsets,default=0):.3g} rad.')
    values=radii+phis+delays
    return math.sqrt(sum(v*v for v in values)/max(1,len(values)))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases',type=Path,default=ROOT/'Tests/physics_cases.json')
    parser.add_argument('--gpu',type=Path)
    parser.add_argument('--gpu-max',type=Path)
    parser.add_argument('--report',type=Path,default=ROOT/'outputs/physics-validation.md')
    parser.add_argument('--reference-json',type=Path,default=ROOT/'work/physics-reference.json')
    args=parser.parse_args()
    start=time.time()
    cases=json.loads(args.cases.read_text())['cases']
    results=[]
    analytic_checks(results,cases)
    reference=reference_cases(results,cases)
    if args.gpu:
        rms=compare_gpu(results,json.loads(args.gpu.read_text()),reference)
        if args.gpu_max:
            tight=compare_gpu(results,json.loads(args.gpu_max.read_text()),reference,'GPU Max Fidelity')
            check(results,'GPU tolerance convergence / float floor',tight<=rms*1.2+1e-6,
                  f'RMS of disk relative-radius, azimuth-radians, and relative-delay errors: '
                  f'Auto(2×10⁻⁶)={rms:.3g}; Max(3×10⁻⁷)={tight:.3g}. '
                  'Individual binary32 errors need not decrease monotonically once roundoff dominates.')
    args.reference_json.parent.mkdir(parents=True,exist_ok=True)
    args.reference_json.write_text(json.dumps(reference,indent=2)+'\n')
    shader=ROOT/'Sources/BlackHoleDesk/ShaderSource.swift'
    digest=hashlib.sha256(shader.read_bytes()).hexdigest() if shader.exists() else 'unavailable'
    failed=sum(not ok for _,ok,_ in results)
    lines=['# Physics validation','',f'{len(results)-failed}/{len(results)} checks passed. Runtime {time.time()-start:.1f} s.','',
           'This report distinguishes analytic/reference tests from actual GPU comparisons. '
           +('Metal diagnostics were supplied and compared with independently integrated binary64 rays.' if args.gpu else 'No GPU diagnostics were supplied; this run does **not** validate the Metal renderer.'),'',
           '| Check | Result | Evidence |','|---|---|---|']
    lines.extend('| '+name+' | '+('PASS' if ok else 'FAIL')+' | '+detail.replace('|','\\|')+' |'
                 for name,ok,detail in results)
    lines += ['', '## Scope and limits','',
              'The reference solves Kerr vacuum null geodesics in Boyer–Lindquist r and θ, '
              'with independent event bisection and binary64 Dormand–Prince integration. '
              'The GPU uses reciprocal radius and cos θ, with binary32 arithmetic for ordinary rays '
              'and two-float compensated radial/azimuth/time arithmetic for ill-conditioned photon whirls. '
              'The observer constants and polar state still use binary32. Tests cover analytic '
              'capture boundaries, conservation, observer geometry, first opaque disk hits, '
              'and past-light-cone travel times. A selected ray suite is regression evidence, '
              'not a global error bound. Near-critical rays, poles and nearly extremal spin '
              'need progressively finer sampling and remain the hardest numerical cases.', '',
              'The CPU reference starts from the exact Float values transmitted through the Metal '
              'uniform/pixel ABI, then computes in binary64. Equatorial near-critical escape rays '
              'use independent quadrature of a factored cubic radial potential; a direct '
              'second-order r integrator also loses useful accuracy after many photon windings. '
              'For that critical propagator comparison, the reference uses the GPU’s exact '
              'represented conserved ξ/η values. Camera-constant mapping error and its amplified '
              'critical endpoint displacement are reported separately, rather than pretending '
              'the camera itself has compensated precision. Pixel integration and convergence '
              'of arbitrarily high-order images remain separate, unproven requirements.', '',
              'The implemented physical model is a stationary Kerr spacetime plus a geometrically thin, '
              'optically thick equatorial disk on circular orbits. It is not a self-consistent '
              'time-dependent magnetized plasma simulation. Disk turbulence, atmosphere, '
              'finite thickness, magnetic fields, radiation feedback, polarization and returning '
              'radiation require additional models and are not validated by these geodesic tests.', '',
              'The observer is locally nonrotating (ZAMO). Moving the viewing position through '
              'the interface does not itself define the four-velocity of an astronaut; physical '
              'aberration from an arbitrary moving observer would need an explicit velocity tetrad.', '',
              'The Planck transfer check establishes the spectral identity only. It does not '
              'validate a display’s color calibration, spectral quadrature or a chosen exposure.', '',
              '## Reproduce','',
              '`python3 Tests/validate_physics.py` runs the independent reference checks.','',
              '`outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --validate-gpu Tests/physics_cases.json outputs/gpu-validation.json` generates actual GPU diagnostics.','',
              '`outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --validate-gpu Tests/physics_cases_max.json outputs/gpu-validation-max.json` generates the tighter Max Fidelity diagnostics.','',
              '`python3 Tests/validate_physics.py --gpu outputs/gpu-validation.json --gpu-max outputs/gpu-validation-max.json` compares Auto and Max Fidelity with the reference.','',
              f'Shader source SHA-256 when this report was produced: `{digest}`.','',
              '## Primary references','',
              '- [James, von Tunzelmann, Franklin & Thorne (2015), DNGR and Interstellar, Appendix A](https://arxiv.org/html/1502.03808): observer tetrad, null geodesics, spherical photon constants and spectral transfer.','',
              '- [Tavlayan & Tekin (2020), Exact Formulas for Spherical Photon Orbits Around Kerr Black Holes](https://arxiv.org/abs/2009.07012): spherical photon structure.','',
              'The DNGR paper explains that the final film altered the appearance of Doppler '
              'shifts and disk brightness. A renderer preserving those physical effects will '
              'show stronger brightness asymmetry than the film.','']
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text('\n'.join(lines))
    return 1 if failed else 0


if __name__=='__main__':
    sys.exit(main())
