;;; decknix-agent-prompt-probe-test.el --- Tests for the prompt probe -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The pure layers only, per AGENTS.md Rule 2: the record shape and the
;; anomaly rule.  Both exist because the anomaly rule is where the last
;; four diagnoses went wrong, so it is the part that must not be verified
;; by eye on a live session.

;;; Code:

(require 'ert)
(require 'decknix-agent-prompt-probe)

(defconst decknix-probe-test--healthy
  '(:time "2026-09-24T11:30:00" :stage "init" :buffer "*Pi: pilot/us*"
    :point-max 484055 :overlay-count 4 :overlay-beg 484050 :overlay-end 484055
    :marker-p t :init-finished t :prompt-live t :window-count 1 :visible t
    :windows ((:start 483843 :end 484021 :point 484055)))
  "Session 01a0b2e2 as actually measured: correct, despite end < point-max.")

;; --- the anomaly rule -------------------------------------------------

(ert-deftest decknix-probe-anomaly--window-end-short-of-point-max-is-healthy ()
  "The 01a0b2e2 shape is NOT an anomaly.

    window-end 484021   point-max 484055

looks like the prompt is off screen and is not.  The prompt's own text is
hidden behind `display \"\"' and drawn by the overlay `before-string', so
buffer-position accounting stops short of `point-max' on a window that is
rendering the badge perfectly.  `pos-visible-in-window-p' returned
(0 154) for exactly this window.

Reading `window-end' as evidence is what produced two wrong diagnoses in
a row, so it is pinned here as a passing case."
  (should-not (decknix--agent-prompt-probe-anomalous-p
               decknix-probe-test--healthy)))

(ert-deftest decknix-probe-anomaly--missing-label ()
  "No chat-me overlay at all: nothing for the user to type at."
  (should (eq 'no-label
              (decknix--agent-prompt-probe-anomalous-p
               (plist-put (copy-sequence decknix-probe-test--healthy)
                          :overlay-beg nil)))))

(ert-deftest decknix-probe-anomaly--label-without-the-marker ()
  "A label lacking `❯' is a SENT turn, not a live prompt.
This is the shape the suppressor used to leave behind after blanking the
first submitted turn."
  (should (eq 'no-marker
              (decknix--agent-prompt-probe-anomalous-p
               (plist-put (copy-sequence decknix-probe-test--healthy)
                          :marker-p nil)))))

(ert-deftest decknix-probe-anomaly--no-window-is-mechanism-c ()
  "Eleven of thirteen sessions had no live window after the 2026-09-24 switch."
  (should (eq 'no-window
              (decknix--agent-prompt-probe-anomalous-p
               (plist-put (plist-put (copy-sequence decknix-probe-test--healthy)
                                     :window-count 0)
                          :windows nil)))))

(ert-deftest decknix-probe-anomaly--off-screen-beats-visible ()
  "A window that exists but does not show `point-max' is mechanism B."
  (should (eq 'off-screen
              (decknix--agent-prompt-probe-anomalous-p
               (plist-put (copy-sequence decknix-probe-test--healthy)
                          :visible nil)))))

(ert-deftest decknix-probe-anomaly--label-check-precedes-window-check ()
  "A missing label is reported even when the window is also wrong.
The label is the thing the user asked about; ordering keeps the log
naming a cause rather than a symptom."
  (should (eq 'no-label
              (decknix--agent-prompt-probe-anomalous-p
               (plist-put (plist-put (copy-sequence decknix-probe-test--healthy)
                                     :overlay-beg nil)
                          :visible nil)))))

;; --- the record shape -------------------------------------------------

(ert-deftest decknix-probe-format--carries-the-decisive-fields ()
  "A line names the stage, the marker, visibility and window geometry."
  (let ((line (decknix--agent-prompt-probe-format
               decknix-probe-test--healthy)))
    (should (string-match-p "stage=init" line))
    (should (string-match-p "marker=yes" line))
    (should (string-match-p "on-screen" line))
    (should (string-match-p "span=484050\\.\\.484055" line))
    (should (string-match-p "win start=483843 end=484021 point=484055" line))))

(ert-deftest decknix-probe-format--flags-a-missing-marker-loudly ()
  "The absent cases are upper-cased so a scan of the log finds them."
  (let ((line (decknix--agent-prompt-probe-format
               (plist-put (copy-sequence decknix-probe-test--healthy)
                          :marker-p nil))))
    (should (string-match-p "marker=NO" line))))

(ert-deftest decknix-probe-format--survives-a-sparse-snapshot ()
  "Missing fields render as placeholders rather than signalling.
The probe runs on a resume path; it must never be the thing that breaks
one."
  (should (stringp (decknix--agent-prompt-probe-format nil)))
  (should (stringp (decknix--agent-prompt-probe-format '(:stage "init")))))

(ert-deftest decknix-probe-format--no-label-renders-as-none ()
  "An absent span is explicit, not an empty gap."
  (should (string-match-p
           "span=none"
           (decknix--agent-prompt-probe-format
            (plist-put (copy-sequence decknix-probe-test--healthy)
                       :overlay-beg nil)))))

;; --- measurement is read-only ----------------------------------------

(ert-deftest decknix-probe-measure--does-not-move-point ()
  "Measuring must not disturb the buffer it is measuring.
A diagnostic that scrolls or moves point would inflict the very fault it
is here to observe."
  (with-temp-buffer
    (insert "Where are we up to?\n\nPi> ")
    (goto-char 5)
    (let ((before (point)))
      (decknix--agent-prompt-probe-measure (current-buffer) "test")
      (should (= before (point))))))

(ert-deftest decknix-probe-measure--reports-a-markerless-last-overlay ()
  "The sent-turn shape is measured as marker-p nil."
  (with-temp-buffer
    (insert "Where are we up to?")
    (let ((o (make-overlay 1 (point-max))))
      (overlay-put o 'category 'agent-shell-chat-me)
      (overlay-put o 'before-string "\n Me \n\n")
      (let ((snap (decknix--agent-prompt-probe-measure (current-buffer) "test")))
        (should (= 1 (plist-get snap :overlay-count)))
        (should-not (plist-get snap :marker-p))))))

(ert-deftest decknix-probe-measure--picks-the-last-overlay ()
  "With history present the LAST chat-me overlay is the candidate prompt."
  (with-temp-buffer
    (insert "aaaa bbbb cccc")
    (let ((old (make-overlay 1 5))
          (new (make-overlay 11 15)))
      (dolist (o (list old new))
        (overlay-put o 'category 'agent-shell-chat-me))
      (overlay-put old 'before-string "\n Me \n\n")
      (overlay-put new 'before-string "\n Me \n\n  ❯ ")
      (let ((snap (decknix--agent-prompt-probe-measure (current-buffer) "test")))
        (should (= 11 (plist-get snap :overlay-beg)))
        (should (plist-get snap :marker-p))))))

(ert-deftest decknix-probe-measure--tolerates-a-dead-buffer ()
  "A killed buffer yields nil rather than signalling on the resume path."
  (let ((b (generate-new-buffer "probe-dead")))
    (kill-buffer b)
    (should-not (decknix--agent-prompt-probe-measure b "test"))))

;; --- resume sampling schedule ----------------------------------------

(ert-deftest decknix-probe-resume--passes-state-as-timer-arguments ()
  "Delayed samples must not depend on a dynamic-binding closure.
`default.el' is dynamically bound, so a timer lambda referring to the
surrounding `shell-buf' and `delay' variables signals `void-variable' after
that surrounding call returns.  Passing both values as explicit timer
arguments keeps the callback valid in every binding mode."
  (let ((buf (generate-new-buffer "probe-schedule"))
        recorded scheduled)
    (unwind-protect
        (cl-letf (((symbol-function 'decknix-agent-prompt-probe-record)
                   (lambda (buffer stage)
                     (push (list buffer stage) recorded)))
                  ((symbol-function 'run-at-time)
                   (lambda (delay repeat function &rest args)
                     (push (append (list delay repeat function) args) scheduled))))
          (decknix--agent-prompt-probe-resume buf)
          (should (equal (nreverse recorded) (list (list buf "resume"))))
          (should
           (equal (nreverse scheduled)
                  (list
                   (list 2 nil #'decknix--agent-prompt-probe-delayed-sample buf 2)
                   (list 6 nil #'decknix--agent-prompt-probe-delayed-sample buf 6)
                   (list 15 nil #'decknix--agent-prompt-probe-delayed-sample buf 15)))))
      (kill-buffer buf))))

(provide 'decknix-agent-prompt-probe-test)
;;; decknix-agent-prompt-probe-test.el ends here
