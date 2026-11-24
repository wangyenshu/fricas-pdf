// Passed to emcc with --pre-js; runs after pdfcc's runtime, before the embedded files
// are decoded. pdfcc decodes them with a base64 loop in JavaScript. Chrome's PDF viewer
// has Uint8Array.fromBase64, which is about 30x faster: 4 s less startup for this PDF.
if (typeof pdfcc === "object" && typeof Uint8Array.fromBase64 === "function")
  pdfcc.b64decode = function (s) { return Uint8Array.fromBase64(s); };
