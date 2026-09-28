import Metal
import Foundation

/// Display-only photographic response. Linear HDR is never written back into
/// the geodesic/spectral history. Glare is extracted from resolved highlights,
/// so it follows the calculated disk and lensed arcs rather than painting a
/// ring or silhouette over the transport image.
final class CameraResponse {
    private let device: MTLDevice
    private let downsample: MTLComputePipelineState
    private let response: MTLComputePipelineState
    private var levels: [MTLTexture] = []
    private var output: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        downsample = try device.makeComputePipelineState(function: library.makeFunction(name: "cameraDownsample")!)
        response = try device.makeComputePipelineState(function: library.makeFunction(name: "cameraResponse")!)
    }

    func encode(command: MTLCommandBuffer, source: MTLTexture, settings: RenderSettings) -> MTLTexture {
        if output?.width != source.width || output?.height != source.height {
            func texture(_ width: Int, _ height: Int) -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
                return device.makeTexture(descriptor: d)!
            }
            output = texture(source.width, source.height)
            levels = (1...7).map { texture(max(1,source.width >> $0),max(1,source.height >> $0)) }
        }
        let radiant = settings.appearance == .radiant && !settings.diagnosticMode
        if radiant && settings.glowStrength > 0 {
            for i in levels.indices {
                let e = command.makeComputeCommandEncoder()!
                e.label = "Lens PSF level \(i)"
                e.setComputePipelineState(downsample)
                e.setTexture(i == 0 ? source : levels[i-1], index: 0)
                e.setTexture(levels[i], index: 1)
                dispatch(e, pipeline: downsample, texture: levels[i]); e.endEncoding()
            }
        }
        let e = command.makeComputeCommandEncoder()!
        e.label = radiant ? "Radiant cinematic camera response" : "Scientific SDR response"
        e.setComputePipelineState(response); e.setTexture(source, index: 0)
        // Every argument remains bound, including when no glare passes execute.
        e.setTexture(radiant && settings.glowStrength > 0 ? levels[2] : source, index: 1)
        e.setTexture(radiant && settings.glowStrength > 0 ? levels[4] : source, index: 2)
        e.setTexture(radiant && settings.glowStrength > 0 ? levels[6] : source, index: 3)
        e.setTexture(output!, index: 4)
        var values = SIMD4<Float>(0.03 * powf(2,settings.exposureEV), settings.glowStrength, radiant ? 1 : 0, settings.diagnosticMode ? 1 : 0)
        e.setBytes(&values, length: 16, index: 0)
        dispatch(e, pipeline: response, texture: output!); e.endEncoding()
        return output!
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, texture: MTLTexture) {
        encoder.dispatchThreads(.init(width:texture.width,height:texture.height,depth:1), threadsPerThreadgroup:.init(width:pipeline.threadExecutionWidth,height:4,depth:1))
    }

    static let metalSource = #"""
    // Multiscale convolution of linear radiance. The 3x3 binomial low-pass
    // has unit weight; bilinear reconstruction forms broad soft PSF lobes.
    kernel void cameraDownsample(texture2d<float,access::sample> source [[texture(0)]],
                                 texture2d<float,access::write> output [[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 uv=(float2(gid)+.5)/float2(output.get_width(),output.get_height());
        float2 texel=1./float2(source.get_width(),source.get_height());
        float3 c=0.;
        for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
            float weight=(x==0 ? 2. : 1.)*(y==0 ? 2. : 1.)/16.;
            c+=max(float3(0.),source.sample(s,uv+float2(x,y)*texel).rgb)*weight;
        }
        output.write(float4(min(c,float3(60000.)),1.),gid);
    }
    // This is a display transform, rather than an artistic change to the
    // radiance field. It is deliberately luminance-based: the relative RGB
    // spectrum calculated by the disk shader survives the filmic toe and
    // shoulder instead of being independently re-coloured per channel.
    float3 photographicMap(float3 color) {
        float luminance=dot(color,float3(.2126,.7152,.0722));
        if(luminance<=1.e-10) return float3(0.);
        // Narkowicz 2016 filmic fit (CC0), adapted to luminance, not full ACES.
        // A bounded filmic toe/shoulder applied to luminance, not separately
        // to RGB. This preserves chromaticity until an SDR gamut boundary.
        float x=luminance*1.35;
        float mapped=clamp((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14),0.,.995);
        float3 c=color*(mapped/luminance);
        float peak=max(c.r,max(c.g,c.b));
        if(peak>1.) c=mix(float3(mapped),c,clamp((1.-mapped)/max(peak-mapped,1.e-6),0.,1.));
        return clamp(c,0.,1.);
    }
    // A deliberately small, highlight-derived lens artifact. This has no
    // scene-space notion of a black hole, disk radius, or image centre: it can
    // only originate in the actual resolved HDR image. A bright lensed arc,
    // not an invented circular overlay, is therefore responsible for every
    // soft halo and aperture streak below. Constant fields cancel exactly.
    float3 cinematicGlare(float2 uv, float3 sourceColor, float3 smallBlur,
                          texture2d<float,access::sample> medium,
                          texture2d<float,access::sample> wide,
                          sampler s, float strength) {
        float3 local=max(float3(0.),smallBlur-sourceColor);
        float3 mediumCenter=max(float3(0.),medium.sample(s,uv).rgb);
        float3 wideCenter=max(float3(0.),wide.sample(s,uv).rgb);
        float2 mediumTexel=1./float2(medium.get_width(),medium.get_height());

        // A restrained anamorphic aperture response. It is a difference from
        // the local blur, so uniform fields, black frames, and Scientific mode
        // gain no artifact. Offsets are measured in an already blurred HDR
        // level, preventing a hard, synthetic line from being painted over the
        // calculated image.
        float3 lateral=(medium.sample(s,uv+float2(7.,0.)*mediumTexel).rgb+
                        medium.sample(s,uv-float2(7.,0.)*mediumTexel).rgb)*.20+
                       (medium.sample(s,uv+float2(19.,0.)*mediumTexel).rgb+
                        medium.sample(s,uv-float2(19.,0.)*mediumTexel).rgb)*.075;
        float3 streak=max(float3(0.),lateral-.55*mediumCenter);
        // Difference-of-scales keeps broad halation tied to local image
        // structure. A fully uniform HDR field has zero response here too.
        float3 halo=max(float3(0.),wideCenter-mediumCenter);

        // Tight glare retains its resolved hue. The broad lobe has a barely
        // perceptible warm/cool split characteristic of photographed high
        // intensity light; it is a camera response, never a new emitter.
        float haloL=dot(halo,float3(.2126,.7152,.0722));
        float3 splitHalo=haloL*float3(.94,1.0,1.055);
        float flareL=dot(max(local,mediumCenter),float3(.2126,.7152,.0722));
        float highlightGate=smoothstep(.18,1.4,flareL);
        return strength*highlightGate*(.24*local+.115*streak+.045*mix(halo,splitHalo,.38));
    }
    kernel void cameraResponse(texture2d<float,access::read> source [[texture(0)]],
                               texture2d<float,access::sample> small [[texture(1)]],
                               texture2d<float,access::sample> medium [[texture(2)]],
                               texture2d<float,access::sample> wide [[texture(3)]],
                               texture2d<float,access::write> output [[texture(4)]],
                               constant float4& p [[buffer(0)]],uint2 gid [[thread_position_in_grid]]) {
        if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float2 uv=(float2(gid)+.5)/float2(output.get_width(),output.get_height());
        float4 sourcePixel=source.read(gid);
        if(p.w>0. && sourcePixel.a<0.) { output.write(float4(1.,0.,1.,1.),gid); return; }
        float3 c=max(float3(0.),sourcePixel.rgb);
        if(p.z>.5) {
            float3 spread=.50*small.sample(s,uv).rgb+.32*medium.sample(s,uv).rgb+.18*wide.sample(s,uv).rgb;
            float glareStrength=clamp(p.y,0.,.65);
            // The resolved source remains the anchor. Bloom is additive and
            // highlight-derived rather than a whole-frame blur, retaining the
            // sharp mathematical lensing structure beneath the camera layer.
            c+=cinematicGlare(uv,c,spread,medium,wide,s,glareStrength);
            c=photographicMap(c*p.x);
        } else {
            c*=p.x;
            c=c/(1.+max(c.r,max(c.g,c.b)));
        }
        output.write(float4(c,1.),gid);
    }
    fragment float4 cameraPresentFragment(VOut in [[stage_in]],texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        return float4(image.sample(s,in.uv).rgb,1.);
    }
    """#
}
