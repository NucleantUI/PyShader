/*
 * PyShader live preview for MkDocs.
 *
 * Every `.pyshader` element the fences emit gets a WebGPU canvas. The Python
 * source goes through two wasm modules in the browser: PyShader (Swift, WASI)
 * compiles it to SPIR-V, naga (Rust) turns that into WGSL, which the browser
 * takes. Compute-target shaders write a storage texture that is blitted to
 * the canvas; graphics-target ones — a module with a `vertex` and a `fragment`
 * stage, which the fence names or `detectTarget` recognises — draw straight
 * into it.
 *
 * `pyshader-edit` blocks put a Monaco editor next to the canvas and recompile
 * on every change.
 *
 * `pyshader-convert` blocks go the other way: GLSL (ShaderToy's `mainImage`
 * or a whole fragment shader) through glslang (wasm) to SPIR-V, then through
 * PyShader's decompiler to Python, shown in a second editor.
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
      glslang: "https://cdn.jsdelivr.net/npm/@webgpu/glslang@0.0.15/dist/web-devel/glslang.js",
    },
    window.PyShaderConfig || {}
  );
  config.assets = new URL(config.assets, document.baseURI).href;
  config.siteRoot = new URL(config.siteRoot, document.baseURI).href;

  /** A wasm module's URL with the plugin's content hash, so a deploy is not served from the cache. */
  function assetUrl(name) {
    const url = new URL(name, config.assets);
    if (config.versions && config.versions[name]) url.searchParams.set("v", config.versions[name]);
    return url;
  }

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
        WebAssembly.compileStreaming(fetch(assetUrl("pyshader.wasm"))),
        WebAssembly.instantiateStreaming(fetch(assetUrl("naga.wasm")), {}),
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

  /** SPIR-V bytes -> { source, warnings }; throws with the decompiler's message. */
  async function decompile(spirv, options) {
    const { swift } = await loadModules();
    const opt = encoder.encode(options || "");
    const spvPtr = putBytes(swift, "pyshader_alloc", spirv), optPtr = putBytes(swift, "pyshader_alloc", opt);
    const status = swift.pyshader_decompile(spvPtr, spirv.length, optPtr, opt.length);
    swift.pyshader_dealloc(spvPtr, spirv.length);
    swift.pyshader_dealloc(optPtr, opt.length);
    const result = decoder.decode(new Uint8Array(swift.memory.buffer, swift.pyshader_result_ptr(), swift.pyshader_result_len()));
    swift.pyshader_result_free();
    if (status !== 0) throw new Error(result);

    const size = swift.pyshader_decompile_warnings(0, 0);
    let warnings = [];
    if (size > 0) {
      const buf = swift.pyshader_alloc(size);
      swift.pyshader_decompile_warnings(buf, size);
      warnings = decoder.decode(new Uint8Array(swift.memory.buffer, buf, size)).split("\n");
      swift.pyshader_dealloc(buf, size);
    }
    return { source: result, warnings };
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
  // What a source asks for

  const DEF = (name) => new RegExp(`^[ \\t]*def[ \\t]+${name}[ \\t]*\\(`, "m");
  const VERTEX_DEF = DEF("vertex"), FRAGMENT_DEF = DEF("fragment"), MAIN_DEF = DEF("main");

  /** A module with a `vertex` and a `fragment` stage is a graphics target; anything else computes. */
  function detectTarget(source) {
    return !MAIN_DEF.test(source) && VERTEX_DEF.test(source) && FRAGMENT_DEF.test(source) ? "graphics" : "compute";
  }

  /** The number of elements in the list literal whose `[` is at `start`, or 0. */
  function listLength(source, start) {
    let depth = 0, items = 0, item = false;
    for (let i = start; i < source.length; i++) {
      const c = source[i];
      if (c === "]" && depth === 1) return items + (item ? 1 : 0);
      if (c === "," && depth === 1) { items += item ? 1 : 0; item = false; }
      else if (c === "[" || c === "(") { item = item || depth > 0; depth++; }
      else if (c === ")" || c === "]") depth--;
      else if (depth > 0 && c.trim()) item = true;
    }
    return 0;
  }

  /**
   * How many vertices a graphics source draws: the length of the list its vertex
   * stage indexes with `vertex_index`, following one name to the next, as the
   * compiler's "dynamic indexing needs the list in a variable" makes it one
   * (`corner = quad[vertex_index]`, `quad = QUAD`, `QUAD = [...]`), else 0.
   */
  function detectVertices(source) {
    let name = /([A-Za-z_]\w*)\s*\[\s*vertex_index\b/.exec(source)?.[1];
    for (let hop = 0; name && hop < 4; hop++) {
      const assigned = new RegExp(`^[ \\t]*${name}[ \\t]*=[ \\t]*(\\[|[A-Za-z_]\\w*[ \\t]*$)`, "m").exec(source);
      if (!assigned) return 0;
      if (assigned[1] === "[") return listLength(source, assigned.index + assigned[0].length - 1);
      name = assigned[1].trim();
    }
    return 0;
  }

  // The parameter names both targets fill in themselves; anything else an
  // entry point takes is a ShaderArgument (or, in `fragment`, a varying).
  const BUILTIN_PARAMS = new Set([
    "uv", "frag_coord", "pixel", "front_facing", "time", "time_delta",
    "frame", "resolution", "mouse", "mouse_click", "vertex_index", "instance_index",
  ]);
  const ARG_KINDS = {
    float: "float", float2: "float2", float3: "float3", float4: "float4",
    FloatArray: "floatArray", Float2Array: "float2Array", Float3Array: "float3Array", Float4Array: "float4Array",
  };

  /** The `name: Type` parameters of `def name(...)`, or []. */
  function parameters(source, name) {
    const m = new RegExp(`^[ \\t]*def[ \\t]+${name}[ \\t]*\\(([^)]*)\\)`, "m").exec(source);
    if (!m) return [];
    return m[1].split(",").map((p) => /^\s*([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*)/.exec(p)).filter(Boolean)
      .map((p) => ({ name: p[1], type: p[2] }));
  }

  /** The varyings a graphics module interpolates: the fields of the class `vertex` returns. */
  function varyings(source) {
    const returns = /^[ \t]*def[ \t]+vertex[ \t]*\([^)]*\)[ \t]*->[ \t]*([A-Za-z_]\w*)/m.exec(source);
    if (!returns) return [];
    const body = new RegExp(`^class[ \\t]+${returns[1]}[ \\t]*:[ \\t]*$((?:\\n(?:[ \\t]+.*)?)*)`, "m").exec(source);
    return body ? [...body[1].matchAll(/^[ \t]+([A-Za-z_]\w*)[ \t]*:/gm)].map((m) => m[1]) : [];
  }

  /**
   * The `ShaderArgument`s a source implies: every entry-point parameter that is
   * neither a built-in input nor a varying, in the order the stages take them,
   * which is the order the argument buffer is packed in.
   */
  function detectArguments(source) {
    const seen = new Set(varyings(source));
    const args = [];
    for (const entry of ["vertex", "fragment", "main"]) {
      for (const { name, type } of parameters(source, entry)) {
        if (BUILTIN_PARAMS.has(name) || seen.has(name)) continue;
        seen.add(name);
        if (ARG_KINDS[type]) args.push({ name, kind: ARG_KINDS[type], value: [] });
      }
    }
    return args;
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
      // The header pair is (offset, count), and `len(a)` reads that count: floats
      // for a value, but elements for an array of vectors.
      data.push(header + values.length, Math.floor(value.length / (isArgArray(arg.kind) ? argWidth(arg.kind) : 1)));
      values.push(...value);
    }
    return new Float32Array([...data, ...values, 0]);
  }

  const isArgArray = (kind) => kind.endsWith("Array");
  const argWidth = (kind) => Number(/\d/.exec(kind)?.[0]) || 1;

  function defaultArgument(kind) {
    return Array(argWidth(kind)).fill(isArgArray(kind) ? 0 : 1);
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
      this.argValues = new Map();
      this.extraArgs = [];
      this.disposers = [];
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

    /** The fence's target, or the one the current source implies. */
    target() {
      return this.data.target || detectTarget(this.source);
    }

    /** The fence's argument declarations, or the source's, carrying any values the toolbar holds. */
    declaredArguments() {
      const declared = this.data.args?.length ? this.data.args : detectArguments(this.source);
      return declared.map((a) => (this.argValues.has(a.name) ? { ...a, value: this.argValues.get(a.name) } : a));
    }

    /** Those, and the rows the Arguments panel adds for what the source does not declare. */
    arguments() {
      const declared = this.declaredArguments();
      const named = new Set(declared.map((a) => a.name));
      return [...declared, ...this.extraArgs.filter((a) => a.name && !named.has(a.name))];
    }

    /** The graphics draw call: the toolbar's counts, the fence's, or the source's. */
    draw() {
      return {
        vertices: this.drawOverride?.vertices || this.data.vertices || detectVertices(this.source) || 3,
        instances: this.drawOverride?.instances || this.data.instances || 1,
      };
    }

    options() {
      const parts = [`target=${this.target()}`];
      if (this.data.content || /\blayer\s*\(/.test(this.source)) parts.push("content=1");
      for (const arg of this.arguments()) parts.push(`arg=${arg.name}:${arg.kind}`);
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
        this.onCompiled?.();
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
      const next = this.target() === "graphics" ? new GraphicsPipeline(this) : new ComputePipeline(this);
      await next.build();
      const old = this.pipeline;
      this.pipeline = next;
      old?.dispose();
      if (!this.running) this.start();
    }

    argumentBuffer() {
      const args = this.arguments();
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
      for (const off of this.disposers) off();
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
      const { device, compiled } = this.p;
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
      const draw = this.p.draw();
      this.vertices = draw.vertices;
      this.instances = draw.instances;
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

  /** A toolbar button that runs `action` and shows `done` for a moment, or reports the error. */
  function actionButton(label, done, action, onError) {
    const b = Object.assign(document.createElement("button"), { type: "button", textContent: label });
    b.addEventListener("click", async () => {
      try {
        await action();
        b.textContent = done;
        setTimeout(() => { b.textContent = label; }, 1500);
      } catch (error) {
        onError(`${label} failed: ${error.message}`);
      }
    });
    return b;
  }

  /** "Copy" / "Paste" for a Monaco editor: the whole text to and from the clipboard. */
  function clipboardButtons(editor, what, onError) {
    const copy = actionButton(`Copy ${what}`, "Copied", () => navigator.clipboard.writeText(editor.getValue()), onError);
    const paste = actionButton(`Paste ${what}`, "Pasted", async () => {
      if (!navigator.clipboard?.readText) throw new Error("this browser does not let pages read the clipboard");
      editor.setValue(await navigator.clipboard.readText());
    }, onError);
    return [paste, copy];
  }

  const ARG_KINDS_IN_ORDER = ["float", "float2", "float3", "float4", "floatArray", "float2Array", "float3Array", "float4Array"];

  /** `1 0.5 0` -> [1, 0.5, 0]; null when it is not a list of numbers. */
  function parseValues(text) {
    const parsed = text.split(/[\s,]+/).filter(Boolean).map(Number);
    return parsed.length && !parsed.some(Number.isNaN) ? parsed : null;
  }

  function element(tag, className, properties) {
    return Object.assign(document.createElement(tag), { className, ...properties });
  }

  /** A number field in the toolbar, calling `apply` with its new value. */
  function countField(label, value, apply) {
    const wrap = element("label", "pyshader-toolbar-field");
    const input = element("input", "", { type: "number", min: "1", value: String(value) });
    input.addEventListener("change", () => apply(input.value));
    wrap.append(element("span", "", { textContent: label }), input);
    return wrap;
  }

  /**
   * The draw call, and the `ShaderArgument`s behind an Arguments button: a row
   * per argument the source declares, holding the values handed to it, and rows
   * the reader adds for what it does not — a name, a kind, its values. A value
   * only rebuilds the pipeline; a name or a kind is a declaration, so it
   * recompiles. The panel is built as it opens, so an edit to the source is
   * picked up without a half-typed row being taken away under the reader.
   */
  function attachControls(preview, bar) {
    const controls = element("span", "pyshader-toolbar-group pyshader-toolbar-controls");
    const draw = element("span", "pyshader-toolbar-group");
    const open = element("button", "", { type: "button", textContent: "Arguments" });
    const panel = element("div", "pyshader-popover", { hidden: true });
    controls.append(draw, open, panel);
    bar.append(controls);

    const rebuild = () => {
      if (preview.compiled) preview.build().catch((e) => preview.status(e.message, "error"));
    };
    const recompile = () => preview.setSource(preview.source);

    const valueField = (arg, apply) => {
      const input = element("input", "", { type: "text", spellcheck: false, placeholder: arg.kind,
        value: (arg.value.length ? arg.value : defaultArgument(arg.kind)).join(" ") });
      input.addEventListener("change", () => {
        const values = parseValues(input.value);
        if (!values) return preview.status(`${arg.name || "argument"}: want numbers, as \`1 0.5 0\``, "error");
        apply(values);
        rebuild();
      });
      return input;
    };

    const declaredRow = (arg) => {
      const row = element("div", "pyshader-popover-row");
      row.append(
        element("span", "pyshader-popover-name", { textContent: arg.name, title: arg.name }),
        element("span", "pyshader-popover-kind", { textContent: arg.kind }),
        valueField(arg, (values) => preview.argValues.set(arg.name, values)),
      );
      return row;
    };

    const addedRow = (arg, render) => {
      const row = element("div", "pyshader-popover-row");
      const name = element("input", "pyshader-popover-name", { type: "text", spellcheck: false, placeholder: "name", value: arg.name });
      name.addEventListener("change", () => { arg.name = name.value.trim(); recompile(); });
      const kind = element("select", "pyshader-popover-kind");
      for (const k of ARG_KINDS_IN_ORDER) kind.append(new Option(k, k, false, k === arg.kind));
      kind.addEventListener("change", () => { arg.kind = kind.value; arg.value = []; recompile(); render(); });
      const remove = element("button", "pyshader-popover-remove", { type: "button", textContent: "×", title: `Remove ${arg.name || "this row"}` });
      remove.addEventListener("click", () => {
        preview.extraArgs.splice(preview.extraArgs.indexOf(arg), 1);
        recompile();
        render();
      });
      row.append(name, kind, valueField(arg, (values) => { arg.value = values; }), remove);
      return row;
    };

    const render = () => {
      panel.replaceChildren();
      const declared = preview.declaredArguments();
      if (!declared.length && !preview.extraArgs.length) {
        panel.append(element("p", "pyshader-popover-empty", {
          textContent: "This shader asks for no arguments. Add a row to pass one it takes by name.",
        }));
      }
      for (const arg of declared) panel.append(declaredRow(arg));
      for (const arg of preview.extraArgs) panel.append(addedRow(arg, render));
      const add = element("button", "pyshader-popover-add", { type: "button", textContent: "+ Add argument" });
      add.addEventListener("click", () => {
        preview.extraArgs.push({ name: "", kind: "float", value: [] });
        render();
      });
      panel.append(add);
    };

    const setOpen = (isOpen) => {
      if (isOpen) render();
      panel.hidden = !isOpen;
      open.classList.toggle("pyshader-active", isOpen);
    };
    open.addEventListener("click", (e) => { e.stopPropagation(); setOpen(panel.hidden); });
    const outside = (e) => { if (!panel.hidden && !panel.contains(e.target)) setOpen(false); };
    const escape = (e) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("click", outside);
    document.addEventListener("keydown", escape);
    preview.disposers.push(() => {
      document.removeEventListener("click", outside);
      document.removeEventListener("keydown", escape);
    });

    // The draw call belongs to a vertex + fragment module, and to no other.
    let graphics = null;
    preview.onCompiled = () => {
      const isGraphics = preview.target() === "graphics";
      if (isGraphics === graphics) return;
      graphics = isGraphics;
      draw.replaceChildren();
      if (!isGraphics) return;
      const counts = preview.draw();
      draw.append(element("span", "pyshader-toolbar-label", { textContent: "Draw" }),
        ...[["vertices", "Vertices"], ["instances", "Instances"]].map(([key, label]) =>
          countField(label, counts[key], (value) => {
            preview.drawOverride = { ...preview.draw(), [key]: Math.max(1, Math.round(Number(value)) || 1) };
            rebuild();
          })));
    };
    preview.onCompiled();
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

    attachControls(preview, bar);
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
    const bar = preview.element.querySelector(".pyshader-toolbar");
    const group = document.createElement("span");
    group.className = "pyshader-toolbar-group pyshader-toolbar-clipboard";
    group.append(...clipboardButtons(editor, "code", (message) => preview.status(message, "error")));
    bar.append(group);
  }

  // ---------------------------------------------------------------------------
  // GLSL -> PyShader for `pyshader-convert` blocks

  let glslangPromise = null;

  /**
   * glslang built to wasm. glslang.js only exports a factory that hides the
   * Emscripten module and its print hooks, so the script's text is taken
   * instead and instantiated with hooks that collect the compiler's messages.
   */
  function loadGlslang() {
    if (glslangPromise) return glslangPromise;
    glslangPromise = (async () => {
      const url = new URL(config.glslang, document.baseURI);
      const response = await fetch(url);
      if (!response.ok) throw new Error(`glslang failed to load (${response.status})`);
      const text = await response.text();
      const cut = text.lastIndexOf("export default");
      const blob = new Blob([cut < 0 ? text : text.slice(0, cut), "\nexport { Module };\n"], { type: "text/javascript" });
      const blobUrl = URL.createObjectURL(blob);
      let factory;
      try {
        factory = (await import(blobUrl)).Module;
      } finally {
        URL.revokeObjectURL(blobUrl);
      }
      const messages = [];
      // Emscripten turns the settings object into the module itself and gives
      // it a `then`, which a Promise would adopt without end: hand back only
      // the compile function.
      const module = await new Promise((resolve, reject) => {
        const settings = {
          locateFile: (file) => new URL(file, url).href,
          print: (line) => messages.push(line),
          printErr: (line) => messages.push(line),
          onRuntimeInitialized: () => resolve({ compileGLSL: settings.compileGLSL }),
          onAbort: (why) => reject(new Error(`glslang failed to start: ${why}`)),
        };
        factory(settings);
      });
      return { module, messages };
    })();
    glslangPromise.catch(() => { glslangPromise = null; });
    return glslangPromise;
  }

  /** GLSL fragment source -> { spirv (bytes), messages }; throws with glslang's diagnostics. */
  async function compileGLSL(source) {
    const { module, messages } = await loadGlslang();
    messages.length = 0;
    // glslang's summary lines add nothing to the diagnostics themselves.
    const noise = /^(Parse failed|ERROR: \d+ compilation errors?\.|ERROR: \d+:\d+: '' : compilation terminated)/;
    const diagnostics = () => messages.filter((m) => m.trim() && !noise.test(m)).map((m) => m.trim());
    let words;
    try {
      words = module.compileGLSL(source, "fragment", true, "1.0");
    } catch (error) {
      throw new GLSLError(diagnostics().join("\n") || error.message);
    }
    return { spirv: new Uint8Array(words.buffer, words.byteOffset, words.byteLength), messages: diagnostics() };
  }

  class GLSLError extends Error {
    constructor(message) {
      super(message);
      // "ERROR: 0:12: 'foo' : undeclared identifier"
      this.markers = [...message.matchAll(/^(ERROR|WARNING): \d+:(\d+): (.*)$/gm)].map((m) => ({ line: Number(m[2]), message: m[3].trim(), error: m[1] === "ERROR" }));
    }
  }

  /** A string export of the Swift module (`pyshader_shadertoy_prelude` and the like). */
  function readExport(swift, name) {
    const size = swift[name](0, 0);
    if (size <= 0) return "";
    const buf = swift.pyshader_alloc(size);
    swift[name](buf, size);
    const text = decoder.decode(new Uint8Array(swift.memory.buffer, buf, size));
    swift.pyshader_dealloc(buf, size);
    return text;
  }

  /**
   * A pasted `mainImage` is wrapped in the decompiler's ShaderToy layout
   * (`ShaderToy.wrap` in Swift; its names are the compute target's, so the
   * result runs as a NucleantSwiftUI `Shader`). Its `#line 1` keeps
   * glslang's line numbers those of the pasted text. A source with its own
   * `#version` is compiled as it is, against NucleantVulkan's layout.
   */
  async function wrapGLSL(source) {
    if (/^\s*#\s*version\b/m.test(source)) return { glsl: source, interface: "nucleant" };
    const { swift } = await loadModules();
    const glsl = readExport(swift, "pyshader_shadertoy_prelude") + source + readExport(swift, "pyshader_shadertoy_epilogue");
    return { glsl, interface: "shadertoy" };
  }

  /** GLSL -> PyShader source; throws GLSLError or Error. */
  async function convertGLSL(source, options) {
    const wrapped = await wrapGLSL(source);
    const { spirv, messages } = await compileGLSL(wrapped.glsl);
    const result = await decompile(spirv, `interface=${wrapped.interface} ${options || ""}`);
    return { source: result.source, warnings: [...messages, ...result.warnings] };
  }

  let glslRegistered = false;

  /** A small GLSL highlighter; Monaco has none of its own. */
  function registerGLSL(monaco) {
    if (glslRegistered) return;
    glslRegistered = true;
    monaco.languages.register({ id: "glsl" });
    monaco.languages.setLanguageConfiguration("glsl", {
      comments: { lineComment: "//", blockComment: ["/*", "*/"] },
      brackets: [["{", "}"], ["[", "]"], ["(", ")"]],
      autoClosingPairs: [{ open: "{", close: "}" }, { open: "[", close: "]" }, { open: "(", close: ")" }],
    });
    monaco.languages.setMonarchTokensProvider("glsl", {
      keywords: ["break", "case", "const", "continue", "default", "discard", "do", "else", "for", "if", "in", "inout", "out",
        "return", "struct", "switch", "uniform", "while", "layout", "precision", "highp", "mediump", "lowp", "true", "false",
        "push_constant", "location", "binding", "set"],
      types: ["void", "bool", "int", "uint", "float", "double", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2",
        "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "mat2x2", "mat3x3", "mat4x4", "sampler2D",
        "samplerCube", "sampler3D"],
      builtins: ["abs", "acos", "all", "any", "asin", "atan", "ceil", "clamp", "cos", "cross", "degrees", "dFdx", "dFdy",
        "distance", "dot", "exp", "exp2", "faceforward", "floor", "fract", "fwidth", "inversesqrt", "length", "log", "log2",
        "max", "min", "mix", "mod", "normalize", "pow", "radians", "reflect", "refract", "round", "sign", "sin", "smoothstep",
        "sqrt", "step", "tan", "texture", "transpose", "inverse", "determinant", "trunc", "isnan", "isinf", "sinh", "cosh",
        "tanh", "asinh", "acosh", "atanh", "mainImage", "iTime", "iResolution", "iMouse", "iFrame", "iTimeDelta",
        "gl_FragCoord", "gl_FragColor", "iChannel0", "iChannel1", "iChannel2", "iChannel3"],
      tokenizer: {
        root: [
          [/^\s*#\s*\w+/, "keyword.directive"],
          [/[a-zA-Z_]\w*/, { cases: { "@keywords": "keyword", "@types": "type", "@builtins": "predefined", "@default": "identifier" } }],
          [/\/\/.*$/, "comment"],
          [/\/\*/, "comment", "@comment"],
          [/\d*\.\d+([eE][-+]?\d+)?[fF]?/, "number.float"],
          [/\d+([eE][-+]?\d+)?[fFuU]?/, "number"],
          [/[{}()[\]]/, "@brackets"],
          [/[<>=!+\-*/%&|^~?:,;.]/, "operator"],
        ],
        comment: [[/[^/*]+/, "comment"], [/\*\//, "comment", "@pop"], [/[/*]/, "comment"]],
      },
    });
  }

  const CONVERT_HELP = [
    "Paste a ShaderToy shader (its mainImage) on the left; the PyShader for it appears on the right.",
    "fragCoord → frag_coord, iResolution → resolution, iTime → time, iTimeDelta → time_delta, iFrame → frame, iMouse.xy → mouse, iMouse.zw → mouse_click.",
    "Those are the names NucleantSwiftUI's Shader and the previews on this site give main, so the result runs there as it is (unless it uses derivatives).",
    "Not translated: iChannel textures, iDate, iSampleRate, the keyboard.",
    "A source with its own #version line is compiled as it is, against NucleantVulkan's fragment layout (uv at location 0; push constants time, resolution, mouse).",
  ];

  /** One `pyshader-convert` block: a GLSL editor on the left, the PyShader it becomes on the right. */
  class Converter {
    constructor(element, data) {
      this.element = element;
      this.data = data;
      this.source = data.source;
      this.statusEl = element.querySelector(".pyshader-status");
      this.convertId = 0;
    }

    status(text, kind) {
      this.statusEl.textContent = text || "";
      this.statusEl.className = "pyshader-status" + (kind ? ` pyshader-status-${kind}` : "");
      this.statusEl.hidden = !text;
    }

    async mount() {
      const monaco = await loadMonaco();
      registerGLSL(monaco);
      const el = this.element;

      const bar = document.createElement("div");
      bar.className = "pyshader-toolbar";
      if (this.data.examples?.length) {
        const wrap = document.createElement("label");
        wrap.className = "pyshader-toolbar-group";
        wrap.append(Object.assign(document.createElement("span"), { className: "pyshader-toolbar-label", textContent: "Example" }));
        const select = document.createElement("select");
        select.append(new Option("paste your own…", ""));
        for (const ex of this.data.examples) select.append(new Option(ex.name, ex.name));
        const initial = this.data.examples.find((ex) => ex.source === this.source);
        select.value = initial ? initial.name : "";
        select.addEventListener("change", () => {
          const ex = this.data.examples.find((e) => e.name === select.value);
          if (ex) this.glsl.setValue(ex.source);
        });
        wrap.append(select);
        bar.append(wrap);
        this.select = select;
      }
      const help = Object.assign(document.createElement("button"), { type: "button", textContent: "?", title: "What this does" });
      const panel = document.createElement("div");
      panel.className = "pyshader-convert-help";
      panel.hidden = true;
      for (const line of CONVERT_HELP) panel.append(Object.assign(document.createElement("p"), { textContent: line }));
      help.addEventListener("click", () => {
        panel.hidden = !panel.hidden;
        help.classList.toggle("pyshader-active", !panel.hidden);
      });
      bar.append(Object.assign(document.createElement("span"), { className: "pyshader-toolbar-group" }), help);
      el.insertBefore(bar, this.statusEl);
      el.insertBefore(panel, this.statusEl);

      const panes = document.createElement("div");
      panes.className = "pyshader-convert-panes";
      const pane = (title) => {
        const box = document.createElement("div");
        box.className = "pyshader-convert-pane";
        box.append(Object.assign(document.createElement("div"), { className: "pyshader-convert-title", textContent: title }));
        const host = document.createElement("div");
        host.className = "pyshader-editor";
        box.append(host);
        panes.append(box);
        return host;
      };
      const glslHost = pane("GLSL");
      const pyHost = pane("PyShader");
      el.insertBefore(panes, this.statusEl);

      const dark = document.documentElement.dataset.mdColorScheme === "slate" || matchMedia("(prefers-color-scheme: dark)").matches;
      const common = { theme: dark ? "vs-dark" : "vs", minimap: { enabled: false }, fontSize: 13, lineNumbersMinChars: 3, scrollBeyondLastLine: false, automaticLayout: true, tabSize: 4, wordWrap: "off" };
      this.glsl = monaco.editor.create(glslHost, { ...common, value: this.source, language: "glsl" });
      this.py = monaco.editor.create(pyHost, { ...common, value: "", language: "python", readOnly: true });
      this.monaco = monaco;
      const onError = (message) => this.status(message, "error");
      const [pasteGlsl] = clipboardButtons(this.glsl, "GLSL", onError);
      const [, copyPy] = clipboardButtons(this.py, "PyShader", onError);
      bar.append(pasteGlsl, copyPy);
      this.themeObserver = new MutationObserver(() => {
        const scheme = document.documentElement.dataset.mdColorScheme;
        if (scheme) monaco.editor.setTheme(scheme === "slate" ? "vs-dark" : "vs");
      });
      this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ["data-md-color-scheme"] });

      const debounce = Number(this.data.debounce) > 0 ? Number(this.data.debounce) : 700;
      let timer = null;
      this.glsl.onDidChangeModelContent(() => {
        if (this.select && !this.data.examples.some((ex) => ex.source === this.glsl.getValue())) this.select.value = "";
        clearTimeout(timer);
        timer = setTimeout(() => this.convert(), debounce);
      });
      await this.convert();
    }

    async convert() {
      const source = this.glsl.getValue();
      const id = ++this.convertId;
      this.status("converting…", "busy");
      let result;
      try {
        result = await convertGLSL(source, "");
      } catch (error) {
        if (id !== this.convertId) return;
        this.status(error.message, "error");
        this.markers(error.markers || []);
        console.error(error);
        return;
      }
      if (id !== this.convertId) return;
      this.markers([]);
      this.py.setValue(result.source);
      this.status(result.warnings.length ? result.warnings.map((w) => `warning: ${w}`).join("\n") : "", "warning");
    }

    markers(list) {
      const model = this.glsl.getModel();
      const { MarkerSeverity } = this.monaco;
      this.monaco.editor.setModelMarkers(model, "glsl", list.filter((m) => m.line >= 1 && m.line <= model.getLineCount()).map((m) => ({
        severity: m.error ? MarkerSeverity.Error : MarkerSeverity.Warning,
        message: m.message,
        startLineNumber: m.line, startColumn: 1, endLineNumber: m.line, endColumn: model.getLineMaxColumn(m.line),
      })));
    }

    dispose() {
      this.themeObserver?.disconnect();
      this.glsl?.dispose();
      this.py?.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Wiring

  const previews = new Map();
  const converters = new Map();

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
    for (const element of root.querySelectorAll(".pyshader-convert[data-pyshader-convert]")) {
      if (converters.has(element)) continue;
      const converter = new Converter(element, JSON.parse(element.dataset.pyshaderConvert));
      converters.set(element, converter);
      converter.mount().catch((e) => { converter.status(e.message, "error"); console.error(e); });
    }
  }

  function unmountAll() {
    for (const [element, preview] of previews) {
      visibility.unobserve(element);
      preview.dispose();
      preview.editor?.dispose();
    }
    previews.clear();
    for (const converter of converters.values()) converter.dispose();
    converters.clear();
  }

  // Material's instant navigation swaps the page without a reload.
  if (window.document$ && typeof window.document$.subscribe === "function") {
    window.document$.subscribe(() => { unmountAll(); mount(document); });
  } else if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => mount(document));
  } else {
    mount(document);
  }

  window.PyShaderPreview = { compile, decompile, convertGLSL, mount, previews, converters };
})();
