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
;; On Windows Emacs the path must be in the Windows namespace, e.g.
;; "C:/Users/you/src/claude-lisp-repl/slime-bridge.el", even when the call is
;; issued from WSL.
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
;; Usage convention (see the README prompts): stage or send, then report and
;; stop.  The user is watching the REPL, so reading results back is wasted
;; effort unless they ask for them.  `my/slime-busy-p' before sending a NEW
;; form is the exception -- a precondition check, not result analysis.

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
poll forever."
  (and (fboundp 'slime-busy-p)
       (not (null (ignore-errors (slime-busy-p))))))

(defun my/slime-interrupt ()
  "Interrupt the running evaluation -- the shell-side equivalent of C-c C-c.

Lets a caller stop a runaway form it started itself, without touching whatever
window the user is looking at.  Returns \"interrupted\" if a request was sent,
\"idle\" if nothing was running."
  (if (my/slime-busy-p)
      (progn (my/slime-assert-connected)
             (slime-interrupt)
             "interrupted")
    "idle"))

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
    (while (and (my/slime-busy-p) (< (float-time) deadline))
      (sleep-for 0.05))
    (let ((timed-out (and (my/slime-busy-p) (>= (float-time) deadline))))
      (with-current-buffer buf
        (let ((text (buffer-substring-no-properties
                     (min start (point-max)) (point-max))))
          (if timed-out
              (concat text "\n[TIMEOUT -- evaluation still running]")
            (if (and n-chars (> (length text) n-chars))
                (substring text (- (length text) n-chars))
              text)))))))

;;; ---------------------------------------------------------------------------
;;; Long-running work: mark / send / poll / read
;;;
;;;   (my/slime-mark)                  -> remember where output starts
;;;   (my/slime-send "(long-form)")    -> returns immediately
;;;   (my/slime-busy-p)                -> poll from the shell, sleeping THERE
;;;   (my/slime-output-since-mark)     -> collect the result
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

(defun my/slime-output-since-mark-to-file (path &optional max-chars)
  "Write `my/slime-output-since-mark' to PATH as UTF-8.  Return PATH."
  (my/slime-write-string-to-file (my/slime-output-since-mark max-chars) path))

(defun my/slime-repl-tail-to-file (path &optional n-chars)
  "Write `my/slime-repl-tail' to PATH as UTF-8.  Return PATH."
  (my/slime-write-string-to-file (my/slime-repl-tail n-chars) path))

(defun my/slime-repl-status ()
  "One-call summary: connection, REPL buffer, package, busy state, prompt tail."
  (if (not (and (fboundp 'slime-connected-p) (slime-connected-p)))
      (list :connected nil)
    (list :connected t
          :repl-buffer (buffer-name (slime-output-buffer))
          :package (ignore-errors (slime-current-package))
          :busy (and (my/slime-busy-p) t)
          :visible (and (get-buffer-window (slime-output-buffer) 0) t)
          :pending-input (my/slime-pending-input)
          :tail (string-trim (my/slime-repl-tail 200)))))

(provide 'slime-bridge)
;;; slime-bridge.el ends here
