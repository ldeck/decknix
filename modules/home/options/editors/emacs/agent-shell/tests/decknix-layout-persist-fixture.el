;;; decknix-layout-persist-fixture.el --- A real saved layout, anonymised -*- lexical-binding: t -*-

;;; Commentary:
;;
;; The fourth frame of a layout saved by `decknix-layout-save' on a working
;; daemon, just before the restart whose restore came back with one tab per
;; frame.  Session names, ids and paths are replaced; the window trees,
;; sizes and the selected-tab index are as saved.  Per-window prev/next
;; buffer lists are dropped, as restore drops them.
;;
;; Kept in its own file so the restore tests read like tests and the data
;; can be regenerated without touching them.

;;; Code:

(defconst decknix-layout-test-fixture
  '(:version 1 :saved-at 100.0 :buffers
             (("*Claude: session-7*" :kind agent :session
               ((session-id . "sid-session-7")
                (name . "*Claude: session-7*") (workspace . "/work/")
                (conv-key . "ck-session-7") (tags)))
              ("*Review Board*" :kind other)
              ("*Claude: session-1*" :kind agent :session
               ((session-id . "sid-session-1")
                (name . "*Claude: session-1*") (workspace . "/work/")
                (conv-key . "ck-session-1") (tags)))
              ("*Agent Sidebar*" :kind sidebar)
              ("*Claude: session-2*" :kind agent :session
               ((session-id . "sid-session-2")
                (name . "*Claude: session-2*") (workspace . "/work/")
                (conv-key . "ck-session-2") (tags)))
              ("*Claude: session-3*" :kind agent :session
               ((session-id . "sid-session-3")
                (name . "*Claude: session-3*") (workspace . "/work/")
                (conv-key . "ck-session-3") (tags)))
              ("*Claude: session-4*" :kind agent :session
               ((session-id . "sid-session-4")
                (name . "*Claude: session-4*") (workspace . "/work/")
                (conv-key . "ck-session-4") (tags)))
              ("*Claude: session-5*" :kind agent :session
               ((session-id . "sid-session-5")
                (name . "*Claude: session-5*") (workspace . "/work/")
                (conv-key . "ck-session-5") (tags)))
              ("*Claude: session-6*" :kind agent :session
               ((session-id . "sid-session-6")
                (name . "*Claude: session-6*") (workspace . "/work/")
                (conv-key . "ck-session-6") (tags))))
             :frames
             ((:params ((width . 244) (height . 74)) :selected t
                       :current-tab 1 :tabs
                       ((:name "*Review Board*" :explicit nil :state
                               (((min-height . 4) (min-width . 20)
                                 (min-height-ignore . 4)
                                 (min-width-ignore . 10)
                                 (min-height-safe . 1)
                                 (min-width-safe . 4)
                                 (min-pixel-height . 56)
                                 (min-pixel-width . 140)
                                 (min-pixel-height-ignore . 56)
                                 (min-pixel-width-ignore . 70)
                                 (min-pixel-height-safe . 14)
                                 (min-pixel-width-safe . 28))
                                hc (pixel-width . 1724)
                                (pixel-height . 1022)
                                (total-width . 246)
                                (total-height . 73)
                                (normal-height . 1.0)
                                (normal-width . 1.0)
                                (combination-limit)
                                (leaf (pixel-width . 863)
                                      (pixel-height . 1022)
                                      (total-width . 123)
                                      (total-height . 73)
                                      (normal-height . 1.0)
                                      (normal-width . 0.5)
                                      (buffer "*Review Board*"
                                              (selected . t)
                                              (hscroll . 0)
                                              (fringes 8 8 nil nil)
                                              (margins nil)
                                              (scroll-bars nil 0 t nil
                                                           0 t nil)
                                              (vscroll . 0)
                                              (dedicated) (point . 1)
                                              (start . 1)))
                                (leaf (last . t) (pixel-width . 861)
                                      (pixel-height . 1022)
                                      (total-width . 123)
                                      (total-height . 73)
                                      (normal-height . 1.0)
                                      (normal-width . 0.5)
                                      (buffer "*Claude: session-1*"
                                              (selected) (hscroll . 0)
                                              (fringes 8 8 nil nil)
                                              (margins nil)
                                              (scroll-bars nil 0 t nil
                                                           0 t nil)
                                              (vscroll . 0)
                                              (dedicated)
                                              (point . 67793)
                                              (start . 36577)))))
                        (:name "Agents" :explicit t :state
                               (((min-height . 8) (min-width . 30)
                                 (min-height-ignore . 8)
                                 (min-width-ignore . 15)
                                 (min-height-safe . 2)
                                 (min-width-safe . 6)
                                 (min-pixel-height . 112)
                                 (min-pixel-width . 210)
                                 (min-pixel-height-ignore . 112)
                                 (min-pixel-width-ignore . 105)
                                 (min-pixel-height-safe . 28)
                                 (min-pixel-width-safe . 42))
                                hc (pixel-width . 1724)
                                (pixel-height . 1022)
                                (total-width . 246)
                                (total-height . 73)
                                (normal-height . 1.0)
                                (normal-width . 1.0)
                                (combination-limit)
                                (leaf (pixel-width . 357)
                                      (pixel-height . 1022)
                                      (total-width . 51)
                                      (total-height . 73)
                                      (normal-height . 1.0)
                                      (normal-width
                                       . 0.20765661252900233)
                                      (parameters (window-side . left)
                                                  (window-slot . 0))
                                      (buffer "*Agent Sidebar*"
                                              (selected) (hscroll . 0)
                                              (fringes 8 8 nil nil)
                                              (margins nil)
                                              (scroll-bars nil 0 t nil
                                                           0 t nil)
                                              (vscroll . 0)
                                              (dedicated . t)
                                              (point . 1) (start . 1)))
                                (vc (last . t) (pixel-width . 1367)
                                    (pixel-height . 1022)
                                    (total-width . 195)
                                    (total-height . 73)
                                    (normal-height . 1.0)
                                    (normal-width . 0.7923433874709978)
                                    (combination-limit . t)
                                    (hc (pixel-width . 1367)
                                        (pixel-height . 517)
                                        (total-width . 195)
                                        (total-height . 37)
                                        (normal-height . 0.5)
                                        (normal-width . 1.0)
                                        (combination-limit)
                                        (leaf (pixel-width . 681)
                                              (pixel-height . 517)
                                              (total-width . 97)
                                              (total-height . 37)
                                              (normal-height . 1.0)
                                              (normal-width . 0.5)
                                              (buffer
                                               "*Claude: session-2*"
                                               (selected)
                                               (hscroll . 0)
                                               (fringes 8 8 nil nil)
                                               (margins nil)
                                               (scroll-bars nil 0 t
                                                            nil 0 t
                                                            nil)
                                               (vscroll . 0)
                                               (dedicated)
                                               (point . 602755)
                                               (start . 601584)))
                                        (leaf (last . t)
                                              (pixel-width . 686)
                                              (pixel-height . 517)
                                              (total-width . 98)
                                              (total-height . 37)
                                              (normal-height . 1.0)
                                              (normal-width . 0.5)
                                              (buffer
                                               "*Claude: session-3*"
                                               (selected)
                                               (hscroll . 0)
                                               (fringes 8 8 nil nil)
                                               (margins nil)
                                               (scroll-bars nil 0 t
                                                            nil 0 t
                                                            nil)
                                               (vscroll . 0)
                                               (dedicated)
                                               (point . 1179619)
                                               (start . 1179213))))
                                    (hc (last . t)
                                        (pixel-width . 1367)
                                        (pixel-height . 505)
                                        (total-width . 195)
                                        (total-height . 36)
                                        (normal-height . 0.5)
                                        (normal-width . 1.0)
                                        (combination-limit)
                                        (leaf (pixel-width . 681)
                                              (pixel-height . 505)
                                              (total-width . 97)
                                              (total-height . 36)
                                              (normal-height . 1.0)
                                              (normal-width . 0.5)
                                              (buffer
                                               "*Claude: session-4*"
                                               (selected)
                                               (hscroll . 0)
                                               (fringes 8 8 nil nil)
                                               (margins nil)
                                               (scroll-bars nil 0 t
                                                            nil 0 t
                                                            nil)
                                               (vscroll . 0)
                                               (dedicated)
                                               (point . 361240)
                                               (start . 342037)))
                                        (leaf (last . t)
                                              (pixel-width . 686)
                                              (pixel-height . 505)
                                              (total-width . 98)
                                              (total-height . 36)
                                              (normal-height . 1.0)
                                              (normal-width . 0.5)
                                              (buffer
                                               "*Claude: session-5*"
                                               (selected)
                                               (hscroll . 0)
                                               (fringes 8 8 nil nil)
                                               (margins nil)
                                               (scroll-bars nil 0 t
                                                            nil 0 t
                                                            nil)
                                               (vscroll . 0)
                                               (dedicated)
                                               (point . 395404)
                                               (start . 394372)))))))
                        (:name "*Claude: session-7*" :explicit nil
                               :state
                               (((min-height . 4) (min-width . 20)
                                 (min-height-ignore . 4)
                                 (min-width-ignore . 10)
                                 (min-height-safe . 1)
                                 (min-width-safe . 4)
                                 (min-pixel-height . 56)
                                 (min-pixel-width . 140)
                                 (min-pixel-height-ignore . 56)
                                 (min-pixel-width-ignore . 70)
                                 (min-pixel-height-safe . 14)
                                 (min-pixel-width-safe . 28))
                                hc (pixel-width . 1724)
                                (pixel-height . 1022)
                                (total-width . 246)
                                (total-height . 73)
                                (normal-height . 1.0)
                                (normal-width . 1.0)
                                (combination-limit)
                                (leaf (pixel-width . 863)
                                      (pixel-height . 1022)
                                      (total-width . 123)
                                      (total-height . 73)
                                      (normal-height . 1.0)
                                      (normal-width . 0.5)
                                      (buffer "*Claude: session-6*"
                                              (selected) (hscroll . 0)
                                              (fringes 8 8 nil nil)
                                              (margins nil)
                                              (scroll-bars nil 0 t nil
                                                           0 t nil)
                                              (vscroll . 0)
                                              (dedicated)
                                              (point . 2197717)
                                              (start . 78333)))
                                (leaf (last . t) (pixel-width . 861)
                                      (pixel-height . 1022)
                                      (total-width . 123)
                                      (total-height . 73)
                                      (normal-height . 1.0)
                                      (normal-width . 0.5)
                                      (buffer "*Claude: session-7*"
                                              (selected . t)
                                              (hscroll . 0)
                                              (fringes 8 8 nil nil)
                                              (margins nil)
                                              (scroll-bars nil 0 t nil
                                                           0 t nil)
                                              (vscroll . 0)
                                              (dedicated)
                                              (point . 1058097)
                                              (start . 459003)))))))))
  "Three tabs (a board beside a session; the Agents tab, with the sidebar
and a 2x2 grid; two sessions), the middle one selected.")

(provide 'decknix-layout-persist-fixture)
;;; decknix-layout-persist-fixture.el ends here
