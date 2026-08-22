;;; slime-bridge.el --- Drive a SLIME REPL from outside Emacs  -*- lexical-binding: t; -*-

;; Helpers so that a person working in Emacs and an assistant driving
;; `emacsclient' can share ONE running Lisp image, with every interaction going
;; through the visible SLIME REPL rather than a side channel.
;;
;; Used by approaches 2 and 3 of https://github.com/occisn/claude-lisp-repl
;;
;; Load it in the running Emacs:
;;
;;   emacsclient --eval '(load-file "/path/to/slime-bridge.el")'
;;
;; The path is in the namespace of the Emacs PROCESS, which may differ from the
;; Windows or Linux Emacs -- a native Linux/WSL Emacs takes a Linux path
;; ("/home/you/src/claude-lisp-repl/slime-bridge.el"); a Windows Emacs takes a
;; Windows path ("C:/Users/you/src/claude-lisp-repl/slime-bridge.el") even when
;; you call emacsclient from WSL.  `my/slime-host-info' reports which one you
;; reached, so a dual-target driver can state its target and pick the path rules.
;;
;; Load order does not matter: this file may be loaded before SLIME is started.
;; The prompt hook the `*-then-touch' sentinels ride on is (re)installed when
;; SLIME loads AND every time a sentinel is armed.  `my/slime-host-info' and
;; `my/slime-repl-status' report `:touch-armed' if you want to confirm it before
;; blocking a shell on a sentinel file.
;;
;; Three rules this file enforces:
;;
;;   * Never steal the user's window. The REPL is surfaced only when it is not
;;     already visible in some window on some frame (0 = all frames, including
;;     iconified ones).
;;   * Never destroy what the user is typing. Staging refuses to overwrite
;;     unsent input at the prompt unless explicitly forced.
;;   * Everything lands as real REPL input, so it appears in the user's history
;;     and scrollback exactly as if they had typed it.
;;
;; Usage convention (see the README prompts): send, then read the result back
;; and report it.  Which waiting shape depends on how long the form runs:
;;
;;   * SHORT forms -- `my/slime-mark', `my/slime-send', a few polls of
;;     `my/slime-ready-p' from the shell, `my/slime-output-since-mark'.
;;   * ANYTHING SLOW (load-system, test-system, quickload) -- do NOT poll.  Use
;;     `my/slime-send-capturing-then-touch' and let the shell BLOCK on the
;;     sentinel file.  A poll loop is a long-lived shell command, and an agent
;;     harness caps how long one command may run (Claude Code's Bash tool: 10
;;     minutes), so the loop is killed mid-watch and the driver never learns
;;     the form finished.  A `while [ ! -e SENTINEL ]' wait is far cheaper,
;;     survives much longer, is trivially bounded, and is RESUMABLE -- the
;;     sentinel persists, so re-running the wait picks it back up.  Read the
;;     line it holds and test `:done': the wait also ends when the form parks
;;     in the debugger, and that case says `(:done nil :sldb t ...)'.
;;
;; Staging is the exception to reading back: a staged form has not run, so
;; report "staged" and leave the prompt alone rather than polling it (that
;; races the user's RET).  When you do poll, poll `my/slime-ready-p', NOT
;; `my/slime-busy-p': the latter reports a form parked in SLDB as idle (see its
;; docstring), so it cannot detect an open debugger and would have you read an
;; errored form as a finished one.
;;
;; Restarting the image is a normal, self-service operation -- see
;; `my/slime-restart-and-wait'.  It is cheap and fully recoverable, so a driver
;; should do it rather than ask, whenever a stale image would lie: changed
;; `defstruct'/`defclass' slots, stale ftype/export proclamations after a
;; rename, or verifying a genuinely cold load.

;;; Code:

(defun my/slime-assert-connected ()
  "Return the SLIME REPL buffer, or signal a clear error.

Note that `slime-output-buffer' calls `slime-connection', which SIGNALS when
nothing is connected -- it does not return nil.  Guarding with
(and (fboundp \\='slime-output-buffer) (slime-output-buffer)) therefore never
produces a friendly message; check `slime-connected-p' first."
  (unless (and (fboundp 'slime-connected-p) (slime-connected-p))
    (user-error "SLIME is not connected; run M-x slime (or M-x slime-connect)"))
  (let ((buf (ignore-errors (slime-output-buffer))))
    (unless (buffer-live-p buf)
      (user-error "No live SLIME REPL buffer"))
    buf))

(defun my/slime-pending-input ()
  "Return text typed at the REPL prompt but not yet submitted (trimmed)."
  (let ((buf (my/slime-assert-connected)))
    (with-current-buffer buf
      (if (and (boundp 'slime-repl-input-start-mark)
               (markerp slime-repl-input-start-mark))
          (string-trim (buffer-substring-no-properties
                        (marker-position slime-repl-input-start-mark)
                        (point-max)))
        ""))))

(defun my/slime-stage (code &optional force)
  "Insert CODE as pending input at the SLIME REPL prompt, WITHOUT sending it.
The user reviews/tweaks and presses RET to evaluate.

Refuses to clobber input the user has already typed unless FORCE is non-nil.
`slime-repl-kill-input' kills from the prompt to point, so staging over
half-typed input would silently discard the user's work -- it goes to the kill
ring, but nothing says so, and the whole premise here is that the user may be
mid-form at any moment."
  (let ((buf (my/slime-assert-connected))
        (pending (my/slime-pending-input)))
    (when (and (not force) (not (string-empty-p pending)))
      (user-error "REPL prompt already holds unsent input (%s); pass FORCE to overwrite"
                  (if (> (length pending) 40)
                      (concat (substring pending 0 40) "...")
                    pending)))
    (with-current-buffer buf
      (goto-char (point-max))
      (when (fboundp 'slime-repl-kill-input) (slime-repl-kill-input))
      (insert code))
    (unless (get-buffer-window buf 0)
      (display-buffer buf))
    "staged"))

(defun my/slime-send (code &optional force)
  "Stage CODE at the REPL prompt and submit it.
Returns \"sent\" immediately -- NOT the value of CODE, which is computed
asynchronously.  Use `my/slime-send-wait' when you need the result."
  (my/slime-stage code force)
  (let ((buf (slime-output-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))
  "sent")

(defun my/slime-stage-file (path &optional force)
  "Read PATH and stage its (trimmed) contents into the SLIME REPL prompt."
  (my/slime-stage
   (with-temp-buffer
     (insert-file-contents path)
     (string-trim (buffer-string)))
   force))

(defun my/slime-send-file (path &optional force)
  "Read PATH, stage its contents at the REPL prompt, then submit.
The forms run as visible REPL input and land in the SLIME history."
  (my/slime-stage-file path force)
  (let ((buf (slime-output-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))
  "sent")

;;; ---------------------------------------------------------------------------
;;; Catching errors instead of dropping into SLDB
;;;
;;; When a form errors, SLIME pops an SLDB buffer and the evaluation blocks
;;; there waiting for a restart.  The trap for a shell driver is that
;;; `my/slime-busy-p' goes NIL at that moment -- SLIME's `slime-busy-p' is
;;; documented "Debugged requests are ignored" and removes the debugged
;;; continuations -- so a parked form is indistinguishable from a finished one.
;;; A poll loop does not hang; it reports success and fires the next form into
;;; an open debugger.  Gate on `my/slime-ready-p' (idle AND no SLDB) instead.
;;;
;;; Better still, for a driver that fires and reports, keep the error IN the
;;; REPL: wrap the form so any `error' prints its type, message and a
;;; backtrace, then returns `:error' instead of entering the debugger.
;;;
;;; `handler-bind' (not `handler-case') runs the handler BEFORE the stack
;;; unwinds, so the backtrace is taken at the signalling point and actually
;;; shows where the error came from; the enclosing `block'/`return-from' then
;;; performs the unwind cleanly.  SBCL-specific (`sb-debug:print-backtrace').
;;;
;;; The guard must cover READING as well as evaluating.  Splicing CODE straight
;;; into the wrapper only protects it from evaluation-time errors: the handler
;;; is part of the very form being read, so it is not established yet while the
;;; reader is parsing.  A form naming a package that does not exist in the image
;;; yet (`my-system::+some-constant+' before the system is loaded) signals
;;; SB-INT:SIMPLE-READER-PACKAGE-ERROR during READ, and unbalanced parens signal
;;; END-OF-FILE -- both straight into SLDB, past a guard that had no chance to
;;; run.  So CODE travels as a STRING and the wrapper reads it itself, inside
;;; the `handler-bind'.  See `my/slime--read-eval-body'.
;;; ---------------------------------------------------------------------------

(defun my/slime--lisp-string (s)
  "Return S as a Lisp string literal: quoted, with \\ and \" escaped.
Newlines are left as themselves -- a Lisp string may span lines -- so a
multi-line form stays multi-line and readable in the REPL scrollback."
  (concat "\"" (replace-regexp-in-string "[\\\"]" "\\\\\\&" s) "\""))

(defun my/slime--read-eval-body (code)
  "Return a Lisp form that READS CODE from a string and evaluates it.
Used as the body of the guards in `my/slime--capture-wrap' and
`my/slime-send-timed', so that reader errors -- a missing package, a stray
paren -- are signalled INSIDE the guard and self-report like any other error,
instead of parking the evaluation in SLDB where the guard never ran.

Reads one form at a time and evaluates it before reading the next, exactly as
the REPL listener does, so a leading `in-package' (or a reader macro CODE itself
defines) still affects how the following forms are read.  The last form's values
are returned, all of them, so a multiple-valued form still prints as it would at
the prompt.  CODE is evaluated by `eval' in the null lexical environment, which
is what the toplevel prompt does anyway; the wrapper's own bindings are
therefore invisible to it and cannot be captured."
  (concat "(with-input-from-string (my/s " (my/slime--lisp-string code) ")\n"
          "      (let ((my/eof '#:eof) (my/v nil))\n"
          "        (loop (let ((my/f (read my/s nil my/eof)))\n"
          "                (when (eq my/f my/eof) (return (values-list my/v)))\n"
          "                (setf my/v (multiple-value-list (eval my/f)))))))"))

(defun my/slime--capture-wrap (code &optional n-frames)
  "Return CODE as a form that self-reports an ERROR instead of opening SLDB.
On error the wrapped form prints \"; CONDITION <type>: <message>\" followed by up
to N-FRAMES backtrace frames (default 20) and returns `:error'; on success it
returns CODE's own values unchanged.  Split out from `my/slime-send-capturing'
so the same wrapper can be combined with the sentinel signal -- see
`my/slime-send-capturing-then-touch', which is the pairing that matters: a form
that errors into SLDB never returns the prompt, so it would never touch the
sentinel on that edge -- only the SLDB net would end the wait, and it ends it
with the image still parked at a debugger prompt.

CODE is embedded as a string and read by the wrapper
\(`my/slime--read-eval-body') rather than spliced in as source, so READ-time
errors are caught too -- see the commentary above.  The cost is cosmetic: the
REPL shows the form inside a string literal, with embedded quotes backslashed."
  (format
   (concat "(block my/slime--capture\n"
           "  (handler-bind\n"
           "      ((error (lambda (c)\n"
           "                (format t \"~&; CONDITION ~s: ~a~%%\" (type-of c) c)\n"
           "                (ignore-errors\n"
           "                  (sb-debug:print-backtrace :count %d :stream *standard-output*))\n"
           "                (return-from my/slime--capture (values :error c)))))\n"
           "    %s))")
   (or n-frames 20) (my/slime--read-eval-body code)))

(defun my/slime-send-capturing (code &optional n-frames force)
  "Send CODE wrapped so any ERROR self-reports in the REPL instead of opening SLDB.
On error the REPL prints \"; CONDITION <type>: <message>\" followed by up to
N-FRAMES backtrace frames (default 20) and the form returns `:error'; on success
CODE's own values are returned unchanged.  Like `my/slime-send' this returns
\"sent\" immediately -- watch the REPL (or use the mark/poll/read helpers) for
the result.  READ-time errors are trapped as well as evaluation-time ones -- a
missing package, a stray paren -- because the wrapper reads CODE itself; see
`my/slime--capture-wrap'.  What is still NOT trapped: conditions that are not
`error' subtypes, and a deliberate C-c interrupt, which reach SLDB as usual.

For slow work, prefer `my/slime-send-capturing-then-touch', which adds the
done-sentinel so the shell can block instead of poll."
  (my/slime-send (my/slime--capture-wrap code n-frames) force))

(defun my/slime-send-timed (code seconds &optional n-frames force)
  "Send CODE wrapped in `sb-ext:with-timeout' so a HANG self-reports in the REPL.
If CODE does not finish within SECONDS -- or signals an `error' first -- the REPL
prints a backtrace taken at the point of the hang/error (via `handler-bind',
before the stack unwinds) and the form returns `:timed-out' or `:error';
otherwise CODE's own values are returned.  N-FRAMES defaults to 20.  Like
`my/slime-send-capturing' it reads CODE inside the guard, so a reader error
(missing package, stray paren) self-reports too instead of opening SLDB.

This is the deterministic, safer alternative to `my/slime-interrupt': the timeout
is delivered by the image's own timer, so there is no external SIGINT and the
image is never left parked in SLDB -- it unwinds cleanly and the prompt returns.
Use it for any hang you can wrap in a single form; keep `my/slime-interrupt' for
stopping something already running that you did not launch this way.  Returns
\"sent\" immediately, like `my/slime-send'."
  (my/slime-send
   (format
    (concat "(block my/slime--timed\n"
            "  (handler-bind\n"
            "      ((sb-ext:timeout\n"
            "         (lambda (c)\n"
            "           (format t \"~&; TIMEOUT after %s s -- backtrace at the hang:~%%\")\n"
            "           (ignore-errors\n"
            "             (sb-debug:print-backtrace :count %d :stream *standard-output*))\n"
            "           (return-from my/slime--timed (values :timed-out c))))\n"
            "       (error\n"
            "         (lambda (c)\n"
            "           (format t \"~&; CONDITION ~s: ~a~%%\" (type-of c) c)\n"
            "           (ignore-errors\n"
            "             (sb-debug:print-backtrace :count %d :stream *standard-output*))\n"
            "           (return-from my/slime--timed (values :error c)))))\n"
            "    (sb-ext:with-timeout %s\n"
            "      %s)))")
    seconds (or n-frames 20) (or n-frames 20) seconds
    (my/slime--read-eval-body code))
   force))

;;; ---------------------------------------------------------------------------
;;; Reading results back
;;;
;;; Without these there is no way to know the prompt has returned, which is what
;;; "send one instruction at a time, waiting for the prompt" actually requires.
;;; ---------------------------------------------------------------------------

(defun my/slime-busy-p ()
  "Return t while the Lisp is still working on something, nil otherwise.

Deliberately coerced to a strict boolean.  The documented workflow polls this
from the shell via `emacsclient --eval', which PRINTS the value, and SLIME's own
`slime-busy-p' returns the list of pending continuations rather than t/nil.  A
shell test like [ \"$x\" = \"nil\" ] would then never match and the caller would
poll forever.

IMPORTANT -- this is NOT a \"safe to send\" test.  SLIME's `slime-busy-p' is
documented \"Debugged requests are ignored\": it removes the continuations that
`sldb-debugged-continuations' reports, so a form that has died into SLDB reads
exactly like one that finished cleanly.  Polling this alone therefore reports
the REPL idle seconds after a form errored, and the next form is fired into an
open debugger.  Use `my/slime-ready-p' as the precondition before sending."
  (and (fboundp 'slime-busy-p)
       (not (null (ignore-errors (slime-busy-p))))))

(defun my/slime-ready-p ()
  "Return t when it is safe to send a new form: connected, idle, no debugger.

This -- not `my/slime-busy-p' -- is the precondition check to poll before
sending.  `my/slime-busy-p' deliberately keeps its strict busy/not-busy
contract (a shell poll loop needs a two-valued answer), but \"not busy\" is not
the same as \"ready\": a form parked in SLDB is not busy, and neither is a dead
connection.  This conjoins the three conditions `my/slime-repl-status' reports
separately as :connected, :busy and :in-debugger.

Also strictly t/nil, for the same shell-printing reason.  When it returns nil
and you need to know WHY, call `my/slime-repl-status'."
  (and (fboundp 'slime-connected-p)
       (ignore-errors (slime-connected-p))
       (not (my/slime-busy-p))
       (not (my/slime-sldb-buffer))
       t))

(defun my/slime-interrupt ()
  "Interrupt the running evaluation -- the shell-side equivalent of C-c C-c.

Lets a caller stop a runaway form it started itself, without touching whatever
window the user is looking at.  Returns \"interrupted\" if a request was sent,
\"in-debugger\" when a form is parked in SLDB (there is nothing to interrupt --
use `my/slime-sldb-backtrace' then `my/slime-sldb-abort'), and \"idle\" when
nothing was running.  The SLDB case is reported separately because
`my/slime-busy-p' alone cannot distinguish it from a clean idle prompt."
  (cond
   ((my/slime-busy-p)
    (my/slime-assert-connected)
    (slime-interrupt)
    "interrupted")
   ((my/slime-sldb-buffer) "in-debugger")
   (t "idle")))

(defun my/slime-repl-tail (&optional n-chars)
  "Return the last N-CHARS characters of the SLIME REPL buffer (default 2000)."
  (let ((buf (my/slime-assert-connected))
        (n (or n-chars 2000)))
    (with-current-buffer buf
      (buffer-substring-no-properties
       (max (point-min) (- (point-max) n))
       (point-max)))))

(defun my/slime-send-wait (code &optional timeout-seconds n-chars force)
  "Submit CODE, wait for the prompt, and return the output it produced.

Returns only text written since CODE was submitted, so the caller need not diff
against earlier scrollback.  TIMEOUT-SECONDS defaults to 60; on timeout the text
captured so far is returned with a [TIMEOUT] marker and the evaluation is left
running rather than killed.

If CODE errors into SLDB the wait ends immediately -- a debugged request is no
longer \"busy\" -- and the text is returned with an [SLDB] marker.  Without that
marker the return would be indistinguishable from a clean completion, which is
the trap described in `my/slime-busy-p'.  Recover with `my/slime-sldb-backtrace'
and `my/slime-sldb-abort', or avoid the debugger entirely with
`my/slime-send-capturing'.

BEWARE: this blocks Emacs in `sleep-for'.  Timers and process filters still run
-- so REPL output keeps arriving -- but the user's KEYSTROKES are merely queued,
and Emacs feels frozen for the duration.  Fine for a quick form; for anything
slow use the mark/send/poll/read sequence below instead."
  (let* ((buf (my/slime-assert-connected))
         (start (with-current-buffer buf (point-max)))
         (deadline (+ (float-time) (or timeout-seconds 60))))
    (my/slime-send code force)
    ;; Let the request register before testing busy-ness, otherwise a fast form
    ;; can look idle before it ever started.
    (sleep-for 0.05)
    ;; The SLDB test is not redundant with the busy test: a form that drops
    ;; into the debugger stops counting as busy, so this loop would exit on its
    ;; own -- the point is to record WHY it exited, below.
    (while (and (my/slime-busy-p)
                (not (my/slime-sldb-buffer))
                (< (float-time) deadline))
      (sleep-for 0.05))
    (let ((in-sldb (and (my/slime-sldb-buffer) t))
          (timed-out (and (my/slime-busy-p) (>= (float-time) deadline))))
      (with-current-buffer buf
        (let ((text (buffer-substring-no-properties
                     (min start (point-max)) (point-max))))
          (cond
           (in-sldb
            (concat text "\n[SLDB -- evaluation parked in the debugger]"))
           (timed-out
            (concat text "\n[TIMEOUT -- evaluation still running]"))
           ((and n-chars (> (length text) n-chars))
            (substring text (- (length text) n-chars)))
           (t text)))))))

;;; ---------------------------------------------------------------------------
;;; Long-running work: mark / send / poll / read
;;;
;;;   (my/slime-mark)                  -> remember where output starts
;;;   (my/slime-send "(long-form)")    -> returns immediately
;;;   (my/slime-ready-p)               -> poll from the shell, sleeping THERE
;;;   (my/slime-output-since-mark)     -> collect the result
;;;
;;; Poll `my/slime-ready-p', not `my/slime-busy-p': the latter reads nil for a
;;; form that errored into SLDB, so the loop would exit announcing success.
;;;
;;; Every call returns instantly, so Emacs stays responsive while a system
;;; compiles or a test suite runs.
;;; ---------------------------------------------------------------------------

(defvar my/slime--mark nil
  "REPL buffer position recorded by `my/slime-mark'.")

(defun my/slime-mark ()
  "Record the current end of the REPL buffer; see `my/slime-output-since-mark'."
  (setq my/slime--mark
        (with-current-buffer (my/slime-assert-connected) (point-max)))
  (format "marked at %d" my/slime--mark))

(defun my/slime-output-since-mark (&optional max-chars)
  "Return REPL output produced since `my/slime-mark', truncated to MAX-CHARS."
  (let ((buf (my/slime-assert-connected)))
    (with-current-buffer buf
      (let* ((start (min (or my/slime--mark (point-min)) (point-max)))
             (text (buffer-substring-no-properties start (point-max))))
        (if (and max-chars (> (length text) max-chars))
            (concat "...[truncated]...\n" (substring text (- (length text) max-chars)))
          text)))))

;;; --- Output to a file ------------------------------------------------------
;;;
;;; `emacsclient --eval' prints its result as an Elisp string literal: newlines
;;; come back as \n escapes, non-ASCII is mangled, and long strings can make
;;; emacsclient emit "*ERROR*: Unknown message:" mid-stream.  Writing to a file
;;; side-steps the printer entirely, so the shell can just read plain UTF-8.

(defun my/slime-write-string-to-file (string path)
  "Write STRING to PATH as UTF-8 with Unix line endings.  Return PATH."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path (insert string)))
  path)

(defun my/slime--write-atomically (string path)
  "Write STRING to PATH via a temporary file and a rename.  Return PATH.
Matters for the done-sentinel specifically: the shell's wait is
`while [ ! -e PATH ]', so the instant PATH exists the driver reads it.  Writing
in place would let that read catch a half-written file; a rename is atomic
within a filesystem, so PATH never exists with partial contents.  The temporary
lives at PATH.tmp -- next to PATH, hence same filesystem, and not itself matched
by a wait on PATH."
  (let ((tmp (concat path ".tmp")))
    (my/slime-write-string-to-file string tmp)
    (rename-file tmp path t)
    path))

(defun my/slime-send-wait-to-file (path code &optional timeout-seconds n-chars force)
  "Like `my/slime-send-wait' but write the captured output to PATH instead of
returning it.  Return PATH.

`my/slime-send-wait' hands its result back as the `emacsclient --eval' return
value, whose string escaping mangles newlines and can make emacsclient emit
\"*ERROR*: Unknown message:\" mid-stream on noisy output -- exactly what a
recompile full of `redefining ...' warnings produces.  This variant builds the
string inside Emacs and writes it straight to disk, so the shell just reads plain
UTF-8.  (It still blocks Emacs in `sleep-for' while waiting; for long, noisy
builds prefer the non-blocking `my/slime-mark' / poll / `my/slime-output-since-\
mark-to-file' sequence, which does not freeze Emacs.)"
  (my/slime-write-string-to-file
   (my/slime-send-wait code timeout-seconds n-chars force) path))

(defun my/slime-output-since-mark-to-file (path &optional max-chars)
  "Write `my/slime-output-since-mark' to PATH as UTF-8.  Return PATH."
  (my/slime-write-string-to-file (my/slime-output-since-mark max-chars) path))

(defun my/slime-repl-tail-to-file (path &optional n-chars)
  "Write `my/slime-repl-tail' to PATH as UTF-8.  Return PATH."
  (my/slime-write-string-to-file (my/slime-repl-tail n-chars) path))

;;; ---------------------------------------------------------------------------
;;; Reading the debugger after an interrupt
;;;
;;; Interrupting a hung form (`my/slime-interrupt', = C-c C-c) raises
;;; `sb-sys:interactive-interrupt' -- which is a `serious-condition' but NOT an
;;; `error', so `my/slime-send-capturing' does not catch it -- and SLIME opens
;;; an SLDB debugger buffer with the backtrace at the point of the hang.  That
;;; backtrace is exactly what tells you WHERE it was stuck (and, at debug 3, the
;;; local values there), but it lives in the `*sldb ...*' buffer, which none of
;;; the REPL-reading helpers above touch.  These three reach it:
;;;
;;;   (my/slime-interrupt)             -> stop the hang; SLDB opens
;;;   (my/slime-sldb-backtrace)        -> read where it was stuck
;;;   (my/slime-sldb-abort)            -> back to the top-level prompt
;;; ---------------------------------------------------------------------------

(defun my/slime-sldb-buffer ()
  "Return the active SLDB debugger buffer, or nil when no debugger is open."
  (let ((buf (or (ignore-errors (sldb-get-default-buffer))
                 (car (ignore-errors (sldb-buffers))))))
    (and (buffer-live-p buf) buf)))

(defun my/slime-sldb-backtrace (&optional n-chars)
  "Return the text of the active SLDB debugger buffer, or nil if none is open.
This is the condition, the restart list and the backtrace frames Claude gets to
see after an interrupt or an unhandled error.  Truncated to N-CHARS (default
4000) from the TOP, because the condition and the first frames -- where the
offending call and its arguments show -- are what matter, not the deep tail."
  (let ((buf (my/slime-sldb-buffer)))
    (when buf
      (with-current-buffer buf
        (let ((text (buffer-substring-no-properties (point-min) (point-max)))
              (n (or n-chars 4000)))
          (if (> (length text) n)
              (concat (substring text 0 n) "\n...[truncated]...")
            text))))))

(defun my/slime-sldb-backtrace-to-file (path &optional n-chars)
  "Write `my/slime-sldb-backtrace' to PATH as UTF-8.
Return PATH, or nil when no debugger is open.  Preferred over reading the
backtrace through `emacsclient --eval', whose string escaping mangles the
multi-line frames."
  (let ((text (my/slime-sldb-backtrace n-chars)))
    (and text (my/slime-write-string-to-file text path))))

(defun my/slime-sldb-abort ()
  "Invoke the ABORT restart in the active SLDB buffer, returning to the REPL.
Use once the backtrace has been read, so the image is usable again.  Until then
the connection sits in the debugger -- which `my/slime-busy-p' does NOT show
\(it reads nil, as if idle); `my/slime-ready-p' and the :in-debugger flag of
`my/slime-repl-status' are what detect it.  Returns \"aborted\" if a debugger
was open, \"no-debugger\" otherwise."
  (let ((buf (my/slime-sldb-buffer)))
    (if (not buf)
        "no-debugger"
      (with-current-buffer buf (sldb-abort))
      "aborted")))

(defun my/slime-host-info ()
  "Report which Emacs is answering, so a dual-target driver can name its target.
Unlike the other helpers this does NOT need SLIME connected -- it describes the
Emacs PROCESS that `emacsclient' reached, which is what decides the path rules:

  * `windows-nt' (or `cygwin'/`ms-dos') -> a Windows Emacs.  Paths sent to Emacs
    (`load-file') and into the image (`load', `asdf') must be Windows form
    (\"C:/...\"); your WSL shell uses the mount form (\"/mnt/c/...\").
  * `gnu/linux' (or `darwin') -> a native Emacs.  Emacs, the image and the
    shell all share the same plain paths; no translation.

Call it right after loading this file -- before `M-x slime-connect' even -- to
confirm and announce which target you are driving.

`:touch-armed' says whether the `*-then-touch' sentinel machinery can fire (see
`my/slime-touch-armed-p').  It reads nil until SLIME's REPL is loaded, which is
fine -- arming a sentinel installs the hook itself.  `:touch-armed' nil together
with `:slime-connected' t is the state to act on: sentinels would never appear,
so reload this file rather than starting a wait."
  (let ((win (memq system-type '(windows-nt ms-dos cygwin))))
    (list :emacs-system-type system-type
          :windows-emacs (and win t)
          :path-style (if win 'windows 'unix)
          :emacs-version emacs-version
          :slime-loaded (and (featurep 'slime) t)
          :slime-connected (and (fboundp 'slime-connected-p)
                                (ignore-errors (slime-connected-p)) t)
          :touch-armed (my/slime-touch-armed-p))))

(defun my/slime-repl-status ()
  "One-call summary: target, connection, REPL buffer, package, busy state, tail.
`:emacs-system-type' and `:path-style' identify which Emacs (Windows or Linux)
is answering -- see `my/slime-host-info' -- so the caller can pick path rules
even from this single call.  `:can-restart' says whether Emacs started this
image itself and can therefore restart it (`my/slime-restart-and-wait'); it is
nil for an image reached with `M-x slime-connect'.  `:touch-armed' is the
precondition for the `*-then-touch' sentinels -- nil there while `:connected'
is t means a wait on a sentinel file would never end (see
`my/slime-touch-armed-p')."
  (if (not (and (fboundp 'slime-connected-p) (slime-connected-p)))
      (list :connected nil
            :emacs-system-type system-type
            :path-style (if (memq system-type '(windows-nt ms-dos cygwin))
                            'windows 'unix)
            :touch-armed (my/slime-touch-armed-p))
    (list :connected t
          :emacs-system-type system-type
          :path-style (if (memq system-type '(windows-nt ms-dos cygwin))
                          'windows 'unix)
          :repl-buffer (buffer-name (slime-output-buffer))
          :package (ignore-errors (slime-current-package))
          :busy (and (my/slime-busy-p) t)
          :in-debugger (and (my/slime-sldb-buffer) t)
          :can-restart (and (ignore-errors (slime-inferior-process)) t)
          :touch-armed (my/slime-touch-armed-p)
          :visible (and (get-buffer-window (slime-output-buffer) 0) t)
          :pending-input (my/slime-pending-input)
          :tail (string-trim (my/slime-repl-tail 200)))))

;;; ---------------------------------------------------------------------------
;;; A push signal for "the REPL is available again"
;;;
;;; SLIME ships NO hook that fires when evaluation finishes and the prompt
;;; returns.  `slime-busy-p' (which `my/slime-busy-p' wraps) is poll-only -- it
;;; just inspects the pending `slime-rex-continuations'.  `slime-event-hooks'
;;; fires for EVERY protocol event and is run with
;;; `run-hook-with-args-until-success', so a function that returns non-nil would
;;; swallow the event and break SLIME; it also sees autodoc/completion traffic,
;;; not just the REPL.  And the per-form `slime-eval-async'/`slime-rex'
;;; continuations do not apply here, because this bridge sends forms as REPL
;;; input (`slime-repl-return'), never through `slime-eval-async'.
;;;
;;; What DOES fire on exactly the transition we want is `slime-repl-insert-
;;; prompt': both the `:ok' and `:abort' listener continuations call it once the
;;; result is in and the prompt is redrawn, and it is NOT called while the form
;;; is parked in SLDB -- a STRICTER boundary than `my/slime-busy-p' draws, since
;;; that one already reads nil for a debugged form.  The idle signal is thus the
;;; more trustworthy of the two: it fires on a genuine prompt return, never on
;;; an error that merely stopped being "busy".  So we advise it and expose
;;; `my/slime-repl-idle-functions', letting Emacs-side code react to idle
;;; instead of polling.  The gate `(not (my/slime-busy-p))' means that with
;;; several forms pipelined the hook runs only when the LAST one drains, i.e.
;;; on the genuine idle edge.  (That gate is safe despite the SLDB blind spot:
;;; the advice only runs when a prompt is actually being inserted.)
;;;
;;; For a shell driver that cannot receive an Elisp callback, `my/slime-send-
;;; then-touch' turns that edge into a file: send, then create PATH when the
;;; prompt returns.  The shell blocks on PATH appearing (a `while [ ! -e PATH ]'
;;; or an inotifywait) instead of re-polling `my/slime-busy-p' in a loop.
;;; ---------------------------------------------------------------------------

(defvar my/slime-repl-idle-functions nil
  "Abnormal hook run when the SLIME REPL prompt returns and the Lisp is idle.
Each function is called with no arguments.  Fired by an `:after' advice on
`slime-repl-insert-prompt', gated on `slime-connected-p' and
\(not (my/slime-busy-p)), so with pipelined forms it runs only once the last
one drains.  Errors in a function are demoted to a message so they cannot
corrupt SLIME's prompt handling.  Note the prompt is also redrawn on a package
switch (`slime-repl-set-package'), so a stray idle-edge is possible; keep the
functions cheap and idempotent.")

(defvar my/slime--prompt-inserts 0
  "Count of `slime-repl-insert-prompt' calls since this file was loaded.
Incremented by `my/slime--run-idle-functions' BEFORE the idle gate, so it counts
every prompt redraw -- including the ones that do not fire the idle hook (the
Lisp still busy) and the ones that are not evaluation results at all (a package
switch redraws the prompt too).  The difference between two readings is what
lets a sentinel say how many times the prompt came back while it was armed: 1
is a clean single completion, more than 1 means something else redrew the
prompt as well.")

(defun my/slime--run-idle-functions (&rest _)
  "Run `my/slime-repl-idle-functions' when connected and not busy.
Advice target: `slime-repl-insert-prompt'.  Always returns nil and never
signals, so it cannot alter or break prompt insertion.  Bumps
`my/slime--prompt-inserts' unconditionally, before the gate."
  (setq my/slime--prompt-inserts (1+ my/slime--prompt-inserts))
  (when (and (fboundp 'slime-connected-p)
             (ignore-errors (slime-connected-p))
             (not (my/slime-busy-p)))
    (with-demoted-errors "my/slime idle hook error: %S"
      (run-hooks 'my/slime-repl-idle-functions)))
  nil)

(defun my/slime--ensure-idle-advice ()
  "Put the idle advice on `slime-repl-insert-prompt'; return non-nil once it is.
Returns nil only while that function is still undefined -- i.e. in an Emacs
where SLIME (strictly: its REPL contrib) has not been loaded yet.

Called at load time, again when SLIME loads, and ONCE MORE EVERY TIME A
SENTINEL IS ARMED, so the order in which this file and SLIME are loaded does
not matter.  It used to matter, silently: the advice was installed only if
`slime-repl-insert-prompt' happened to be defined when this file was read, so
loading the bridge into a SLIME-less Emacs left every `*-then-touch' sentinel
dead for the life of that Emacs -- forms really ran, \"sent\" really came back,
and the file simply never appeared, costing each waiter its whole timeout.
Resolving the advice at arm time instead of at load time is what removes that
failure mode; `my/slime-touch-armed-p' is how a driver checks it.

`advice-add' de-duplicates by function symbol, and this checks `advice-member-p'
besides, so repeated calls and reloads of this file cannot stack the advice."
  (and (fboundp 'slime-repl-insert-prompt)
       (progn
         (unless (advice-member-p #'my/slime--run-idle-functions
                                  'slime-repl-insert-prompt)
           (advice-add 'slime-repl-insert-prompt :after
                       #'my/slime--run-idle-functions))
         t)))

(defun my/slime-touch-armed-p ()
  "Return t when the `*-then-touch' sentinel machinery can actually fire.
That is: `slime-repl-insert-prompt' exists and carries the idle advice.  This
only REPORTS -- `my/slime--ensure-idle-advice' is what installs it -- so it is
safe to call as a precondition check.

nil BEFORE SLIME's REPL is loaded is expected and harmless: arming a sentinel
installs the advice on the spot.  nil while `my/slime-host-info' says
`:slime-connected t' is the red flag -- something removed the advice, and no
sentinel will ever appear."
  (and (fboundp 'slime-repl-insert-prompt)
       (advice-member-p #'my/slime--run-idle-functions
                        'slime-repl-insert-prompt)
       t))

;; Install now if SLIME is already here, and again when it -- or the REPL
;; contrib, which is where `slime-repl-insert-prompt' actually lives -- loads
;; later.  Neither is load-bearing on its own: arming a sentinel calls
;; `my/slime--ensure-idle-advice' too, which is the guarantee that matters.
(my/slime--ensure-idle-advice)
(with-eval-after-load 'slime (my/slime--ensure-idle-advice))
(with-eval-after-load 'slime-repl (my/slime--ensure-idle-advice))

(defun my/slime-run-once-when-idle (fn)
  "Arrange for FN (no arguments) to run once, the next time the REPL is idle.
Returns the internal hook entry, so a caller that decides not to wait can pass
it to `remove-hook' on `my/slime-repl-idle-functions'.  The entry removes
itself before calling FN, so a re-entrant FN cannot re-trigger it.

Installs the prompt advice first (`my/slime--ensure-idle-advice'), so a one-shot
armed in an Emacs that loaded this file before SLIME still fires."
  (my/slime--ensure-idle-advice)
  (letrec ((entry (lambda ()
                    (remove-hook 'my/slime-repl-idle-functions entry)
                    (funcall fn))))
    (add-hook 'my/slime-repl-idle-functions entry)
    entry))

(defun my/slime--write-sentinel (path armed-at armed-prompts start-pos &optional sldb)
  "Write the done-sentinel PATH with evidence about how it came to fire.

ARMED-AT is a `float-time' taken when the one-shot was armed, ARMED-PROMPTS the
`my/slime--prompt-inserts' reading at that moment, and START-POS the REPL buffer
position just after the form was submitted.  The file gets ONE readable line:

  (:done t :elapsed-ms 8021 :prompt-returns 1 :output-chars 18422 :suspect nil)

  :elapsed-ms      wall time from arming to the prompt returning.
  :prompt-returns  prompt redraws while armed.  A clean single completion is 1.
  :output-chars    characters the REPL gained since the form was submitted.
  :suspect         t when :prompt-returns is above 1 -- something redrew the
                   prompt besides the result, a package switch being the
                   documented case, so the fire may not be this form finishing.

Elapsed time alone cannot answer \"did my form really finish?\", because a fast
completion and a spurious redraw both return instantly; the other three fields
are what separate them.  A 0 ms fire with :output-chars 0 and :suspect t is a
redraw; a 200 ms fire with thousands of characters of output is a warm cache
doing exactly what it should.

With SLDB non-nil the line instead starts `(:done nil :sldb t ...)': the form
did not finish, it parked in the debugger, and the wait was ended by the net in
`my/slime-send-then-touch' rather than by a prompt return.  `:done' is therefore
the field to test -- a caller that only checks \"the file exists\" will read a
parked form as a finished one.

Written atomically, so a shell that sees PATH appear never reads a partial line.
Never signals: an unreadable REPL buffer degrades to :output-chars -1, because
failing to write the sentinel would hang the waiting shell -- a far worse
outcome than a missing number."
  (let* ((elapsed-ms (round (* 1000 (- (float-time) armed-at))))
         (returns (- my/slime--prompt-inserts armed-prompts))
         (chars (condition-case nil
                    (with-current-buffer (slime-output-buffer)
                      (max 0 (- (point-max) start-pos)))
                  (error -1))))
    (my/slime--write-atomically
     (format
      "(%s :elapsed-ms %d :prompt-returns %d :output-chars %d :suspect %s)\n"
      (if sldb ":done nil :sldb t" ":done t")
      elapsed-ms returns chars (if (> returns 1) "t" "nil"))
     path)))

(defun my/slime-send-then-touch (path code &optional force)
  "Send CODE via the REPL, then create/overwrite PATH when the prompt returns.
This -- not a poll loop -- is the default shape for anything slow: the shell
BLOCKS on PATH appearing (`while [ ! -e PATH ]; do sleep 2; done') instead of
re-running `emacsclient' every few seconds.  A poll loop is a long-lived shell
command, and agent harnesses cap how long one command may run, so the loop gets
killed mid-watch and the driver silently stops watching; a blocking wait is far
cheaper, survives much longer, and re-running it simply resumes the wait.

Any PRE-EXISTING PATH is deleted before the one-shot is armed, so a sentinel
left over from an earlier call cannot make the next wait return instantly.
The one-shot is armed BEFORE sending so a fast form cannot finish first; if
`my/slime-send' signals (e.g. unsent input at the prompt and FORCE nil) the
one-shot is removed and the error re-raised, so PATH is never touched for a
form that did not run.

Returns \"sent\" immediately, like `my/slime-send'.  PATH is still a
done-sentinel rather than the result -- read the result with
`my/slime-output-since-mark-to-file' -- but it is not silent about HOW it fired:
it holds one readable line of evidence, written atomically (see
`my/slime--write-sentinel'), e.g.

  (:done t :elapsed-ms 8021 :prompt-returns 1 :output-chars 18422 :suspect nil)

so `cat PATH' after the wait distinguishes a genuinely fast completion (warm
fasl cache, nothing to recompile) from a prompt redraw that fired the one-shot
early.  Without it a 0-second return on a `ql:quickload' is indistinguishable
from a spurious one, and the honest driver wastes a round trip re-checking
`my/slime-repl-status' -- or, worse, distrusts a real result.

The prompt-return edge is not the only way the wait can end: a second one-shot
is armed on `sldb-hook', so a form that parks in the debugger writes PATH too,
as `(:done nil :sldb t ...)'.  Whichever fires first disarms the other, so the
verdict is the FIRST thing that happened and a later abort cannot overwrite it.
That net is what makes \"the wait always ends\" true unconditionally -- the error
capture in `my/slime-send-capturing-then-touch' handles `error' conditions, but
an interrupt or a non-`error' `serious-condition' still opens SLDB.  Test
`:done', not the mere existence of PATH, or a parked form reads as a finished
one.  (`sldb-hook' is global, so an unrelated debugger entry while CODE runs
would also end the wait -- it says `:sldb t', which is honest either way.)

Prefer `my/slime-send-capturing-then-touch': ending the wait with `:sldb t'
still leaves the image parked in the debugger, whereas capturing keeps the form
running to a real prompt.

The prompt advice the sentinel rides on is installed HERE, at arm time, not at
this file's load time, so loading the bridge before SLIME no longer breaks the
sentinel.  In the one case where it still cannot be installed -- no
`slime-repl-insert-prompt' at all, so no prompt-return edge to observe -- CODE
is NOT sent and the return value is an `*ERROR*' string instead of \"sent\".
That is deliberate: a cheerful \"sent\" with no sentinel behind it is invisible
to the driver, which then blocks for its full timeout on a file that can never
appear."
  (if (not (my/slime--ensure-idle-advice))
      (concat "*ERROR* sentinel not armed: `slime-repl-insert-prompt' is"
              " undefined (SLIME REPL not loaded), so the prompt-return edge"
              " cannot be observed; nothing was sent")
    (when (file-exists-p path)
      (delete-file path))
    (let* ((armed-at (float-time))
           (armed-prompts my/slime--prompt-inserts)
           ;; Reset to the post-send position below, so the echoed input form
           ;; itself is not counted as output.
           (start-pos (with-current-buffer (my/slime-assert-connected)
                        (point-max)))
           idle-entry sldb-entry)
      (letrec ((disarm (lambda ()
                         (remove-hook 'my/slime-repl-idle-functions idle-entry)
                         (remove-hook 'sldb-hook sldb-entry)))
               (fire (lambda (sldb)
                       (funcall disarm)
                       (my/slime--write-sentinel path armed-at armed-prompts
                                                 start-pos sldb))))
        (setq idle-entry (lambda () (funcall fire nil))
              ;; Runs inside `sldb-setup', with the SLDB buffer current; demote
              ;; errors so a failure here cannot break the debugger buffer.
              sldb-entry (lambda ()
                           (with-demoted-errors "my/slime sldb sentinel error: %S"
                             (funcall fire t))))
        (add-hook 'my/slime-repl-idle-functions idle-entry)
        (add-hook 'sldb-hook sldb-entry)
        (condition-case err
            (progn
              (my/slime-send code force)
              ;; No process output can arrive between the send and this setq --
              ;; nothing here yields to the filter -- so the one-shot cannot
              ;; fire with the stale position.
              (setq start-pos
                    (with-current-buffer (slime-output-buffer) (point-max))))
          (error
           (funcall disarm)
           (signal (car err) (cdr err))))))
    "sent"))

(defun my/slime-send-capturing-then-touch (path code &optional n-frames force)
  "Send CODE so that errors stay in the REPL and PATH is touched when it is done.
The default call for long-running work, because it composes the two halves that
have to go together:

  * `my/slime--capture-wrap' keeps an `error' in the REPL (condition, message,
    N-FRAMES backtrace frames, return value `:error') instead of parking the
    evaluation in SLDB; and
  * `my/slime-send-then-touch' creates PATH on the prompt-return edge.

Used separately, the sentinel has a nasty failure mode: a form that drops into
SLDB never returns the prompt, so PATH is never created and a shell
`while [ ! -e PATH ]' blocks until a human aborts the debugger.  Capturing the
error means the prompt always comes back -- with `:error' and a backtrace in the
output -- so the wait always ends.  Returns \"sent\" immediately.  Mark first
\(`my/slime-mark') and read `my/slime-output-since-mark-to-file' once PATH
appears.

The capture covers READING as well as evaluating (`my/slime--capture-wrap'), so
a form naming a package the image does not have yet -- the classic
`(my-system::+some-constant+)' before the system is loaded -- self-reports
instead of parking in SLDB.  What capture cannot cover is a non-`error'
`serious-condition' or a C-c interrupt; for those the SLDB net in
`my/slime-send-then-touch' ends the wait with `(:done nil :sldb t ...)'.  So
test `:done' in the sentinel rather than treating its existence as success."
  (my/slime-send-then-touch path (my/slime--capture-wrap code n-frames) force))

;;; ---------------------------------------------------------------------------
;;; Restarting the image
;;;
;;; A stale image lies: `defstruct'/`defclass' slot changes leave old accessors
;;; and instances behind, a renamed or deleted function leaves its ftype and
;;; export proclamations in the package, and a system that only loads because
;;; something earlier defined a symbol will not load cold.  Restarting costs a
;;; re-load and whatever in-image state was built up, and nothing else -- so a
;;; driver should just do it rather than stall waiting for permission.
;;;
;;; The reconnect is itself a wait, i.e. exactly the thing a poll loop gets
;;; wrong, so it lives here rather than in a driver's shell script.
;;; ---------------------------------------------------------------------------

(defun my/slime--connection ()
  "Return the live SLIME connection object, or nil when nothing is connected."
  (and (fboundp 'slime-connected-p)
       (ignore-errors (slime-connected-p))
       (ignore-errors (slime-connection))))

(defun my/slime-restart-and-wait (&optional timeout-seconds load-form sentinel-path)
  "Restart the inferior Lisp, wait for the new REPL, and optionally re-load.

Returns a plist -- `:restarted', `:connected', `:elapsed', `:repl-buffer',
`:load-sent', `:sentinel', and `:error' if the re-load could not be sent.

TIMEOUT-SECONDS (default 60) bounds the wait for the NEW connection; readiness
means a connection object different from the old one plus `my/slime-ready-p',
so a lingering old connection cannot be mistaken for the restarted image.

LOAD-FORM, when given, is a Lisp string sent into the fresh image as visible
REPL input (via `my/slime-send-capturing', so a load error self-reports instead
of opening SLDB) -- typically \"(asdf:load-system :my-system)\".  It is NOT
waited for: a system load is slow, and blocking Emacs on it is the mistake this
file exists to avoid.  Pass SENTINEL-PATH to have the prompt-return touch that
file, then block on it from the shell as usual.  `my/slime-mark' is called just
before the load is sent, so `my/slime-output-since-mark' reads exactly the load
output.

Blocking Emacs in `sleep-for' is acceptable HERE, unlike in
`my/slime-send-wait': an SBCL restart takes a couple of seconds, and everything
slow that follows is sent asynchronously.

Signals a `user-error' when Emacs has no inferior Lisp process -- i.e. the image
was reached with `M-x slime-connect' (Annex B: SBCL running under tmux), where
Emacs did not start it and cannot restart it.  Restart it where it runs, or ask
the user.  Check `my/slime-ready-p' first if you want to be sure you are not
killing a form the user launched; the restart kills the image either way."
  (unless (fboundp 'slime-restart-inferior-lisp)
    (user-error "SLIME is not loaded in this Emacs"))
  (unless (ignore-errors (slime-inferior-process))
    (user-error (concat "No inferior Lisp process: Emacs did not start this "
                        "image (M-x slime-connect), so it cannot restart it")))
  (let* ((old (my/slime--connection))
         (start (float-time))
         (deadline (+ start (or timeout-seconds 60)))
         ready)
    (setq my/slime--mark nil)           ; the old mark points into the old REPL
    (slime-restart-inferior-lisp)
    (while (and (not (setq ready
                           (let ((conn (my/slime--connection)))
                             (and conn (not (eq conn old))
                                  (my/slime-ready-p)))))
                (< (float-time) deadline))
      (sleep-for 0.1))
    ;; Let SLIME's own connected-hooks finish creating/initialising the REPL
    ;; buffer before anything is sent into it.
    (when ready (sleep-for 0.3))
    (let ((elapsed (/ (round (* 10 (- (float-time) start))) 10.0))
          (buf (and ready (ignore-errors (buffer-name (slime-output-buffer)))))
          load-sent load-error)
      (when (and ready load-form)
        (condition-case err
            (progn
              (my/slime-mark)
              (if sentinel-path
                  (my/slime-send-capturing-then-touch sentinel-path load-form)
                (my/slime-send-capturing load-form))
              (setq load-sent load-form))
          (error (setq load-error (error-message-string err)))))
      (append
       (list :restarted t
             :connected (and ready t)
             :elapsed elapsed
             :repl-buffer buf
             :load-sent load-sent)
       (when (and load-sent sentinel-path) (list :sentinel sentinel-path))
       (when load-error (list :error load-error))
       (unless ready
         (list :error (format "no new SLIME connection after %s s" elapsed)))))))

(provide 'slime-bridge)
;;; slime-bridge.el ends here
