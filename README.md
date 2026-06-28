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

Any comment? Open an [issue](https://github.com/occisn/claude-lisp-repl/issues), or start a discussion [here](https://github.com/occisn/claude-lisp-repl/discussions) or [at profile level](https://github.com/occisn/occisn/discussions).

## Prerequisites

- **SBCL** — the Lisp implementation driven in every recipe.
- **Quicklisp** — needed to `(ql:quickload :swank)` in approach 2.
- **tmux** — approaches 1 and 2.
- **Emacs with SLIME** — approaches 2 and 3.
- **WSL + Windows Emacs** — approach 2 specifically assumes SBCL in WSL (Linux) and Emacs on Windows. Adjust the `emacsclient.exe` path below to your install.

## Contents

- [Prerequisites](#prerequisites)
- [1. Claude interacts with Lisp image created within tmux session, through tmux REPL (no emacs)](#1-claude-interacts-with-lisp-image-created-within-tmux-session-through-tmux-repl-no-emacs)
- [2. Claude interacts with Lisp image created within tmux session, through (Windows) Emacs](#2-claude-interacts-with-lisp-image-created-within-tmux-session-through-windows-emacs)
- [3. Claude interacts with Lisp image created within Emacs through Emacs REPL](#3-claude-interacts-with-lisp-image-created-within-emacs-through-emacs-repl)

## 1. Claude interacts with Lisp image created within tmux session, through tmux REPL (no Emacs)

**Step 1** - Claude prompt:

```
Launch SBCL inside a detached tmux session named `lisp`.

If you need to send several instructions to the REPL, send them one at a time, waiting for the prompt to return between them.

The user may be interacting with the lisp image through the REPL on its own, independently from you.

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').
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

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
In `test.lisp` file, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![REPL interaction in a tmux SBCL session: test.lisp loaded (returns T), and (bar 11) returns 121](screenshots/screenshot_1_b.png)

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

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

Paths sent to the image must be in WSL form (`/mnt/c/...`), since the SBCL image runs in Linux. Paths sent to Emacs itself (`load-file` etc.) must be in Windows form (`C:/...`).

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').

When you are ready, tell me, and I will connect to the image from Emacs with `M-x slime-connect RET 127.0.0.1 RET 4006 RET`.

I want all your interactions (stage, execute, load, etc.) with the image to go through the Emacs REPL.

I do not want you to force the REPL buffer onto whatever buffer the user is working on in Emacs. First check if the buffer is open somewhere in a frame or window.

The helper functions below may help. They need SLIME to be connected. Load them in the running Emacs via emacsclient if you find them useful. If you find better variants, tell me so I can improve this prompt.

```elisp
(defun my/slime-stage (code)
  "Insert CODE as pending input at the SLIME REPL prompt, WITHOUT sending it.
The user reviews/tweaks and presses RET to evaluate."
  (let ((buf (and (fboundp 'slime-output-buffer) (slime-output-buffer))))
    (unless buf (user-error "No SLIME REPL buffer; is SLIME connected?"))
    (with-current-buffer buf
      (goto-char (point-max))
      (when (fboundp 'slime-repl-kill-input) (slime-repl-kill-input)) ; clear half-typed input
      (insert code))
    ;; Only surface the REPL if it isn't already shown in any window on any
    ;; frame (0 = all frames, including iconified/minimized); otherwise leave
    ;; the user's current window untouched.
    (unless (get-buffer-window buf 0)
      (display-buffer buf))
    "staged"))

(defun my/slime-send (code)
  (my/slime-stage code)                    ; clears prompt, inserts CODE
  (let ((buf (slime-output-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))                ; presses RET → submits to REPL
  "sent")

(defun my/slime-stage-file (path)
  "Read PATH and stage its (trimmed) contents into the SLIME REPL prompt."
  (my/slime-stage
   (with-temp-buffer
     (insert-file-contents path)
     (string-trim (buffer-string)))))

(defun my/slime-send-file (path)
  "Read PATH, stage its contents at the SLIME REPL prompt, then SUBMIT (execute) it.
Like `my/slime-stage-file' but also presses RET for you, so the form runs as
visible REPL input and lands in the SLIME history."
  (my/slime-stage-file path)            ; guards: errors early if SLIME not connected
  (let ((buf (slime-output-buffer)))    ; safe to call now — connection is established
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))
  "sent")
```
````


**Step 3** - In Emacs: `M-x slime-connect RET 127.0.0.1 RET 4006 RET`

**Example 1 of interaction prompt:**

```
Create a `foo` function which doubles its argument. Apply it to 45. Stage (foo 15).
```

![SLIME REPL: foo defined, (foo 45) returns 90, and (foo 15) staged at the CL-USER prompt](screenshots/screenshot_2_a.png)

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
I have executed a command in the Lisp REPL within Emacs. Do you see it? What was the result?
```

**Example 3 of interaction prompt:**

```
In `test.lisp`, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![SLIME REPL: test.lisp loaded (returns T), and (bar 11) returns 121 at the CL-USER prompt](screenshots/screenshot_2_b.png)

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

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

**Note:** you can obviously use Emacs commands to modify and compile sections of code, for instance `C-c C-c`.

**Note:** even if the purpose of this section is to work through the Emacs REPL, you can still reach the tmux REPL via

```sh
tmux attach -t lisp
```

and detach with `C-b d`.

## 3. Claude interacts with Lisp image created within Emacs through Emacs REPL

**Step 1** - In Emacs: `M-x server-start`.

**Step 2** - Claude prompt:

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

In our future interactions, "stage" instructions would mean send instructions to the REPL without executing them (no 'Enter').

I want all your interactions (stage, execute, load, etc.) with the image to go through the Emacs REPL.

The image is Windows SBCL (Win32), so file loading within the image requires the Windows path namespace.

I do not want you to force the REPL buffer onto whatever buffer the user is working on in Emacs. First check if the buffer is open somewhere in a frame or window.

The helper functions below may help. They need SLIME to be connected. Load them in the running Emacs via emacsclient if you find them useful. If you find better variants, tell me so I can improve this prompt.

```elisp
(defun my/slime-stage (code)
  "Insert CODE as pending input at the SLIME REPL prompt, WITHOUT sending it.
The user reviews/tweaks and presses RET to evaluate."
  (let ((buf (and (fboundp 'slime-output-buffer) (slime-output-buffer))))
    (unless buf (user-error "No SLIME REPL buffer; is SLIME connected?"))
    (with-current-buffer buf
      (goto-char (point-max))
      (when (fboundp 'slime-repl-kill-input) (slime-repl-kill-input)) ; clear half-typed input
      (insert code))
    ;; Only surface the REPL if it isn't already shown in any window on any
    ;; frame (0 = all frames, including iconified/minimized); otherwise leave
    ;; the user's current window untouched.
    (unless (get-buffer-window buf 0)
      (display-buffer buf))
    "staged"))

(defun my/slime-send (code)
  (my/slime-stage code)                    ; clears prompt, inserts CODE
  (let ((buf (slime-output-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))                ; presses RET → submits to REPL
  "sent")

(defun my/slime-stage-file (path)
  "Read PATH and stage its (trimmed) contents into the SLIME REPL prompt."
  (my/slime-stage
   (with-temp-buffer
     (insert-file-contents path)
     (string-trim (buffer-string)))))

(defun my/slime-send-file (path)
  "Read PATH, stage its contents at the SLIME REPL prompt, then SUBMIT (execute) it.
Like `my/slime-stage-file' but also presses RET for you, so the form runs as
visible REPL input and lands in the SLIME history."
  (my/slime-stage-file path)            ; guards: errors early if SLIME not connected
  (let ((buf (slime-output-buffer)))    ; safe to call now — connection is established
    (with-current-buffer buf
      (goto-char (point-max))
      (slime-repl-return)))
  "sent")
```
````

**Example 1 of interaction prompt:**

```
Create a `foo` function which doubles its argument. Apply it to 45. Stage (foo 15).
```

![SLIME REPL: foo defined, (foo 45) returns 90, and (foo 15) staged at the CL-USER prompt](screenshots/screenshot_3_a.png)

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

**Example 2 of interaction prompt:**

```
I have executed a command in the Lisp REPL within Emacs. Do you see it? What was the result?
```

**Example 3 of interaction prompt:**

```
In `test.lisp`, create a `bar` function which squares its argument. Load it in the image and apply it to 11.
```

![SLIME REPL: test.lisp loaded from a Windows path (returns T), and (bar 11) returns 121 at the CL-USER prompt](screenshots/screenshot_3_b.png)

*On the above picture, all interaction with REPL have been performed by Claude directly, with no manual input.*

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

(end of README)
