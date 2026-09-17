/*
 * PyShader live preview for MkDocs.
 *
 * Every `.pyshader` element the fences emit gets a WebGPU canvas. The Python
 * source goes through two wasm modules in the browser: PyShader (Swift, WASI)
 * compiles it to SPIR-V, naga (Rust) turns that into WGSL, which the browser
 * takes. Compute-target shaders write a storage texture that is blitted to
 * the canvas; graphics-target ones draw straight into it.
 *
 * `pyshader-edit` blocks put a Monaco editor next to the canvas and recompile
 * on every change.
 */
(() => {
  "use strict";

  // The plugin writes `window.PyShaderConfig` into every page; the fallbacks
  // derive the same paths from this script's own URL.
  const script = document.currentScript;
  const scriptUrl = new URL(script ? script.src : "assets/pyshader/pyshader-preview.js", document.baseURI);
  const config = Object.assign(
    {
      assets: new URL(".", scriptUrl).href,
      siteRoot: new URL("../../", scriptUrl).href,
      monaco: "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs",
    },
    window.PyShaderConfig || {}
  );
  config.assets = new URL(config.assets, document.baseURI).href;
  config.siteRoot = new URL(config.siteRoot, document.baseURI).href;

  // ---------------------------------------------------------------------------
  // Wasm modules

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();

  /** Enough of WASI preview1 for the Swift runtime to start and print errors. */
  function wasiImports(getMemory) {
    const ENOSYS = 52, EBADF = 8;
    const view = () => new DataView(getMemory().buffer);
    const bytes = () => new Uint8Array(getMemory().buffer);
    return {
      args_get: () => 0,
      args_sizes_get: (argc, argvBufSize) => { view().setUint32(argc, 0, true); view().setUint32(argvBufSize, 0, true); return 0; },
      environ_get: () => 0,
      environ_sizes_get: (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; },
      clock_res_get: (id, out) => { view().setBigUint64(out, 1000n, true); return 0; },
      clock_time_get: (id, precision, out) => {
        const ns = id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
        view().setBigUint64(out, ns, true);
        return 0;
      },
      fd_close: () => 0,
      fd_fdstat_get: (fd, out) => {
        if (fd > 2) return EBADF;
        const v = view();
        v.setUint8(out, 2); // character device
        v.setUint16(out + 2, 0, true);
        v.setBigUint64(out + 8, 0n, true);
        v.setBigUint64(out + 16, 0n, true);
        return 0;
      },
      fd_filestat_get: () => ENOSYS,
      fd_filestat_set_times: () => ENOSYS,
      fd_pread: () => ENOSYS,
      fd_prestat_get: () => EBADF,
      fd_prestat_dir_name: () => EBADF,
      fd_read: () => ENOSYS,
      fd_readdir: () => ENOSYS,
      fd_seek: () => ENOSYS,
      fd_sync: () => 0,
      fd_tell: () => ENOSYS,
      fd_write: (fd, iovs, iovsLen, written) => {
        const v = view(), b = bytes();
        let total = 0, text = "";
        for (let i = 0; i < iovsLen; i++) {
          const ptr = v.getUint32(iovs + i * 8, true), len = v.getUint32(iovs + i * 8 + 4, true);
          text += decoder.decode(b.subarray(ptr, ptr + len));
          total += len;
        }
        v.setUint32(written, total, true);
        if (text.trim()) (fd === 2 ? console.error : console.log)("[pyshader.wasm]", text);
        return 0;
      },
      path_create_directory: () => ENOSYS,
      path_filestat_get: () => ENOSYS,
      path_filestat_set_times: () => ENOSYS,
      path_link: () => ENOSYS,
      path_open: () => ENOSYS,
      path_readlink: () => ENOSYS,
      path_remove_directory: () => ENOSYS,
      path_rename: () => ENOSYS,
      path_symlink: () => ENOSYS,
      path_unlink_file: () => ENOSYS,
      poll_oneoff: () => ENOSYS,
      proc_exit: (code) => { throw new Error(`pyshader.wasm exited with code ${code}`); },
      random_get: (ptr, len) => { crypto.getRandomValues(bytes().subarray(ptr, ptr + len)); return 0; },
      sched_yield: () => 0,
    };
  }

  let modulesPromise = null;

  function loadModules() {
    if (modulesPromise) return modulesPromise;
    modulesPromise = (async () => {
      let swiftExports = null;
      const [swiftModule, naga] = await Promise.all([
        WebAssembly.compileStreaming(fetch(new URL("pyshader.wasm", config.assets))),
        WebAssembly.instantiateStreaming(fetch(new URL("naga.wasm", config.assets)), {}),
      ]);
      // Which WASI calls the module imports depends on the toolchain that
      // built it; anything the shim does not implement gets an ENOSYS stub.
      const wasi = wasiImports(() => swiftExports.memory);
      for (const { module, name } of WebAssembly.Module.imports(swiftModule)) {
        if (module === "wasi_snapshot_preview1" && !(name in wasi)) wasi[name] = () => 52;
      }
      const swift = await WebAssembly.instantiate(swiftModule, { wasi_snapshot_preview1: wasi });
      swiftExports = swift.exports;
      swiftExports._initialize();
      return { swift: swiftExports, naga: naga.instance.exports };
    })();
    modulesPromise.catch(() => { modulesPromise = null; });
    return modulesPromise;
  }

  function putBytes(exports, alloc, data) {
    const ptr = exports[alloc](data.length);
    new Uint8Array(exports.memory.buffer, ptr, data.length).set(data);
    return ptr;
  }

  /** Python source -> { wgsl, entryPoint, vertexEntryPoint, spirv }; throws with the compiler's message. */
  async function compile(source, options) {
    const { swift, naga } = await loadModules();

    const src = encoder.encode(source), opt = encoder.encode(options);
    const srcPtr = putBytes(swift, "pyshader_alloc", src), optPtr = putBytes(swift, "pyshader_alloc", opt);
    const status = swift.pyshader_compile(srcPtr, src.length, optPtr, opt.length);
    swift.pyshader_dealloc(srcPtr, src.length);
    swift.pyshader_dealloc(optPtr, opt.length);
    const result = new Uint8Array(swift.memory.buffer, swift.pyshader_result_ptr(), swift.pyshader_result_len()).slice();
    swift.pyshader_result_free();
    if (status !== 0) throw new CompileError(decoder.decode(result));

    const nameBuf = swift.pyshader_alloc(256);
    const readName = (fn) => {
      const n = fn(nameBuf, 256);
      return decoder.decode(new Uint8Array(swift.memory.buffer, nameBuf, Math.min(n, 256)));
    };
    const entryPoint = readName(swift.pyshader_entry_point);
    const vertexEntryPoint = readName(swift.pyshader_vertex_entry_point);
    swift.pyshader_dealloc(nameBuf, 256);

    const spvPtr = putBytes(naga, "naga_alloc", result);
    const nagaStatus = naga.naga_spirv_to_wgsl(spvPtr, result.length);
    naga.naga_dealloc(spvPtr, result.length);
    const wgsl = decoder.decode(new Uint8Array(naga.memory.buffer, naga.naga_result_ptr(), naga.naga_result_len()));
    naga.naga_result_free();
    if (nagaStatus !== 0) throw new CompileError(`WebGPU cannot run this shader: ${wgsl}`);

    return { wgsl, entryPoint, vertexEntryPoint, spirv: result };
  }

  class CompileError extends Error {
    constructor(message) {
      super(message);
      // "line 7: …" from the compiler, "… at line 7, column 3" from the parser.
      const m = /^line (\d+): /.exec(message) || / at line (\d+)/.exec(message);
      this.line = m ? Number(m[1]) : null;
    }
  }

  // ---------------------------------------------------------------------------
  // WebGPU

  let devicePromise = null;

  function getDevice() {
    if (devicePromise) return devicePromise;
    devicePromise = (async () => {
      if (!navigator.gpu) throw new Error("WebGPU is not available in this browser");
      const adapter = await navigator.gpu.requestAdapter();
      if (!adapter) throw new Error("No WebGPU adapter found");
      const requiredFeatures = adapter.features.has("shader-f16") ? ["shader-f16"] : [];
      const device = await adapter.requestDevice({ requiredFeatures });
      device.lost.then((info) => {
        console.warn("WebGPU device lost:", info.message);
        devicePromise = null;
      });
      return device;
    })();
    devicePromise.catch(() => { devicePromise = null; });
    return devicePromise;
  }

  const BLIT_WGSL = `
    @group(0) @binding(0) var src: texture_2d<f32>;
    struct Out { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> }
    @vertex fn vs(@builtin(vertex_index) i: u32) -> Out {
      let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
      return Out(vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0), vec2<f32>(p.x, 1.0 - p.y));
    }
    @fragment fn fs(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
      let size = vec2<f32>(textureDimensions(src));
      return textureLoad(src, vec2<i32>(uv * size), 0);
    }`;

  /** The argument buffer PyShader reads: (offset, count) per argument, then the values. */
  function packArguments(args) {
    const header = args.length * 2;
    const values = [];
    const data = [];
    for (const arg of args) {
      const value = arg.value.length ? arg.value : defaultArgument(arg.kind);
      data.push(header + values.length, value.length);
      values.push(...value);
    }
    return new Float32Array([...data, ...values, 0]);
  }

  function defaultArgument(kind) {
    return { float: [1], float2: [1, 1], float3: [1, 1, 1], float4: [1, 1, 1, 1], floatArray: [0] }[kind];
  }

  /** A content image for `layer()` when the block names none: a soft test card. */
  function testCard(width, height) {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    const g = ctx.createLinearGradient(0, 0, width, height);
    g.addColorStop(0, "#1e3a8a");
    g.addColorStop(0.5, "#0f766e");
    g.addColorStop(1, "#7c2d12");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, width, height);
    const cell = Math.round(width / 12);
    ctx.fillStyle = "rgba(255,255,255,0.12)";
    for (let y = 0; y < height; y += cell) {
      for (let x = ((y / cell) % 2) * cell; x < width; x += cell * 2) ctx.fillRect(x, y, cell, cell);
    }
    ctx.fillStyle = "#fff";
    ctx.font = `bold ${Math.round(height / 4)}px system-ui, sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText("PyShader", width / 2, height / 2);
    return canvas;
  }

  // ---------------------------------------------------------------------------
  // One preview

  class Preview {
    constructor(element, data) {
      this.element = element;
      this.data = data;
      this.frame = element.querySelector(".pyshader-frame");
      this.canvas = element.querySelector(".pyshader-canvas");
      this.statusEl = element.querySelector(".pyshader-status");
      this.source = data.source;
      this.running = false;
      this.visible = false;
      this.pipeline = null;
      this.mouse = [0, 0, 0, 0];
      this.pressed = false;
      this.frameIndex = 0;
      this.startTime = performance.now();
      this.lastTime = this.startTime;
      this.compileId = 0;

      this.canvas.addEventListener("pointermove", (e) => this.pointer(e));
      this.canvas.addEventListener("pointerdown", (e) => { this.pressed = true; this.canvas.setPointerCapture(e.pointerId); this.pointer(e); });
      this.canvas.addEventListener("pointerup", (e) => { this.pressed = false; this.pointer(e); });
      this.canvas.addEventListener("pointercancel", () => { this.pressed = false; });

      this.resizeObserver = new ResizeObserver(() => this.resize());
      this.resizeObserver.observe(this.frame);
    }

    pointer(e) {
      const rect = this.canvas.getBoundingClientRect();
      const scale = this.canvas.width / rect.width;
      const x = (e.clientX - rect.left) * scale, y = (e.clientY - rect.top) * scale;
      this.mouse[0] = x;
      this.mouse[1] = y;
      if (this.pressed) { this.mouse[2] = x; this.mouse[3] = y; }
    }

    status(text, kind) {
      this.statusEl.textContent = text || "";
      this.statusEl.className = "pyshader-status" + (kind ? ` pyshader-status-${kind}` : "");
      this.statusEl.hidden = !text;
    }

    resize() {
      const rect = this.frame.getBoundingClientRect();
      if (rect.width === 0) return;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const w = Math.max(1, Math.round(rect.width * dpr)), h = Math.max(1, Math.round(rect.height * dpr));
      if (w !== this.canvas.width || h !== this.canvas.height) {
        this.canvas.width = w;
        this.canvas.height = h;
        this.sized = true;
        if (this.pipeline) this.pipeline.resize(w, h);
      }
    }

    options() {
      const parts = [`target=${this.data.target || "compute"}`];
      if (this.data.content || /\blayer\s*\(/.test(this.source)) parts.push("content=1");
      for (const arg of this.data.args || []) parts.push(`arg=${arg.name}:${arg.kind}`);
      return parts.join(" ");
    }

    async setSource(source) {
      this.source = source;
      const id = ++this.compileId;
      this.status("compiling…", "busy");
      let compiled;
      try {
        compiled = await compile(source, this.options());
      } catch (error) {
        if (id !== this.compileId) return;
        this.status(error.message, "error");
        this.onError?.(error);
        return;
      }
      if (id !== this.compileId) return;
      this.compiled = compiled;
      this.onError?.(null);
      try {
        await this.build();
        this.status("");
      } catch (error) {
        this.status(error.message, "error");
        console.error(error);
      }
    }

    async build() {
      const device = await getDevice();
      this.device = device;
      if (!this.context) {
        this.context = this.canvas.getContext("webgpu");
        if (!this.context) {
          throw new Error("This browser reports WebGPU but refuses a WebGPU canvas; it may be disabled for this GPU. "
            + "Chrome: check chrome://gpu; Firefox: dom.webgpu.enabled; Safari 26 works out of the box.");
        }
        this.format = navigator.gpu.getPreferredCanvasFormat();
        this.context.configure({ device, format: this.format, alphaMode: "opaque" });
      }
      if (!this.uniforms) this.uniforms = device.createBuffer({ size: 48, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
      this.resize();
      // Keep drawing the old pipeline until the new one is ready.
      const next = this.data.target === "graphics" ? new GraphicsPipeline(this) : new ComputePipeline(this);
      await next.build();
      const old = this.pipeline;
      this.pipeline = next;
      old?.dispose();
      if (!this.running) this.start();
    }

    argumentBuffer() {
      const args = this.data.args || [];
      if (!args.length) return null;
      const packed = packArguments(args);
      const buffer = this.device.createBuffer({ size: packed.byteLength, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
      this.device.queue.writeBuffer(buffer, 0, packed);
      return buffer;
    }

    async contentTexture() {
      let image;
      if (this.data.content) {
        image = new Image();
        image.crossOrigin = "anonymous";
        image.src = new URL(this.data.content, config.siteRoot).href;
        await image.decode();
      } else {
        image = testCard(this.canvas.width || 640, this.canvas.height || 360);
      }
      const bitmap = await createImageBitmap(image);
      const texture = this.device.createTexture({
        size: [bitmap.width, bitmap.height],
        format: "rgba8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
      });
      // `layer(uv)` samples in the shader's y-up space, so the content goes in bottom row first.
      this.device.queue.copyExternalImageToTexture({ source: bitmap, flipY: true }, { texture }, [bitmap.width, bitmap.height]);
      return texture;
    }

    start() {
      this.running = true;
      const tick = () => {
        if (!this.running) return;
        this.raf = requestAnimationFrame(tick);
        if (!this.visible || !this.pipeline || this.canvas.width === 0) return;
        try {
          this.render();
        } catch (error) {
          this.status(error.message, "error");
          console.error(error);
          this.pipeline = null;
        }
      };
      this.raf = requestAnimationFrame(tick);
    }

    stop() {
      this.running = false;
      cancelAnimationFrame(this.raf);
    }

    render() {
      const now = performance.now();
      const time = (now - this.startTime) / 1000, dt = (now - this.lastTime) / 1000;
      this.lastTime = now;
      const u = new Float32Array([
        time, dt, this.frameIndex++, 0,
        this.canvas.width, this.canvas.height, 0, 0,
        this.mouse[0], this.mouse[1], this.mouse[2], this.mouse[3],
      ]);
      this.device.queue.writeBuffer(this.uniforms, 0, u);
      const encoder = this.device.createCommandEncoder();
      this.pipeline.encode(encoder, this.context.getCurrentTexture().createView());
      this.device.queue.submit([encoder.finish()]);
    }

    dispose() {
      this.stop();
      this.resizeObserver.disconnect();
      this.pipeline?.dispose();
    }
  }

  /** Compute target: dispatch over a storage texture, then blit it to the canvas. */
  class ComputePipeline {
    constructor(preview) {
      this.p = preview;
    }

    async build() {
      const { device, compiled } = this.p;
      const module = device.createShaderModule({ code: compiled.wgsl });
      const info = await module.getCompilationInfo();
      const errors = info.messages.filter((m) => m.type === "error");
      if (errors.length) throw new Error("WGSL: " + errors.map((m) => m.message).join("\n"));
      this.compute = await device.createComputePipelineAsync({ layout: "auto", compute: { module, entryPoint: compiled.entryPoint } });

      const blit = device.createShaderModule({ code: BLIT_WGSL });
      this.blit = device.createRenderPipeline({
        layout: "auto",
        vertex: { module: blit, entryPoint: "vs" },
        fragment: { module: blit, entryPoint: "fs", targets: [{ format: this.p.format }] },
      });
      this.args = this.p.argumentBuffer();
      this.needsContent = /\blayer\s*\(/.test(this.p.source) || !!this.p.data.content;
      if (this.needsContent) {
        this.content = await this.p.contentTexture();
        this.sampler = device.createSampler({ magFilter: "linear", minFilter: "linear", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge" });
      }
      this.resize(this.p.canvas.width, this.p.canvas.height);
    }

    resize(width, height) {
      if (!this.compute) return;
      const { device } = this.p;
      this.target?.destroy();
      this.target = device.createTexture({
        size: [width, height],
        format: "rgba8unorm",
        usage: GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING,
      });
      const view = this.target.createView();
      const entries = [
        { binding: 0, resource: view },
        { binding: 1, resource: { buffer: this.p.uniforms } },
      ];
      if (this.content) entries.push({ binding: 2, resource: this.content.createView() });
      if (this.args) entries.push({ binding: 3, resource: { buffer: this.args } });
      this.bindGroups = [device.createBindGroup({ layout: this.compute.getBindGroupLayout(0), entries })];
      if (this.content) {
        this.bindGroups.push(device.createBindGroup({
          layout: this.compute.getBindGroupLayout(1),
          entries: [{ binding: 2, resource: this.sampler }],
        }));
      }
      this.blitGroup = device.createBindGroup({ layout: this.blit.getBindGroupLayout(0), entries: [{ binding: 0, resource: view }] });
      this.width = width;
      this.height = height;
    }

    encode(encoder, canvasView) {
      const pass = encoder.beginComputePass();
      pass.setPipeline(this.compute);
      this.bindGroups.forEach((g, i) => pass.setBindGroup(i, g));
      pass.dispatchWorkgroups(Math.ceil(this.width / 8), Math.ceil(this.height / 8));
      pass.end();
      const render = encoder.beginRenderPass({ colorAttachments: [{ view: canvasView, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 1] }] });
      render.setPipeline(this.blit);
      render.setBindGroup(0, this.blitGroup);
      render.draw(3);
      render.end();
    }

    dispose() {
      this.target?.destroy();
      this.content?.destroy();
      this.args?.destroy();
    }
  }

  /** Graphics target: the module's vertex + fragment pair drawn into the canvas. */
  class GraphicsPipeline {
    constructor(preview) {
      this.p = preview;
    }

    async build() {
      const { device, compiled, data } = this.p;
      const module = device.createShaderModule({ code: compiled.wgsl });
      const info = await module.getCompilationInfo();
      const errors = info.messages.filter((m) => m.type === "error");
      if (errors.length) throw new Error("WGSL: " + errors.map((m) => m.message).join("\n"));
      this.pipeline = await device.createRenderPipelineAsync({
        layout: "auto",
        vertex: { module, entryPoint: compiled.vertexEntryPoint },
        fragment: {
          module,
          entryPoint: compiled.entryPoint,
          targets: [{
            format: this.p.format,
            blend: {
              color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
              alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
            },
          }],
        },
        primitive: { topology: "triangle-list" },
      });
      this.args = this.p.argumentBuffer();
      const entries = [{ binding: 1, resource: { buffer: this.p.uniforms } }];
      if (this.args) entries.push({ binding: 3, resource: { buffer: this.args } });
      this.bindGroup = device.createBindGroup({ layout: this.pipeline.getBindGroupLayout(0), entries });
      this.vertices = data.vertices || 3;
      this.instances = data.instances || 1;
    }

    resize() {}

    encode(encoder, canvasView) {
      const pass = encoder.beginRenderPass({ colorAttachments: [{ view: canvasView, loadOp: "clear", storeOp: "store", clearValue: [0, 0, 0, 1] }] });
      pass.setPipeline(this.pipeline);
      pass.setBindGroup(0, this.bindGroup);
      pass.draw(this.vertices, this.instances);
      pass.end();
    }

    dispose() {
      this.args?.destroy();
    }
  }

  // ---------------------------------------------------------------------------
  // Monaco editor for `pyshader-edit` blocks

  let monacoPromise = null;

  function loadMonaco() {
    if (monacoPromise) return monacoPromise;
    monacoPromise = new Promise((resolve, reject) => {
      const loader = document.createElement("script");
      loader.src = `${config.monaco}/loader.js`;
      loader.onload = () => {
        window.require.config({ paths: { vs: config.monaco } });
        window.require(["vs/editor/editor.main"], () => resolve(window.monaco), reject);
      };
      loader.onerror = () => reject(new Error("Monaco failed to load"));
      document.head.appendChild(loader);
    });
    return monacoPromise;
  }

  const LAYOUTS = [["horizontal", "Side by side"], ["vertical", "Stacked"]];
  const ASPECTS = [["16/9", "16:9"], ["4/3", "4:3"], ["1/1", "1:1"], ["", "Fill"]];

  function pref(key, fallback) {
    try { return localStorage.getItem(`pyshader.${key}`) ?? fallback; } catch { return fallback; }
  }
  function setPref(key, value) {
    try { localStorage.setItem(`pyshader.${key}`, value); } catch {}
  }

  /** Layout and aspect pickers above an edit block; the fence options are the defaults. */
  function attachToolbar(preview) {
    const el = preview.element;
    const bar = document.createElement("div");
    bar.className = "pyshader-toolbar";
    el.insertBefore(bar, el.firstChild);

    const group = (label, choices, current, apply) => {
      const wrap = document.createElement("span");
      wrap.className = "pyshader-toolbar-group";
      wrap.append(Object.assign(document.createElement("span"), { className: "pyshader-toolbar-label", textContent: label }));
      const buttons = choices.map(([value, text]) => {
        const b = Object.assign(document.createElement("button"), { type: "button", textContent: text });
        b.addEventListener("click", () => { select(value); apply(value); });
        wrap.append(b);
        return [value, b];
      });
      const select = (value) => buttons.forEach(([v, b]) => b.classList.toggle("pyshader-active", v === value));
      select(current);
      apply(current);
      return wrap;
    };

    const fenceLayout = [...el.classList].find((c) => c.startsWith("pyshader-layout-"))?.slice(16) || "auto";
    const defaultLayout = fenceLayout === "auto" ? (matchMedia("(max-width: 76em)").matches ? "vertical" : "horizontal") : fenceLayout;
    bar.append(group("Layout", LAYOUTS, pref("layout", defaultLayout), (value) => {
      el.classList.remove("pyshader-layout-auto", "pyshader-layout-horizontal", "pyshader-layout-vertical");
      el.classList.add(`pyshader-layout-${value}`);
      setPref("layout", value);
    }));

    const fenceAspect = el.style.getPropertyValue("--pyshader-aspect").trim();
    bar.append(group("Preview", ASPECTS, pref("aspect", fenceAspect), (value) => {
      el.classList.toggle("pyshader-has-aspect", !!value);
      el.style.setProperty("--pyshader-aspect", value || "auto");
      setPref("aspect", value);
    }));
  }

  async function attachEditor(preview) {
    attachToolbar(preview);
    const monaco = await loadMonaco();
    const host = document.createElement("div");
    host.className = "pyshader-editor";
    preview.element.insertBefore(host, preview.frame);
    const dark = document.documentElement.dataset.mdColorScheme === "slate" || matchMedia("(prefers-color-scheme: dark)").matches;
    const editor = monaco.editor.create(host, {
      value: preview.source,
      language: "python",
      theme: dark ? "vs-dark" : "vs",
      minimap: { enabled: false },
      fontSize: 13,
      lineNumbersMinChars: 3,
      scrollBeyondLastLine: false,
      automaticLayout: true,
      tabSize: 4,
      wordWrap: "off",
    });
    const model = editor.getModel();
    // Recompile once typing has paused for `debounce` ms (fence option; 1 s by default).
    const debounce = Number(preview.data.debounce) > 0 ? Number(preview.data.debounce) : 1000;
    let timer = null;
    editor.onDidChangeModelContent(() => {
      clearTimeout(timer);
      timer = setTimeout(() => preview.setSource(editor.getValue()), debounce);
    });
    preview.onError = (error) => {
      const markers = error && error.line
        ? [{ severity: monaco.MarkerSeverity.Error, message: error.message, startLineNumber: error.line, startColumn: 1, endLineNumber: error.line, endColumn: model.getLineMaxColumn(error.line) }]
        : [];
      monaco.editor.setModelMarkers(model, "pyshader", markers);
    };
    new MutationObserver(() => {
      const scheme = document.documentElement.dataset.mdColorScheme;
      if (scheme) monaco.editor.setTheme(scheme === "slate" ? "vs-dark" : "vs");
    }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-md-color-scheme"] });
    preview.editor = editor;
  }

  // ---------------------------------------------------------------------------
  // Wiring

  const previews = new Map();

  const visibility = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const preview = previews.get(entry.target);
      if (!preview) continue;
      preview.visible = entry.isIntersecting;
      if (entry.isIntersecting && !preview.started) {
        preview.started = true;
        preview.setSource(preview.source);
      }
    }
  }, { rootMargin: "200px" });

  function mount(root) {
    for (const element of root.querySelectorAll(".pyshader[data-pyshader]")) {
      if (previews.has(element)) continue;
      const data = JSON.parse(element.dataset.pyshader);
      const preview = new Preview(element, data);
      previews.set(element, preview);
      if (!navigator.gpu) {
        preview.status("This browser has no WebGPU; the preview needs Chrome, Edge, Safari 26 or Firefox 141+.", "error");
        continue;
      }
      if (data.mode === "edit") attachEditor(preview).catch((e) => preview.status(e.message, "error"));
      visibility.observe(element);
    }
  }

  function unmountAll() {
    for (const [element, preview] of previews) {
      visibility.unobserve(element);
      preview.dispose();
      preview.editor?.dispose();
    }
    previews.clear();
  }

  // Material's instant navigation swaps the page without a reload.
  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(() => { unmountAll(); mount(document); });
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => mount(document));
  } else {
    mount(document);
  }

  window.PyShaderPreview = { compile, mount, previews };
})();
