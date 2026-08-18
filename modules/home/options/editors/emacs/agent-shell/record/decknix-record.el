;;; decknix-record.el --- Record decknix/agent-shell demos -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, screencast

;;; Commentary:
;;
;; Record a demo of a decknix session (#158).  Two backends:
;;
;;   - GUI  : macOS `screencapture -v' captures a screen RECTANGLE to a
;;            .mov.  The rectangle is derived from a chosen capture
;;            TARGET so you can record just the sidebar, a single
;;            agent-shell window, the whole Emacs frame, or the whole
;;            display.  Optionally transcoded to mp4/gif via `ffmpeg'.
;;   - TERM : `asciinema rec' captures a terminal session to a .cast in a
;;            fresh `ansi-term'; `agg' renders it to an animated GIF.
;;            (For `emacs -nw' or recording a shell/vterm session.)
;;
;; Entry points:
;;   `decknix-record-start'   — pick backend + target, begin recording.
;;   `decknix-record-stop'    — finish and finalise the file.
;;   `decknix-record-toggle'  — start if idle, stop if recording.
;;   `decknix-record-open-directory' — open the recordings folder.
;;
;; macOS note: GUI capture needs Screen Recording permission for the
;; Emacs binary (System Settings > Privacy & Security > Screen Recording).
;;
;; Retina/geometry: `screencapture -R' takes POINTS while Emacs reports
;; PIXELS, so a Retina display needs `decknix-record-scale' = 2.0 (the
;; default).  If a window/frame capture is offset or wrong-sized, tune
;; `decknix-record-scale' and `decknix-record-y-offset' once for your
;; machine.  "Whole display" needs no geometry and always works.

;;; Code:

(require 'subr-x)

(defgroup decknix-record nil
  "Record decknix/agent-shell demos."
  :group 'decknix)

(defcustom decknix-record-directory (expand-file-name "~/Recordings/decknix")
  "Directory where recordings are written (created on demand)."
  :type 'directory :group 'decknix-record)

(defcustom decknix-record-scale 2.0
  "Pixels-per-point of the display, used to convert Emacs pixel
geometry into the POINT coordinates `screencapture -R' expects.
2.0 for a Retina display, 1.0 for a non-Retina display."
  :type 'number :group 'decknix-record)

(defcustom decknix-record-y-offset 0
  "Extra points added to the top of a computed capture rectangle.
Calibrates for the window-system title bar that `frame-position'
may or may not include.  Increase if captures sit too high."
  :type 'integer :group 'decknix-record)

(defcustom decknix-record-gui-format 'mov
  "Container/format for GUI recordings.
`mov' keeps `screencapture' output as-is (no transcode).  `mp4' and
`gif' transcode via `ffmpeg' after stopping."
  :type '(choice (const mov) (const mp4) (const gif))
  :group 'decknix-record)

(defcustom decknix-record-framerate 30
  "Target frame rate for transcoded (mp4/gif) GUI output."
  :type 'integer :group 'decknix-record)

;; -- State --------------------------------------------------------------

(defvar decknix-record--process nil
  "The live recording process, or nil when idle.")

(defvar decknix-record--output nil
  "Absolute path of the file the live recording writes to.")

(defvar decknix-record--backend nil
  "Backend of the live recording: `gui' or `term'.")

(defun decknix-record--active-p ()
  "Return non-nil when a recording is in progress."
  (and decknix-record--process
       (process-live-p decknix-record--process)))

;; -- Geometry -----------------------------------------------------------
;;
;; All rectangles are (X Y W H) in screen POINTS, top-left origin, ready
;; for `screencapture -R X,Y,W,H'.  nil means "whole display".

(defun decknix-record--scale (px)
  "Convert PX Emacs pixels to screen points via `decknix-record-scale'."
  (round (/ px (max 0.1 decknix-record-scale))))

(defun decknix-record--frame-rect (frame)
  "Return the (X Y W H) point rectangle covering FRAME's content."
  (let* ((pos (frame-position frame))
         (fx (car pos))
         (fy (cdr pos)))
    (list (decknix-record--scale fx)
          (+ (decknix-record--scale fy) decknix-record-y-offset)
          (decknix-record--scale (frame-pixel-width frame))
          (decknix-record--scale (frame-pixel-height frame)))))

(defun decknix-record--window-rect (win)
  "Return the (X Y W H) point rectangle covering WIN in its frame."
  (let* ((frame (window-frame win))
         (pos (frame-position frame))
         (fx (car pos))
         (fy (cdr pos))
         ;; window-pixel-left/top are relative to the frame's inner area.
         (wl (window-pixel-left win))
         (wt (window-pixel-top win)))
    (list (decknix-record--scale (+ fx wl))
          (+ (decknix-record--scale (+ fy wt)) decknix-record-y-offset)
          (decknix-record--scale (window-pixel-width win))
          (decknix-record--scale (window-pixel-height win)))))

(defun decknix-record--pick-window ()
  "Prompt for a window in the selected frame by its buffer name.
Returns the chosen window."
  (let* ((wins (window-list nil 'no-minibuffer))
         (alist (mapcar (lambda (w) (cons (buffer-name (window-buffer w)) w))
                        wins))
         (choice (completing-read "Record window: " alist nil t)))
    (cdr (assoc choice alist))))

(defun decknix-record--resolve-rect (target)
  "Return the (X Y W H) point rect for TARGET, or nil for whole display.
TARGET is one of the symbols `this-window', `this-frame',
`whole-display', or `pick-window'."
  (pcase target
    ('whole-display nil)
    ('this-frame (decknix-record--frame-rect (selected-frame)))
    ('this-window (decknix-record--window-rect (selected-window)))
    ('pick-window (decknix-record--window-rect (decknix-record--pick-window)))
    (_ nil)))

;; -- Filenames ----------------------------------------------------------

(defun decknix-record--timestamp ()
  "Return a filesystem-safe timestamp string."
  (format-time-string "%Y%m%d-%H%M%S"))

(defun decknix-record--new-path (ext)
  "Return a fresh absolute recording path with EXT (no leading dot)."
  (unless (file-directory-p decknix-record-directory)
    (make-directory decknix-record-directory t))
  (expand-file-name (format "decknix-%s.%s" (decknix-record--timestamp) ext)
                    decknix-record-directory))

;; -- GUI backend (screencapture) ---------------------------------------

(defun decknix-record--start-gui (target)
  "Start a macOS `screencapture' recording of TARGET."
  (unless (executable-find "screencapture")
    (user-error "`screencapture' not found (macOS only)"))
  (let* ((rect (decknix-record--resolve-rect target))
         (out (decknix-record--new-path "mov"))
         (args (append (list "-v")
                       (when rect
                         (list "-R" (format "%d,%d,%d,%d"
                                             (nth 0 rect) (nth 1 rect)
                                             (nth 2 rect) (nth 3 rect))))
                       (list out))))
    (setq decknix-record--output out
          decknix-record--backend 'gui
          decknix-record--process
          (make-process
           :name "decknix-record"
           :buffer (get-buffer-create "*decknix-record*")
           :command (cons "screencapture" args)
           :noquery t
           :sentinel #'decknix-record--gui-sentinel))
    (message "Recording %s → %s  (M-x decknix-record-stop to finish)"
             target (abbreviate-file-name out))))

(defun decknix-record--gui-sentinel (_proc event)
  "Sentinel for the GUI recording PROC; finalise on EVENT."
  (when (string-match-p "\\(finished\\|exited\\|killed\\|interrupt\\)" event)
    (let ((out decknix-record--output))
      (setq decknix-record--process nil)
      (when (and out (file-exists-p out))
        (decknix-record--maybe-transcode out)))))

(defun decknix-record--maybe-transcode (mov)
  "Transcode MOV to `decknix-record-gui-format' when it is mp4/gif."
  (pcase decknix-record-gui-format
    ('mov (message "Recording saved: %s" (abbreviate-file-name mov)))
    ((and fmt (or 'mp4 'gif))
     (if (not (executable-find "ffmpeg"))
         (message "Recording saved: %s (ffmpeg absent — kept .mov)"
                  (abbreviate-file-name mov))
       (let* ((ext (symbol-name fmt))
              (out (concat (file-name-sans-extension mov) "." ext))
              (args (if (eq fmt 'gif)
                        (list "-y" "-i" mov "-vf"
                              (format "fps=%d,scale=1280:-1:flags=lanczos"
                                      decknix-record-framerate)
                              out)
                      (list "-y" "-i" mov "-r"
                            (number-to-string decknix-record-framerate)
                            "-pix_fmt" "yuv420p" out))))
         (message "Transcoding → %s…" (abbreviate-file-name out))
         (make-process
          :name "decknix-record-transcode"
          :buffer (get-buffer-create "*decknix-record*")
          :command (cons "ffmpeg" args)
          :noquery t
          :sentinel
          (lambda (_p e)
            (when (string-match-p "finished" e)
              (message "Recording saved: %s" (abbreviate-file-name out))))))))))

;; -- Terminal backend (asciinema) --------------------------------------

(defun decknix-record--start-term ()
  "Start an `asciinema rec' session in a fresh `ansi-term'."
  (unless (executable-find "asciinema")
    (user-error "`asciinema' not found"))
  (let ((out (decknix-record--new-path "cast")))
    (setq decknix-record--output out
          decknix-record--backend 'term
          decknix-record--process nil) ;; the term process owns the TTY
    (require 'term)
    (let ((buf (get-buffer-create "*decknix-record-term*")))
      (with-current-buffer buf
        (term-mode)
        (term-exec buf "decknix-record-term"
                   "asciinema" nil (list "rec" out))
        (term-char-mode))
      (switch-to-buffer buf)
      (message "asciinema recording → %s. Type `exit' (or C-d) in the terminal to finish; then M-x decknix-record-cast-to-gif."
               (abbreviate-file-name out)))))

(defun decknix-record-cast-to-gif (cast)
  "Render an asciinema CAST file to an animated GIF via `agg'."
  (interactive
   (list (read-file-name "Cast file: " decknix-record-directory
                         decknix-record--output t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-suffix-p ".cast" f))))))
  (unless (executable-find "agg")
    (user-error "`agg' not found (needed to render .cast → .gif)"))
  (let ((out (concat (file-name-sans-extension cast) ".gif")))
    (message "Rendering → %s…" (abbreviate-file-name out))
    (make-process
     :name "decknix-record-agg"
     :buffer (get-buffer-create "*decknix-record*")
     :command (list "agg" cast out)
     :noquery t
     :sentinel (lambda (_p e)
                 (when (string-match-p "finished" e)
                   (message "GIF saved: %s" (abbreviate-file-name out)))))))

;; -- Public commands ----------------------------------------------------

;;;###autoload
(defun decknix-record-start ()
  "Begin recording a demo: choose a backend and (for GUI) a target."
  (interactive)
  (when (decknix-record--active-p)
    (user-error "Already recording (M-x decknix-record-stop to finish)"))
  (let ((backend (intern (completing-read
                          "Record backend: "
                          '("gui" "terminal") nil t nil nil "gui"))))
    (pcase backend
      ('gui
       (let ((target (intern (completing-read
                              "Capture: "
                              '("this-window" "this-frame"
                                "whole-display" "pick-window")
                              nil t nil nil "this-frame"))))
         (decknix-record--start-gui target)))
      ('terminal (decknix-record--start-term)))))

;;;###autoload
(defun decknix-record-stop ()
  "Stop the current GUI recording and finalise the file.
Terminal recordings finish when you exit the `asciinema' shell."
  (interactive)
  (cond
   ((decknix-record--active-p)
    ;; SIGINT lets `screencapture -v' flush and write a valid .mov.
    (interrupt-process decknix-record--process)
    (message "Stopping recording…"))
   ((eq decknix-record--backend 'term)
    (message "Terminal recording: type `exit' / C-d in *decknix-record-term* to finish"))
   (t (message "No active recording"))))

;;;###autoload
(defun decknix-record-toggle ()
  "Start a recording when idle, stop it when active."
  (interactive)
  (if (decknix-record--active-p)
      (decknix-record-stop)
    (decknix-record-start)))

;;;###autoload
(defun decknix-record-open-directory ()
  "Open the recordings directory in Dired."
  (interactive)
  (unless (file-directory-p decknix-record-directory)
    (make-directory decknix-record-directory t))
  (dired decknix-record-directory))

(provide 'decknix-record)
;;; decknix-record.el ends here
