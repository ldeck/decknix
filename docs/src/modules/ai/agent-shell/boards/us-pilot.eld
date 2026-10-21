;; -*- mode: lisp-data -*-
;; Example decknix board: the US pilot as a sidebar focus target.
;; Copy to ~/.config/decknix/boards/us-pilot.eld and edit.
(:name "us-pilot"
 :title "US Pilot"
 :goal "Bramlett live on NurtureCloud in us-prd"
 ;; Pilot sessions are tagged for the customer or the region.
 :tags-any ("bramlett" "us" "acker")
 ;; The repositories pilot work lands in.
 :repos ("UpsideRealty/followupboss-integration"
         "UpsideRealty/upside"
         "UpsideRealty/address-normaliser")
 ;; Both: a pilot tag AND one of these repositories.  `either' would pull
 ;; in every monolith session, pilot or not.
 :match both
 :backend github
 ;; Issues are optional for a focus; label pilot issues `us-pilot' so the
 ;; board only lists those from the shared repository.
 :github (:repo "UpsideRealty/followupboss-integration"
          :label "us-pilot" :label-prefix "type:"))
