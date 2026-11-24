# fricas-pdf

The [FriCAS](https://fricas.github.io) computer algebra system as a PDF file, for Chromium's
PDF viewer. Built with [pdfcc](https://github.com/wangyenshu/pdfcc).

FriCAS here is [fricas0](https://github.com/oldk1331/fricas0) 1.3.13 (FriCAS's interpreter and
algebra as Common Lisp) on ECL 26.5.5, compiled to JavaScript. The build follows
emscripten-forge's `fricas0-ecl` and `fricas0-data` recipes.

```
./build.sh                       # clones pdfcc, runs its ./setup.sh --async
PDFCC_DIR=~/pdfcc ./build.sh     # existing pdfcc checkout, after its ./setup.sh --async
tests/run.sh                     # checks fricas.pdf in pdfcc's simulator
```

Needs Linux x86-64, gcc, make, git, curl, Python 3. The first build takes about 15 minutes,
plus pdfcc's setup. Output: `fricas.pdf`, 27 MB.

## Build steps (`build.sh`)

1. Native ECL.
2. ECL for Emscripten with its own build system, as in pdfcc's `examples/ecl`: `-O2`,
   bytecode compiler only (`--with-cmp=no`). Neutral install prefix and file names, so that
   no path of the build machine ends up in the PDF; `build.sh` checks `fricas.tar` and
   `fricas.mem` for the build directory.
3. The native ECL compiles FriCAS's Lisp to ECL bytecode (`.fasc`), as in the recipe, but
   without source-location annotations (22% smaller). The bytecode, the databases
   (`*.daase`), `msgs/` and `lib/` are packed in `fricas.tar`. HyperDoc data is left out.
4. pdfcc links `frontend.c` with `libecl.a` and embeds `fricas.tar`: `fricas-noimage.pdf`.
5. `tools/snapshot.mjs` runs that PDF's JavaScript in Node with a mock of the viewer API.
   FriCAS starts, evaluates `warm-up.input`, and the program's memory is saved to
   `fricas.mem`. `inject.py` (pdfcc) puts it into the PDF: `fricas.pdf`.

## In the viewer

`frontend.c` unpacks `fricas.tar` into the in-memory file system, copies `fricas.mem` over the
program's memory (skipping the C stack), and reopens the database files at the saved
positions. FriCAS is then in the state it had after the warm-up: the code of the domains used
by `warm-up.input` is already loaded.

Without the image (`fricas-noimage.pdf`) the program starts ECL and evaluates `fricas.lisp`
one form per frame (`frontend.lisp`): 45 s in Chrome instead of 5 s.

FriCAS's top level blocks on stdin. `toplevel.lisp` replaces it: each typed line is processed
by `pdf-line`, which does one iteration of FriCAS's `intloopReadConsole`. A confirmation query
(`)display operations`) is printed and the command abandoned; the next line is the answer, and
the command is run again with it.

`pre.js` makes pdfcc decode the embedded files with `Uint8Array.fromBase64`, which Chrome's
PDF viewer has: 0.1 s instead of 4 s for the 112 MB of base64.

Measured in Chrome 153 (Linux, x86-64); command times from `)set message time on`. For
comparison, the same bytecode on native ECL after the same warm-up:

| | Chrome | native ECL |
|---|---|---|
| startup | 5 s | |
| `factor(x^6-1)` | 0.4 s | <0.01 s |
| `integrate(x^3*cos(x),x)` | 9.1 s | 0.16 s |
| `eigenvalues(matrix [[1,2],[3,4]])` (loads more domains) | 3.5 s | 0.05 s |

## Limitations

- Chromium-based viewers only (pdfcc).
- PDF JavaScript runs without a JIT: 50-70× slower than the same bytecode on native ECL.
  The viewer does not respond during a computation. The first use of a domain that is not
  preloaded reads its bytecode, which adds seconds.
- Recursion is limited by V8's stack: about 500 nested calls of a user function. Deeper
  calls end with "Recursion too deep for the viewer's JavaScript stack" and a new prompt.
- `)quit` and `)lisp (quit)` only print a note.
- No HyperDoc or graphics. `)set message time on` shows elapsed time: the viewer has no CPU
  time. Files written by FriCAS live in memory until the PDF is closed.

## Files

| file | |
|---|---|
| `build.sh` | build steps above |
| `frontend.c` | unpack, restore the image or start step by step, line input, recovery from JavaScript stack overflow |
| `frontend.lisp` | startup without image: `fricas.lisp` one form at a time; loads `.fasc` from memory |
| `toplevel.lisp` | FriCAS top level, one line per call; queries; warm-up |
| `warm-up.input` | expressions evaluated before the image is taken |
| `pre.js` | native base64 decoding for pdfcc's embedded files |
| `tools/snapshot.mjs` | runs the PDF in Node and writes the memory image |
| `tests/run.sh` | checks with pdfcc's `tests/pdfsim.mjs` |

## License

GPL v2 (`LICENSE`), as pdfcc. The PDF also contains FriCAS (modified BSD) and ECL (LGPL 2.1+),
which the build downloads.
