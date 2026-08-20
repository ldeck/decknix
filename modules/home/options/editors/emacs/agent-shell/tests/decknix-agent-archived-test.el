;;; decknix-agent-archived-test.el --- Tests for archived-session picker -*- lexical-binding: t -*-

(require 'ert)
(require 'decknix-agent-archived)

(ert-deftest decknix-agent-archived-first-line-picks-first-nonblank ()
  "Leading blank lines are skipped; the first non-blank line is trimmed."
  (should (equal (decknix-agent-archived--first-line "\n\n  hello world  \nsecond")
                 "hello world"))
  (should (equal (decknix-agent-archived--first-line "") ""))
  (should (equal (decknix-agent-archived--first-line nil) "")))

(ert-deftest decknix-agent-archived-first-line-truncates-with-ellipsis ()
  "Lines longer than WIDTH are truncated and gain a single ellipsis char."
  (let ((out (decknix-agent-archived--first-line "abcdefghij" 5)))
    (should (= (length out) 5))
    (should (string-suffix-p "…" out))
    (should (equal out "abcd…"))))

(ert-deftest decknix-agent-archived-workspace-name-is-final-segment ()
  (should (equal (decknix-agent-archived--workspace-name "/Users/x/Code/nurturecloud/metabase")
                 "metabase"))
  (should (equal (decknix-agent-archived--workspace-name "/Users/x/Code/nurturecloud/metabase/")
                 "metabase"))
  (should (equal (decknix-agent-archived--workspace-name nil) ""))
  (should (equal (decknix-agent-archived--workspace-name "") "")))

(ert-deftest decknix-agent-archived-parse-maps-camelcase-keys ()
  "The list JSON is parsed into alists with normalised keys."
  (let* ((json "[{\"id\":\"abc123\",\"agent\":\"claude\",\"firstMessage\":\"hi there\",\"tags\":[\"a\",\"b\"],\"workspace\":\"/w/repo\",\"lastModified\":\"2026-08-01T00:00:00Z\"}]")
         (out (decknix-agent-archived--parse json))
         (e (car out)))
    (should (= (length out) 1))
    (should (equal (alist-get 'id e) "abc123"))
    (should (equal (alist-get 'agent e) "claude"))
    (should (equal (alist-get 'first-message e) "hi there"))
    (should (equal (alist-get 'tags e) '("a" "b")))
    (should (equal (alist-get 'workspace e) "/w/repo"))
    (should (equal (alist-get 'last-modified e) "2026-08-01T00:00:00Z"))))

(ert-deftest decknix-agent-archived-parse-tolerates-garbage ()
  "Malformed JSON yields nil, not an error."
  (should (null (decknix-agent-archived--parse "not json")))
  (should (null (decknix-agent-archived--parse ""))))

(ert-deftest decknix-agent-archived-parse-restore-single-object ()
  (let ((res (decknix-agent-archived--parse-restore
              "{\"id\":\"xyz\",\"provider\":\"auggie\",\"restoredPath\":\"/p/x.json\",\"workspace\":\"/w\"}")))
    (should (equal (alist-get 'id res) "xyz"))
    (should (equal (alist-get 'provider res) "auggie"))
    (should (equal (alist-get 'restored-path res) "/p/x.json"))
    (should (equal (alist-get 'workspace res) "/w"))))

(ert-deftest decknix-agent-archived-candidate-label-shape ()
  "The label carries date, agent tag, message snippet, tags, workspace, short id."
  (let* ((entry (list (cons 'id "abcd1234-5678")
                      (cons 'agent "claude")
                      (cons 'first-message "fix the thing\nmore")
                      (cons 'tags '("decknix" "cli"))
                      (cons 'workspace "/Users/x/tools/decknix")
                      (cons 'last-modified "2026-08-01T12:00:00Z")))
         (label (decknix-agent-archived--candidate-label entry)))
    (should (string-prefix-p "2026-08-01 " label))
    (should (string-match-p "\\[claude\\]" label))
    (should (string-match-p "fix the thing" label))
    (should (string-match-p "#decknix,cli" label))
    (should (string-match-p "decknix" label))
    (should (string-suffix-p "(abcd1234)" label))
    ;; single line
    (should-not (string-match-p "\n" label))))

(ert-deftest decknix-agent-archived-candidate-label-handles-missing-fields ()
  "Absent tags/workspace/message/date degrade gracefully."
  (let ((label (decknix-agent-archived--candidate-label
                (list (cons 'agent "pi") (cons 'id "zz")))))
    (should (string-match-p "\\[pi\\]" label))
    (should (string-prefix-p "----------" label)) ; placeholder date
    (should-not (string-match-p "#" label))
    (should (string-suffix-p "(zz)" label))))

(ert-deftest decknix-agent-archived-labels-unique-despite-identical-content ()
  "Entries identical except for id must produce DISTINCT labels, so `assoc'
in the picker can reach each one (the 48-resume thread failure mode)."
  (let* ((base (list (cons 'agent "auggie")
                     (cons 'first-message "We currently have a fairly stable installation")
                     (cons 'tags nil)
                     (cons 'workspace "/Users/x")
                     (cons 'last-modified "2026-06-01T00:00:00Z")))
         (a (cons (cons 'id "aaaaaaaa-1") base))
         (b (cons (cons 'id "bbbbbbbb-2") base)))
    (should-not (equal (decknix-agent-archived--candidate-label a)
                       (decknix-agent-archived--candidate-label b)))))

(ert-deftest decknix-agent-archived-sort-most-recent-first ()
  "Entries sort by last-modified descending, without mutating the input."
  (let* ((input (list (list (cons 'id "old") (cons 'last-modified "2026-01-01"))
                      (list (cons 'id "new") (cons 'last-modified "2026-08-01"))
                      (list (cons 'id "mid") (cons 'last-modified "2026-05-01"))))
         (sorted (decknix-agent-archived--sort input)))
    (should (equal (mapcar (lambda (e) (alist-get 'id e)) sorted)
                   '("new" "mid" "old")))
    ;; original order preserved (copy-sequence, not in-place)
    (should (equal (alist-get 'id (car input)) "old"))))

;;; decknix-agent-archived-test.el ends here
