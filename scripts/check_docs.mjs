#!/usr/bin/env node
// Compiles every pyshader fence in docs/ through the same wasm modules the
// site uses (pyshader.wasm -> naga.wasm), with the modules the site hands
// it: the installed libraries (pyshader-stdlib, as the docs environment has
// it) and a fence's own `modules="…"` folder. A snippet that fails in the
// browser fails here first. Run after scripts/build_wasm.py.
//
//   node scripts/check_docs.mjs
//   PYSHADER_STDLIB=../pyshader-stdlib node scripts/check_docs.mjs   # a stdlib checkout instead
import { WASI } from 'node:wasi';
import { execFileSync } from 'node:child_process';
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

/** Every `.py` file under `folder` by dotted name, as the plugin's folder_modules has them. */
function folderModules(folder, prefix = '') {
  const out = {};
  for (const file of fs.readdirSync(folder, { recursive: true }).filter((f) => f.endsWith('.py')).sort()) {
    const parts = file.slice(0, -3).split(path.sep);
    if (parts.includes('__pycache__')) continue;
    if (parts[parts.length - 1] === '__init__') parts.pop();
    const name = [...(prefix ? [prefix] : []), ...parts].join('.');
    if (name) out[name] = fs.readFileSync(path.join(folder, file), 'utf8');
  }
  return out;
}

/** The libraries the site ships as modules.json: the plugin's own list, from the docs environment. */
function installedModules() {
  if (process.env.PYSHADER_STDLIB) {
    return folderModules(path.join(path.resolve(process.env.PYSHADER_STDLIB), 'src', 'pyshader', 'stdlib'), 'pyshader.stdlib');
  }
  const script = 'import json; from mkdocs_pyshader.plugin import installed_modules; print(json.dumps(installed_modules()))';
  return JSON.parse(execFileSync('uv', ['run', '--group', 'docs', 'python', '-c', script], { cwd: root, encoding: 'utf8' }));
}

const libraries = installedModules();
console.log(`${Object.keys(libraries).length} library modules${process.env.PYSHADER_STDLIB ? ` from ${process.env.PYSHADER_STDLIB}` : ''}`);

function registerModules(local) {
  sw.pyshader_clear_modules();
  for (const [name, source] of Object.entries({ ...libraries, ...local })) {
    const n = enc.encode(name), s = enc.encode(source);
    sw.pyshader_add_module(put(sw, 'pyshader_alloc', n), n.length, put(sw, 'pyshader_alloc', s), s.length);
  }
}

function compile(source, options, local = {}) {
  registerModules(local);
  const src = enc.encode(source), opt = enc.encode(options);
  const rc = sw.pyshader_compile(put(sw, 'pyshader_alloc', src), src.length, put(sw, 'pyshader_alloc', opt), opt.length);
  const out = new Uint8Array(sw.memory.buffer, sw.pyshader_result_ptr(), sw.pyshader_result_len()).slice();
  if (rc !== 0) return { error: dec.decode(out) };
  const nrc = ng.naga_spirv_to_wgsl(put(ng, 'naga_alloc', out), out.length);
  const text = dec.decode(new Uint8Array(ng.memory.buffer, ng.naga_result_ptr(), ng.naga_result_len()));
  if (nrc !== 0) return { error: `naga: ${text}` };
  return { wgsl: text };
}

// The target and the arguments a block does not name are read off its source,
// by the preview's own rules: its code is taken from the asset so the two cannot drift.
const previewJs = fs.readFileSync(path.join(assets, 'pyshader-preview.js'), 'utf8');
const from = previewJs.indexOf('// What a source asks for'), to = previewJs.indexOf('// WebGPU');
if (from < 0 || to < from) throw new Error('pyshader-preview.js: cannot find the detection helpers');
const { detectTarget, detectArguments } = new Function(`${previewJs.slice(from, to)}\nreturn { detectTarget, detectArguments };`)();

// ```pyshader[-preview|-edit] key="value" ...\n...\n``` (pyshader-convert holds GLSL; not checked here)
const fence = /^```(pyshader(?:-preview|-edit)?)(?![\w-])([^\n]*)\n([\s\S]*?)^```/gm;
const optionRe = /([a-zA-Z_]+)=(?:"([^"]*)"|'([^']*)')/g;

let failures = 0, count = 0;
const files = fs.readdirSync(path.join(root, 'docs'), { recursive: true }).filter((f) => f.endsWith('.md'));
for (const file of files) {
  const text = fs.readFileSync(path.join(root, 'docs', file), 'utf8');
  for (const m of text.matchAll(fence)) {
    const options = {};
    for (const o of m[2].matchAll(optionRe)) options[o[1]] = o[2] ?? o[3];
    const source = options.file ? fs.readFileSync(path.join(root, options.file), 'utf8') : m[3];
    const parts = [`target=${options.target ?? detectTarget(source)}`];
    if (options.content || /\blayer\s*\(/.test(source)) parts.push('content=1');
    const declared = (options.args ?? '').split(',')
      .map((arg) => /^\s*(\w+)\s*:\s*(\w+)/.exec(arg)).filter(Boolean)
      .map((a) => ({ name: a[1], kind: a[2] }));
    for (const arg of declared.length ? declared : detectArguments(source)) parts.push(`arg=${arg.name}:${arg.kind}`);
    const line = text.slice(0, m.index).split('\n').length;
    const local = options.modules ? folderModules(path.join(root, options.modules)) : {};
    const result = compile(source, parts.join(' '), local);
    count++;
    if (result.error) {
      failures++;
      console.log(`FAIL ${file}:${line} ${options.file ?? ''}\n     ${result.error}`);
    }
  }
}
console.log(`${count - failures}/${count} pyshader blocks compile`);
process.exit(failures ? 1 : 0);
