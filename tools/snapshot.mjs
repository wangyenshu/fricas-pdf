// Runs fricas.pdf's JavaScript in Node until FriCAS has started, then writes the
// program's memory to a file (format: see frontend.c, "snapshot").
//
//   node tools/snapshot.mjs fricas.pdf fricas.mem
//
// The PDF is parsed and its page-open action chain run against a minimal mock of
// the viewer API, as in pdfcc's tests/pdfsim.mjs. frontend.c sees the global
// fricasSnapshot, runs (boot::pdf-warm-up) after startup and passes its memory.
import fs from "node:fs";
import vm from "node:vm";
import zlib from "node:zlib";

const [pdfPath, outPath] = process.argv.slice(2);
if (!outPath) { console.error("usage: node tools/snapshot.mjs fricas.pdf fricas.mem"); process.exit(2); }

// ---- the PDF's objects (later versions win), the open action and its /Next chain ----
const buf = fs.readFileSync(pdfPath);
const text = buf.toString("latin1");
const objs = {};
for (const m of text.matchAll(/(\d+) 0 obj\n/g)) {
  const start = m.index + m[0].length, end = text.indexOf("\nendobj", start);
  let body = text.slice(start, end), stream = null;
  const si = body.indexOf("\nstream\n");
  if (si >= 0) {
    const len = +/\/Length (\d+)/.exec(body)[1];
    const raw = buf.subarray(start + si + 8, start + si + 8 + len);
    stream = /FlateDecode/.test(body.slice(0, si)) ? zlib.inflateSync(raw) : raw;
    body = body.slice(0, si);
  }
  objs[+m[1]] = { body, stream };
}
const ref = (body, key) => { const r = new RegExp("/" + key + " (\\d+) 0 R").exec(body); return r ? +r[1] : null; };
const page = Object.values(objs).find(o => /\/Type \/Page\b/.test(o.body));
const scripts = [];
for (let a = +/\/AA <<\/O (\d+) 0 R/.exec(page.body)[1]; a; a = ref(objs[a].body, "Next"))
  scripts.push(objs[ref(objs[a].body, "JS")].stream.toString("latin1"));

// ---- mock viewer, in its own context ----
const fields = {};
let line = "";
const sandbox = {
  app: {
    setInterval: (expr, ms) => setInterval(() => run(expr), Math.max(1, ms)),
    setTimeOut: (expr, ms) => setTimeout(() => run(expr), Math.max(1, ms)),
    clearInterval: h => clearInterval(h), clearTimeOut: h => clearTimeout(h),
    alert: msg => console.log("[alert] " + msg),
  },
  getField: name => fields[name] || (fields[name] = { name, value: "" }),
  console: { log() {}, warn() {}, error() {} },
  fricasSnapshot(mem, info) {
    if (!mem) { console.error(`snapshot: ${info.error}`); process.exit(1); }
    // chunks of 4 KB that are not all zero, in [0, stack start) and [stack end, size)
    const chunks = [], parts = [], PAGE = 4096;
    for (const [from, to] of [[0, info.stack[0]], [info.stack[1], info.size]]) {
      for (let a = from; a < to; a += PAGE) {
        const b = Math.min(a + PAGE, to);
        let zero = true;
        for (let i = a; i < b; i++) if (mem[i]) { zero = false; break; }
        if (zero) continue;
        const last = chunks[chunks.length - 1];
        if (last && last[0] + last[1] === a) last[1] += b - a; else chunks.push([a, b - a]);
        parts.push(mem.subarray(a, b));
      }
    }
    const head = Buffer.from(JSON.stringify({ ...info, chunks }));
    const len = Buffer.alloc(4);
    len.writeUInt32LE(head.length);
    fs.writeFileSync(outPath, Buffer.concat([Buffer.from("FMEM"), len, head, ...parts]));
    const data = parts.reduce((n, p) => n + p.length, 0);
    console.log(`\n${outPath}: memory ${(info.size / 1e6).toFixed(1)} MB, ` +
                `${(data / 1e6).toFixed(1)} MB not zero, ${info.files.length} open files`);
    process.exit(0);
  },
};
const ctx = vm.createContext(sandbox);
function run(code) { return vm.runInContext(code, ctx); }

run(scripts[0]); // pdfcc runtime: defines Module; show the program's output here too
const termByte = sandbox.Module.stdout;
let esc = false; // inside an escape sequence: ESC [ parameters final-byte
sandbox.Module.stdout = sandbox.Module.stderr = b => {
  termByte(b);
  if (esc) esc = b === 91 || b < 64 || b > 126;
  else if (b === 27) esc = true;
  else if (b === 10) { console.log(line); line = ""; }
  else if (b === 13) line = "";
  else line += String.fromCharCode(b & 255);
};
for (const js of scripts.slice(1)) run(js);
setTimeout(() => { console.error("snapshot: timed out"); process.exit(1); }, 20 * 60 * 1000);
