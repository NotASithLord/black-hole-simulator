#include <math.h>
#include <stdint.h>
#include "cie1931.h"

// CPU model ported from the native Swift implementation. Double precision is
// retained through quadrature/color integration; only final GPU tables are f32.
// Fixed storage avoids allocators, memory growth and JS/WASM copies per frame.
#define API __attribute__((visibility("default")))
#define RADIAL_COUNT 4096
#define SPECTRAL_COUNT 2048
static const double PI = 3.1415926535897932384626433832795;
static const double G = 6.67430e-11, C = 299792458.0, MSUN = 1.98847e30;
static const double YEAR = 31557600.0, SIGMA = 5.670374419e-8;
static const double H = 6.62607015e-34, K = 1.380649e-23;
static const double MP = 1.67262192369e-27, THOMSON = 6.6524587321e-29;
static float radial[RADIAL_COUNT][4] __attribute__((aligned(16)));
static float spectral[SPECTRAL_COUNT][4] __attribute__((aligned(16)));
static double metadata[11] __attribute__((aligned(16)));
static double source_seconds;
// Geometry and spectral data are intrinsic to their models, not animation time.
static double radial_factor[RADIAL_COUNT] __attribute__((aligned(16)));
static double cached_spin, cached_outer, cached_mass, cached_mdot;
static int geometry_ready, thermal_ready, spectrum_ready;
static double spectral_exponent[471];
static double spectral_weight[471][3] __attribute__((aligned(16)));

typedef struct { double energy, angular_momentum, omega, ut, dl, domega; } Orbit;
static double clamp(double v, double lo, double hi) { return fmin(hi, fmax(lo, v)); }

API double isco(double spin) {
    if (!isfinite(spin)) return NAN;
    const double a = clamp(spin, -0.9999, 0.9999);
    const double z1 = 1 + cbrt(1-a*a)*(cbrt(1+a)+cbrt(1-a));
    const double z2 = sqrt(3*a*a+z1*z1);
    return 3+z2-(a<0 ? -1 : 1)*sqrt(fmax(0,(3-z1)*(3+z1+2*z2)));
}

static Orbit orbit(double r, double a) {
    const double root=sqrt(r), r32=r*root, core=r32-3*root+2*a;
    const double denominator=sqrt(r*root)*sqrt(core);
    const double l=(r*r-2*a*root+a*a)/denominator;
    const double omega=1/(r32+a);
    const double dlog=0.75/r+0.75*(root-1/root)/core;
    return (Orbit){(r32-2*root+a)/denominator,l,omega,(r32+a)/denominator,
                   (2*r-a/root)/denominator-l*dlog,-1.5*root*omega*omega};
}

static double flux_integrand(double r, double a) {
    const double root=sqrt(r), r32=r*root, core=r32-3*root+2*a;
    const double numerator_l=r*r-2*a*root+a*a;
    const double dlog=0.75/r+0.75*(root-1/root)/core;
    // (E-ΩL)L,r = L,r/u^t. The common r^(3/4)*sqrt(core)
    // normalization cancels analytically; no approximation to the quadrature.
    return (2*r-a/root-numerator_l*dlog)/(r32+a);
}

static double flux_integral(double lo, double hi, double spin) {
    static const double nodes[4]={0.1834346424956498,0.5255324099163290,0.7966664774136267,0.9602898564975363};
    static const double weights[4]={0.3626837833783620,0.3137066458778873,0.2223810344533745,0.1012285362903763};
    const double mid=0.5*(lo+hi), width=0.5*(hi-lo);
    double sum=0;
    for(int i=0;i<4;i++) {
        sum+=weights[i]*(flux_integrand(mid-width*nodes[i],spin)+flux_integrand(mid+width*nodes[i],spin));
    }
    return sum*width;
}

API int radial_ptr(void) { return (int)(uintptr_t)radial; }
API int spectral_ptr(void) { return (int)(uintptr_t)spectral; }
API int metadata_ptr(void) { return (int)(uintptr_t)metadata; }
API int radial_count(void) { return RADIAL_COUNT; }
API int spectral_count(void) { return SPECTRAL_COUNT; }
API int abi_version(void) { return 1; }

// Returns 0 for success, 1 for rejected input. Rejection preserves prior tables.
API int init_model(double spin, double mass_solar, double mdot_solar_year,
                   double outer, double thickness_multiplier) {
    if(!isfinite(spin)||fabs(spin)>0.9999||!isfinite(mass_solar)||mass_solar<=0||
       !isfinite(mdot_solar_year)||mdot_solar_year<0||!isfinite(outer)||
       !isfinite(thickness_multiplier)||thickness_multiplier<0) return 1;
    const int same_spin=geometry_ready && spin==cached_spin;
    const double inner=same_spin ? metadata[0] : isco(spin);
    if(outer<=inner) return 1;
    const double rg=G*mass_solar*MSUN/(C*C), tg=rg/C;
    const double mdot=mdot_solar_year*MSUN/YEAR;
    const double physical_scale=mdot*C*C/(4*PI*rg*rg);
    const double efficiency=same_spin ? metadata[8] : 1-orbit(inner,spin).energy;
    const double eddington=4*PI*G*mass_solar*MSUN*MP*C/THOMSON;
    const double ratio=efficiency*mdot*C*C/eddington;
    const double nominal_height=3*ratio/efficiency*thickness_multiplier;
    const double height=fmin(nominal_height,0.20*27*inner/(4*1.08));
    const double logmin=log(inner), step=(log(outer)-logmin)/(RADIAL_COUNT-1);
    const int changed_geometry=!same_spin || outer!=cached_outer;
    if(changed_geometry) {
        double integral=0, previous=inner;
        for(int i=0;i<RADIAL_COUNT;i++) {
            const double radius=exp(logmin+i*step);
            if(i) integral+=flux_integral(previous,radius,spin);
            const Orbit o=orbit(radius,spin);
            radial_factor[i]=i ? -o.domega*o.ut*o.ut*fmax(0,integral)/radius : 0;
            radial[i][2]=(float)o.omega; radial[i][3]=(float)o.ut;
            previous=radius;
        }
        cached_spin=spin; cached_outer=outer; geometry_ready=1;
    }
    double peak=metadata[4];
    if(changed_geometry || !thermal_ready || mass_solar!=cached_mass || mdot_solar_year!=cached_mdot) {
        peak=0;
        for(int i=0;i<RADIAL_COUNT;i++) {
            const double flux=physical_scale*radial_factor[i];
            const double temperature=sqrt(sqrt(flux/SIGMA));
            radial[i][0]=(float)temperature; radial[i][1]=(float)flux;
            peak=fmax(peak,temperature);
        }
        cached_mass=mass_solar; cached_mdot=mdot_solar_year; thermal_ready=1;
    }
    metadata[0]=inner; metadata[1]=outer; metadata[2]=logmin; metadata[3]=step;
    metadata[4]=peak; metadata[7]=tg; metadata[8]=efficiency;
    metadata[9]=ratio; metadata[10]=height;
    return 0;
}

static void xyz(double temperature, double out[3]) {
    out[0]=out[1]=out[2]=0;
    const double inverse_temperature=1/temperature;
    for(int i=0;i<471;i++) {
        const double exponent=spectral_exponent[i]*inverse_temperature;
        if(exponent>=700) continue;
        const double scale=1/expm1(exponent);
        for(int j=0;j<3;j++) out[j]+=spectral_weight[i][j]*scale;
    }
}

API int init_spectrum(void) {
    if(spectrum_ready) return 0;
    // All wavelength, observer and trapezoid weights are independent of T.
    // Evaluate them once; retain libm expm1 and all 471 official CIE samples.
    for(int i=0;i<471;i++) {
        const double wavelength=cie1931[i][0]*1e-9, l2=wavelength*wavelength;
        spectral_exponent[i]=H*C/(wavelength*K);
        const double weight=2*H*C*C/(l2*l2*wavelength)*1e-9*683*((i==0||i==470) ? 0.5 : 1);
        for(int j=0;j<3;j++) spectral_weight[i][j]=cie1931[i][j+1]*weight;
    }
    const double logmin=log(300.0), step=(log(10000000.0)-logmin)/(SPECTRAL_COUNT-1);
    double reference[3]; xyz(10000,reference);
    for(int i=0;i<SPECTRAL_COUNT;i++) {
        double p[3]; xyz(exp(logmin+i*step),p);
        const double x=p[0]/reference[1], y=p[1]/reference[1], z=p[2]/reference[1];
        spectral[i][0]=(float)(3.2404542*x-1.5371385*y-0.4985314*z);
        spectral[i][1]=(float)(-0.9692660*x+1.8760108*y+0.0415560*z);
        spectral[i][2]=(float)(0.0556434*x-0.2040259*y+1.0572252*z);
        spectral[i][3]=(float)y;
    }
    metadata[5]=logmin; metadata[6]=step;
    spectrum_ready=1;
    return 0;
}

API double orbital_period(double radius, double spin, double mass_solar) {
    if(!isfinite(radius)||radius<=0||!isfinite(spin)||fabs(spin)>=1||
       !isfinite(mass_solar)||mass_solar<=0) return 0;
    const double denominator=radius*sqrt(radius)+spin;
    return denominator>0 ? 2*PI*(G*mass_solar*MSUN/(C*C*C))*denominator : 0;
}

API double advance_clock(double elapsed, double rate, int active) {
    if(active&&isfinite(elapsed)&&elapsed>=0&&isfinite(rate)&&rate>=0) {
        const double next=source_seconds+elapsed*rate;
        if(isfinite(next)) source_seconds=next;
    }
    return source_seconds;
}
API double clock_seconds(void) { return source_seconds; }
API void reset_clock(void) { source_seconds=0; }

// A damped pixel-budget controller. Host passes measured GPU time when available,
// otherwise submission throughput; camera and cached shading use separate costs.
API double adaptive_scale(double current, double measured_ms, double budget_ms,
                          double minimum, double maximum) {
    if(!isfinite(current)||!isfinite(minimum)||!isfinite(maximum)||minimum<=0||maximum<minimum) return current;
    if(!isfinite(measured_ms)||measured_ms<=0||!isfinite(budget_ms)||budget_ms<=0) return clamp(current,minimum,maximum);
    const double ratio=budget_ms/measured_ms;
    if(ratio>=0.88&&ratio<=1.12) return clamp(current,minimum,maximum);
    const double target=current*sqrt(ratio);
    const double next=current+0.20*(target-current);
    return clamp(clamp(next,current*0.90,current*1.04),minimum,maximum);
}
