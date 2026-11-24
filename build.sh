#!/bin/bash
# Builds fricas.pdf: FriCAS (fricas0, its Common Lisp form) on ECL, packaged by pdfcc.
# Needs Linux, gcc, make, git, curl, Python 3. Steps 1-3 run once (~15 min).
#
#   PDFCC_DIR=/path/to/pdfcc ./build.sh    # use an existing pdfcc checkout
set -e
cd "$(dirname "$0")"
HERE=$PWD
ECL_V=26.5.5
ECL_SHA256=a01a5bcda8c5b73e59dda3494fd13e5fec5db6aa1dad782c3cc3bb57f1633435
FRICAS_V=1.3.13
FRICAS_REV=247e2506d70bc860047c125f1f5df83a65bac2f1
PDFCC_REV=462b76ccccd5a0d766b3bc2eb2ee7e2c58bb965b
JOBS=$(nproc)

die() { echo "build.sh: $*" >&2; exit 1; }

# 0. pdfcc, with its Emscripten 4.0.12 toolchain
PDFCC_DIR=${PDFCC_DIR:-$HERE/pdfcc}
if [ ! -f "$PDFCC_DIR/bin/pdfcc" ]; then
  git clone https://github.com/wangyenshu/pdfcc "$PDFCC_DIR"
  git -C "$PDFCC_DIR" checkout -q "$PDFCC_REV"
fi
PDFCC=(python3 "$PDFCC_DIR/bin/pdfcc")
"${PDFCC[@]}" --env --toolchain upstream >/dev/null 2>&1 || bash "$PDFCC_DIR/setup.sh" --async
EMSDK_ENV=$("${PDFCC[@]}" --env --toolchain upstream) || die "pdfcc has no Emscripten 4.0.12"

if [ ! -f "ecl-$ECL_V.tgz" ]; then
  curl -fL -o "ecl-$ECL_V.tgz.part" "https://ecl.common-lisp.dev/static/files/release/ecl-$ECL_V.tgz"
  mv "ecl-$ECL_V.tgz.part" "ecl-$ECL_V.tgz"
fi
echo "$ECL_SHA256  ecl-$ECL_V.tgz" | sha256sum -c --quiet - || die "ecl-$ECL_V.tgz: wrong checksum"
[ -d fricas0 ] || git clone -q --depth 1 --branch "$FRICAS_V" https://github.com/oldk1331/fricas0
[ "$(git -C fricas0 rev-parse HEAD)" = "$FRICAS_REV" ] || die "fricas0 is not at tag $FRICAS_V ($FRICAS_REV)"

# 1. Native ECL. It compiles ECL's Lisp sources to C in step 2 and FriCAS to bytecode in step 3.
if [ ! -x host/bin/ecl ]; then
  rm -rf build-host && mkdir build-host && tar xzf "ecl-$ECL_V.tgz" -C build-host
  (cd "build-host/ecl-$ECL_V" && ./configure --prefix="$HERE/host" && make -j"$JOBS" && make install)
fi

# 2. ECL for Emscripten, as in pdfcc's examples/ecl: ECL's own build, -O2 instead of -O0,
#    bytecode compiler only (--with-cmp=no). No paths of this machine end up in the PDF: a
#    neutral prefix (installed through DESTDIR), relative __FILE__ names, and no source
#    directory for ECL's SRC: logical host.
if [ ! -f target/libecl.a ]; then
  rm -rf build-target target-stage target && mkdir build-target && tar xzf "ecl-$ECL_V.tgz" -C build-target
  (
    cd "build-target/ecl-$ECL_V"
    sed -i 's/VARIADIC_DISPATCH -O0"/VARIADIC_DISPATCH -O2"/' src/configure
    grep -q 'VARIADIC_DISPATCH -O2"' src/configure || die "src/configure: -O0 not found"
    sed -i 's|#.(truename "@true_srcdir@/")|#P"/ecl/src/"|' src/lsp/config.lsp.in
    grep -q '#P"/ecl/src/"' src/lsp/config.lsp.in || die "src/lsp/config.lsp.in: srcdir not found"
    eval "$EMSDK_ENV"
    export ECL_TO_RUN=$HERE/host/bin/ecl
    BUILD=$(sh src/config.guess)
    CFLAGS="-O2 -ffile-prefix-map=$PWD=ecl-$ECL_V" emconfigure ./configure \
      --host=wasm32-unknown-emscripten --build="$BUILD" \
      --with-cross-config="$PWD/src/util/wasm32-unknown-emscripten.cross_config" \
      --prefix=/ecl --disable-shared --with-tcp=no --with-cmp=no
    emmake make -j"$JOBS"
    emmake make install DESTDIR="$HERE/target-stage"
  )
  mv target-stage/ecl target && rmdir target-stage
fi

# 3. FriCAS compiled to ECL bytecode (.fasc) by the native ECL, as in emscripten-forge's
#    fricas0-ecl recipe; without source-location annotations (22% smaller, faster to load).
#    ECL exits with 0 even if a file fails to compile: every source must have its .fasc.
compile_fricas() {
  local ecl=$HERE/host/bin/ecl noannot='(setq ext:*register-with-pde-hook* nil)' f
  rm -rf data && cp -r fricas0 data && rm -rf data/.git && cd data || return 1
  "$ecl" -norc -eval "(progn $noannot (load \"lisp/load-lisp.lisp\") (load \"lisp/compile-interp.lisp\") (quit))" || return 1
  echo ")lisp (progn $noannot (load \"lisp/compile-algebra.lisp\") (quit))" | "$ecl" -norc -load fricas || return 1
  for f in interp/*.lisp algebra/*.lsp; do
    [ -f "${f%.*}.fasc" ] || { echo "not compiled: $f"; return 1; }
  done
  rm -f interp/*.lisp algebra/*.lsp lisp/compile-*.lisp algebra/*.text
  rm -rf algebra/*.DAASE update-fricas-sources.sh README.rest
  touch .compiled
}
if [ ! -f data/.compiled ]; then
  (compile_fricas) > build-fricas.log 2>&1 || { tail -20 build-fricas.log; die "step 3 failed"; }
fi
cp frontend.lisp toplevel.lisp warm-up.input data/
(cd data && tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
   -cf ../fricas.tar -- *)

# 4. Link the front end with ECL. Embed fricas.tar; leave a slot for the memory image.
"${PDFCC[@]}" --toolchain upstream frontend.c -Itarget target/libecl.a target/libeclgc.a target/libeclgmp.a \
  -O2 -sBINARYEN_EXTRA_PASSES=--spill-pointers --stack 2048 --memory 256 --memory-growth \
  --pre-js pre.js --file fricas.tar:/fricas.tar --slot image:/fricas.mem -o fricas-noimage.pdf \
  --title "FriCAS" --terminal 80x36 --dark \
  --subtitle "FriCAS $FRICAS_V (fricas0) on ECL $ECL_V, built with pdfcc." \
  --help-line "Click the box on the right, type a FriCAS command, press Enter." \
  --help-line "The first use of a domain that is not preloaded loads its code: slow."

# 5. Start FriCAS with the PDF's own JavaScript in Node, evaluate warm-up.input, save the
#    program's memory and put it in the slot: the PDF starts from there.
(
  eval "$EMSDK_ENV"
  node tools/snapshot.mjs fricas-noimage.pdf fricas.mem > build-snapshot.log 2>&1
) || { tail -20 build-snapshot.log; die "step 5 failed"; }
for f in fricas.tar fricas.mem; do # what the PDF embeds
  ! grep -qaF "$HERE" "$f" || die "$f contains the path $HERE"
done
python3 "$PDFCC_DIR/tools/inject.py" fricas-noimage.pdf -o fricas.pdf --file image=fricas.mem
ls -l fricas.pdf
