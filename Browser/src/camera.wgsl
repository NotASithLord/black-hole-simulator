// Display-only port of the native photographic response. Its inputs are the
// resolved HDR image; none of these passes feed back into Kerr transport.
struct CameraParameters {
    response: vec4<f32>, // exposure, glare strength, radiant, diagnostic
    presentation: vec4<f32>, // explicit sRGB encoding, reserved
}

@group(0) @binding(0) var linearSampler: sampler;
@group(0) @binding(1) var sourceImage: texture_2d<f32>;
@group(0) @binding(2) var smallImage: texture_2d<f32>;
@group(0) @binding(3) var mediumImage: texture_2d<f32>;
@group(0) @binding(4) var wideImage: texture_2d<f32>;
@group(0) @binding(5) var<uniform> camera: CameraParameters;
@group(0) @binding(6) var downsampleOutput: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn cameraDownsample(@builtin(global_invocation_id) gid: vec3<u32>) {
    let size = textureDimensions(downsampleOutput);
    if (gid.x >= size.x || gid.y >= size.y) { return; }
    let uv = (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(size);
    let texel = 1.0 / vec2<f32>(textureDimensions(sourceImage));
    var color = vec3<f32>(0.0);
    // Unit-weight binomial filter. Explicit LOD is required in compute.
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let weight = select(1.0, 2.0, x == 0) * select(1.0, 2.0, y == 0) / 16.0;
            let sampleColor = textureSampleLevel(sourceImage, linearSampler,
                uv + vec2<f32>(f32(x), f32(y)) * texel, 0.0).rgb;
            color += max(vec3<f32>(0.0), sampleColor) * weight;
        }
    }
    textureStore(downsampleOutput, gid.xy, vec4<f32>(min(color, vec3<f32>(60000.0)), 1.0));
}

fn photographicMap(color: vec3<f32>) -> vec3<f32> {
    let luminance = dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
    if (luminance <= 1e-10) { return vec3<f32>(0.0); }
    // Narkowicz's CC0 filmic fit applied to luminance, as in the native app.
    let x = luminance * 1.35;
    let mapped = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 0.995);
    var colorOut = color * (mapped / luminance);
    let peak = max(colorOut.r, max(colorOut.g, colorOut.b));
    if (peak > 1.0) {
        colorOut = mix(vec3<f32>(mapped), colorOut,
            clamp((1.0 - mapped) / max(peak - mapped, 1e-6), 0.0, 1.0));
    }
    return clamp(colorOut, vec3<f32>(0.0), vec3<f32>(1.0));
}

fn cinematicGlare(uv: vec2<f32>, sourceColor: vec3<f32>, smallBlur: vec3<f32>,
                  mediumSample: vec3<f32>, wideSample: vec3<f32>, strength: f32) -> vec3<f32> {
    let local = max(vec3<f32>(0.0), smallBlur - sourceColor);
    let mediumCenter = max(vec3<f32>(0.0), mediumSample);
    let wideCenter = max(vec3<f32>(0.0), wideSample);
    let mediumTexel = 1.0 / vec2<f32>(textureDimensions(mediumImage));
    let offsetNear = vec2<f32>(7.0, 0.0) * mediumTexel;
    let offsetFar = vec2<f32>(19.0, 0.0) * mediumTexel;
    let lateral = (textureSampleLevel(mediumImage, linearSampler, uv + offsetNear, 0.0).rgb
                 + textureSampleLevel(mediumImage, linearSampler, uv - offsetNear, 0.0).rgb) * 0.20
                + (textureSampleLevel(mediumImage, linearSampler, uv + offsetFar, 0.0).rgb
                 + textureSampleLevel(mediumImage, linearSampler, uv - offsetFar, 0.0).rgb) * 0.075;
    let streak = max(vec3<f32>(0.0), lateral - 0.55 * mediumCenter);
    let halo = max(vec3<f32>(0.0), wideCenter - mediumCenter);
    let haloLuminance = dot(halo, vec3<f32>(0.2126, 0.7152, 0.0722));
    let splitHalo = haloLuminance * vec3<f32>(0.94, 1.0, 1.055);
    let flareLuminance = dot(max(local, mediumCenter), vec3<f32>(0.2126, 0.7152, 0.0722));
    let highlightGate = smoothstep(0.18, 1.4, flareLuminance);
    return strength * highlightGate * (0.24 * local + 0.115 * streak + 0.045 * mix(halo, splitHalo, 0.38));
}

struct FullscreenVertex {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn cameraVertex(@builtin(vertex_index) index: u32) -> FullscreenVertex {
    let positions = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    let position = positions[index];
    var vertex: FullscreenVertex;
    vertex.position = vec4<f32>(position, 0.0, 1.0);
    vertex.uv = vec2<f32>(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
    return vertex;
}

fn linearToSRGB(color: vec3<f32>) -> vec3<f32> {
    let low = color * 12.92;
    let high = 1.055 * pow(max(color, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(high, low, color <= vec3<f32>(0.0031308));
}

@fragment
fn cameraFragment(vertex: FullscreenVertex) -> @location(0) vec4<f32> {
    let pixel = textureSampleLevel(sourceImage, linearSampler, vertex.uv, 0.0);
    if (camera.response.w > 0.0 && pixel.a < 0.0) { return vec4<f32>(1.0, 0.0, 1.0, 1.0); }
    var color = max(vec3<f32>(0.0), pixel.rgb);
    if (camera.response.z > 0.5) {
        if (camera.response.y > 0.0) {
            // Reuse the exact same samples for the PSF mixture and halo.
            let smallSample = textureSampleLevel(smallImage, linearSampler, vertex.uv, 0.0).rgb;
            let mediumSample = textureSampleLevel(mediumImage, linearSampler, vertex.uv, 0.0).rgb;
            let wideSample = textureSampleLevel(wideImage, linearSampler, vertex.uv, 0.0).rgb;
            let spread = 0.50 * smallSample + 0.32 * mediumSample + 0.18 * wideSample;
            color += cinematicGlare(vertex.uv, color, spread, mediumSample, wideSample, clamp(camera.response.y, 0.0, 0.65));
        }
        color = photographicMap(color * camera.response.x);
    } else {
        color *= camera.response.x;
        color /= 1.0 + max(color.r, max(color.g, color.b));
    }
    if (camera.presentation.x > 0.5) { color = linearToSRGB(color); }
    return vec4<f32>(color, 1.0);
}
