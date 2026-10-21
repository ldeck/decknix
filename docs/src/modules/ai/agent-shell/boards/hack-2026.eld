;; -*- mode: lisp-data -*-
;; Example decknix board: a hackathon spread over several repositories.
;; Copy to ~/.config/decknix/boards/hack-2026.eld and edit.
(:name "hack-2026"
 :title "Hackathon 2026"
 :goal "Ship coordination boards"
 :tags-any ("hackathon" "hack-2026")
 ;; Every hack-* repository, plus the shared website.
 :repos ("UpsideRealty/hack-*" "UpsideRealty/website")
 ;; A session is on the board by tag, or by working in one of the repos.
 :match either
 :slack-channel "C0123ABCD"
 :backend github
 ;; Items are created here; the goal issue is #1 of this repository.
 :github (:repo "UpsideRealty/hack-2026" :root 1 :label-prefix "type:"))
