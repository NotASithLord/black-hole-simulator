enum DiagnosticsSource {
    static let code = #"""
    #include <metal_stdlib>
    using namespace metal;
    kernel void diagnoseFrame(texture2d<float,access::read> frame [[texture(0)]],
                              device atomic_uint* counts [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
        if(p.x>=frame.get_width() || p.y>=frame.get_height()) return;
        float4 value=frame.read(p);
        if(value.a<0.) atomic_fetch_add_explicit(&counts[0],1u,memory_order_relaxed);
        if(!all(isfinite(value))) atomic_fetch_add_explicit(&counts[1],1u,memory_order_relaxed);
    }
    """#
}
