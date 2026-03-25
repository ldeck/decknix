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

      ;; == Reload ==

      (defun deckmacs-reload ()
        "Reload the current Nix profile's default.el without restarting the daemon.
      Compares store paths to detect changes. With \\[universal-argument], force
      reload even if the store path hasn't changed."
        (interactive)
        (let* ((new-el (deckmacs--resolve-current-default-el))
               (new-store (deckmacs--store-path-for new-el))
               (force (equal current-prefix-arg '(4)))
               (timestamp (format-time-string "%Y-%m-%d %H:%M:%S")))
          (cond
           ((not new-el)
            (message "Deckmacs: Could not resolve default.el from ~/.nix-profile"))
           ((and (equal new-store deckmacs--loaded-store-path) (not force))
            (message "Deckmacs: Already up to date (%s)"
                     (deckmacs--short-store-path new-store)))
           (t
            (let ((old-store deckmacs--loaded-store-path))
              (load-file new-el)
              (setq deckmacs--loaded-store-path new-store)
              (setq deckmacs--reload-count (1+ deckmacs--reload-count))
              (push (list timestamp new-store
                         (if old-store "reload" "initial"))
                    deckmacs--reload-history)
              (message "Deckmacs: Reloaded default.el%s (%s)"
                       (if old-store
                           (format " (store path changed)")
                         " (initial load tracked)")
                       (deckmacs--short-store-path new-store)))))))

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

