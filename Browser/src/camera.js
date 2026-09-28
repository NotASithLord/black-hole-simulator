/** GPU photographic response; the HDR transport image is strictly read-only. */
export class CameraResponse {
  constructor(device, format) {
    this.device = device;
    this.format = format;
    this.levels = [];
    this.levelViews = [];
    this.downsampleBindings = [];
    this.sharedDownsampleBindings = [];
    this.width = 0;
    this.height = 0;
    this.sourceTexture = null;
    this.activeGlare = null;
    this.sourceBindings = new WeakMap();
    this.uniformValues = new Float32Array(8);
    this.uploadedUniforms = new Float32Array(8);
    this.uniformDirty = true;
  }

  async init() {
    const response = await fetch(new URL('./camera.wgsl', import.meta.url));
    if (!response.ok) throw new Error(`Unable to load camera shader: ${response.status}`);
    const module = this.device.createShaderModule({ label: 'Photographic camera', code: await response.text() });
    const compilation = await module.getCompilationInfo();
    const errors = compilation.messages.filter(message => message.type === 'error');
    if (errors.length) {
      throw new Error(errors.map(message => `Camera shader ${message.lineNum}:${message.linePos}: ${message.message}`).join('\n'));
    }
    [this.downsample, this.presentation] = await Promise.all([
      this.device.createComputePipelineAsync({
        label: 'Unit-weight glare pyramid', layout: 'auto',
        compute: { module, entryPoint: 'cameraDownsample' },
      }),
      this.device.createRenderPipelineAsync({
        label: 'Photographic response and presentation', layout: 'auto',
        vertex: { module, entryPoint: 'cameraVertex' },
        fragment: { module, entryPoint: 'cameraFragment', targets: [{ format: this.format }] },
        primitive: { topology: 'triangle-list' },
      }),
    ]);
    this.downsampleLayout = this.downsample.getBindGroupLayout(0);
    this.presentationLayout = this.presentation.getBindGroupLayout(0);
    this.sampler = this.device.createSampler({
      label: 'Camera linear clamp', magFilter: 'linear', minFilter: 'linear',
      addressModeU: 'clamp-to-edge', addressModeV: 'clamp-to-edge',
    });
    this.uniformBuffer = this.device.createBuffer({
      label: 'Camera settings', size: this.uniformValues.byteLength,
      usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    });
    this.uniformDirty = true;
    // The fragment pipeline has three statically declared glare bindings even
    // when its uniform branch skips them. One tiny, zero-initialized texture
    // supplies valid resources without allocating a frame-sized pyramid.
    this.emptyGlare = this.device.createTexture({
      label: 'Inactive camera glare', size: [1, 1], format: 'rgba16float',
      usage: GPUTextureUsage.TEXTURE_BINDING,
    });
    this.emptyGlareView = this.emptyGlare.createView();
  }

  resize(width, height) {
    width = Math.max(1, Math.floor(width));
    height = Math.max(1, Math.floor(height));
    if (width === this.width && height === this.height) return;
    for (const level of this.levels) level.destroy();
    this.width = width;
    this.height = height;
    this.levels = [];
    this.levelViews = [];
    this.sourceTexture = null;
    this.activeGlare = null;
    this.sourceBindings = new WeakMap();
    this.downsampleBindings = [];
    this.sharedDownsampleBindings = [];
    this.presentationBindings = null;
  }

  _ensurePyramid() {
    if (this.levels.length) return;
    for (let index = 0; index < 7; index++) {
      const width = Math.max(1, this.width >> (index + 1));
      const height = Math.max(1, this.height >> (index + 1));
      this.levels.push(this.device.createTexture({
        label: `Camera glare level ${index + 1}`, size: [width, height], format: 'rgba16float',
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING,
      }));
      // Once both dimensions are one, the unit-weight clamp-to-edge filter
      // leaves this nonnegative, <=60000 half-float pixel exactly unchanged.
      // Reuse its view for all later logical levels instead of copying it.
      if (width === 1 && height === 1) break;
    }
    const views = this.levels.map(level => level.createView());
    this.levelViews = Array.from({ length: 7 }, (_, index) => views[Math.min(index, views.length - 1)]);
    this.sharedDownsampleBindings = new Array(this.levels.length);
    for (let index = 1; index < this.levels.length; index++) {
      this.sharedDownsampleBindings[index] = this._downsampleBinding(this.levelViews[index - 1], this.levelViews[index], index);
    }
  }

  _downsampleBinding(input, output, index) {
    return this.device.createBindGroup({
      label: `Camera pyramid bindings ${index + 1}`, layout: this.downsampleLayout,
      entries: [
        { binding: 0, resource: this.sampler },
        { binding: 1, resource: input },
        { binding: 6, resource: output },
      ],
    });
  }

  _bindSource(sourceTexture, glare) {
    if (sourceTexture === this.sourceTexture && glare === this.activeGlare) return;
    this.sourceTexture = sourceTexture;
    this.activeGlare = glare;
    let cached = this.sourceBindings.get(sourceTexture);
    if (!cached) {
      cached = { sourceView: sourceTexture.createView() };
      this.sourceBindings.set(sourceTexture, cached);
    }
    const ready = glare ? cached.glare : cached.direct;
    if (ready) {
      this.downsampleBindings = glare ? cached.downsample : [];
      this.presentationBindings = ready;
      return;
    }
    const presentationBinding = views => this.device.createBindGroup({
      label: glare ? 'Photographic glare bindings' : 'Photographic direct bindings',
      layout: this.presentationLayout,
      entries: [
        { binding: 0, resource: this.sampler },
        { binding: 1, resource: cached.sourceView },
        { binding: 2, resource: views[0] },
        { binding: 3, resource: views[1] },
        { binding: 4, resource: views[2] },
        { binding: 5, resource: { buffer: this.uniformBuffer } },
      ],
    });
    if (glare) {
      if (!cached.glare) {
        cached.downsample = this.sharedDownsampleBindings.slice();
        cached.downsample[0] = this._downsampleBinding(cached.sourceView, this.levelViews[0], 0);
        cached.glare = presentationBinding([this.levelViews[2], this.levelViews[4], this.levelViews[6]]);
      }
      this.downsampleBindings = cached.downsample;
      this.presentationBindings = cached.glare;
    } else {
      cached.direct ??= presentationBinding([this.emptyGlareView, this.emptyGlareView, this.emptyGlareView]);
      this.downsampleBindings = [];
      this.presentationBindings = cached.direct;
    }
  }

  /** Encode into an existing frame; caller owns encoder submission and canvas sizing. */
  encode(encoder, sourceTexture, canvasView, settings = {}, timestampWrites) {
    if (!this.presentation) throw new Error('CameraResponse.init() must complete before encode().');
    this.resize(sourceTexture.width, sourceTexture.height);
    const radiant = settings.appearance !== 'scientific' && !settings.diagnosticMode;
    const glow = Math.min(0.65, Math.max(0, settings.glowStrength ?? 0));
    const glare = radiant && glow > 0;
    if (glare) this._ensurePyramid();
    this._bindSource(sourceTexture, glare);
    if (glare) {
      // Each compute dispatch is its own WebGPU usage scope. The browser
      // inserts storage→sample barriers between these dependent dispatches;
      // seven separate pass encoders and pipeline bindings are unnecessary.
      // https://www.w3.org/TR/webgpu/#programming-model-resource-usages
      const pass = encoder.beginComputePass({ label: 'Camera glare pyramid' });
      pass.setPipeline(this.downsample);
      for (let index = 0; index < this.levels.length; index++) {
        pass.setBindGroup(0, this.downsampleBindings[index]);
        pass.dispatchWorkgroups(Math.ceil(this.levels[index].width / 8), Math.ceil(this.levels[index].height / 8));
      }
      pass.end();
    }
    this.uniformValues[0] = 0.03 * 2 ** Math.min(20, Math.max(-20, settings.exposureEV ?? 0));
    this.uniformValues[1] = glare ? glow : 0;
    this.uniformValues[2] = radiant ? 1 : 0;
    this.uniformValues[3] = settings.diagnosticMode ? 1 : 0;
    // A normal unorm WebGPU canvas needs explicit encoding; an sRGB render
    // attachment performs this conversion itself. Keep that distinction here.
    this.uniformValues[4] = this.format.endsWith('-srgb') ? 0 : 1;
    let changed = this.uniformDirty;
    for (let index = 0; !changed && index < this.uniformValues.length; index++) {
      changed = this.uniformValues[index] !== this.uploadedUniforms[index];
    }
    if (changed) {
      this.device.queue.writeBuffer(this.uniformBuffer, 0, this.uniformValues);
      this.uploadedUniforms.set(this.uniformValues);
      this.uniformDirty = false;
    }
    const pass = encoder.beginRenderPass({
      label: radiant ? 'Cinematic camera' : 'Scientific display',
      colorAttachments: [{ view: canvasView, loadOp: 'clear', storeOp: 'store', clearValue: { r: 0, g: 0, b: 0, a: 1 } }],
      ...(timestampWrites ? { timestampWrites } : {}),
    });
    pass.setPipeline(this.presentation);
    pass.setBindGroup(0, this.presentationBindings);
    pass.draw(3);
    pass.end();
  }

  destroy() {
    for (const level of this.levels) level.destroy();
    this.uniformBuffer?.destroy();
    this.emptyGlare?.destroy();
    this.levels = [];
    this.levelViews = [];
    this.downsampleBindings = [];
    this.sharedDownsampleBindings = [];
    this.sourceTexture = null;
    this.activeGlare = null;
    this.sourceBindings = new WeakMap();
    this.presentationBindings = null;
    this.presentation = null;
    this.downsample = null;
    this.downsampleLayout = null;
    this.presentationLayout = null;
    this.emptyGlare = null;
    this.emptyGlareView = null;
    this.width = this.height = 0;
  }
}
