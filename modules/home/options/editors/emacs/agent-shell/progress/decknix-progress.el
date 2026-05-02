;;; decknix-progress.el --- Provider-agnostic progress data layer -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1"))
;; Keywords: agent, progress, tools

;;; Commentary:
;;
;; Provider-agnostic representation of "things in flight" — todos from
;; the agent's TODO tool stream, my open PRs from the hub, and tasks
;; from a task tracker (currently Jira; designed so additional
;; providers can be added via `decknix-progress-adapter-functions').
;;
;; This is the data layer only.  See `decknix-progress-ui' for the
;; *decknix-progress* buffer renderer and `decknix-progress-sidebar'
;; for the workspace sidebar badge integration.
;;
;; Item shape, state-derivation rules, and attention-rollup rules are
;; documented inline at the top of each defun.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

;; -- Forward declarations: functions defined elsewhere in agent-shell config --
;; These resolve at runtime via the surrounding `default.el' (loaded by the
;; Emacs daemon).  Declared here so byte-compilation of this isolated
;; trivialBuild package stays warning-clean.
(declare-function decknix--agent-current-conv-key "ext:agent-shell-config")
(declare-function decknix--agent-latest-session-id-for-conv-key "ext:agent-shell-config" (conv-key))
(declare-function decknix--agent-tags-conversations "ext:agent-shell-config" (store))
(declare-function decknix--agent-tags-for-conv-key "ext:agent-shell-config" (conv-key))
(declare-function decknix--agent-tags-read "ext:agent-shell-config")
(defvar decknix--hub-wip)
(defvar decknix--hub-jira-tasks)

;; == Progress data layer ==
;;
;; Provider-agnostic representation of "things in flight" — todos from
;; the agent's TODO tool stream, my open PRs from the hub, and tasks
;; from a task tracker (currently Jira; designed so additional
;; providers can be added via `decknix-progress-adapter-functions`).
;;
;; Each item is a plist with these keys:
;;   :id         unique within (provider, conv-key); never nil
;;   :provider   symbol — 'pr 'jira 'todo (extensible)
;;   :title      human-readable summary
;;   :url        optional navigation URL (string or nil)
;;   :state      'todo | 'wip | 'blocked | 'done | 'neutral
;;   :attention  'red  | 'amber | 'green | 'none
;;   :children   list of child plists (sub-tasks, etc.)
;;   :links      list of (:type "blocks" :direction inward|outward
;;                        :id "..." :title "..." :url ...)
;;   :extra      provider-specific raw data (alist; opaque to the layer)
;;
;; State derivation rules:
;;   PR    : merged → done; closed → neutral; CI fail → blocked;
;;           draft → todo; review_decision APPROVED → wip; else wip.
;;   Jira  : status_category done → done; status name "Blocked" or
;;           any inward "is blocked by" link to a non-done issue →
;;           blocked; indeterminate → wip; new → todo.
;;   Todo  : NOT_STARTED → todo; IN_PROGRESS → wip; CANCELLED → neutral;
;;           COMPLETE → done.
;;
;; Attention rules (signal something needs eyes):
;;   red   : CI fail, blocked state, or any child red.
;;   amber : bot/human waiting reply, stale wip, or any child amber.
;;   green : ready to merge / approved / nothing pending.
;;   none  : neutral / informational only.

(defvar decknix-progress--attention-rank
  '((none . 0) (green . 1) (amber . 2) (red . 3))
  "Numeric rank for attention symbols.  Higher rank wins when rolled up.")

(defun decknix-progress--attention-max (a b)
  "Return the higher-priority attention symbol of A and B.
nil counts as `none'."
  (let ((ra (alist-get (or a 'none) decknix-progress--attention-rank 0))
        (rb (alist-get (or b 'none) decknix-progress--attention-rank 0)))
    (if (>= ra rb) (or a 'none) (or b 'none))))

(defun decknix-progress--rollup-attention (item)
  "Return the rolled-up attention for ITEM, considering its :children.
Walks recursively so deep hierarchies propagate correctly.  Does not
mutate the items."
  (let ((self (or (plist-get item :attention) 'none))
        (children (plist-get item :children)))
    (dolist (c children)
      (setq self (decknix-progress--attention-max
                  self
                  (decknix-progress--rollup-attention c))))
    self))

(defun decknix-progress--state-from-pr (pr)
  "Map a hub WipPr alist PR to the unified progress state symbol."
  (let ((merged-at (alist-get 'merged_at pr))
        (state-str (downcase (or (alist-get 'state pr) "")))
        (draft (alist-get 'draft pr))
        (ci (alist-get 'ci pr)))
    (cond
     ((and merged-at (not (string-empty-p merged-at))) 'done)
     ((string= state-str "closed") 'neutral)
     ((and ci (string= (downcase (or (alist-get 'status ci) "")) "fail"))
      'blocked)
     (draft 'todo)
     (t 'wip))))

(defun decknix-progress--state-from-jira (task)
  "Map a hub JiraTask alist TASK to the unified progress state symbol.
Inspects status_category, the literal status name, and any inward
\"is blocked by\" links pointing at non-done issues."
  (let* ((cat (downcase (or (alist-get 'status_category task) "")))
         (status (downcase (or (alist-get 'status task) "")))
         (links (alist-get 'links task))
         (blocked-by-link
          (seq-some
           (lambda (l)
             (let* ((dir (downcase (or (alist-get 'direction l) "")))
                    (type (downcase (or (alist-get 'link_type l) "")))
                    (other (alist-get 'other l))
                    (other-cat (downcase
                                (or (alist-get 'status_category other)
                                    ""))))
               (and (string= dir "inward")
                    (string-match-p "block" type)
                    (not (string= other-cat "done")))))
           links)))
    (cond
     ((string= cat "done") 'done)
     ((or (string= status "blocked") blocked-by-link) 'blocked)
     ((string= cat "indeterminate") 'wip)
     ((string= cat "new") 'todo)
     (t 'neutral))))

(defun decknix-progress--state-from-todo (state-str)
  "Map an Augment task tool STATE-STR to the unified progress state.
STATE-STR is one of NOT_STARTED, IN_PROGRESS, COMPLETE, CANCELLED."
  (pcase (upcase (or state-str "NOT_STARTED"))
    ("NOT_STARTED" 'todo)
    ("IN_PROGRESS" 'wip)
    ("COMPLETE"    'done)
    ("CANCELLED"   'neutral)
    (_             'todo)))

(defun decknix-progress--attention-from-pr (pr)
  "Compute the attention symbol for a hub WipPr alist PR."
  (let* ((ci (alist-get 'ci pr))
         (ci-status (when ci
                      (downcase (or (alist-get 'status ci) ""))))
         (mergeable (downcase (or (alist-get 'mergeable pr) "")))
         (review-decision (upcase
                           (or (alist-get 'review_decision pr) "")))
         (needs-reply (alist-get 'needs_reply pr))
         (bot-pending (alist-get 'bot_pending pr))
         (replies-to-me (alist-get 'replies_to_me pr))
         (merged-at (alist-get 'merged_at pr))
         (state-str (downcase (or (alist-get 'state pr) ""))))
    (cond
     ;; Closed-not-merged is informational only.
     ((and (string= state-str "closed")
           (or (null merged-at) (string-empty-p merged-at)))
      'none)
     ;; Merged is "shipped" — green unless CI on default failed.
     ((and merged-at (not (string-empty-p merged-at)))
      (if (string= ci-status "fail") 'red 'green))
     ;; CI failure or merge conflict on an open PR is red.
     ((string= ci-status "fail") 'red)
     ((string= mergeable "conflicting") 'red)
     ;; Changes requested or someone replied to me → amber.
     ((string= review-decision "CHANGES_REQUESTED") 'amber)
     ((or needs-reply bot-pending replies-to-me) 'amber)
     ;; Approved + clean CI → ready to ship.
     ((and (string= review-decision "APPROVED")
           (or (null ci-status) (string= ci-status "pass")))
      'green)
     (t 'none))))

(defun decknix-progress--attention-from-jira (task)
  "Compute the attention symbol for a hub JiraTask alist TASK.
Mirrors the state derivation: blocked → red, code review → amber,
done → green, anything else → none."
  (let* ((status (downcase (or (alist-get 'status task) "")))
         (cat (downcase (or (alist-get 'status_category task) "")))
         (state (decknix-progress--state-from-jira task)))
    (cond
     ((eq state 'blocked) 'red)
     ((eq state 'done) 'green)
     ((string= status "code review") 'amber)
     ((string= cat "indeterminate") 'amber)
     (t 'none))))

(defun decknix-progress--attention-from-todo (state)
  "Compute the attention symbol for a TODO-stream STATE symbol.
Long-running WIP and blocked items earn amber; the renderer can
overlay a stale-time check later when timestamps are wired in."
  (pcase state
    ('blocked 'red)
    ('wip     'amber)
    ('done    'green)
    (_        'none)))

;; -- Hub adapter: PRs + Jira tasks --

(defun decknix-progress--pr-id (repo number)
  "Return a stable :id string for the PR at REPO #NUMBER."
  (format "pr:%s#%s" (or repo "?") (or number "?")))

(defun decknix-progress--pr-to-item (repo pr)
  "Convert a hub WipPr alist PR (under REPO) to a progress item plist."
  (let* ((number (alist-get 'number pr))
         (title  (or (alist-get 'title pr) ""))
         (url    (alist-get 'url pr))
         (state  (decknix-progress--state-from-pr pr))
         (att    (decknix-progress--attention-from-pr pr)))
    (list :id (decknix-progress--pr-id repo number)
          :provider 'pr
          :title (format "%s #%s — %s" (or repo "") number title)
          :url url
          :state state
          :attention att
          :children nil
          :links nil
          :extra (list (cons 'repo repo)
                       (cons 'pr pr)))))

(defun decknix-progress--from-hub-prs ()
  "Return progress items for every open PR in `decknix--hub-wip'.
Items are flat (one per PR); grouping by repo is the renderer's job
since different surfaces want different layouts."
  (let* ((data decknix--hub-wip)
         (repos (when data (alist-get 'repos data)))
         (out nil))
    (dolist (entry repos)
      (let ((repo (alist-get 'repo entry))
            (prs  (alist-get 'prs entry)))
        (dolist (pr prs)
          (push (decknix-progress--pr-to-item repo pr) out))))
    (nreverse out)))

(defun decknix-progress--jira-ref-to-child (ref)
  "Convert a Jira sub-task REF alist to a progress item child plist.
Sub-task REFs only carry summary/status, not the full link/sub-task
chain, so :children and :links are always nil."
  (let* ((cat (downcase (or (alist-get 'status_category ref) "")))
         (status (downcase (or (alist-get 'status ref) "")))
         (state (cond
                 ((string= cat "done") 'done)
                 ((string= status "blocked") 'blocked)
                 ((string= cat "indeterminate") 'wip)
                 ((string= cat "new") 'todo)
                 (t 'neutral)))
         (att (cond ((eq state 'blocked) 'red)
                    ((eq state 'done) 'green)
                    ((eq state 'wip) 'amber)
                    (t 'none))))
    (list :id (format "jira:%s" (alist-get 'key ref))
          :provider 'jira
          :title (format "%s — %s"
                         (or (alist-get 'key ref) "?")
                         (or (alist-get 'summary ref) ""))
          :url (alist-get 'url ref)
          :state state
          :attention att
          :children nil
          :links nil
          :extra (list (cons 'ref ref)))))

(defun decknix-progress--jira-link-to-edge (link)
  "Convert a Jira LINK alist to the progress :links plist edge."
  (let ((other (alist-get 'other link)))
    (list :type      (alist-get 'link_type link)
          :direction (intern (or (alist-get 'direction link)
                                 "outward"))
          :id        (format "jira:%s" (alist-get 'key other))
          :title     (or (alist-get 'summary other) "")
          :url       (alist-get 'url other))))

(defun decknix-progress--from-hub-jira ()
  "Return progress items for every task in `decknix--hub-jira-tasks'.
Sub-tasks are nested under :children; issue links become :links edges
on the parent."
  (let* ((data decknix--hub-jira-tasks)
         (items (when data (alist-get 'items data)))
         (out nil))
    (dolist (task items)
      (let* ((subs  (alist-get 'subtasks task))
             (links (alist-get 'links task))
             (state (decknix-progress--state-from-jira task))
             (att   (decknix-progress--attention-from-jira task))
             (item
              (list :id (format "jira:%s" (alist-get 'key task))
                    :provider 'jira
                    :title (format "%s — %s"
                                   (or (alist-get 'key task) "?")
                                   (or (alist-get 'summary task) ""))
                    :url (alist-get 'url task)
                    :state state
                    :attention att
                    :children (mapcar
                               #'decknix-progress--jira-ref-to-child
                               subs)
                    :links (mapcar
                            #'decknix-progress--jira-link-to-edge
                            links)
                    :extra (list (cons 'task task)))))
        (push item out)))
    (nreverse out)))

;; -- TODO-stream adapter (Augment session JSON) --
;;
;; Augment serialises every conversation to ~/.augment/sessions/<sid>.json.
;; Task tool calls live in chatHistory[].exchange.{response_nodes (use),
;; request_nodes (result)}.  Three tools shape the task list:
;;
;;   add_tasks         — input has new tasks (no IDs); result markdown
;;                       lists them with the server-allocated UUIDs.
;;   update_tasks      — input has task_id + new state/name/description.
;;   reorganize_tasklist — input has the full markdown snapshot of
;;                       the tree.
;;
;; We walk all task-tool RESULT markdown progressively (results are the
;; common denominator — every tool emits the same `[X] UUID:... NAME:...
;; DESCRIPTION:...' format with dash-indented hierarchy), maintaining a
;; UUID-keyed table.  For `update_tasks' inputs we also apply the new
;; state directly, since the result echoes only the changed lines and
;; that is sufficient.

(defvar decknix-progress--todo-cache (make-hash-table :test 'equal)
  "Cache of (mtime . items) keyed by session file path.
Walking a session JSON is O(N) over potentially tens of MB; we skip
re-parsing when the file mtime is unchanged.")

(defconst decknix-progress--todo-line-re
  "\\`\\(-*\\)\\[\\([ /xX-]\\)\\] UUID:\\([^ ]+\\) NAME:\\(.*?\\)\\(?: DESCRIPTION:\\(.*\\)\\)?\\'"
  "Regex for one task line in result markdown.
Group 1: leading dashes (depth).  Group 2: state glyph.
Group 3: UUID.  Group 4: NAME.  Group 5: DESCRIPTION (optional).")

(defun decknix-progress--todo-glyph-state (glyph)
  "Map a state GLYPH char to the unified progress state."
  (pcase glyph
    (?\s 'todo)
    (?/  'wip)
    (?x  'done)
    (?X  'done)
    (?-  'neutral)
    (_   'todo)))

(defun decknix-progress--todo-parse-markdown (text)
  "Parse markdown TEXT into an ordered list of task entries.
Each entry is an alist with keys: depth, state, id, name, description.
Lines that don't match `decknix-progress--todo-line-re' are ignored."
  (let ((entries nil))
    (dolist (line (split-string (or text "") "\n"))
      (when (string-match decknix-progress--todo-line-re line)
        (push (list (cons 'depth (length (match-string 1 line)))
                    (cons 'state (decknix-progress--todo-glyph-state
                                  (string-to-char
                                   (match-string 2 line))))
                    (cons 'id (match-string 3 line))
                    (cons 'name (string-trim
                                 (or (match-string 4 line) "")))
                    (cons 'description
                          (string-trim
                           (or (match-string 5 line) ""))))
              entries)))
    (nreverse entries)))

(defun decknix-progress--todo-merge-entries (table entries)
  "Update TABLE (UUID → entry plist) from parsed ENTRIES.
Last write wins for state/name/description.  Hierarchy (parent and
ordering) is tracked separately by `decknix-progress--todo-build-tree'."
  (dolist (e entries)
    (let* ((id (alist-get 'id e))
           (prior (gethash id table))
           (merged (or prior
                       (list :id id
                             :name nil :description nil
                             :state 'todo
                             :order (hash-table-count table)))))
      (setq merged (plist-put merged :state (alist-get 'state e)))
      (when (alist-get 'name e)
        (setq merged (plist-put merged :name (alist-get 'name e))))
      (when (alist-get 'description e)
        (setq merged (plist-put merged :description
                               (alist-get 'description e))))
      (puthash id merged table))))

(defun decknix-progress--todo-collect-events (history)
  "Walk session HISTORY (chatHistory list) and yield task tool events.
Returns a list of plists in chronological order:
  (:kind use|result :tool NAME :tool-id ID :input STR :output STR)"
  (let ((out nil))
    (dolist (ex history)
      (let ((exch (alist-get 'exchange ex)))
        ;; Tool uses live in response_nodes (type 5).
        (dolist (n (alist-get 'response_nodes exch))
          (let ((tu (alist-get 'tool_use n)))
            (when (and tu (member (alist-get 'tool_name tu)
                                  '("add_tasks" "update_tasks"
                                    "reorganize_tasklist"
                                    "view_tasklist")))
              (push (list :kind 'use
                          :tool (alist-get 'tool_name tu)
                          :tool-id (alist-get 'tool_use_id tu)
                          :input (alist-get 'input_json tu)
                          :output nil)
                    out))))
        ;; Tool results live in request_nodes (type 1).
        (dolist (n (alist-get 'request_nodes exch))
          (let ((tr (alist-get 'tool_result_node n)))
            (when tr
              (push (list :kind 'result
                          :tool nil
                          :tool-id (alist-get 'tool_use_id tr)
                          :input nil
                          :output (alist-get 'content tr))
                    out))))))
    (nreverse out)))

(defun decknix-progress--todo-update-parents (parents entries)
  "Walk dash-depth ENTRIES, updating PARENTS hash for each UUID.
PARENTS maps id → (parent-id . order); a depth-0 row has parent nil.
Order is the running insertion index across the whole replay so that
later snapshots win on ordering when an id is re-seen at the same
depth."
  (let ((stack nil)
        (base (hash-table-count parents)))
    (cl-loop for e in entries
             for n from 0
             do (let* ((id (alist-get 'id e))
                       (depth (alist-get 'depth e)))
                  (while (and stack (>= (caar stack) depth))
                    (pop stack))
                  (let ((parent-id (cdar stack)))
                    (puthash id (cons parent-id (+ base n)) parents))
                  (push (cons depth id) stack)))))

(defun decknix-progress--todo-pair-add-result (parents input-tasks
                                                      entries)
  "Pair INPUT-TASKS (from `add_tasks` input) with result ENTRIES.
Record `parent_task_id` for each newly-allocated UUID in PARENTS,
preserving prior parentage when a row is re-seen.  ENTRIES carry the
result UUIDs in the same order the request supplied them, so we
zip the two lists positionally."
  (let ((base (hash-table-count parents)))
    (cl-loop for task in input-tasks
             for ent in entries
             for n from 0
             do (let* ((rid (alist-get 'id ent))
                       (parent (alist-get 'parent_task_id task)))
                  (unless (gethash rid parents)
                    (puthash rid (cons parent (+ base n))
                             parents))))))

(defun decknix-progress--todo-replay (events)
  "Replay task tool EVENTS into (TABLE . PARENTS).
TABLE is a UUID → entry-plist hash table.  PARENTS is a UUID →
\(parent-uuid . order) hash table accumulated from authoritative
structural sources only — `reorganize_tasklist` input markdown
\(full dash-indented snapshot) and `add_tasks` input paired with its
result IDs.  Partial result markdowns from `add_tasks`,
`update_tasks` and `view_tasklist` carry no leading dashes, so we
deliberately do NOT derive parent links from them."
  (let ((table (make-hash-table :test 'equal))
        (parents (make-hash-table :test 'equal))
        (task-ids (make-hash-table :test 'equal))
        (pending-add (make-hash-table :test 'equal)))
    (dolist (ev events)
      (pcase (plist-get ev :kind)
        ('use
         (let ((tool (plist-get ev :tool))
               (tid  (plist-get ev :tool-id))
               (inp  (plist-get ev :input)))
           (puthash tid tool task-ids)
           ;; reorganize_tasklist input is a full hierarchical snapshot.
           (when (and (string= tool "reorganize_tasklist") inp)
             (let* ((parsed (decknix--hub-read-json-string inp))
                    (md (alist-get 'markdown parsed))
                    (entries (decknix-progress--todo-parse-markdown
                              md)))
               (when entries
                 (decknix-progress--todo-merge-entries table entries)
                 (decknix-progress--todo-update-parents parents
                                                        entries))))
           ;; add_tasks input has no IDs (server allocates them in
           ;; the result); stash the input task list so we can pair
           ;; it with the result UUIDs to recover parent_task_id.
           (when (and (string= tool "add_tasks") inp)
             (let* ((parsed (decknix--hub-read-json-string inp))
                    (tasks (alist-get 'tasks parsed)))
               (puthash tid tasks pending-add)))
           ;; update_tasks input gives us authoritative state changes
           ;; even before the result comes back.
           (when (and (string= tool "update_tasks") inp)
             (let* ((parsed (decknix--hub-read-json-string inp))
                    (tasks (alist-get 'tasks parsed)))
               (dolist (task tasks)
                 (let* ((id (alist-get 'task_id task))
                        (state-str (alist-get 'state task))
                        (entry (or (gethash id table)
                                   (list :id id :name nil
                                         :description nil :state 'todo
                                         :order (hash-table-count
                                                 table)))))
                   (when state-str
                     (setq entry
                           (plist-put
                            entry :state
                            (decknix-progress--state-from-todo
                             state-str))))
                   (dolist (k '(name description))
                     (let ((v (alist-get k task)))
                       (when v
                         (setq entry (plist-put
                                      entry
                                      (intern (format ":%s" k))
                                      v)))))
                   (puthash id entry table)))))))
        ('result
         (let* ((tid (plist-get ev :tool-id))
                (tool (gethash tid task-ids))
                (out (plist-get ev :output)))
           (when (and tool out
                      (member tool
                              '("add_tasks" "update_tasks"
                                "reorganize_tasklist"
                                "view_tasklist")))
             (let ((entries (decknix-progress--todo-parse-markdown
                             out)))
               (when entries
                 ;; Merge state/name/description; never trust the
                 ;; partial result for depth (no dashes echoed).
                 (decknix-progress--todo-merge-entries table entries)
                 ;; Pair add_tasks input with result IDs to recover
                 ;; parent_task_id for the freshly-allocated UUIDs.
                 (when (string= tool "add_tasks")
                   (let ((input-tasks (gethash tid pending-add)))
                     (when input-tasks
                       (decknix-progress--todo-pair-add-result
                        parents input-tasks entries)
                       (remhash tid pending-add)))))))))))
    (cons table parents)))

(defun decknix--hub-read-json-string (s)
  "Parse JSON string S to an alist, returning nil on error."
  (when (and s (stringp s) (not (string-empty-p s)))
    (condition-case _err
        (json-parse-string s
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object nil)
      (error nil))))

(defun decknix-progress--todo-build-subtree (id items children-of
                                                order-of)
  "Recursively assemble the subtree rooted at ID.
Returns the item plist with :children populated by recursively
descending CHILDREN-OF.  ORDER-OF maps an id to a sortable index."
  (let ((item (gethash id items)))
    (when item
      (let* ((kids (gethash id children-of))
             (sorted (sort (copy-sequence (or kids nil))
                           (lambda (a b)
                             (< (funcall order-of a)
                                (funcall order-of b)))))
             (children (delq nil
                             (mapcar
                              (lambda (cid)
                                (decknix-progress--todo-build-subtree
                                 cid items children-of order-of))
                              sorted))))
        (plist-put item :children children)
        (puthash id item items)
        item))))

(defun decknix-progress--todo-build-tree (table parents)
  "Build a tree of progress items from TABLE keyed by PARENTS.
TABLE is a UUID → entry-plist hash from the replay; PARENTS is a
UUID → (parent-uuid . order) hash accumulated from the authoritative
structural sources (`reorganize_tasklist` input + `add_tasks` input
paired with its result).  Tasks with no recorded parent — or whose
parent is unknown — surface as roots, ordered first by their PARENTS
order and then by their entry insertion order so newer add_tasks rows
follow their predecessors."
  (let ((items (make-hash-table :test 'equal))
        (children-of (make-hash-table :test 'equal))
        (orphans nil))
    ;; Materialise every UUID from TABLE.
    (maphash
     (lambda (id entry)
       (let* ((name (or (plist-get entry :name) ""))
              (state (or (plist-get entry :state) 'todo))
              (item (list :id (format "todo:%s" id)
                          :provider 'todo
                          :title name
                          :url nil
                          :state state
                          :attention
                          (decknix-progress--attention-from-todo state)
                          :children nil
                          :links nil
                          :extra
                          (list (cons 'todo-uuid id)
                                (cons 'description
                                      (or (plist-get entry :description)
                                          ""))
                                (cons 'order
                                      (or (plist-get entry :order)
                                          0))))))
         (puthash id item items)))
     table)
    ;; Group by parent: anything pointing at a known parent goes
    ;; under it; the rest become root candidates.
    (maphash
     (lambda (id _it)
       (let* ((entry (gethash id parents))
              (parent (and entry (car entry))))
         (if (and parent (gethash parent items))
             (puthash parent
                      (cons id (gethash parent children-of))
                      children-of)
           (push id orphans))))
     items)
    ;; Order resolution: prefer the structural order recorded in
    ;; PARENTS; otherwise fall back to the entry's insertion order.
    (let* ((order-of
            (lambda (id)
              (or (cdr (gethash id parents))
                  (alist-get 'order
                             (plist-get (gethash id items) :extra))
                  0)))
           (sorted-roots (sort orphans
                               (lambda (a b)
                                 (< (funcall order-of a)
                                    (funcall order-of b))))))
      (delq nil
            (mapcar (lambda (rid)
                      (decknix-progress--todo-build-subtree
                       rid items children-of order-of))
                    sorted-roots)))))

(defun decknix-progress--from-todo-stream (session-id)
  "Return progress items parsed from SESSION-ID's session JSON.
Returns nil when the session file is missing or has no task tool calls.
Caches the result by file mtime to avoid re-parsing huge transcripts."
  (when session-id
    (let* ((path (expand-file-name
                  (format "~/.augment/sessions/%s.json" session-id)))
           (mtime (when (file-exists-p path)
                    (float-time
                     (file-attribute-modification-time
                      (file-attributes path)))))
           (cached (gethash path decknix-progress--todo-cache)))
      (cond
       ((null mtime) nil)
       ((and cached (= (car cached) mtime)) (cdr cached))
       (t
        (condition-case err
            (let* ((data (with-temp-buffer
                           (insert-file-contents path)
                           (json-parse-buffer
                            :object-type 'alist
                            :array-type 'list
                            :null-object nil
                            :false-object nil)))
                   (history (alist-get 'chatHistory data))
                   (events (decknix-progress--todo-collect-events
                            history))
                   (replay (decknix-progress--todo-replay events))
                   (tree (decknix-progress--todo-build-tree
                          (car replay) (cdr replay))))
              (puthash path (cons mtime tree)
                       decknix-progress--todo-cache)
              tree)
          (error
           (message "decknix-progress: %s parse error: %s" path err)
           nil)))))))

;; -- Adapter registry + per-conv-key aggregator --
;;
;; Each adapter is a (CONV-KEY) → list-of-items function.  CONV-KEY
;; may be nil when the caller wants "everything" (e.g. PRs are not
;; tied to a specific conversation; the aggregator includes them
;; under every conversation that has a workspace match).  Adapters
;; that don't apply to the given conv-key return nil.

(defvar decknix-progress-adapter-functions
  '(decknix-progress--adapter-todo-stream
    decknix-progress--adapter-jira
    decknix-progress--adapter-prs)
  "List of progress-data adapters.
Each entry is a function `(CONV-KEY) → list-of-progress-items'.
PR 1 ships three: TODO-stream (per-conversation), Jira (global), and
hub PRs (global).  Future ports plug in by adding to this list.")

(defun decknix-progress--adapter-todo-stream (conv-key)
  "Adapter: parse TODO-stream items for CONV-KEY's latest session."
  (when conv-key
    (let ((sid (when (fboundp
                      'decknix--agent-latest-session-id-for-conv-key)
                 (decknix--agent-latest-session-id-for-conv-key
                  conv-key))))
      (when sid
        (decknix-progress--from-todo-stream sid)))))

(defun decknix-progress--adapter-jira (_conv-key)
  "Adapter: hub Jira tasks (global — included under every conv-key)."
  (decknix-progress--from-hub-jira))

(defun decknix-progress--adapter-prs (_conv-key)
  "Adapter: hub PRs (global — included under every conv-key)."
  (decknix-progress--from-hub-prs))

(defun decknix-progress-for-conv-key (conv-key)
  "Return the aggregated, attention-rolled-up progress for CONV-KEY.
Result is a plist:
  (:conv-key KEY :updated FLOAT-TIME :attention SYM :items LIST)
ITEMS preserves adapter order (TODO-stream first, then Jira, then PRs).
:attention is the rolled-up max across every item (and recursively
through children)."
  (let ((items nil))
    (dolist (fn decknix-progress-adapter-functions)
      (when (functionp fn)
        (let ((batch (condition-case err
                         (funcall fn conv-key)
                       (error
                        (message "decknix-progress: adapter %s: %s"
                                 fn err)
                        nil))))
          (when batch
            (setq items (append items batch))))))
    (let ((rolled 'none))
      (dolist (it items)
        (setq rolled
              (decknix-progress--attention-max
               rolled (decknix-progress--rollup-attention it))))
      (list :conv-key conv-key
            :updated (float-time)
            :attention rolled
            :items items))))

;; -- Persistence --
;;
;; Per-conv-key snapshots in ~/.config/decknix/agent-progress/<key>.json
;; plus a global index.json mapping every known conv-key to a small
;; summary record `{updated, count, attention}'.  PR 3 (sidebar) reads
;; the index for cheap badge rendering and only opens individual files
;; when the user expands a row.

(defvar decknix-progress--dir
  (expand-file-name "~/.config/decknix/agent-progress/")
  "Directory for per-conversation progress snapshots and the index.")

(defun decknix-progress--ensure-dir ()
  "Create `decknix-progress--dir' if missing."
  (unless (file-directory-p decknix-progress--dir)
    (make-directory decknix-progress--dir t)))

(defun decknix-progress--snapshot-path (conv-key)
  "Return the per-conv-key JSON path."
  (expand-file-name (format "%s.json" conv-key) decknix-progress--dir))

(defun decknix-progress--index-path ()
  "Return the global index path."
  (expand-file-name "index.json" decknix-progress--dir))

(defun decknix-progress--item-to-json (item)
  "Convert an ITEM plist (with nested :children/:links) to a JSON-able
hash table."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (kv '((:id . id) (:provider . provider)
                  (:title . title) (:url . url)
                  (:state . state) (:attention . attention)))
      (let ((v (plist-get item (car kv))))
        (when v
          (puthash (symbol-name (cdr kv))
                   (cond ((symbolp v) (symbol-name v))
                         (t v))
                   h))))
    (puthash "children"
             (vconcat (mapcar #'decknix-progress--item-to-json
                              (plist-get item :children)))
             h)
    (puthash "links"
             (vconcat
              (mapcar
               (lambda (l)
                 (let ((lh (make-hash-table :test 'equal)))
                   (dolist (kv '((:type . type) (:direction . direction)
                                 (:id . id) (:title . title)
                                 (:url . url)))
                     (let ((v (plist-get l (car kv))))
                       (when v
                         (puthash (symbol-name (cdr kv))
                                  (cond ((symbolp v) (symbol-name v))
                                        (t v))
                                  lh))))
                   lh))
               (plist-get item :links)))
             h)
    h))

(defun decknix-progress--persist (conv-key payload)
  "Write PAYLOAD (from `decknix-progress-for-conv-key') for CONV-KEY.
Updates both the per-conv snapshot and the global index."
  (decknix-progress--ensure-dir)
  (let* ((items (plist-get payload :items))
         (snapshot (make-hash-table :test 'equal)))
    (puthash "conv_key" conv-key snapshot)
    (puthash "updated" (plist-get payload :updated) snapshot)
    (puthash "attention"
             (symbol-name (or (plist-get payload :attention) 'none))
             snapshot)
    (puthash "items"
             (vconcat (mapcar #'decknix-progress--item-to-json items))
             snapshot)
    (let ((coding-system-for-write 'utf-8))
      (with-temp-file (decknix-progress--snapshot-path conv-key)
        (insert (json-serialize snapshot
                                :null-object :null
                                :false-object :false)))))
  (decknix-progress--update-index conv-key payload))

(defun decknix-progress--read-index ()
  "Return the global index hash table (creates an empty one if missing)."
  (let ((path (decknix-progress--index-path)))
    (if (file-exists-p path)
        (condition-case _err
            (with-temp-buffer
              (insert-file-contents path)
              (json-parse-buffer
               :object-type 'hash-table
               :array-type 'list
               :null-object nil
               :false-object nil))
          (error (make-hash-table :test 'equal)))
      (make-hash-table :test 'equal))))

(defun decknix-progress--update-index (conv-key payload)
  "Update the global index entry for CONV-KEY from PAYLOAD."
  (decknix-progress--ensure-dir)
  (let* ((idx (decknix-progress--read-index))
         (entry (make-hash-table :test 'equal))
         (items (plist-get payload :items)))
    (puthash "updated" (plist-get payload :updated) entry)
    (puthash "count" (length items) entry)
    (puthash "attention"
             (symbol-name (or (plist-get payload :attention) 'none))
             entry)
    (puthash conv-key entry idx)
    (let ((coding-system-for-write 'utf-8))
      (with-temp-file (decknix-progress--index-path)
        (insert (json-serialize idx
                                :null-object :null
                                :false-object :false))))))

(defun decknix-progress-refresh-conv-key (conv-key)
  "Recompute and persist the progress snapshot for CONV-KEY.
Returns the payload (same shape as `decknix-progress-for-conv-key')."
  (when (and conv-key (not (string-empty-p conv-key)))
    (let ((payload (decknix-progress-for-conv-key conv-key)))
      (decknix-progress--persist conv-key payload)
      payload)))

(defun decknix-progress-refresh-all ()
  "Recompute and persist progress snapshots for every known conv-key.
Walks `decknix--agent-tags-conversations' so adapters that ignore the
key (PRs/Jira) still get included under each conversation's snapshot."
  (let* ((store (when (fboundp 'decknix--agent-tags-read)
                  (decknix--agent-tags-read)))
         (convs (when store
                  (decknix--agent-tags-conversations store))))
    (when (hash-table-p convs)
      (maphash (lambda (k _v)
                 (decknix-progress-refresh-conv-key k))
               convs))))


(provide 'decknix-progress)
;;; decknix-progress.el ends here
