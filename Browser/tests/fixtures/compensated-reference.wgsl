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
