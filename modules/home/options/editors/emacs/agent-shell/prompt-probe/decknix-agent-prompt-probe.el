;;; decknix-agent-prompt-probe.el --- Resume-time prompt state capture -*- lexical-binding: t -*-

;;; Commentary:
;;
;; Why this exists rather than another fix attempt.
;;
;; "No ` Me ' label and no prompt after resuming" has been reported four
;; times and diagnosed differently each time, because every diagnosis read
;; state MINUTES after the sighting:
;;
;;   A  prompt genuinely buried below a `session/load' replay   fixed
;;   B  window kept a stale `window-start', prompt off screen   fixed
;;   C  no live window at all; a tab restored a stale scroll    open
;;
;; On session 01a0b2e2 all three were ruled out: the overlay carried its
;; marker, `init-finished' was t, and `pos-visible-in-window-p' put
;; `point-max' on screen at (0 154).  The label was correct by the time it
;; was measured and demonstrably wrong when it was seen, so the fault is
;; transient and after-the-fact state cannot name it.
;;
;; Two traps this module exists to avoid repeating:
;;
;; `window-end' is NOT evidence.  It counts buffer positions, and the
;; prompt is drawn by an overlay `before-string' over text hidden with
;; `display ""', so it legitimately stops short of `point-max' on a window
;; that is displaying the badge perfectly.  Reading it as "off screen" is
;; what made 01a0b2e2 look like mechanism B.  `pos-visible-in-window-p' is
;; the authoritative test and is what this records.
;;
;; A snapshot is taken at SEVERAL stages, not one.  A single snapshot
;; cannot distinguish "the lazy relabel had not landed yet" from "the
;; window was scrolled wrong", which are the two live hypotheses; a
;; sequence across the resume separates them by construction.

;;; Code:

(require 'seq)

(defvar decknix--agent-shell-init-finished)
(declare-function agent-shell--live-input-prompt-p "agent-shell" (prompt))

(defcustom decknix-agent-prompt-probe-file
  (locate-user-emacs-file "decknix-prompt-probe.log")
  "File the resume-time prompt snapshots are appended to."
  :type 'file
  :group 'decknix)

(defcustom decknix-agent-prompt-probe-enabled t
  "When non-nil, record prompt state during resume.
Diagnostic only.  Each snapshot is a handful of buffer and window reads
plus one line appended to `decknix-agent-prompt-probe-file'."
  :type 'boolean
  :group 'decknix)

(defconst decknix--agent-prompt-probe-marker "❯"
  "The input affordance glyph, present only on an UNSENT prompt label.")


;; --- pure formatting --------------------------------------------------

(defun decknix--agent-prompt-probe-format (snapshot)
  "Render SNAPSHOT, a plist, as one log line.

Kept pure and separate from measurement so the shape of the record is
unit-testable without a live shell, which is the whole point: every
previous attempt here was verified against state that turned out to be
the wrong state."
  (format (concat "%s stage=%s buf=%s point-max=%s me=%s span=%s "
                  "marker=%s init=%s prompt-live=%s wins=%s vis=%s%s")
          (or (plist-get snapshot :time) "-")
          (or (plist-get snapshot :stage) "-")
          (or (plist-get snapshot :buffer) "-")
          (or (plist-get snapshot :point-max) "-")
          (or (plist-get snapshot :overlay-count) "-")
          (if (plist-get snapshot :overlay-beg)
              (format "%s..%s" (plist-get snapshot :overlay-beg)
                      (plist-get snapshot :overlay-end))
            "none")
          (if (plist-get snapshot :marker-p) "yes" "NO")
          (if (plist-get snapshot :init-finished) "t" "nil")
          (if (plist-get snapshot :prompt-live) "t" "nil")
          (or (plist-get snapshot :window-count) "-")
          (if (plist-get snapshot :visible) "on-screen" "OFF-SCREEN")
          (mapconcat (lambda (w)
                       (format " [win start=%s end=%s point=%s]"
                               (plist-get w :start) (plist-get w :end)
                               (plist-get w :point)))
                     (plist-get snapshot :windows) "")))

(defun decknix--agent-prompt-probe-anomalous-p (snapshot)
  "Return non-nil when SNAPSHOT shows a prompt the user cannot act on.

Deliberately NOT keyed on `window-end' against `point-max'.  That
comparison reads as broken on a window that is rendering the badge
correctly, because the prompt text is hidden behind `display \"\"' and
drawn by an overlay `before-string', so position accounting stops short
of `point-max' by design.  It is what made 01a0b2e2 look like a window
fault for the first two probes.

A snapshot is anomalous when the label is absent or unmarked, or when a
window exists that does not actually show `point-max'.  No window at all
is mechanism C and counts."
  (let ((wins (plist-get snapshot :window-count)))
    (cond
     ((not (plist-get snapshot :overlay-beg)) 'no-label)
     ((not (plist-get snapshot :marker-p)) 'no-marker)
     ((or (null wins) (zerop wins)) 'no-window)
     ((not (plist-get snapshot :visible)) 'off-screen)
     (t nil))))


;; --- measurement (read-only) ------------------------------------------

(defun decknix--agent-prompt-probe-measure (buffer stage &optional time)
  "Return a snapshot plist for BUFFER tagged STAGE.
Reads only; never moves point, scrolls, or forces redisplay.  TIME is
supplied by the caller so the pure layer stays free of the clock."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((overlays (sort (seq-filter
                             (lambda (o) (eq (overlay-get o 'category)
                                             'agent-shell-chat-me))
                             (overlays-in (point-min) (point-max)))
                            (lambda (a b) (< (overlay-start a)
                                             (overlay-start b)))))
             (last (car (last overlays)))
             (before (and last (overlay-get last 'before-string)))
             (windows (get-buffer-window-list buffer nil t))
             (prompt (and (boundp 'comint-last-prompt) comint-last-prompt)))
        (list :time (or time "-")
              :stage stage
              :buffer (buffer-name buffer)
              :point-max (point-max)
              :overlay-count (length overlays)
              :overlay-beg (and last (overlay-start last))
              :overlay-end (and last (overlay-end last))
              :marker-p (and (stringp before)
                             (string-match-p
                              (regexp-quote decknix--agent-prompt-probe-marker)
                              before)
                             t)
              :init-finished (and (boundp 'decknix--agent-shell-init-finished)
                                  decknix--agent-shell-init-finished)
              :prompt-live (and prompt
                                (fboundp 'agent-shell--live-input-prompt-p)
                                (agent-shell--live-input-prompt-p prompt)
                                t)
              :window-count (length windows)
              ;; The authoritative visibility test.  See the commentary.
              :visible (and windows
                            (seq-some (lambda (w)
                                        (pos-visible-in-window-p
                                         (point-max) w t))
                                      windows)
                            t)
              :windows (mapcar (lambda (w)
                                 (list :start (window-start w)
                                       :end (window-end w nil)
                                       :point (window-point w)))
                               windows))))))

(defun decknix-agent-prompt-probe-record (buffer stage)
  "Append a snapshot of BUFFER at STAGE to the probe log."
  (when (and decknix-agent-prompt-probe-enabled (buffer-live-p buffer))
    (let ((snapshot (decknix--agent-prompt-probe-measure
                     buffer stage (format-time-string "%FT%T"))))
      (when snapshot
        (let ((anomaly (decknix--agent-prompt-probe-anomalous-p snapshot)))
          (write-region
           (concat (decknix--agent-prompt-probe-format snapshot)
                   (if anomaly (format " ANOMALY=%s" anomaly) "")
                   "\n")
           nil decknix-agent-prompt-probe-file 'append 'quiet))))))

(provide 'decknix-agent-prompt-probe)
;;; decknix-agent-prompt-probe.el ends here
