;;; decknix-support-workflow-test.el --- Tests for the support workflow -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-support-workflow "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT tests for the PURE layer of the guided support workflow: day-awareness,
;; word-wrap, single-activity formatting (checkbox state + row id property),
;; and the full render (phase ordering + legend).  No live buffers, no timers,
;; no network.

;;; Code:

(require 'ert)
(require 'decknix-support-workflow)

;; -- day awareness ------------------------------------------------------

(ert-deftest decknix-support-workflow/today-p-no-days-is-every-day ()
  "An activity with no `:days' applies on any weekday."
  (should (decknix--support-workflow-activity-today-p '(:id x) 0))
  (should (decknix--support-workflow-activity-today-p '(:id x) 3))
  (should (decknix--support-workflow-activity-today-p '(:id x) 6)))

(ert-deftest decknix-support-workflow/today-p-honours-days ()
  "Deployments (:days (2 4)) apply Tue/Thu, not Wed."
  (let ((dep '(:id deployments :days (2 4))))
    (should (decknix--support-workflow-activity-today-p dep 2))     ; Tue
    (should (decknix--support-workflow-activity-today-p dep 4))     ; Thu
    (should-not (decknix--support-workflow-activity-today-p dep 3)) ; Wed
    (should-not (decknix--support-workflow-activity-today-p dep 0)))) ; Sun

;; -- word wrap ----------------------------------------------------------

(ert-deftest decknix-support-workflow/wrap-prefixes-and-breaks ()
  "Wrap prefixes every line and never exceeds width by a whole word."
  (let* ((text "one two three four five six seven eight nine ten")
         (out (decknix--support-workflow-wrap text "  " 15))
         (lines (split-string out "\n")))
    (should (> (length lines) 1))
    (should (seq-every-p (lambda (l) (string-prefix-p "  " l)) lines))
    ;; each line's content (minus prefix) fits the width
    (should (seq-every-p (lambda (l) (<= (length l) (+ 2 15 8))) lines))))

(ert-deftest decknix-support-workflow/wrap-empty-is-empty ()
  "Wrapping empty/nil text yields an empty string, never an error."
  (should (equal "" (decknix--support-workflow-wrap "" "  " 20)))
  (should (equal "" (decknix--support-workflow-wrap nil "  " 20))))

;; -- format-activity ----------------------------------------------------

(ert-deftest decknix-support-workflow/format-carries-id-property ()
  "A formatted activity row carries its id as `decknix-workflow-id'."
  (let ((row (decknix--support-workflow-format-activity
              '(:id build-health :phase daily :title "Build Health"
                :when "daily" :how "do it" :action ignore)
              1 nil)))
    (should (eq 'build-health (get-text-property 0 'decknix-workflow-id row)))
    (should (string-match-p "Build Health" row))
    (should (string-match-p "\\[ \\]" row))))          ; unchecked

(ert-deftest decknix-support-workflow/format-checkbox-states ()
  "Done shows [x]; a not-today scheduled item shows [-] and the marker."
  (let ((done (decknix--support-workflow-format-activity
               '(:id a :phase daily :title "T" :when "daily" :how "h") 1 t))
        (not-today (decknix--support-workflow-format-activity
                    '(:id deployments :phase scheduled :title "Deploy"
                      :when "Tue & Thu" :how "h" :days (2 4))
                    3 nil)))                            ; Wed
    (should (string-match-p "\\[x\\]" done))
    (should (string-match-p "\\[-\\]" not-today))
    (should (string-match-p "not today" not-today))))

(ert-deftest decknix-support-workflow/format-action-hint ()
  "Items with an action advertise RET; those without omit it."
  (let ((with-a (decknix--support-workflow-format-activity
                 '(:id a :phase work :title "T" :when "x" :how "h" :action ignore)
                 1 nil))
        (without (decknix--support-workflow-format-activity
                  '(:id b :phase work :title "T" :when "x" :how "h") 1 nil)))
    (should (string-match-p "RET: run" with-a))
    (should-not (string-match-p "RET: run" without))))

;; -- render -------------------------------------------------------------

(ert-deftest decknix-support-workflow/render-orders-phases ()
  "Phases render incident -> daily -> scheduled -> work, in that order."
  (let* ((acts '((:id i :phase incident :title "Inc" :when "x" :how "h")
                 (:id d :phase daily :title "Daily" :when "x" :how "h")
                 (:id s :phase scheduled :title "Sched" :when "x" :how "h")
                 (:id w :phase work :title "Work" :when "x" :how "h")))
         (text (decknix--support-workflow-render acts 1 nil))
         (pi (string-match "Incidents" text))
         (pd (string-match "Daily Checks" text))
         (ps (string-match "Scheduled" text))
         (pw (string-match "Work Items" text)))
    (should (and pi pd ps pw))
    (should (< pi pd)) (should (< pd ps)) (should (< ps pw))))

(ert-deftest decknix-support-workflow/render-has-legend-and-keys ()
  "The render carries the checkbox legend and the key hints."
  (let ((text (decknix--support-workflow-render
               '((:id a :phase daily :title "T" :when "x" :how "h")) 1 nil)))
    (should (string-match-p "Legend:" text))
    (should (string-match-p "\\[x\\] done" text))
    (should (string-match-p "? menu" text))))

(ert-deftest decknix-support-workflow/render-marks-done ()
  "An id in DONE-IDS renders that activity checked."
  (let ((text (decknix--support-workflow-render
               '((:id alerts :phase work :title "Alerts" :when "x" :how "h"))
               1 '(alerts))))
    (should (string-match-p "\\[x\\] Alerts" text))))

;; -- shipped activity list is well-formed -------------------------------

(ert-deftest decknix-support-workflow/default-activities-render ()
  "The shipped default work order renders without error and covers phases."
  (let ((text (decknix--support-workflow-render
               decknix-support-workflow-activities 2 nil)))  ; Tuesday
    (should (string-match-p "Build Health" text))
    (should (string-match-p "Alerts" text))
    (should (string-match-p "Deployments" text))
    ;; Every activity has an id, phase, title, when and how.
    (should (seq-every-p
             (lambda (a) (and (plist-get a :id) (plist-get a :phase)
                              (plist-get a :title) (plist-get a :when)
                              (plist-get a :how)))
             decknix-support-workflow-activities))))

(provide 'decknix-support-workflow-test)
;;; decknix-support-workflow-test.el ends here
