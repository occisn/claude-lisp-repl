# claude-lisp-repl

Recipes for letting **Claude Code drive a live Common Lisp REPL image** — so it can define functions, load files, and run tests inside the *same* running SBCL you're working in, instead of spawning a throwaway process on every step.

The image is long-lived and shared: you and Claude can both interact with it, independently. This keeps Lisp's interactive, image-based workflow intact while Claude works alongside you.

Three transports are documented, from simplest to most integrated:

| # | Approach                                                                                                          | REPL lives in           | You interact via      | Use when                                                           |
|---|-------------------------------------------------------------------------------------------------------------------|-------------------------|-----------------------|--------------------------------------------------------------------|
| 1 | [tmux session](#1-claude-interacts-with-lisp-image-created-within-tmux-session-through-tmux-repl-no-emacs)        | tmux (SBCL)             | tmux                  | You just want the simplest possible shared REPL, no Emacs.         |
| 2 | [tmux image + Emacs/SLIME](#2-claude-interacts-with-lisp-image-created-within-tmux-session-through-windows-emacs) | WSL tmux (SBCL + swank) | Windows Emacs (SLIME) | You run SBCL in WSL but edit in Windows Emacs and want full SLIME. |
| 3 | [Emacs/SLIME without tmux](#3-claude-interacts-with-lisp-image-created-within-emacs-through-emacs-repl)           | Emacs-launched SLIME    | Windows Emacs (SLIME) | Emacs manages the image itself; no separate tmux needed.           |

A recurring convention across all three: **"stage"** means *send instructions to the REPL without executing them* (no `Enter`) — so you can review or tweak before evaluating.

Approaches 2 and 3 share one set of elisp helpers, [`slime-bridge.el`](slime-bridge.el), covering staging, submitting, waiting for the prompt, and reading output back — see [Helper functions](#helper-functions).

Any comment? Open an [issue](https://github.com/occisn/claude-lisp-repl/issues), or start a discussion [here](https://github.com/occisn/claude-lisp-repl/discussions) or [at profile level](https://github.com/occisn/occisn/discussions).

## Prerequisites

- **SBCL** — the Lisp implementation driven in every recipe.
- **Quicklisp** — needed to `(ql:quickload :swank)` in approach 2.
- **tmux** — approaches 1 and 2.
- **Emacs with SLIME** — approaches 2 and 3.
- **WSL + Windows Emacs** — approach 2 specifically assumes SBCL in WSL (Linux) and Emacs on Windows. Adjust the `emacsclient.exe` path below to your install.

Approaches 2 and 3 also use [`slime-bridge.el`](slime-bridge.el) from this repository; see [Helper functions](#helper-functions).

## Contents

- [Prerequisites](#prerequisites)
- [Helper functions](#helper-functions)
- [Compilation policy and catching errors](#compilation-policy-and-catching-errors)
- [1. Claude interacts with Lisp image created within tmux session, through tmux REPL (no emacs)](#1-claude-interacts-with-lisp-image-created-within-tmux-session-through-tmux-repl-no-emacs)
- [2. Claude interacts with Lisp image created within tmux session, through (Windows) Emacs](#2-claude-interacts-with-lisp-image-created-within-tmux-session-through-windows-emacs)
- [3. Claude interacts with Lisp image created within Emacs through Emacs REPL](#3-claude-interacts-with-lisp-image-created-within-emacs-through-emacs-repl)

## Helper functions

[`slime-bridge.el`](slime-bridge.el) provides the elisp used by approaches 2 and
3. Load it once per Emacs session via `emacsclient`; it needs SLIME connected.

Everything is in that one file — there is no second copy to drift out of sync
— so you can either have Claude `load-file` it as shown in each recipe, or
simply paste its contents at the end of the prompt you give Claude if you
would rather keep the prompt self-contained.

```elisp
(my/slime-stage "(foo 1)")            ; insert at the prompt, do NOT press RET
(my/slime-send  "(foo 1)")            ; insert and submit; returns "sent"
(my/slime-send-wait "(foo 1)" 30)     ; submit, wait for the prompt, return the output
(my/slime-repl-status)                ; connected? busy? visible? pending input?
```

For anything slow — `(ql:quickload ...)`, a test suite — use the non-blocking
sequence instead, which keeps Emacs responsive because every call returns at
once and the shell does the waiting:

```elisp
(my/slime-mark)                       ; remember where output starts
(my/slime-send "(ql:quickload :my-system)")
(my/slime-busy-p)                     ; poll this from the shell, sleeping there
(my/slime-output-since-mark 2000)     ; collect the result

;; …or, to avoid emacsclient's string escaping entirely — which you MUST when a
;; recompile spews `redefining ...' warnings, since send-wait then trips
;; "*ERROR*: Unknown message:" mid-stream — write straight to a file and cat it:
(my/slime-output-since-mark-to-file "/tmp/out.txt")
(my/slime-send-wait-to-file "/tmp/out.txt" "(asdf:load-system :sys :force t)" 300)
(my/slime-interrupt)                  ; stop a runaway form you started
```

To keep an error *in* the REPL — printing its condition and a backtrace, and
returning `:error` — instead of blocking on an SLDB debugger buffer:

```elisp
(my/slime-send-capturing "(risky-form)")       ; wrap in handler-bind, then send
(my/slime-send-capturing "(risky-form)" 40)    ; …and show up to 40 backtrace frames
```

A *hang* you can wrap in a form is best bounded by a self-timeout, which prints
the same spin-point backtrace without ever entering SLDB:

```elisp
(my/slime-send-timed "(maybe-hangs)" 5)        ; with-timeout; returns :timed-out or :error
```

When you must *interrupt* something already running, the story is different — the
interrupt is not an `error`, so it always lands in SLDB. Read that backtrace and
recover with:

```elisp
(my/slime-interrupt)                  ; stop the hang; SLDB opens with a backtrace
(my/slime-sldb-backtrace)             ; return the debugger buffer text (the frames)
(my/slime-sldb-abort)                 ; back to the top-level REPL prompt
```

Four things the file is careful about, each learned the hard way:

- **`slime-output-buffer` signals when nothing is connected**, it does not return
  nil. Guarding with `(and (fboundp 'slime-output-buffer) (slime-output-buffer))`
  therefore never yields a friendly message — you get a raw SLIME error. Check
  `slime-connected-p` first.

- **`my/slime-busy-p` must print as `t` or `nil`.** SLIME's own `slime-busy-p`
  returns the *list* of pending continuations, not a boolean, so a helper that
  passes it through prints something like `((8 . #[(G369) …]))` when called
  through `emacsclient --eval`. A shell poll testing `= "nil"` then never
  matches and the caller waits forever — which is exactly what the workflow
  above tells it to do. The helper coerces to a strict boolean for this reason.
- **`slime-repl-kill-input` kills "from the prompt to point"**, so staging after
  `(goto-char (point-max))` silently discards whatever the user was half-way
  through typing. It lands in the kill ring, but nothing says so. `my/slime-stage`
  refuses to overwrite unsent input unless you pass FORCE — which matters
  precisely because the premise here is that the user is using the image too.
- **The REPL is never forced into the user's window.** It is surfaced only when
  it is not already visible in some window on some frame (`0` = all frames,
  including iconified ones).

## Compilation policy and catching errors

Both of these are just Lisp, so they need no transport of their own — you send
them through the same REPL as everything else (approaches 2 and 3 with
`my/slime-send`, approach 1 with `tmux send-keys`). They matter when you and
Claude are debugging together and want more information out of the image.

### Force full debug info (`debug 3` / `speed 0`)

The compiler's optimization policy governs how much the debugger can later show
you — variable values, un-collapsed stack frames, working single-stepping. To
raise it, set the policy and then **recompile the code you want instrumented**;
the policy only affects compilation done *after* it is set, so already-compiled
functions keep whatever they were built with.

```lisp
;; restrict-compiler-policy sets a FLOOR (min), optionally a CEILING (max):
;;   (restrict-compiler-policy QUALITY &optional (min 0) (max 3))
;; This pins debug UP to 3 -- a floor the source cannot lower:
(sb-ext:restrict-compiler-policy 'debug 3)

;; BEWARE: (restrict-compiler-policy 'speed 0) is a NO-OP -- it sets a floor, and
;; speed >= 0 is always true, so a source (declaim (optimize (speed 3))) still
;; wins.  To force speed DOWN regardless of the source, cap it with the max arg:
(sb-ext:restrict-compiler-policy 'speed 0 0)   ; min 0, max 0 -> pins speed at 0

;; …or the portable global declamation.  This one is a real setter, but only of
;; the DEFAULT policy -- a file-local declaim still overrides it for that file:
(declaim (optimize (debug 3) (speed 0) (safety 3)))

;; then force the recompile so any of the above takes effect
(asdf:load-system "my-system" :force t)   ; :force :all also rebuilds deps
```

The `restrict-compiler-policy` forms are the reliable ones for "make everything
debuggable whatever the source says": a floor (`debug 3`) or ceiling (`speed 0 0`)
clamps the *effective* policy after the code's own declarations, so a stray
`(optimize …)` cannot undo them — which a plain `declaim` (the default only)
can't promise. Undo them later with `(sb-ext:restrict-compiler-policy 'debug 0)`
and `(sb-ext:restrict-compiler-policy 'speed 0 3)` (max back to 3).

### Catch errors instead of dropping into SLDB

When a form errors, SLIME opens an **SLDB** debugger buffer and the evaluation
blocks there — and `my/slime-busy-p` stays `t` the whole time, so a shell poll
loop waits forever. For a driver that fires and reports, it is usually better to
keep the error *in* the REPL. `my/slime-send-capturing` wraps the form so any
`error` prints its type, message and a backtrace, then returns `:error` instead
of entering the debugger:

```elisp
(my/slime-send-capturing "(risky-form)")       ; default 20 backtrace frames
(my/slime-send-capturing "(risky-form)" 40)    ; up to 40 frames
```

The wrapper uses `handler-bind`, not `handler-case`, so the backtrace is taken
at the point the error was *signalled* (before the stack unwinds) and actually
shows where it came from. It traps `error` only — a deliberate `C-c` interrupt,
and conditions that are not `error` subtypes, still reach SLDB as usual. For the
richest backtrace, raise the debug policy (above) before you recompile the code
under test.

### Interrupt a hang, then read the backtrace

`my/slime-send-capturing` does **not** help when a form *hangs* rather than
errors: interrupting it (`my/slime-interrupt`, = `C-c C-c`) raises
`sb-sys:interactive-interrupt`, which is a `serious-condition` but **not** an
`error`, so no `handler-bind` on `error` catches it — it always drops into SLDB.
And while the connection sits in SLDB, `my/slime-busy-p` stays `t`, so a shell
poll loop would wait forever. Three helpers reach the debugger buffer that the
REPL-reading helpers never touch:

```elisp
(my/slime-interrupt)             ; stop the hang; SLDB opens
(my/slime-sldb-backtrace)        ; the debugger buffer text — condition, restarts, frames
(my/slime-sldb-abort)            ; invoke ABORT, returning to the top-level prompt
```

`my/slime-repl-status` also gains an `:in-debugger` flag so one call tells you
the connection is parked in SLDB. To avoid `emacsclient`'s newline escaping on
the multi-line frames, write the backtrace straight to a file with
`my/slime-sldb-backtrace-to-file` and read it from the shell.

For example, a loop that decrements its index by mistake and only exits on
`(> n 100)` never terminates. Raise the debug policy, define it, let it spin,
then interrupt — the backtrace pins the bug, showing the index deep in negative
territory:

```
Backtrace:
  0: (SB-UNIX::WITH-DEFERRABLE-SIGNALS-UNBLOCKED T ...)
  2: (SB-UNIX:NANOSLEEP 0 20000000)
  3: (RUN-UNTIL -56)              ; <- n is negative: the decf should have been incf
  4: (SB-INT:SIMPLE-EVAL-IN-LEXENV (RUN-UNTIL 0) #<NULL-LEXENV>)
```

`(my/slime-sldb-abort)` then returns to the prompt and the image is usable
again. The `-56` (and the `RUN-UNTIL` frame at all) is only visible because the
policy was raised to `debug 3` first — another reason the two halves of this
section belong together.

### Deterministic self-timeout — safer than interrupt

When the hang is something you can wrap in a form, prefer `my/slime-send-timed`
over interrupting. It bounds the call with `sb-ext:with-timeout`, so the image
times *itself* out and prints the same spin-point backtrace — no external
`SIGINT`, no modal SLDB round-trip, and the stack unwinds cleanly so the prompt
returns on its own:

```elisp
(my/slime-send-timed "(run-until 0)" 5)      ; give up after 5 s, print the backtrace
(my/slime-send-timed "(run-until 0)" 5 40)   ; …with up to 40 frames
```

The backtrace is taken at the hang (via `handler-bind`, before unwinding), just
like the interrupt path, and the same wrapper also catches an `error` if the form
blows up first — the form returns `:timed-out` or `:error`. Because the image is
never parked in SLDB, `my/slime-busy-p` never gets stuck at `t`. Keep
`my/slime-interrupt` for stopping something *already* running that you did not
launch through `send-timed`.

### When raising debug *changes* the bug

The `run-until` example is a *logic* bug: it hangs at every optimization policy,
and `debug 3` merely makes the frame's `-56` legible. A nastier class announces
itself differently — **raising `debug` (or `safety`) makes the hang or the wrong
answer disappear.** That is the signature of a miscompilation or an unsound
declaration, not a program-logic error: typically a wrong `(the TYPE …)` or
`(declaim (type …))` that the compiler trusts at low `safety`, producing code
that misbehaves only when optimized. Two techniques:

- **Bisect the level that still reproduces.** Recompile at successively higher
  `debug`/`safety` until the symptom vanishes; the boundary confirms it is an
  optimization/declaration problem rather than logic, and points at the quality
  to distrust.
- **Un-inline the suspects.** At high `speed` SBCL inlines small helpers, so the
  spinning frame is collapsed into its caller and the backtrace shows only the
  outer function with `#<unavailable>` arguments. `(declaim (notinline foo bar))`
  (then recompile) keeps those frames separate, so the backtrace names the
  function that is actually looping and shows its arguments.

## 1. Claude interacts with Lisp image created within tmux session, through tmux REPL (no Emacs)

**Step 1** - Claude prompt:

```
Launch SBCL inside a detached tmux session named `lisp`.

If you need to send several instructions to the REPL, send them one at a time, waiting for the prompt to return between them.

The user may be interacting with the lisp image through the REPL on its own, independently from you.

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').

Fire and report: when I ask you to stage something, stage it and just tell me "staged"; when I ask you to execute something, send it and tell me "sent". Do not keep capturing the pane to read and analyse the output — I am watching the REPL myself. Use `capture-pane` only to confirm the prompt has returned before you send the next instruction. Collect and interpret output only when I explicitly ask for it.
```

**Step 2** - Open the tmux session from a terminal:

```sh
tmux attach -t lisp
```

Detach with `C-b d`.

**Example 1 of interaction prompt:**

```
Create a `foo` function which doubles its argument. Apply it to 45. Stage (foo 15).
```

![REPL interaction in a tmux SBCL session: foo defined, (foo 45) returns 90, and (foo 15) staged at the prompt](screenshots/screenshot_1_a.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
In `test.lisp` file, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![REPL interaction in a tmux SBCL session: test.lisp loaded (returns T), and (bar 11) returns 121](screenshots/screenshot_1_b.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**To close the session**, use this prompt:

```
Close the lisp tmux session
```

## 2. Claude interacts with Lisp image created within tmux session, through (Windows) Emacs

**Step 1** - In Emacs, launch the server:

```elisp
M-x server-start
```

`(bound-and-true-p server-process)` then returns non-nil.

**Step 2** - Claude prompt:

*(The helper functions are in a single file, [`slime-bridge.el`](slime-bridge.el) — let Claude load it, or paste its contents at the end of this prompt.)*

````
Launch SBCL inside a detached tmux session named `lisp`.
Typical instructions for the above:

```sh
tmux new-session -d -s lisp sbcl
sleep 2
tmux capture-pane -t lisp -p | tail -20      # confirm the '*' prompt
```

Load swank into that image and start a server on port 4006 (leaving 4005 free for Emacs's SLIME default).
Typical instructions for the above:

```sh
tmux send-keys -t lisp '(ql:quickload :swank)' Enter
sleep 3
tmux capture-pane -t lisp -p | tail -15      # -> (:SWANK)
tmux send-keys -t lisp '(swank:create-server :port 4006 :dont-close t)' Enter
sleep 3
tmux capture-pane -t lisp -p | tail -15      # -> ";; Swank started at port: 4006."
```

Verify the listener is up.
Typical instructions for the above:

```sh
ss -ltn | grep -E '4006|4005'                # -> LISTEN 127.0.0.1:4006
```

Hint for future interactions: some instructions may need a few seconds to execute on the tmux REPL; in that case you will need to try a new capture-pane after a short interval.

We want to interact with this image through Emacs, not through tmux.

Emacs is running in a Windows environment and `server-start` has been launched. You may need to use `emacsclient.exe` to interact with it.
Location: `/mnt/c/portable-programs/emacs-30.2/bin/emacsclient.exe`
Test:

```sh
/mnt/c/portable-programs/emacs-30.2/bin/emacsclient.exe --eval '(emacs-version)'
```

The user may be interacting with the lisp image through the Emacs REPL on its own, independently from you.

If you need to send several instructions to the REPL, send them one at a time, waiting for the prompt to return between them.

Fire and report: when I ask you to stage something, stage it and just tell me "staged"; when I ask you to execute something, send it and tell me "sent". Do not poll, do not wait for the evaluation to finish, and do not fetch the output to analyse it — I am watching the REPL and can already see the result. Collect and interpret output only when I explicitly ask ("what did that return?"). After staging, leave the prompt alone: checking whether the staged form is still pending just races my RET. One `(my/slime-busy-p)` call before sending a *new* form is fine — that is a precondition check, not result analysis, and it stops you firing into a busy REPL or an open SLDB debugger.

Paths sent to the image must be in WSL form (`/mnt/c/...`), since the SBCL image runs in Linux. Paths sent to Emacs itself (`load-file` etc.) must be in Windows form (`C:/...`).

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').

When you are ready, tell me, and I will connect to the image from Emacs with `M-x slime-connect RET 127.0.0.1 RET 4006 RET`.

I want all your interactions (stage, execute, load, etc.) with the image to go through the Emacs REPL.

I do not want you to force the REPL buffer onto whatever buffer the user is working on in Emacs. First check if the buffer is open somewhere in a frame or window.

Helper functions for staging, sending, waiting for the prompt and reading output
back are in [`slime-bridge.el`](slime-bridge.el) of this repository. Load them in
the running Emacs (Windows path namespace if Emacs is a Windows process, even
when you call it from WSL):

```sh
emacsclient --eval '(load-file "/path/to/claude-lisp-repl/slime-bridge.el")'
```

Then:

| Need | Call |
|------|------|
| stage without evaluating | `(my/slime-stage "FORM")` |
| submit | `(my/slime-send "FORM")` |
| submit and read the result | `(my/slime-send-wait "FORM" TIMEOUT)` |
| submit, catching errors in the REPL instead of SLDB | `(my/slime-send-capturing "FORM")` |
| bound a hang deterministically (safer than interrupt) | `(my/slime-send-timed "FORM" SECONDS)` |
| slow work (system load, test run) | `(my/slime-mark)`, `(my/slime-send ...)`, poll `(my/slime-busy-p)` from the shell, then `(my/slime-output-since-mark)` |
| submit + wait, output to a file (dodges escaping on noisy builds) | `(my/slime-send-wait-to-file "/tmp/out.txt" "FORM" TIMEOUT)` |
| output without escaping | `(my/slime-output-since-mark-to-file "/tmp/out.txt")`, `(my/slime-repl-tail-to-file ...)` |
| stop a runaway form | `(my/slime-interrupt)` |
| read the backtrace after an interrupt | `(my/slime-sldb-backtrace)` / `(my/slime-sldb-backtrace-to-file "/tmp/bt.txt")` |
| leave the debugger | `(my/slime-sldb-abort)` |
| where am I | `(my/slime-repl-status)` |

Do not use `my/slime-send-wait` for slow work: it blocks Emacs in `sleep-for`,
which queues the user's keystrokes and makes Emacs feel frozen until the form
finishes. Poll from the shell instead, so the sleeping happens outside Emacs.

Expect slow to look like stuck. Touching a file near the root of a `:serial t`
ASDF system makes every downstream file recompile, so a `test-system` can sit
silent for many minutes and be perfectly healthy. Judge by whether
`(my/slime-repl-status)`'s `:tail` is *moving*, not by elapsed time — and if it
really is wedged, `(my/slime-interrupt)` ends it without touching the user's
window.

In day-to-day use you will reach for `my/slime-stage` and `my/slime-send` far
more than the reading helpers: the user is watching the REPL, so the default is
to fire and report rather than to read results back (see the prompts). The
reading helpers earn their place when the user *asks* for output, and when a
long build needs watching without freezing Emacs.

If you find better variants, tell me so I can improve this prompt.
````


**Step 3** - In Emacs: `M-x slime-connect RET 127.0.0.1 RET 4006 RET`

**Example 1 of interaction prompt:**

```
Create a `foo` function which doubles its argument. Apply it to 45. Stage (foo 15).
```

![SLIME REPL: foo defined, (foo 45) returns 90, and (foo 15) staged at the CL-USER prompt](screenshots/screenshot_2_a.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
I have executed a command in the Lisp REPL within Emacs. Do you see it? What was the result?
```

**Example 3 of interaction prompt:**

```
In `test.lisp`, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![SLIME REPL: test.lisp loaded (returns T), and (bar 11) returns 121 at the CL-USER prompt](screenshots/screenshot_2_b.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**Other examples of interaction prompt, involving systems:**

```
Force load cl-abc system and launch main function
```

```
I have modified code; force reload and execute main function
```

```
Launch system tests
```

**Example involving the debugger and compilation policy:**

```
Force the compiler to debug 3 / speed 0, reload cl-abc, then run (main) but catch any error in the REPL instead of dropping me into SLDB — I want to see the condition and a backtrace.
```

This has Claude send `(sb-ext:restrict-compiler-policy 'debug 3)` (and `(sb-ext:restrict-compiler-policy 'speed 0 0)` to actually cap speed — a bare `'speed 0` is a no-op), `(asdf:load-system "cl-abc" :force t)`, then `(my/slime-send-capturing "(main)")` — see [Compilation policy and catching errors](#compilation-policy-and-catching-errors).

**Example where a test hangs:**

```
The test seems stuck — interrupt it and show me the backtrace so we can see where it is spinning, then get the REPL back.
```

Claude sends `(my/slime-interrupt)`, reads `(my/slime-sldb-backtrace)` (the frames name the looping function and, at `debug 3`, its arguments), then `(my/slime-sldb-abort)` to return to the prompt.

**Note:** you can obviously use Emacs commands to modify and compile sections of code, for instance `C-c C-c`.

**Note:** even if the purpose of this section is to work through the Emacs REPL, you can still reach the tmux REPL via

```sh
tmux attach -t lisp
```

and detach with `C-b d`.

## 3. Claude interacts with Lisp image created within Emacs through Emacs REPL

**Step 1** - In Emacs: `M-x server-start`.

**Step 2** - Claude prompt:

*(The helper functions are in a single file, [`slime-bridge.el`](slime-bridge.el) — let Claude load it, or paste its contents at the end of this prompt.)*

````
Emacs is running in a Windows environment and `server-start` has been launched. You may need to use `emacsclient.exe` to interact with it.
Location: `/mnt/c/portable-programs/emacs-30.2/bin/emacsclient.exe`
Test:

```sh
/mnt/c/portable-programs/emacs-30.2/bin/emacsclient.exe --eval '(emacs-version)'
```

If not available yet, execute SLIME within Emacs to launch an SBCL image with swank on the default port (4005) and open a REPL.

The user may later be interacting with the lisp image through the Emacs REPL on its own, independently from you.

If you need to send several instructions to the REPL, send them one at a time, waiting for the prompt to return between them.

Fire and report: when I ask you to stage something, stage it and just tell me "staged"; when I ask you to execute something, send it and tell me "sent". Do not poll, do not wait for the evaluation to finish, and do not fetch the output to analyse it — I am watching the REPL and can already see the result. Collect and interpret output only when I explicitly ask ("what did that return?"). After staging, leave the prompt alone: checking whether the staged form is still pending just races my RET. One `(my/slime-busy-p)` call before sending a *new* form is fine — that is a precondition check, not result analysis, and it stops you firing into a busy REPL or an open SLDB debugger.

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').

I want all your interactions (stage, execute, load, etc.) with the image to go through the Emacs REPL.

Emacs **and** the image are Windows processes here, while your shell is WSL, so the same file has two spellings: paths sent to Emacs (`load-file`) or into the image (`load`, `asdf`) must be Windows form (`C:/...`); paths used by your own shell tools must be WSL form (`/mnt/c/...`). Note this is the mirror image of approach 2, where the image runs in WSL.

I do not want you to force the REPL buffer onto whatever buffer the user is working on in Emacs. First check if the buffer is open somewhere in a frame or window.

Helper functions for staging, sending, waiting for the prompt and reading output
back are in [`slime-bridge.el`](slime-bridge.el) of this repository. Load them in
the running Emacs (Windows path namespace if Emacs is a Windows process, even
when you call it from WSL):

```sh
emacsclient --eval '(load-file "/path/to/claude-lisp-repl/slime-bridge.el")'
```

Then:

| Need | Call |
|------|------|
| stage without evaluating | `(my/slime-stage "FORM")` |
| submit | `(my/slime-send "FORM")` |
| submit and read the result | `(my/slime-send-wait "FORM" TIMEOUT)` |
| submit, catching errors in the REPL instead of SLDB | `(my/slime-send-capturing "FORM")` |
| bound a hang deterministically (safer than interrupt) | `(my/slime-send-timed "FORM" SECONDS)` |
| slow work (system load, test run) | `(my/slime-mark)`, `(my/slime-send ...)`, poll `(my/slime-busy-p)` from the shell, then `(my/slime-output-since-mark)` |
| submit + wait, output to a file (dodges escaping on noisy builds) | `(my/slime-send-wait-to-file "/tmp/out.txt" "FORM" TIMEOUT)` |
| output without escaping | `(my/slime-output-since-mark-to-file "/tmp/out.txt")`, `(my/slime-repl-tail-to-file ...)` |
| stop a runaway form | `(my/slime-interrupt)` |
| read the backtrace after an interrupt | `(my/slime-sldb-backtrace)` / `(my/slime-sldb-backtrace-to-file "/tmp/bt.txt")` |
| leave the debugger | `(my/slime-sldb-abort)` |
| where am I | `(my/slime-repl-status)` |

Do not use `my/slime-send-wait` for slow work: it blocks Emacs in `sleep-for`,
which queues the user's keystrokes and makes Emacs feel frozen until the form
finishes. Poll from the shell instead, so the sleeping happens outside Emacs.

Expect slow to look like stuck. Touching a file near the root of a `:serial t`
ASDF system makes every downstream file recompile, so a `test-system` can sit
silent for many minutes and be perfectly healthy. Judge by whether
`(my/slime-repl-status)`'s `:tail` is *moving*, not by elapsed time — and if it
really is wedged, `(my/slime-interrupt)` ends it without touching the user's
window.

If you find better variants, tell me so I can improve this prompt.
````

**Example 1 of interaction prompt:**

```
Create a `foo` function which doubles its argument. Apply it to 45. Stage (foo 15).
```

![SLIME REPL: foo defined, (foo 45) returns 90, and (foo 15) staged at the CL-USER prompt](screenshots/screenshot_3_a.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
I have executed a command in the Lisp REPL within Emacs. Do you see it? What was the result?
```

**Example 3 of interaction prompt:**

```
In `test.lisp`, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![SLIME REPL: test.lisp loaded from a Windows path (returns T), and (bar 11) returns 121 at the CL-USER prompt](screenshots/screenshot_3_b.png)

*On the above picture, all interactions with REPL have been performed by Claude directly, with no manual input.*

**Other examples of interaction prompts, related to systems:**

```
Force load cl-abc system and launch main function
```

```
I have modified code; force reload and execute main function
```

```
Launch system tests
```

**Example involving the debugger and compilation policy:**

```
Force the compiler to debug 3 / speed 0, reload cl-abc, then run (main) but catch any error in the REPL instead of dropping me into SLDB — I want to see the condition and a backtrace.
```

This has Claude send `(sb-ext:restrict-compiler-policy 'debug 3)` (and `(sb-ext:restrict-compiler-policy 'speed 0 0)` to actually cap speed — a bare `'speed 0` is a no-op), `(asdf:load-system "cl-abc" :force t)`, then `(my/slime-send-capturing "(main)")` — see [Compilation policy and catching errors](#compilation-policy-and-catching-errors).

**Example where a test hangs:**

```
The test seems stuck — interrupt it and show me the backtrace so we can see where it is spinning, then get the REPL back.
```

Claude sends `(my/slime-interrupt)`, reads `(my/slime-sldb-backtrace)` (the frames name the looping function and, at `debug 3`, its arguments), then `(my/slime-sldb-abort)` to return to the prompt.

(end of README)
