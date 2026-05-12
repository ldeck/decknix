;;; decknix-agent-post-create.el --- Session post-create decision -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix, session

;;; Commentary:
;;
;; Pure decision helpers for `decknix--agent-session-new-post-create'
;; (PR B.83).  Carved so the immediate-vs-deferred metadata-flush
;; policy and the buffer-name formatter can be exercised without
;; calling `agent-shell-start' or touching live buffers.
;;
;; Public surface (one decision + one formatter):
;;
;;   (decknix--post-create-flush-mode CONV-KEY TAGS WORKSPACE)
;;     -> 'immediate              ; conv-key known + metadata to store
;;      | 'deferred-with-metadata ; no conv-key but tags/ws to stash
;;      | 'deferred-no-metadata   ; no conv-key, nothing to stash
;;
;;     The bulk caller maps these to:
;;       immediate              -> store-metadata + setq-local buffer-locals
;;       deferred-with-metadata -> stash pending-tags / pending-ws +
;;                                 install comint input-filter hook
;;       deferred-no-metadata   -> only the prompt-ready subscription
;;
;;   (decknix--post-create-buffer-name NAME)
;;     -> "*Auggie: NAME*"
;;     The single source of truth for the rename target.  Used by
;;     bulk's `generate-new-buffer-name' wrapper.
;;
;; Per AGENTS.md Rule 2 the `rename-buffer', `setq-local',
;; `decknix--agent-store-metadata-by-conv-key',
;; `add-hook 'comint-input-filter-functions',
;; `agent-shell-subscribe-to', and the ring-extraction logic stay
;; in main-bulk; this module only encodes the two domain rules:
;;
;;   "given (conv-key, tags, workspace) what's our flush strategy?"
;;   "what's the canonical buffer name for a session named NAME?"

;;; Code:

(defconst decknix--post-create-buffer-name-prefix "*Auggie: "
  "Prefix used for the post-create buffer-name template.
Pinned here so the formatter and bulk-caller `rename-buffer'
target read from one source.")

(defconst decknix--post-create-buffer-name-suffix "*"
  "Suffix used for the post-create buffer-name template.")

(defun decknix--post-create-flush-mode (conv-key tags workspace)
  "Return the metadata-flush strategy for a freshly-created session.

CONV-KEY is the SHA-derived conversation key when known (typically
because we have FIRST-MESSAGE for a quickaction), or nil for
guided-flow sessions where the user hasn't typed yet.  TAGS and
WORKSPACE are the metadata captured at session creation; either
or both may be nil.

Strategy table:

  conv-key | tags-or-ws? | strategy
  ---------+-------------+-----------------------
  set      |     t       | immediate
  set      |    nil      | immediate (store-metadata may be a
                            no-op upstream but the conv-key
                            handoff still happens)
  nil      |     t       | deferred-with-metadata
  nil      |    nil      | deferred-no-metadata

The `immediate' branch lets bulk store metadata under CONV-KEY
right now and stash CONV-KEY buffer-locally so the header-line
can render tags without waiting for the session-list cache.
`deferred-with-metadata' installs the comint input-filter hook;
`deferred-no-metadata' only wires the prompt-ready safety-net
subscription."
  (cond
   (conv-key 'immediate)
   ((or tags workspace) 'deferred-with-metadata)
   (t 'deferred-no-metadata)))

(defun decknix--post-create-buffer-name (name)
  "Return the canonical agent-shell buffer name for NAME.

Returns \"*Auggie: NAME*\".  Bulk wraps the result in
`generate-new-buffer-name' so concurrent batch launches with the
same NAME still get unique buffers."
  (concat decknix--post-create-buffer-name-prefix
          name
          decknix--post-create-buffer-name-suffix))

(provide 'decknix-agent-post-create)
;;; decknix-agent-post-create.el ends here
