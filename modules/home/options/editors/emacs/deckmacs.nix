{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.deckmacs;
in
{
  options.programs.emacs.decknix.deckmacs = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Deckmacs framework management (hot-reload, status, diagnostics).";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs.extraConfig = ''
      ;;; Deckmacs — Framework Management (C-c D)
      ;;; Provides hot-reload, status, and diagnostics for the Emacs configuration.
      ;;; See: https://github.com/ldeck/decknix/issues/85

      ;; == State tracking ==
      ;; defvar is a no-op if the variable already exists — preserves state across reloads.

      (defvar deckmacs--loaded-store-path nil
        "Store path of the currently loaded default.el. Nil if not yet tracked.")

      (defvar deckmacs--reload-history nil
        "List of (TIMESTAMP STORE-PATH ACTION) entries for reload log.")

      (defvar deckmacs--reload-count 0
        "Number of successful reloads in this session.")

      ;; == Path resolution ==

      (defun deckmacs--resolve-current-default-el ()
        "Find default.el from the current Nix profile (not the running load-path).
      After `decknix switch --dev', the profile symlink updates but the running
      daemon's load-path still points to the old store path. This function
      resolves the NEW default.el by tracing:
        ~/.nix-profile/bin/emacs → emacs-with-packages → .emacs-wrapped
        → emacsWithPackages_siteLisp=<deps-path> → default.el"
        (let* ((profile-emacs (expand-file-name "~/.nix-profile/bin/emacs"))
               (real-emacs (file-truename profile-emacs))
               (bin-dir (file-name-directory real-emacs))
               (wrapper (expand-file-name ".emacs-wrapped" bin-dir))
               (output (when (file-exists-p wrapper)
                         (shell-command-to-string
                          (format "strings %s | grep 'emacsWithPackages_siteLisp=' | head -1"
                                  (shell-quote-argument wrapper)))))
               (site-lisp (when (and output (string-match "=\\(.+\\)" output))
                            (string-trim (match-string 1 output))))
               (default-el (when site-lisp
                             (expand-file-name "default.el" site-lisp))))
          (when (and default-el (file-exists-p default-el))
            default-el)))

      (defun deckmacs--store-path-for (file)
        "Extract the /nix/store/<hash>-<name> portion from FILE path."
        (when (and file (string-match "\\(/nix/store/[^/]+\\)" file))
          (match-string 1 file)))

      ;; == Hot-reload internals ==

      (defun deckmacs--swap-store-paths (new-store-root)
        "Rewrite emacs-packages-deps store hashes in load paths to NEW-STORE-ROOT.
      The aggregator lives at a single store path that changes on every
      switch.  Walking `load-path' and `native-comp-eln-load-path' and
      replacing the old prefix preserves the upstream Emacs lisp dirs
      interleaved between aggregator entries (their order matters for
      built-in / upstream module precedence).  Returns the count of
      entries rewritten across both lists."
        (let* ((sample (seq-find (lambda (p)
                                   (string-match-p "emacs-packages-deps" p))
                                 load-path))
               (old-root (when sample
                           (when (string-match "\\(/nix/store/[^/]+\\)" sample)
                             (match-string 1 sample))))
               (rewritten 0))
          (when (and old-root (not (equal old-root new-store-root)))
            (setq load-path
                  (mapcar (lambda (p)
                            (if (string-prefix-p old-root p)
                                (progn (setq rewritten (1+ rewritten))
                                       (concat new-store-root
                                               (substring p (length old-root))))
                              p))
                          load-path))
            (when (boundp 'native-comp-eln-load-path)
              (setq native-comp-eln-load-path
                    (mapcar (lambda (p)
                              (if (string-prefix-p old-root p)
                                  (progn (setq rewritten (1+ rewritten))
                                         (concat new-store-root
                                                 (substring p (length old-root))))
                                p))
                            native-comp-eln-load-path))))
          rewritten))

      (defun deckmacs--unload-decknix-features ()
        "Force-unload every loaded decknix-* feature.
      `unload-feature' with FORCE=t bypasses the dependent-features check
      so we can unload in any order; the subsequent `load-file' on the
      new default.el re-runs every `(require 'decknix-...)' call which
      now resolves to the new store paths swapped in by
      `deckmacs--swap-store-paths'.  Returns the list of features
      unloaded."
        (let ((unloaded nil))
          (dolist (feat (copy-sequence features))
            (when (and (symbolp feat)
                       (string-prefix-p "decknix-" (symbol-name feat)))
              (when (ignore-errors (unload-feature feat t) t)
                (push feat unloaded))))
          (nreverse unloaded)))

      (defun deckmacs--strip-stale-decknix-advice ()
        "Remove any advice whose function symbol starts with \"decknix-\"
      and is currently fmakunbound.  Returns the count of advice-remove
      calls.

      `unload-feature' fmakunbounds a package's defuns but does NOT
      remove advice that OTHER function symbols have attached to
      those defuns (the advice registration lives on the advised
      symbol, not the advice function's package).  Any such surviving
      advice raises `(void-function ...)' the next time the advised
      function runs -- and because `deckmacs-reload' invokes
      `load-file' on the new default.el directly after unloading, an
      early call from that new file that triggers stale advice will
      abort the load mid-way, leaving the daemon with a half-loaded
      feature set (concretely: any `(require ...)' beyond the abort
      point never runs, and the timers / advice already registered
      from the previous daemon lifetime keep firing into voidness).

      Calling this between the unload and load-file steps guarantees
      the next load starts from a clean advice slate regardless of
      which decknix-* module owned which advice."
        (let ((stripped 0))
          (mapatoms
           (lambda (sym)
             (when (fboundp sym)
               (let ((to-remove nil))
                 (advice-mapc
                  (lambda (adv-fn _props)
                    (when (and (symbolp adv-fn)
                               (string-prefix-p "decknix-"
                                                (symbol-name adv-fn))
                               (not (fboundp adv-fn)))
                      (push adv-fn to-remove)))
                  sym)
                 (dolist (adv to-remove)
                   (advice-remove sym adv)
                   (setq stripped (1+ stripped)))))))
          stripped))

      ;; == Reload ==

      (defvar deckmacs-pre-reload-hook nil
        "Normal hook run at the start of `deckmacs-reload', before any
      decknix-* feature is unloaded.  At this point the OLD feature set
      is still live, so use this hook to *persist* runtime state that the
      unload/reload cycle would otherwise wipe — e.g. sidebar toggle
      states (`decknix--sidebar-state-save').  Without a pre-reload save,
      `decknix switch' resets every toggle `defvar' to its default and
      the post-reload restore can only recover whatever the periodic
      idle-timer / `kill-emacs' last wrote, silently losing any toggle
      changed since.  Each hook function is run inside `condition-case'
      so a failing saver can never abort the reload.  Add only
      symbol-named functions so they are deduplicated across reloads.")

      (defvar deckmacs-post-reload-hook nil
        "Normal hook run after `deckmacs-reload' completes successfully.
      All decknix-* features have been reloaded and the new store path
      is active when these hooks fire.  Use this hook to restore runtime
      state that was reset by the feature unload/reload cycle — e.g.
      sidebar toggle states (`decknix--sidebar-state-restore').
      Add only symbol-named functions so they are deduplicated across
      repeated reloads.")

      (defun deckmacs-reload ()
        "Reload the current Nix profile's default.el without restarting the daemon.
      Compares store paths to detect changes. With \\[universal-argument], force
      reload even if the store path hasn't changed.

      Hot-reload covers carved first-party packages by rewriting the
      `emacs-packages-deps' store prefix in `load-path' /
      `native-comp-eln-load-path' to the new store root, then
      force-unloading every loaded `decknix-*' feature so the new
      default.el's `(require ...)' calls actually pull the new bytecode
      (a bare `require' is a no-op when the feature is already loaded)."
        (interactive)
        (let* ((new-el (deckmacs--resolve-current-default-el))
               (new-store (deckmacs--store-path-for new-el))
               (force (equal current-prefix-arg '(4)))
               (timestamp (format-time-string "%Y-%m-%d %H:%M:%S")))
          (cond
           ((not new-el)
            (let ((profile-emacs (expand-file-name "~/.nix-profile/bin/emacs")))
              (message "Deckmacs Error: Could not resolve current default.el (tried tracing from %s)"
                       (if (file-exists-p profile-emacs)
                           (file-truename profile-emacs)
                         profile-emacs))))
           ((and (equal new-store deckmacs--loaded-store-path) (not force))
            (message "Deckmacs: Already up to date (%s)"
                     (deckmacs--short-store-path new-store)))
           (t
            ;; Persist runtime state BEFORE unloading any feature — the
            ;; unload re-runs every decknix-* `defvar' and resets toggle
            ;; state to defaults, so the post-reload restore can only
            ;; recover what is on disk at this moment.  Run each hook in
            ;; `condition-case' so a failing saver never aborts the reload.
            (dolist (fn deckmacs-pre-reload-hook)
              (condition-case err
                  (funcall fn)
                (error
                 (message "Deckmacs: pre-reload hook %s failed: %s"
                          fn (error-message-string err)))))
            (let* ((old-store deckmacs--loaded-store-path)
                   (rewritten (deckmacs--swap-store-paths new-store))
                   (unloaded (deckmacs--unload-decknix-features))
                   (stripped (deckmacs--strip-stale-decknix-advice)))
              (load-file new-el)
              (setq deckmacs--loaded-store-path new-store)
              (setq deckmacs--reload-count (1+ deckmacs--reload-count))
              (push (list timestamp new-store
                         (if old-store "reload" "initial"))
                    deckmacs--reload-history)
              (message "Deckmacs: Reloaded default.el%s (%s); rewrote %d load-path entries, unloaded %d decknix-* features, stripped %d stale advice"
                       (if old-store
                           (format " (store path changed)")
                         " (initial load tracked)")
                       (deckmacs--short-store-path new-store)
                       rewritten
                       (length unloaded)
                       stripped)
              ;; Notify listeners that the reload cycle is complete and all
              ;; decknix-* features are live at the new store path.
              ;; Hooks added to this variable survive the unload step because
              ;; the variable is defined here in deckmacs (not in any feature).
              (run-hooks 'deckmacs-post-reload-hook))))))

      ;; == Status ==

      (defun deckmacs-status ()
        "Show current Deckmacs framework status."
        (interactive)
        (let* ((current-el (deckmacs--resolve-current-default-el))
               (current-store (deckmacs--store-path-for current-el))
               (stale (and deckmacs--loaded-store-path current-store
                           (not (equal deckmacs--loaded-store-path current-store))))
               (last-reload (car deckmacs--reload-history)))
          (message (concat
                    "Deckmacs Status\n"
                    (format "  Profile:     %s\n" (file-truename "~/.nix-profile"))
                    (format "  Loaded:      %s\n"
                            (or (deckmacs--short-store-path deckmacs--loaded-store-path)
                                "(not tracked)"))
                    (format "  Current:     %s\n"
                            (or (deckmacs--short-store-path current-store)
                                "(could not resolve)"))
                    (format "  Status:      %s\n"
                            (cond (stale "⚠ STALE — reload recommended (C-c D r)")
                                  (current-store "✓ Up to date")
                                  (t "? Unknown")))
                    (format "  Reloads:     %d%s"
                            deckmacs--reload-count
                            (if last-reload
                                (format " (last: %s)" (car last-reload))
                              ""))))))

      ;; == Diff ==

      (defun deckmacs-diff ()
        "Show the store path difference between loaded and current default.el."
        (interactive)
        (let* ((current-el (deckmacs--resolve-current-default-el))
               (current-store (deckmacs--store-path-for current-el)))
          (cond
           ((not current-store)
            (message "Deckmacs: Could not resolve current default.el"))
           ((not deckmacs--loaded-store-path)
            (message "Deckmacs: No loaded store path tracked yet. Run C-c D r first."))
           ((equal deckmacs--loaded-store-path current-store)
            (message "Deckmacs: No difference — loaded and current store paths match"))
           (t
            (message "Deckmacs Diff:\n  Loaded:  %s\n  Current: %s\n  → Run C-c D r to reload"
                     deckmacs--loaded-store-path current-store)))))

      ;; == Log ==

      (defun deckmacs-log ()
        "Show the reload history log."
        (interactive)
        (if (null deckmacs--reload-history)
            (message "Deckmacs: No reloads yet this session.")
          (message (concat "Deckmacs Reload Log:\n"
                           (mapconcat
                            (lambda (entry)
                              (format "  %s  %s  [%s]"
                                      (nth 0 entry)
                                      (deckmacs--short-store-path (nth 1 entry))
                                      (nth 2 entry)))
                            deckmacs--reload-history "\n")))))

      ;; == Helpers ==

      (defun deckmacs--short-store-path (store-path)
        "Abbreviate a Nix store path for display.
      /nix/store/dsygfns5yak17aqzjmc77mkcypg0f26c-emacs-packages-deps
      → dsygfns5...-emacs-packages-deps"
        (when store-path
          (if (string-match "/nix/store/\\([a-z0-9]\\{8\\}\\)[a-z0-9]*-\\(.*\\)" store-path)
              (format "%s...-%s" (match-string 1 store-path) (match-string 2 store-path))
            store-path)))

      ;; == Keybindings ==

      (define-prefix-command 'deckmacs-prefix-map)
      (global-set-key (kbd "C-c D") 'deckmacs-prefix-map)
      (define-key deckmacs-prefix-map (kbd "r") #'deckmacs-reload)
      (define-key deckmacs-prefix-map (kbd "s") #'deckmacs-status)
      (define-key deckmacs-prefix-map (kbd "d") #'deckmacs-diff)
      (define-key deckmacs-prefix-map (kbd "l") #'deckmacs-log)

      ;; == which-key labels ==

      (with-eval-after-load 'which-key
        (which-key-add-key-based-replacements
          "C-c D"   "Deckmacs"
          "C-c D r" "reload"
          "C-c D s" "status"
          "C-c D d" "diff"
          "C-c D l" "log"))

      ;; == Initial store path capture ==
      ;; Record the currently loaded store path on first load.
      ;; This uses defvar guard to only run once per daemon session.

      (defvar deckmacs--initial-capture-done nil
        "Guard to prevent re-capture on reload.")

      (unless deckmacs--initial-capture-done
        (let* ((current-el (or (locate-library "default")
                               (deckmacs--resolve-current-default-el)))
               (store-path (deckmacs--store-path-for current-el)))
          (when store-path
            (setq deckmacs--loaded-store-path store-path)
            (push (list (format-time-string "%Y-%m-%d %H:%M:%S")
                        store-path "initial")
                  deckmacs--reload-history)))
        (setq deckmacs--initial-capture-done t))
    '';
  };
}

