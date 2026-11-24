#!/bin/bash
# Checks fricas.pdf in pdfcc's Node simulator (tests/pdfsim.mjs). Build it first.
#   PDFCC_DIR=/path/to/pdfcc tests/run.sh [file.pdf]
# Each step waits for output with --until (30 s timeout per --until in pdfsim).
cd "$(dirname "$0")/.." || exit 1
PDF=${1:-fricas.pdf}
PDFCC_DIR=${PDFCC_DIR:-pdfcc}
SIM=(node "$PDFCC_DIR/tests/pdfsim.mjs" "$PDF" --until "(1) ->")
pass=0; fail=0

check() { # description, expected text, pdfsim steps...
  local name="$1" want="$2"; shift 2
  local got; got=$("${SIM[@]}" "$@" 2>&1)
  if grep -qF -- "$want" <<<"$got"; then echo "ok    $name"; pass=$((pass+1));
  else echo "FAIL  $name: expected '$want'"; echo "$got" | tail -15 | sed 's/^/      /'; fail=$((fail+1)); fi
}

check "startup" "Started in" --until "Started"
check "arithmetic" "(1)  5" --type '2+3\n' --until "(2) ->"
check "factor" "(x - 1)(x + 1)(x  - x + 1)(x  + x + 1)" --type 'factor(x^6-1)\n' --until "(2) ->"
check "integrate" "(x  - 6 x)sin(x) + (3 x  - 6)cos(x)" \
  --type 'integrate(x^3*cos(x),x)\n' --until "(2) ->" --until "(2) ->"
check "continued line" "(1)  6" --type '1 + _\n' --type '5\n' --until "(2) ->"
check "user function" "(2)  3628800" \
  --type 'f(n) == if n < 2 then 1 else n*f(n-1)\n' --until "(2) ->" --type 'f 10\n' --until "(3) ->"
check "library error" "division by zero" --type '1/0\n' --until "(1) ->" --until "zero"
check "lisp error" "which is not of the expected type CONS" --type ')lisp (car 1)\n' --until "CONS"
check "system command" "INT abbreviates domain Integer" --type ')abbreviation query INT\n' --until "abbreviates"
# a query is answered by the next line; the command then runs again with that answer
check "query" "the list of" --type ')display operations\n' --until "confirm" --type 'n\n' --until "list of"
check "quit" "close it to quit" --type ')quit\n' --until "close it"
check "lisp quit" "(1)  2" --type ')lisp (ext:quit)\n' --until "(1) ->" --type ')lisp (quit)\n' --until "close it" \
  --type '1+1\n' --until "(1)  2"
# a JavaScript stack overflow returns to the top level; later input still works
check "stack overflow" "(1)  7" --type ')lisp (defun d (n) (if (= n 0) 0 (1+ (d (1- n)))))\n' \
  --until "Value = D" --type ')lisp (d 1000000)\n' --until "too deep" --type '3+4\n' --until "(2) ->"
check "utf-8" '"é€"' --type '"é€"\n' --until "(2) ->"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
