// Frozen pre-hoist material expression, for CPU source-refactor comparisons.
// The noise callback is shared with the current implementation in the test.
fn materialTransmissionReference(r: f32,phase: f32,emittedTime: f32,dye: f32,footprint: f32,u: Uniforms) -> f32 {
    let lr=log(r); let turns=phase/(2.0*PI); let f=max(footprint,0.0); let dyeValue=clamp(dye,0.0,1.0);
    let warp=materialNoise(vec2<f32>(turns*4.0,lr*5.0),4);
    let n0=materialNoise(vec2<f32>(turns*12.0+3.0*warp,lr*48.0+4.0*dyeValue),12);
    let n1=materialNoise(vec2<f32>(turns*24.0+5.0*warp,lr*103.0+7.0*dyeValue),24);
    let n2=materialNoise(vec2<f32>(turns*48.0+7.0*warp,lr*221.0+11.0*dyeValue),48);
    let r32=r*sqrt(r); let omega=1.0/(r32+clamp(u.spin,0.0,0.998));
    let winding=max(0.0,abs(1.5*r32*omega*omega*emittedTime)/(2.0*PI)-8.0);
    let ribbons=0.5+0.56*exp(-(48.0+12.0*winding)*f)*(n0-0.5)+0.30*exp(-(103.0+24.0*winding)*f)*(n1-0.5)+0.14*exp(-(221.0+48.0*winding)*f)*(n2-0.5);
    let eddies=materialNoise(vec2<f32>(turns*7.0,lr*12.0),7)-0.5;
    let broad=0.12*exp(-(8.0+4.0*winding)*f)*(warp-0.5);
    let structure=smoothstep(0.27,0.76,ribbons+0.16*exp(-(18.0+7.0*winding)*f)*eddies+broad+0.24*(dyeValue-0.5));
    let material=0.06+0.94*pow(structure,1.4);
    let radialFraction=(lr-log(u.diskInnerRadius))/max(log(u.diskOuterRadius/u.diskInnerRadius),1.0e-6);
    let outerTaper=1.0-smoothstep(0.87,1.0,radialFraction);
    return mix(1.0,material*outerTaper,clamp(u.materialStrength,0.0,1.0));
}
