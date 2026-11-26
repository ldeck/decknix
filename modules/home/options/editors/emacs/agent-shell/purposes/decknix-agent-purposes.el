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
  '((pr-review     . (:provider auggie :model "prism-a" :mode nil))
    (ops-pr-review . (:provider claude-code :model "claude-sonnet-5-5" :mode "auto"))
    (bot-pr-review . (:provider auggie :model "haiku4.5" :mode nil))
    (new-session   . (:provider claude-code :model nil :mode nil)))
  "Per-purpose (provider, model, mode) settings.
Alist of PURPOSE-SYMBOL -> plist `(:provider PROVIDER-SYM :model
MODEL-STR :mode MODE-STR)'.  PROVIDER must be a registered provider id
\(see `decknix-agent-provider-registry').  MODEL is a provider-specific
model string, or nil to defer to the provider's default.  MODE is a
provider session/permission mode id (see `decknix-agent-known-modes';
Claude: \"default\"/\"auto\"/\"acceptEdits\"/\"bypassPermissions\"/
\"plan\"), or nil to leave the provider's own default in place.

`new-session' seeds interactive/QUICK `C-c A n' sessions; the three
`*-review' purposes seed the auto-review quickaction path (`pr-review'
for service code PRs, `ops-pr-review' for K8s GitOps / Helm manifest PRs,
`bot-pr-review' for dependency bot PRs).

Populated at boot from Nix via
`programs.emacs.decknix.agentShell.purposes.<name>.{provider,model,mode}';
consult via `decknix-agent-purpose-resolve'.")

(defvar decknix-agent-engine-alist
  '((flagship    . (:provider claude-code :model "claude-opus-5-5" :mode "bypassPermissions"
                    :aliases ("v12" "opus" "heavy")))
    (fable       . (:provider claude-code :model "claude-fable-5-2" :mode "bypassPermissions"
                    :aliases ("v10" "fable-5-2")))
    (workhorse   . (:provider claude-code :model "claude-sonnet-5-5" :mode "bypassPermissions"
                    :aliases ("v8" "sonnet" "standard")))
    (fast        . (:provider claude-code :model "claude-haiku-5-5" :mode "bypassPermissions"
                    :aliases ("v6" "haiku" "light")))
    (vertex      . (:provider pi :model "google-vertex/gemini-4-argon:high" :mode nil
                    :aliases ("v12-vertex" "argon")))
    (vertex-fast . (:provider pi :model "google-vertex/gemini-4-neon" :mode nil
                    :aliases ("v6-vertex" "neon")))
    (utility     . (:provider pi :model "google-vertex/gemini-3.8-flash" :mode nil
                    :aliases ("v4" "flash")))
    (codex       . (:provider pi :model "openai-codex/gpt-6.2-sol" :mode nil
                    :aliases ("v10-codex" "gpt")))
    (codex-fast  . (:provider pi :model "openai-codex/gpt-6.2-astra" :mode nil
                    :aliases ("v6-codex" "astra")))
    (local       . (:provider pi :model "llama.cpp/qwen3-coder-30b-a3b" :mode nil
                    :aliases ("v0" "zero-token" "llama"))))
  "Named engine rooms mapping a capability/cost tier to (provider, model, mode).
Used by `decknix session spawn --engine <tier>', `decknix session send
--engine <tier>', and `decknix-agent-engine-resolve'.")

(defvar decknix-agent-known-models
  '((auggie      . ("prism-a" "opus4.7" "sonnet4.6" "haiku4.5"))
    (claude-code . ("default" "sonnet" "opus" "haiku" "opus[1m]"))
    (pi          . nil)
    (gemini      . nil)
    (antigravity . nil)
    (codex       . nil)
    (opencode    . nil)
    (goose       . nil)
    (qwen-code   . nil))
  "Alist of PROVIDER-SYMBOL -> known model-id strings.
When `decknix-agent-purpose-validate' encounters a MODEL not on
the provider's known-list, it warns and drops MODEL to nil.  A
nil value here means \"any model accepted\" (no validation).
Extend by `setq'ing the entry when a new provider ships.")

(defvar decknix-agent-known-model-patterns
  '((claude-code . ("\\`claude-\\(opus\\|sonnet\\|haiku\\|fable\\)-[0-9]+\\(-[a-z0-9]+\\)*\\'")))
  "Alist of PROVIDER-SYMBOL -> regexps matching valid model ids.
Checked by `decknix-agent-purpose--known-model-p' when MODEL is not on
the provider's `decknix-agent-known-models' list.

A pattern exists because an enumerated list cannot track a policy of
PINNING VERSIONS.  decknix-config pins a specific Claude version
deliberately (`claudePinnedModel'), never a floating alias, so that a
session cannot drift onto a new flagship mid-conversation.  The
enumerated list held only the aliases -- \"sonnet\", \"opus\", \"haiku\"
-- so validation dropped every pinned version to nil:

    [decknix-agent-purpose] pr-review model \"claude-opus-4-8\" is not
    known for provider claude-code; dropping to nil

and review sessions then ran on the provider default.  The pin looked
configured and was inert, which is the drift it was written to prevent
arriving by another route.

Enumerating the versions instead would break again on the next bump, and
silently, in exactly this way.  The pattern is deliberately narrow enough
to still reject a typo (\"opus-4-8\", \"claud-opus-5\") and another
vendor's id, which is what the validation is for.")

(defvar decknix-agent-known-modes
  '((claude-code . ("default" "auto" "acceptEdits" "bypassPermissions" "plan")))
  "Alist of PROVIDER-SYMBOL -> known session/permission mode-id strings.
Only providers whose agent-config declares a `:default-session-mode-id'
honour a preset mode; today that is `claude-code' (auggie, pi and gemini
have no entry, so any mode is dropped to nil for them at boot).  When
`decknix-agent-purpose-validate' encounters a MODE not on the provider's
list, it warns and drops MODE to nil (the provider default stays).
A nil/absent entry means \"provider has no session modes\": a non-nil
MODE for it is dropped.")

(defvar decknix-agent-purpose-quota-fallback-enable nil
  "When non-nil, step down or fail over Claude models when weekly quota is high.
Reads `decknix-agent-purpose-quota-file' (`token-quotas.json').")

(defvar decknix-agent-purpose-quota-file
  (expand-file-name "~/.config/decknix/hub/token-quotas.json")
  "Path to `token-quotas.json' written by `decknix-hub'.")

(defvar decknix-agent-purpose-opus-soft-cap-percent 80.0
  "Weekly Claude usage percent at or above which Opus steps down to Sonnet.")

(defvar decknix-agent-purpose--quota-cache nil
  "(MTIME . ALIST) cached from `decknix-agent-purpose-quota-file'.")

(defun decknix-agent-purpose--claude-quota-state ()
  "Return (:limit-reached BOOL :week-percent NUM) from `token-quotas.json', or nil."
  (when (and decknix-agent-purpose-quota-file
             (stringp decknix-agent-purpose-quota-file))
    (let* ((file-name-handler-alist nil)
           (attrs (file-attributes decknix-agent-purpose-quota-file))
           (mtime (and attrs (file-attribute-modification-time attrs))))
      (when attrs
        (if (and decknix-agent-purpose--quota-cache
                 (equal mtime (car decknix-agent-purpose--quota-cache)))
            (cdr decknix-agent-purpose--quota-cache)
          (let ((parsed
                 (ignore-errors
                   (with-temp-buffer
                     (insert-file-contents decknix-agent-purpose-quota-file)
                     (let* ((data (json-parse-string (buffer-string)
                                                     :object-type 'alist
                                                     :array-type 'list
                                                     :null-object nil
                                                     :false-object nil))
                            (accts (alist-get 'accounts data))
                            (claude (seq-find (lambda (a)
                                                (equal (alist-get 'provider a) "anthropic"))
                                              accts))
                            (wins (alist-get 'windows claude))
                            (week (seq-find (lambda (w)
                                              (equal (alist-get 'name w) "week"))
                                            wins)))
                       (when claude
                         (list :limit-reached (eq (alist-get 'limit_reached claude) t)
                               :week-percent (or (alist-get 'used_percent week) 0.0))))))))
            (setq decknix-agent-purpose--quota-cache (cons mtime parsed))
            parsed))))))

(defun decknix-agent-purpose-apply-quota-policy (cfg &optional quota-state)
  "Apply quota-aware step-down or failover to resolved CFG plist.
When `anthropic' has `:limit-reached' t and `pi' is a registered provider,
reroutes `claude-code' to `pi' on Vertex Gemini 4 (`argon:high' for Opus,
`neon' for Sonnet/Haiku).  When `:week-percent' >=
`decknix-agent-purpose-opus-soft-cap-percent', steps `claude-opus-*' down to
`claude-sonnet-5-5'."
  (let* ((qs (or quota-state
                 (and decknix-agent-purpose-quota-fallback-enable
                      (decknix-agent-purpose--claude-quota-state))))
         (provider (plist-get cfg :provider))
         (model (plist-get cfg :model)))
    (cond
     ((or (null qs) (not (eq provider 'claude-code))) cfg)
     ((and (plist-get qs :limit-reached)
           (decknix-agent-purpose--valid-provider-p 'pi))
      (let ((vmodel (if (and (stringp model) (string-match-p "opus" model))
                        "google-vertex/gemini-4-argon:high"
                      "google-vertex/gemini-4-neon")))
        (list :provider 'pi :model vmodel :mode nil)))
     ((and (numberp (plist-get qs :week-percent))
           (>= (plist-get qs :week-percent) decknix-agent-purpose-opus-soft-cap-percent)
           (stringp model)
           (string-match-p "\\`claude-opus-\\|\\`opus\\'" model))
      (plist-put (copy-sequence cfg) :model "claude-sonnet-5-5"))
     (t cfg))))

(defun decknix-agent-purpose-resolve (purpose)
  "Return plist `(:provider PROVIDER :model MODEL :mode MODE)' for PURPOSE.
An unknown PURPOSE resolves to `decknix-agent-default-provider'
with no model or mode pin, so callers can always safely destructure
the result without a nil-guard."
  (decknix-agent-purpose-apply-quota-policy
   (or (alist-get purpose decknix-agent-purpose-alist)
       (list :provider (and (boundp 'decknix-agent-default-provider)
                            decknix-agent-default-provider)
             :model    nil
             :mode     nil))))

(defun decknix-agent-engine-resolve (engine &optional no-quota-policy)
  "Resolve ENGINE (symbol or string, name or alias) to `(:engine SYM :provider PROV :model MODEL :mode MODE)'.
Returns nil when ENGINE is nil or does not match any entry in `decknix-agent-engine-alist'."
  (when engine
    (let* ((name (downcase (if (symbolp engine) (symbol-name engine) (format "%s" engine))))
           (cell (seq-find
                  (lambda (entry)
                    (let ((key (downcase (symbol-name (car entry))))
                          (aliases (mapcar #'downcase (plist-get (cdr entry) :aliases))))
                      (or (equal name key) (member name aliases))))
                  decknix-agent-engine-alist)))
      (when cell
        (let* ((raw (list :provider (plist-get (cdr cell) :provider)
                          :model    (plist-get (cdr cell) :model)
                          :mode     (plist-get (cdr cell) :mode)))
               (resolved (if no-quota-policy
                             raw
                           (decknix-agent-purpose-apply-quota-policy raw))))
          (cons :engine (cons (car cell) resolved)))))))

(defun decknix-agent-engine-for-model (provider model)
  "Return the canonical engine name string matching PROVIDER and MODEL, or nil."
  (when (and provider (stringp model) (not (string-empty-p model)))
    (let* ((prov-sym (if (symbolp provider) provider (intern (format "%s" provider))))
           (cell (seq-find
                  (lambda (entry)
                    (and (eq prov-sym (plist-get (cdr entry) :provider))
                         (equal model (plist-get (cdr entry) :model))))
                  decknix-agent-engine-alist)))
      (and cell (symbol-name (car cell))))))

(defun decknix-agent-purpose--valid-provider-p (sym)
  "Return non-nil when SYM is a registered agent provider id."
  (and (symbolp sym)
       (fboundp 'decknix-agent-get-provider)
       (decknix-agent-get-provider sym)))

(defun decknix-agent-purpose--known-model-p (provider model)
  "Return non-nil when MODEL is acceptable for PROVIDER.
Accepts MODEL when it is on PROVIDER's `decknix-agent-known-models' list
OR matches one of its `decknix-agent-known-model-patterns'.

Also returns non-nil when the list is nil (\"any model accepted\")
or when PROVIDER has no entry (unknown provider defers judgement).

The pattern arm is what lets a PINNED version through; see
`decknix-agent-known-model-patterns' for why an enumerated list alone
silently defeated the pin."
  (let* ((entry (assq provider decknix-agent-known-models))
         (known (cdr entry))
         (patterns (cdr (assq provider decknix-agent-known-model-patterns))))
    (cond
     ((not entry) t)
     ((null known) t)
     (t (and (stringp model)
             (or (member model known)
                 (seq-some (lambda (re) (string-match-p re model)) patterns)
                 nil))))))

(defun decknix-agent-purpose--known-mode-p (provider mode)
  "Return non-nil when MODE is on PROVIDER's known-mode list.
A provider with no `decknix-agent-known-modes' entry has no session
modes, so any non-nil MODE is rejected (returns nil)."
  (let ((known (cdr (assq provider decknix-agent-known-modes))))
    (and known (stringp mode) (member mode known))))

(defun decknix-agent-purpose--coerce-entry (entry)
  "Return ENTRY with its provider/model/mode coerced to a valid triple.
Warns and swaps in `decknix-agent-default-provider' when the
provider is not registered; warns and drops MODEL to nil when it
is not on the provider's known-model list; warns and drops MODE to
nil when the provider has no session modes or MODE is unknown."
  (let* ((purpose (car entry))
         (cfg (cdr entry))
         (provider (plist-get cfg :provider))
         (model    (plist-get cfg :model))
         (mode     (plist-get cfg :mode)))
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
    (when (and (stringp mode)
               (not (string-empty-p mode))
               (not (decknix-agent-purpose--known-mode-p provider mode)))
      (warn "[decknix-agent-purpose] %s mode %S is not valid for \
provider %S; dropping to nil (provider default will be used)"
            purpose mode provider)
      (setq mode nil))
    (cons purpose (list :provider provider :model model :mode mode))))

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
