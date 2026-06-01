;;; decknix-hub-file-event.el --- Hub file-notify event filename helper -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, hub, filenotify

;;; Commentary:
;;
;; Pure helper that extracts the effective filename from a `file-notify'
;; event for the hub directory watcher.
;;
;; The decknix-hub daemon writes JSON files atomically: it writes to a
;; sibling `*.tmp' file and then renames it onto the canonical name.
;; On macOS / kqueue the `renamed' action fires with the `.tmp' name in
;; the source slot (`(nth 2 event)') and the final name in the target
;; slot (`(nth 3 event)').  The original handler only inspected the
;; source slot, so atomic writes never matched the known JSON names and
;; the sidebar silently missed every hub update — merged PRs lingered
;; in WIP until the next manual refresh.
;;
;; This helper normalises the event by preferring the target filename
;; when present and stripping a trailing `.tmp' suffix from whichever
;; name it returns, so the caller can `pcase' on the canonical JSON
;; filename regardless of which kqueue backend the OS exposes.
;;
;; The module is intentionally tiny and side-effect-free so the
;; rename-event contract can be tested in isolation against the
;; bulk-extracted hub module.

;;; Code:

(require 'cl-lib)

(defun decknix--hub-event-filename (event)
  "Return the canonical filename for hub file-notify EVENT, or nil.

EVENT has the shape `(DESCRIPTOR ACTION FILE [FILE1])'.  For `renamed'
actions the source `FILE' carries the `.tmp' name used during atomic
writes and the target `FILE1' carries the final name.  For `created' /
`changed' / `deleted' actions only `FILE' is populated.

Resolution rules (in order):
  1. If `FILE1' is a non-empty string, use it (target wins on rename).
  2. Otherwise fall back to `FILE'.
  3. Strip a trailing `.tmp' suffix so half-states (a `created' event
     on the tmp sibling that races ahead of the rename) still resolve
     to the canonical name.
  4. Return the basename, or nil if no usable name was present."
  (let* ((src    (nth 2 event))
         (target (nth 3 event))
         (raw    (cond ((and (stringp target) (> (length target) 0)) target)
                       ((stringp src) src)
                       (t nil))))
    (when raw
      (let ((name (file-name-nondirectory raw)))
        (if (string-suffix-p ".tmp" name)
            (substring name 0 (- (length name) 4))
          name)))))

(provide 'decknix-hub-file-event)

;;; decknix-hub-file-event.el ends here
