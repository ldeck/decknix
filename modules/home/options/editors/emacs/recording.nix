{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.emacs.decknix.recording;
in
{
  options.programs.emacs.decknix.recording = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Screen-recording helpers for demoing decknix/deckmacs: keycast (an
        on-screen overlay of the command + keystrokes) plus gif-screencast
        (records the frame to a compact, asciinema-style animated GIF).
        Also installs asciinema + agg for terminal (`emacs -nw` / shell) demos.
      '';
    };

    outputDirectory = mkOption {
      type = types.str;
      default = "~/Recordings/decknix";
      description = "Directory where recorded GIFs are written.";
    };
  };

  config = mkIf cfg.enable {
    programs.emacs.extraPackages = epkgs: with epkgs; [
      keycast          # on-screen keystroke + command overlay
      gif-screencast   # frame -> animated GIF, one frame per command
    ];

    # CLI tools gif-screencast shells out to, plus asciinema/agg for terminal
    # demos.  gif-screencast auto-detects `screencapture' on darwin; the rest
    # (convert/mogrify from imagemagick, gifsicle) are pinned by path below.
    home.packages = with pkgs; [
      gifsicle
      imagemagick
      ffmpeg
      asciinema
      asciinema-agg
    ];

    programs.emacs.extraConfig = ''
      ;;; Screen recording — demonstrate decknix/deckmacs with keystroke overlays
      ;;
      ;; keycast shows the current command + the keys that invoked it;
      ;; gif-screencast records the selected frame to an animated GIF, one frame
      ;; per command, so the clip reads clearly (asciinema-style) rather than as
      ;; full-motion video.  Toggles hang off the deckmacs prefix:
      ;;   C-c D V  decknix-screencast-toggle       (start/stop a GIF recording)
      ;;   C-c D K  decknix-screencast-keys-toggle  (just the keystroke overlay)
      ;;
      ;; For terminal demos, `asciinema rec' + `agg' (installed here) record and
      ;; convert a shell / `emacs -nw' session to a GIF outside Emacs.

      (require 'keycast nil t)
      (require 'gif-screencast nil t)

      (defvar decknix-screencast-output-directory
        (expand-file-name "${cfg.outputDirectory}")
        "Directory where recorded GIFs are written.")

      (defvar decknix-screencast-keycast-mode 'keycast-tab-bar-mode
        "Keycast minor-mode toggled on while recording (a mode function symbol).
Alternatives: `keycast-header-line-mode', `keycast-mode-line-mode'.")

      (defvar decknix-screencast--active nil
        "Non-nil while a decknix screencast is recording.")

      (with-eval-after-load 'gif-screencast
        ;; Prefer Emacs' own frame export (`x-export-frames') when the build
        ;; supports it — no external screenshotter, so no macOS screen-recording
        ;; permission prompt.  Falls back to `screencapture' otherwise.
        (setq gif-screencast-capture-prefer-internal t
              gif-screencast-capture-format "png"
              ;; The package's default args are scrot flags; on darwin the
              ;; program is `screencapture', which wants `-x' (silent) instead.
              gif-screencast-args '("-x")
              gif-screencast-convert-program "${pkgs.imagemagick}/bin/convert"
              gif-screencast-cropping-program "${pkgs.imagemagick}/bin/mogrify"
              gif-screencast-optimize-program "${pkgs.gifsicle}/bin/gifsicle"
              gif-screencast-output-directory decknix-screencast-output-directory))

      (defun decknix-screencast-keys-toggle ()
        "Toggle the on-screen keystroke overlay (keycast) without recording.
Useful for live pairing / demos where a GIF isn't wanted."
        (interactive)
        (require 'keycast)
        (call-interactively decknix-screencast-keycast-mode))

      (defun decknix-screencast-start ()
        "Start recording the selected frame to a GIF, keystroke overlay on."
        (interactive)
        (require 'keycast)
        (require 'gif-screencast)
        (make-directory decknix-screencast-output-directory t)
        (funcall decknix-screencast-keycast-mode 1)
        (gif-screencast)
        (setq decknix-screencast--active t)
        (message "decknix screencast: recording — C-c D V to stop"))

      (defun decknix-screencast-stop ()
        "Stop recording; gif-screencast assembles the GIF into the output dir."
        (interactive)
        (when (fboundp 'gif-screencast-stop)
          (gif-screencast-stop))
        (ignore-errors (funcall decknix-screencast-keycast-mode -1))
        (setq decknix-screencast--active nil)
        (message "decknix screencast: stopped — GIF in %s"
                 decknix-screencast-output-directory))

      (defun decknix-screencast-toggle ()
        "Start or stop a decknix screencast."
        (interactive)
        (if decknix-screencast--active
            (decknix-screencast-stop)
          (decknix-screencast-start)))
    '';
  };
}
