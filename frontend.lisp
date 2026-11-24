;;;; Boot driver for FriCAS in a PDF, loaded by frontend.c when the PDF has no
;;;; memory image yet (when tools/snapshot.mjs runs it during the build).
;;;;
;;;; fricas.lisp loads FriCAS and then runs its top level, which blocks on stdin.
;;;; PDF-BOOT-STEP instead evaluates fricas.lisp one form per call, and
;;;; lisp/interp.lisp one form (one file) per call, so the viewer stays responsive
;;;; and can show progress. The last form of fricas.lisp, the one that calls
;;;; (|spad|), is replaced by toplevel.lisp.

(in-package "CL-USER")

;; fricas-package.lisp does (require 'cmp) and fricas-lisp.lisp reads
;; c:build-program. This ECL is built without the C compiler.
(provide "CMP")
(unless (find-package "C") (make-package "C" :use nil))
(export (intern "BUILD-PROGRAM" "C") "C")

(setq *load-verbose* nil *compile-verbose* nil)
;; no source-location annotations for the definitions in lisp/*.lisp
(setq ext:*register-with-pde-hook* nil)

;; Load .fasc files from memory. ECL's loader reads them through the C library,
;; a few bytes per read() call, and each call into the JavaScript file system
;; costs more than the bytes it returns.
(defun pdf-load-bytecodes (file verbose print external-format)
  (declare (ignore external-format))
  (let ((bytes (with-open-file (in file :element-type '(unsigned-byte 8))
                 (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
                   (read-sequence v in)
                   v))))
    (si::load-bytecodes (ext:make-sequence-input-stream bytes :external-format :utf-8)
                        verbose print :utf-8)))

(dolist (hook si::*load-hooks*)
  (when (eq (cdr hook) 'si::load-bytecodes)
    (setf (cdr hook) 'pdf-load-bytecodes)))

;; Open source files, innermost first: (stream . package). As LOAD does,
;; *PACKAGE* is saved per file.
(defvar *pdf-files* '())

(defun pdf-open (file)
  (push (cons (open file) *package*) *pdf-files*))

(defun pdf-calls-spad-p (form)
  (let ((spad (and (find-package "BOOT") (find-symbol "spad" "BOOT"))))
    (labels ((walk (x) (cond ((eq x spad) t)
                             ((consp x) (or (walk (car x)) (walk (cdr x)))))))
      (and spad (walk form)))))

(defun pdf-progress (form)
  (format t "~C~C[K" #\Return #\Escape)
  (when (and (consp form) (symbolp (first form)) (stringp (second form))
             (member (symbol-name (first form)) '("LOAD" "LOAD2") :test #'string=))
    (format t "Loading ~A" (second form)))
  (finish-output))

;; Evaluate the next form. Returns T while forms remain, then NIL; frontend.c
;; then calls BOOT::PDF-START.
(defun pdf-boot-step ()
  (handler-case
      (loop
        (when (null *pdf-files*)
          (format t "~C~C[K" #\Return #\Escape)
          (return nil))
        (let* ((file (first *pdf-files*))
               (*package* (cdr file))
               (form (read (car file) nil file)))
          (cond ((eq form file)
                 (close (car (pop *pdf-files*))))
                ((equal form '(load "lisp/interp.lisp"))
                 (setf (cdr file) *package*)
                 (pdf-open "lisp/interp.lisp")
                 (return t))
                ((pdf-calls-spad-p form)) ; replaced by toplevel.lisp
                (t
                 (pdf-progress form)
                 (eval form)
                 (setf (cdr file) *package*)
                 (return t)))))
    (serious-condition (c)
      (let ((*print-length* 3) (*print-level* 2))
        (format t "~&Error while loading ~A:~%~A~%"
                (and *pdf-files* (pathname (car (first *pdf-files*)))) c))
      :error)))

(pdf-open "toplevel.lisp")
(pdf-open "fricas.lisp")
