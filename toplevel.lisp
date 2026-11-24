;;;; FriCAS top level for the PDF, loaded by frontend.lisp after fricas.lisp.
;;;;
;;;; FriCAS's own loop (|spad| -> |ncTopLevel| -> |SpadInterpretStream| ->
;;;; |intloopReadConsole| in interp/int-top.lisp) blocks on stdin. Here
;;;; frontend.c calls PDF-LINE once per typed line, and PDF-LINE does what one
;;;; iteration of intloopReadConsole does. The dynamic bindings made by the
;;;; functions around that loop are global assignments.

(in-package "BOOT")

(declaim (special |$PrintCompilerMessageIfTrue| |$InteractiveMode| |$e| *eof*
                  |$inclAssertions| |$lastPos| |$erMsgToss| |$ncMsgList|
                  |$InteractiveFrame| |$nopos| $dalymode))

(defvar *pdf-lines* '() "continued lines (ending in _), most recent first")
(defvar *pdf-step* 1)
(defvar *pdf-pending* nil "(lines line . answers): command to run again once its query is answered")
(defvar *pdf-answers* '() "answers to the queries of the command being run again, in order")

;; |SpadInterpretStream|, as entered after (re)start; also called by frontend.c
;; after restoring the memory image
(defun pdf-restart ()
  (setq *pdf-lines* '() *pdf-step* 1 *pdf-pending* nil *pdf-answers* '())
  (|resetStackLimits|)
  (setq |$inclAssertions| (list 'aix '|CommonLisp|)
        |$lastPos| |$nopos| |$erMsgToss| nil |$ncMsgList| nil)
  (|princPrompt|)
  (finish-output))

;; |spad| and |ncTopLevel|. FriCAS interns symbols in *PACKAGE*: it is BOOT
;; whenever FriCAS runs, as during (load "fricas.lisp").
(defun pdf-start ()
  (setq *package* (find-package "BOOT"))
  (setq |$PrintCompilerMessageIfTrue| nil)
  (|setOutputAlgebra| '|%initialize%|)
  (catch '|top_level| (|readSpadProfileIfThere|) (|evalInlineCode|))
  (setq *eof* nil |$InteractiveMode| t |$e| |$InteractiveFrame|)
  (pdf-restart))

;; A confirmation query (")display operations", ")abbreviation query") cannot
;; wait for input inside a call. The question is printed, the command abandoned,
;; and run again with the next typed line as the answer (with the earlier answers
;; for a command that asks more than once).
(defun pdf-query (show)
  (if *pdf-answers*
      (pop *pdf-answers*)
      (progn (funcall show) (finish-output) (throw 'pdf-query :query))))

(defun |queryUser| (msg)
  (pdf-query (lambda () (|sayBrightly| msg))))

(defun |query_user_msg| (key msg args)
  (pdf-query (lambda () (|say_msg| key msg args))))

(defun pdf-no-quit ()
  (|sayBrightly| "   FriCAS runs inside this PDF; close it to quit."))

(defun |quitSpad2Cmd| () ; )quit, )pquit
  (pdf-no-quit)
  (|terminateSystemCommand|))

(defun |leaveScratchpad| ()
  (pdf-no-quit)
  (|throw_to_top_level|))

(defun fricas-lisp::|exit_with_status| (status) ; QUIT, )lisp (quit)
  (declare (ignore status))
  (|leaveScratchpad|))

;; The viewer has no CPU time (getrusage reads 0). Time statistics
;; (")set message time on") report elapsed time instead.
(setf (symbol-function '|get_run_time|) #'get-internal-real-time)

;; One iteration of |intloopReadConsole| for line A.
(defun pdf-read-line (a)
  (let ((b *pdf-lines*) (n *pdf-step*) pfx d)
    (cond ((and (null b) (eql (length a) 0)) (|princPrompt|))
          ((and $dalymode (|intloopPrefix?| "(" a)) (|nplisp| a) (|princPrompt|))
          (t
           (setq pfx (|stripSpaces| (|intloopPrefix?| ")fi" a)))
           (cond ((and pfx (or (equal pfx ")fi") (equal pfx ")fin")))
                  (|sayBrightly| "   )fin is not available here. Use )lisp FORM.")
                  (|princPrompt|))
                 ((and (null b) (setq d (|intloopPrefix?| ")" a)))
                  (|setCurrentLine| d)
                  (setq n (|ncloopCommand| d n))
                  (|princPrompt|))
                 (t
                  (push a b)
                  (unless (|ncloopEscaped| a)
                    (setq n (|intloopProcessStrings| (nreverse b) n))
                    (|princPrompt|)
                    (setq b '()))))))
    (setq *pdf-lines* b *pdf-step* n)))

;; Lisp errors that FriCAS's handler declines, and other serious conditions
;; (ECL's own stack and heap limits): report and return to the top level.
(defun pdf-lisp-error (c)
  (|sayBrightly| (list "   >> System error:" '|%l| (|error_format| c)))
  (|throw_to_top_level|))

(defun pdf-decode (bytes) ; base-string holding UTF-8
  (or (ignore-errors
       (ext:octets-to-string (map '(vector (unsigned-byte 8)) #'char-code bytes)
                             :external-format :utf-8))
      bytes))

;; Called by frontend.c with each typed line.
(defun cl-user::pdf-line (bytes)
  (let ((*package* (find-package "BOOT"))
        (a (pdf-decode bytes))
        (lines *pdf-lines*)
        (answers '())
        result)
    (when *pdf-pending*                 ; A answers a query: run the command again
      (destructuring-bind (plines pline . panswers) *pdf-pending*
        (setq answers (append panswers (list a))
              lines plines
              a pline
              *pdf-lines* plines
              *pdf-pending* nil)))
    (setq *pdf-answers* answers
          result (catch 'pdf-query
                   (catch '|coerceFailure|
                     (catch '|top_level|
                       (handler-bind ((serious-condition #'pdf-lisp-error))
                         (handler-bind ((error #'|spad_system_error_handler|))
                           (pdf-read-line a)))
                       :done)))
          *pdf-answers* '())
    (case result
      (:done)
      (:query (setq *pdf-pending* (list* lines a answers)))
      (t (pdf-restart)))
    (finish-output)
    nil))

;; Called by frontend.c when PDF-LINE was left by a non-local exit that it does
;; not catch (EXT:QUIT unwinds to the outermost frame).
(defun cl-user::pdf-abort ()
  (setq *package* (find-package "BOOT"))
  (pdf-restart))

;; Called by frontend.c after a JavaScript stack overflow.
(defun cl-user::pdf-overflow ()
  (setq *package* (find-package "BOOT"))
  (|sayBrightly| (list "   >> System error:" '|%l|
                       "   Recursion too deep for the viewer's JavaScript stack."))
  (pdf-restart))

;; Called by frontend.c before the memory image is taken (tools/snapshot.mjs):
;; evaluates each line of warm-up.input, so that the code of the domains they use
;; is loaded in the image. Output is discarded; history is not touched.
(defun pdf-warm-up ()
  (with-open-file (in "warm-up.input")
    (loop for line = (read-line in nil) while line
          unless (or (string= (string-trim " " line) "")
                     (and (>= (length line) 2) (string= "--" line :end2 2)))
            do (format t "warm-up: ~A~%" line)
               (finish-output)
               (handler-case
                   (handler-bind ((error #'|spad_system_error_handler|))
                     (catch '|top_level| (|parseAndEvalToString| line)))
                 (serious-condition (c) (format t "  ~A~%" c))))))
