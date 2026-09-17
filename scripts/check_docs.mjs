#!/usr/bin/env node
// Compiles every pyshader fence in docs/ through the same wasm modules the
// site uses (pyshader.wasm -> naga.wasm), so a snippet that fails in the
// browser fails here first. Run after scripts/build_wasm.py.
import { WASI } from 'node:wasi';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const assets = path.join(root, 'mkdocs-pyshader', 'mkdocs_pyshader', 'assets');

const wasi = new WASI({ version: 'preview1', args: [], env: {} });
const { instance: swift } = await WebAssembly.instantiate(fs.readFileSync(path.join(assets, 'pyshader.wasm')), { wasi_snapshot_preview1: wasi.wasiImport });
wasi.initialize(swift);
const { instance: naga } = await WebAssembly.instantiate(fs.readFileSync(path.join(assets, 'naga.wasm')), {});
const sw = swift.exports, ng = naga.exports;
const enc = new TextEncoder(), dec = new TextDecoder();

function put(exports, alloc, bytes) { const p = exports[alloc](bytes.length); new Uint8Array(exports.memory.buffer, p, bytes.length).set(bytes); return p; }

function compile(source, options) {
  const src = enc.encode(source), opt = enc.encode(options);
  const rc = sw.pyshader_compile(put(sw, 'pyshader_alloc', src), src.length, put(sw, 'pyshader_alloc', opt), opt.length);
  const out = new Uint8Array(sw.memory.buffer, sw.pyshader_result_ptr(), sw.pyshader_result_len()).slice();
  if (rc !== 0) return { error: dec.decode(out) };
  const nrc = ng.naga_spirv_to_wgsl(put(ng, 'naga_alloc', out), out.length);
  const text = dec.decode(new Uint8Array(ng.memory.buffer, ng.naga_result_ptr(), ng.naga_result_len()));
  if (nrc !== 0) return { error: `naga: ${text}` };
  return { wgsl: text };
}

// ```pyshader[-preview|-edit] key="value" ...\n...\n```
const fence = /^```(pyshader(?:-preview|-edit)?)([^\n]*)\n([\s\S]*?)^```/gm;
const optionRe = /([a-zA-Z_]+)=(?:"([^"]*)"|'([^']*)')/g;

let failures = 0, count = 0;
const files = fs.readdirSync(path.join(root, 'docs'), { recursive: true }).filter((f) => f.endsWith('.md'));
for (const file of files) {
  const text = fs.readFileSync(path.join(root, 'docs', file), 'utf8');
  for (const m of text.matchAll(fence)) {
    const options = {};
    for (const o of m[2].matchAll(optionRe)) options[o[1]] = o[2] ?? o[3];
    const source = options.file ? fs.readFileSync(path.join(root, options.file), 'utf8') : m[3];
    const parts = [`target=${options.target ?? 'compute'}`];
    if (options.content || /\blayer\s*\(/.test(source)) parts.push('content=1');
    for (const arg of (options.args ?? '').split(',')) {
      const a = /^\s*(\w+)\s*:\s*(\w+)/.exec(arg);
      if (a) parts.push(`arg=${a[1]}:${a[2]}`);
    }
    const line = text.slice(0, m.index).split('\n').length;
    const result = compile(source, parts.join(' '));
    count++;
    if (result.error) {
      failures++;
      console.log(`FAIL ${file}:${line} ${options.file ?? ''}\n     ${result.error}`);
    }
  }
}
console.log(`${count - failures}/${count} pyshader blocks compile`);
process.exit(failures ? 1 : 0);
