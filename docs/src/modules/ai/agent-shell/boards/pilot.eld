;; -*- mode: lisp-data -*-
;; Example decknix board: a pilot as a sidebar focus target.
;; Copy to ~/.config/decknix/boards/pilot.eld and edit.
(:name "pilot"
 :title "Pilot"
 :goal "First tenant live in the new region"
 ;; Pilot sessions are tagged for the tenant or the pilot.
 :tags-any ("tenant-a" "pilot")
 ;; The repositories pilot work lands in.
 :repos ("acme/portal-integration"
         "acme/widgets"
         "acme/address-service")
 ;; Both: a pilot tag AND one of these repositories.  `either' would pull
 ;; in every monolith session, pilot or not.
 :match both
 :backend github
 ;; Issues are optional for a focus; label pilot issues `pilot' so the
 ;; board only lists those from the shared repository.
 :github (:repo "acme/portal-integration"
          :label "pilot" :label-prefix "type:"))
