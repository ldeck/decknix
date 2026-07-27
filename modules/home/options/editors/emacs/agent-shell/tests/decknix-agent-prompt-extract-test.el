;;; decknix-agent-prompt-extract-test.el --- Tests for prompt extractor -*- lexical-binding: t -*-

;; Author: decknix
;; Maintainer: decknix
;; Package-Requires: ((emacs "29.1") (decknix-agent-prompt-extract "0.1"))
;; Keywords: decknix, tests

;;; Commentary:
;;
;; ERT characterisation tests for `decknix--prompt-extract-from-file'
;; and the `decknix--prompt-extract-ensure-jq-filter' filter-cache
;; helper (carved from `decknix-agent-shell-main' / main-bulk).
;;
;; The extractor shells out to jq; tests run only when `jq' is on
;; PATH so the build remains green on minimal CI images that lack
;; it.  When jq is present, fixtures stage real session-shaped JSON
;; under a tmp file so we exercise the full shell + parse path
;; instead of mocking it away.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'decknix-agent-prompt-extract)

(defun decknix-agent-prompt-extract-test--jq-available-p ()
  "Return non-nil when `jq' is on PATH."
  (executable-find "jq"))

(defmacro decknix-agent-prompt-extract-test--with-fixture
    (json-string var-name &rest body)
  "Stage JSON-STRING in a tmp file, bind VAR-NAME to the path, run BODY.
Caller is expected to issue its own `skip-unless' for jq presence."
  (declare (indent 2))
  `(let ((,var-name (make-temp-file "decknix-prompt-" nil ".json")))
     (unwind-protect
         (progn
           (with-temp-file ,var-name (insert ,json-string))
           ,@body)
       (when (file-exists-p ,var-name) (delete-file ,var-name)))))

;; -- ensure-jq-filter ---------------------------------------------

(ert-deftest decknix-agent-prompt-extract/ensure-creates-and-caches ()
  "First call writes a tmp .jq file; second call returns the same path."
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (let ((p1 (decknix--prompt-extract-ensure-jq-filter)))
      (should (stringp p1))
      (should (file-exists-p p1))
      (should (string-suffix-p ".jq" p1))
      (let ((p2 (decknix--prompt-extract-ensure-jq-filter)))
        (should (equal p1 p2)))
      (delete-file p1))))

(ert-deftest decknix-agent-prompt-extract/ensure-rewrites-when-deleted ()
  "If the cached jq file is gone, ensure rewrites it (tmp cleanup safety)."
  (let* ((decknix--prompt-extract-jq-filter-file nil)
         (p1 (decknix--prompt-extract-ensure-jq-filter)))
    (delete-file p1)
    (let ((p2 (decknix--prompt-extract-ensure-jq-filter)))
      (should (file-exists-p p2))
      (delete-file p2))))

(ert-deftest decknix-agent-prompt-extract/filter-content-shape ()
  "Filter file body emits a reversed array of non-empty request_messages."
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (let* ((path (decknix--prompt-extract-ensure-jq-filter))
           (body (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string))))
      (should (string-match-p "\\.chatHistory\\[\\]" body))
      (should (string-match-p "request_message" body))
      (should (string-match-p "select(length > 0)" body))
      (should (string-match-p "reverse" body))
      (delete-file path))))

;; -- extract-from-file --------------------------------------------

(ert-deftest decknix-agent-prompt-extract/missing-file-returns-nil ()
  "A non-existent path yields nil rather than an error."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (should (null (decknix--prompt-extract-from-file
                   "/tmp/decknix-prompt-extract-does-not-exist.json")))))

(ert-deftest decknix-agent-prompt-extract/empty-history-returns-nil ()
  "Empty chatHistory yields a `[]' jq result -> nil after seq-filter."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (decknix-agent-prompt-extract-test--with-fixture
        "{\"chatHistory\":[]}" file
      (should (null (decknix--prompt-extract-from-file file))))))

(ert-deftest decknix-agent-prompt-extract/returns-prompts-newest-first ()
  "Real chat history -> only non-empty user prompts, newest first."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (decknix-agent-prompt-extract-test--with-fixture
        "{\"chatHistory\":[
           {\"exchange\":{\"request_message\":\"first\",\"response_text\":\"r1\"}},
           {\"exchange\":{\"request_message\":\"\",\"response_text\":\"chunk\"}},
           {\"exchange\":{\"request_message\":\"second\",\"response_text\":\"r2\"}},
           {\"exchange\":{\"request_message\":\"third\",\"response_text\":\"r3\"}}
         ]}" file
      (let ((msgs (decknix--prompt-extract-from-file file)))
        (should (equal '("third" "second" "first") msgs))))))

(ert-deftest decknix-agent-prompt-extract/filters-blank-strings ()
  "Whitespace-only request_messages are dropped by the seq-filter pass."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (decknix-agent-prompt-extract-test--with-fixture
        "{\"chatHistory\":[
           {\"exchange\":{\"request_message\":\"keep-me\"}},
           {\"exchange\":{\"request_message\":\"   \"}},
           {\"exchange\":{\"request_message\":\"\\t\\n\"}}
         ]}" file
      (let ((msgs (decknix--prompt-extract-from-file file)))
        (should (equal '("keep-me") msgs))))))

(ert-deftest decknix-agent-prompt-extract/missing-request-message-treated-as-empty ()
  "Entries lacking the field are coerced to \"\" by jq's `// \"\"' default."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (decknix-agent-prompt-extract-test--with-fixture
        "{\"chatHistory\":[
           {\"exchange\":{\"response_text\":\"only-resp\"}},
           {\"exchange\":{\"request_message\":\"survives\"}}
         ]}" file
      (let ((msgs (decknix--prompt-extract-from-file file)))
        (should (equal '("survives") msgs))))))

(ert-deftest decknix-agent-prompt-extract/malformed-json-returns-nil ()
  "jq fails on malformed JSON; the wrapper swallows it and returns nil."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (let ((decknix--prompt-extract-jq-filter-file nil))
    (decknix-agent-prompt-extract-test--with-fixture
        "{not valid json" file
      (should (null (decknix--prompt-extract-from-file file))))))

;; -- hexagonal: adapter dispatch (pure) ---------------------------

(ert-deftest decknix-agent-prompt-extract/adapter-dispatch ()
  "Provider-id selects the adapter; unknown / nil fall back to auggie."
  (should (eq #'decknix--prompt-extract-claude
              (decknix--prompt-extract-adapter 'claude-code)))
  (should (eq #'decknix--prompt-extract-auggie
              (decknix--prompt-extract-adapter 'auggie)))
  ;; no adapter registered yet -> auggie default (safe, yields nil)
  (should (eq #'decknix--prompt-extract-auggie
              (decknix--prompt-extract-adapter 'pi)))
  (should (eq #'decknix--prompt-extract-auggie
              (decknix--prompt-extract-adapter nil))))

;; -- hexagonal: NDJSON parsing (pure) -----------------------------

(ert-deftest decknix-agent-prompt-extract/ndjson-parse-strings ()
  "Parse keeps non-blank strings in input order; drops blanks/non-strings."
  (should (equal '("a" "b")
                 (decknix--prompt-extract-parse-ndjson-strings
                  "\"a\"\n\"\"\n\"   \"\n\"b\"\n{\"x\":1}\nnot-json")))
  (should (null (decknix--prompt-extract-parse-ndjson-strings "")))
  (should (null (decknix--prompt-extract-parse-ndjson-strings nil))))

;; -- claude adapter + port dispatch (jq) --------------------------

(ert-deftest decknix-agent-prompt-extract/claude-adapter-jsonl ()
  "Claude adapter extracts user prompts (string + text-array) newest-first,
dropping assistant lines and tool-result-only user messages."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (decknix-agent-prompt-extract-test--with-fixture
      (concat
       "{\"type\":\"user\",\"message\":{\"content\":\"first\"}}\n"
       "{\"type\":\"assistant\",\"message\":{\"content\":\"reply\"}}\n"
       "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"second\"}]}}\n"
       "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"out\"}]}}\n"
       "{\"type\":\"user\",\"message\":{\"content\":\"third\"}}\n")
      file
    (should (equal '("third" "second" "first")
                   (decknix--prompt-extract-claude file)))))

(ert-deftest decknix-agent-prompt-extract/port-dispatches-to-claude ()
  "The port routes provider `claude-code' through the claude adapter."
  (skip-unless (decknix-agent-prompt-extract-test--jq-available-p))
  (decknix-agent-prompt-extract-test--with-fixture
      "{\"type\":\"user\",\"message\":{\"content\":\"only\"}}\n"
      file
    (should (equal '("only")
                   (decknix--prompt-extract-from-file file 'claude-code)))))

(provide 'decknix-agent-prompt-extract-test)
;;; decknix-agent-prompt-extract-test.el ends here
