;;; decknix-agent-purposes.el --- Per-purpose (provider, model) resolver -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, agent-shell, decknix

;;; Commentary:
;;
;; Small pure resolver + boot-time validator for the per-purpose
;; agent-provider / model settings.  The Nix layer
;; (`programs.emacs.decknix.agentShell.purposes.<name>.{provider,model}')
;; populates `decknix-agent-purpose-alist' via a `setq' in the heredoc;
;; this module exposes:
;;
;;   `decknix-agent-purpose-resolve'  -> alist-get returning a
;;                                       plist `(:provider PROV :model MODEL)'.
;;   `decknix-agent-purpose-validate' -> boot-time sanity check that
;;                                       warns and coerces unknown
;;                                       providers and drops unknown
;;                                       models to nil (falling back to
;;                                       the provider default).
;;
;; Purpose IDs today:
;;   `pr-review'     - human-authored PR review sessions.
;;   `bot-pr-review' - bot-authored PR review sessions.
;;
;; Everything else keeps the interactive/default behaviour -- the
;; worktree `w s' path, `C-c A n', and the fork path all fall through
;; to `decknix-agent-default-provider' with no model pin.

;;; Code:

(require 'cl-lib)

;; External symbols resolved at runtime.  Value-less `defvar' marks
;; these special so byte-compiled reads bind lazily against the live
;; heredoc-populated values.
(declare-function decknix-agent-get-provider "decknix-agent-provider")
(defvar decknix-agent-default-provider)

(defvar decknix-agent-purpose-alist
  '((pr-review     . (:provider auggie :model "prism-a"))
    (bot-pr-review . (:provider auggie :model "haiku4.5")))
  "Per-purpose (provider, model) settings.
Alist of PURPOSE-SYMBOL -> plist `(:provider PROVIDER-SYM :model
MODEL-STR)'.  PROVIDER must be a registered provider id (see
`decknix-agent-provider-registry').  MODEL is a provider-specific
model string, or nil to defer to the provider's default.

Populated at boot from Nix via
`programs.emacs.decknix.agentShell.purposes.<name>.{provider,model}';
consult via `decknix-agent-purpose-resolve'.")

(defvar decknix-agent-known-models
  '((auggie      . ("prism-a" "opus4.7" "sonnet4.6" "haiku4.5"))
    (claude-code . ("sonnet" "opus" "haiku"))
    (pi          . nil))
  "Alist of PROVIDER-SYMBOL -> known model-id strings.
When `decknix-agent-purpose-validate' encounters a MODEL not on
the provider's known-list, it warns and drops MODEL to nil.  A
nil value here means \"any model accepted\" (no validation).
Extend by `setq'ing the entry when a new provider ships.")

(defun decknix-agent-purpose-resolve (purpose)
  "Return plist `(:provider PROVIDER :model MODEL)' for PURPOSE.
An unknown PURPOSE resolves to `decknix-agent-default-provider'
with no model pin, so callers can always safely destructure the
result without a nil-guard."
  (or (alist-get purpose decknix-agent-purpose-alist)
      (list :provider (and (boundp 'decknix-agent-default-provider)
                           decknix-agent-default-provider)
            :model    nil)))

(defun decknix-agent-purpose--valid-provider-p (sym)
  "Return non-nil when SYM is a registered agent provider id."
  (and (symbolp sym)
       (fboundp 'decknix-agent-get-provider)
       (decknix-agent-get-provider sym)))

(defun decknix-agent-purpose--known-model-p (provider model)
  "Return non-nil when MODEL is on PROVIDER's known-model list.
Also returns non-nil when the list is nil (\"any model accepted\")
or when PROVIDER has no entry (unknown provider defers judgement)."
  (let* ((entry (assq provider decknix-agent-known-models))
         (known (cdr entry)))
    (cond
     ((not entry) t)
     ((null known) t)
     (t (and (stringp model) (member model known))))))

(defun decknix-agent-purpose--coerce-entry (entry)
  "Return ENTRY with its provider/model coerced to a valid pair.
Warns and swaps in `decknix-agent-default-provider' when the
provider is not registered; warns and drops MODEL to nil when it
is not on the provider's known-model list."
  (let* ((purpose (car entry))
         (cfg (cdr entry))
         (provider (plist-get cfg :provider))
         (model    (plist-get cfg :model)))
    (unless (decknix-agent-purpose--valid-provider-p provider)
      (warn "[decknix-agent-purpose] %s provider %S is not registered; \
coercing to %S"
            purpose provider decknix-agent-default-provider)
      (setq provider decknix-agent-default-provider))
    (when (and (stringp model)
               (not (string-empty-p model))
               (not (decknix-agent-purpose--known-model-p provider model)))
      (warn "[decknix-agent-purpose] %s model %S is not known for \
provider %S; dropping to nil (provider default will be used)"
            purpose model provider)
      (setq model nil))
    (cons purpose (list :provider provider :model model))))

(defun decknix-agent-purpose-validate ()
  "Coerce every entry in `decknix-agent-purpose-alist' to a valid pair.
Called from the heredoc after the Nix-emitted setq block so any
mis-configuration surfaces once at daemon start rather than at
launch time."
  (setq decknix-agent-purpose-alist
        (mapcar #'decknix-agent-purpose--coerce-entry
                decknix-agent-purpose-alist)))

(provide 'decknix-agent-purposes)
;;; decknix-agent-purposes.el ends here
