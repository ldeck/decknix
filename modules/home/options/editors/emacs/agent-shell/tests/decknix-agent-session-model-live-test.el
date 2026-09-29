;;; decknix-agent-session-model-live-test.el --- Live model reading -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The save-on-change callback read `(:session :model-id)', which is nil in
;; current agent-shell builds, so its `(when (and conv-key model-id) ...)' guard
;; never passed and NO model change was ever persisted, for any provider.  The
;; header reads the store, so it kept reporting the previous model after a
;; change.  The fixture is the real `agent-shell--state' shape, measured off a
;; live pi buffer, so a change to it fails here rather than silently returning to
;; saving nothing.

;;; Code:

(require 'ert)
(require 'decknix-agent-session-model)

(defconst decknix-model-live-test--state
  '((:agent-config (:identifier . pi))
    (:session (:session-id . "s-1"))
    (:config-options
     ((:id . "model") (:name . "Model") (:type . "select")
      (:current-value . "openai-codex/gpt-6-sol")
      (:options ((:value . "openai-codex/gpt-5.6-sol"))
                ((:value . "openai-codex/gpt-6-sol"))))
     ((:id . "reasoning-effort") (:current-value . "high"))))
  "State shaped like a live pi session mid-conversation.")

(ert-deftest decknix-model-live--reads-the-config-option ()
  "The live model is the `model' config option's current value."
  (should (equal "openai-codex/gpt-6-sol"
                 (decknix--agent-model-id-from-state
                  decknix-model-live-test--state))))

(ert-deftest decknix-model-live--ignores-other-config-options ()
  "Another option's current value must not be mistaken for the model.
`reasoning-effort' sits in the same list and would otherwise be picked up by
a first-entry read."
  (should (equal "openai-codex/gpt-6-sol"
                 (decknix--agent-model-id-from-state
                  (list (assoc :config-options
                               decknix-model-live-test--state))))))

(ert-deftest decknix-model-live--falls-back-to-the-legacy-path ()
  "An older adapter exposing `(:session :model-id)' still works."
  (should (equal "claude-opus-5-5"
                 (decknix--agent-model-id-from-state
                  '((:session (:model-id . "claude-opus-5-5")))))))

(ert-deftest decknix-model-live--config-option-wins-over-legacy ()
  "When both are present the config option is the live truth."
  (should (equal "live"
                 (decknix--agent-model-id-from-state
                  '((:session (:model-id . "stale"))
                    (:config-options ((:id . "model")
                                      (:current-value . "live"))))))))

(ert-deftest decknix-model-live--absent-or-empty-is-nil ()
  "Nil must stay distinct from a value, or a blank pin gets written."
  (should-not (decknix--agent-model-id-from-state nil))
  (should-not (decknix--agent-model-id-from-state '((:config-options))))
  (should-not (decknix--agent-model-id-from-state
               '((:config-options ((:id . "model") (:current-value . ""))))))
  (should-not (decknix--agent-model-id-from-state
               '((:config-options ((:id . "other") (:current-value . "x"))))))
  (should-not (decknix--agent-model-id-from-state
               '((:session (:model-id . ""))))))

(ert-deftest decknix-model-live--non-string-value-is-nil ()
  "A symbol or number would be written into the store verbatim and then
compared against strings on resume."
  (should-not (decknix--agent-model-id-from-state
               '((:config-options ((:id . "model") (:current-value . 5))))))
  (should-not (decknix--agent-model-id-from-state
               '((:config-options ((:id . "model") (:current-value . sym)))))))

(provide 'decknix-agent-session-model-live-test)
;;; decknix-agent-session-model-live-test.el ends here
