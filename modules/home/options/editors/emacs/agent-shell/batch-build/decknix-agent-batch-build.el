;;; decknix-agent-batch-build.el --- Batch spec -> Command/Tags/Workspace -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (cl-lib "1.0"))
;; Keywords: agent, agent-shell, decknix, batch

;;; Commentary:
;;
;; Pure builders for the batch-launch pipeline (PR B.82).
;; Carved out of `decknix--batch-launch' and
;; `decknix--batch-show-summary' so the spec -> command,
;; spec -> tags, spec -> workspace, and results -> summary-rows
;; transforms can be exercised without launching live sessions.
;;
;; Public surface (four pure functions):
;;
;;   (decknix--batch-build-command GROUPED ITEMS)
;;     -> "/review-service-pr <url>"           ; ungrouped: just car
;;      | "/review-service-pr a\n/.../ b"      ; grouped: newline-joined
;;
;;   (decknix--batch-build-tags ITEMS PARSER-FN)
;;     -> ("review" REPO ... "#NUMBER" ...)
;;     PARSER-FN is invoked as `(funcall PARSER-FN ITEM)' and is
;;     expected to return either nil or an alist with `repo' and
;;     `number' keys (matching `decknix--agent-parse-pr-url').
;;
;;   (decknix--batch-resolve-workspace SPEC ITEMS DEFAULT-WS
;;                                      PARSER-FN DETECTOR-FN)
;;     -> workspace string.  When SPEC's workspace differs from
;;        DEFAULT-WS or SPEC is ungrouped, the spec's value wins;
;;        otherwise we walk ITEMS calling PARSER-FN + DETECTOR-FN
;;        until we find a workspace.  Falls back to the spec's
;;        value when nothing detects.
;;     PARSER-FN: `(item) -> alist | nil'
;;     DETECTOR-FN: `(owner repo) -> workspace | nil'
;;
;;   (decknix--batch-summary-rows RESULTS)
;;     -> list of plists `(:icon ICON :name NAME :status STATUS :err ERR)'
;;     describing each row in the *Batch Launch* summary buffer.
;;     Pure transformation; the renderer in main-bulk applies
;;     faces and inserts.
;;
;; Per AGENTS.md Rule 2 the actual `decknix--agent-quickaction-start'
;; invocations, the `condition-case' result accumulation, and the
;; `*Batch Launch*' buffer rendering stay in main-bulk.

;;; Code:

(require 'cl-lib)

(declare-function decknix--agent-review-get-params "decknix-agent-shell-main-link")

(defun decknix--batch-build-command (grouped items)
  "Build the `/review-service-pr' command string for ITEMS.
Aware of bot authors via `decknix--agent-review-get-params'.

When GROUPED is non-nil, every item gets its own
`/review-service-pr <url>' line, joined with newlines so the
agent receives them as a single multi-line message.
Otherwise the function returns the command for `(car ITEMS)'
only -- the ungrouped path that produces one session per item
upstream.

ITEMS must be a non-empty list of strings (URLs typically); the
function does not validate.  The 200 200-character spec keeps
this strictly textual."
  (if grouped
      (mapconcat (lambda (item)
                   (let ((params (decknix--agent-review-get-params item)))
                     (format "%s %s" (cadr params) item)))
                 items "\n")
    (let ((params (decknix--agent-review-get-params (car items))))
      (format "%s %s" (cadr params) (car items)))))

(defun decknix--batch-build-tags (items parser-fn)
  "Return the tag list derived from ITEMS using PARSER-FN.

Always starts with the `\"review\"' tag, then walks each item
through PARSER-FN.  When PARSER-FN returns a non-nil alist with
`repo' and `number' keys, both are added to the tag list with
`cl-pushnew' so duplicates collapse (one repo + one PR number per
distinct value).  PARSER-FN is typically
`decknix--agent-parse-pr-url'.

The returned list preserves insertion order (latest-added at the
front) -- callers that want display order should reverse it."
  (let ((tag-list (list "review")))
    (dolist (item items)
      (let ((parsed (funcall parser-fn item)))
        (when parsed
          (cl-pushnew (alist-get 'repo parsed)
                      tag-list :test #'string=)
          (cl-pushnew (format "#%s" (alist-get 'number parsed))
                      tag-list :test #'string=))))
    tag-list))

(defun decknix--batch-resolve-workspace (spec items default-ws
                                              parser-fn detector-fn)
  "Resolve the workspace for SPEC, auto-detecting from ITEMS if needed.

SPEC is the batch-spec alist; PARSER-FN / DETECTOR-FN are the
per-item URL parser and the (owner, repo) -> workspace lookup
respectively (see header).  DEFAULT-WS is the value the parser
falls back to when no explicit `--- group: WS' header is given;
auto-detection only runs for grouped specs whose workspace still
matches DEFAULT-WS (an explicit per-group workspace always wins).

Walks ITEMS through `cl-some' -- the first PARSER-FN result that
has a non-nil DETECTOR-FN match returns that workspace.  Falls
back to the spec's own workspace when nothing detects."
  (let ((ws (alist-get 'workspace spec))
        (grouped (alist-get 'grouped spec)))
    (if (and grouped
             (string= ws default-ws))
        (or (cl-some
             (lambda (item)
               (let ((parsed (funcall parser-fn item)))
                 (when parsed
                   (funcall detector-fn
                            (alist-get 'owner parsed)
                            (alist-get 'repo parsed)))))
             items)
            ws)
      ws)))

(defun decknix--batch-summary-rows (results)
  "Return the per-row plist list to render in the *Batch Launch* buffer.

RESULTS is the launched-results list of `(NAME STATUS ERR)'
triples accumulated by the bulk caller.  Each row becomes a plist:

  (:icon \"\u2713 \" :name NAME :status STATUS :err nil)        ; launched
  (:icon \"\u2717 \" :name NAME :status STATUS :err ERR-STRING)  ; failed

The renderer in main-bulk applies `success' / `error' faces to
:icon and inserts the row.  Keeping the icon choice here lets
the test suite verify the success/failure mapping without
spinning up a font-locked buffer."
  (mapcar
   (lambda (r)
     (let ((name (nth 0 r))
           (status (nth 1 r))
           (err (nth 2 r)))
       (list :icon (if (string= status "launched") "\u2713 " "\u2717 ")
             :name name
             :status status
             :err err)))
   results))

(provide 'decknix-agent-batch-build)
;;; decknix-agent-batch-build.el ends here
