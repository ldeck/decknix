;;; decknix-board-fixture.el --- A hackathon repo as `gh api graphql --jq' prints it -*- lexical-binding: t -*-

;;; Commentary:
;;
;; What `decknix-board-github--list-argv' returns from GitHub for a small
;; hackathon repository: one shaped issue per line, keys sorted as gh
;; prints them.  The shape was taken from a real run against a public
;; repository; the issues are invented so the tree has every level (goal,
;; epic, story, task, subtask), a closed item, a linked draft PR, an item
;; typed only by GitHub's issue type, and one issue outside the goal.

;;; Code:

(defconst decknix-board-test-github-ndjson
  (mapconcat
   #'identity
   '("{\"assignees\":[],\"body\":\"Coordinate agent sessions on one board.\\r\\n\\r\\nDone when a team can run a hackathon from it.\",\"id\":\"I_kwDOAAAA01\",\"issueType\":null,\"labels\":[\"type:goal\"],\"number\":1,\"parent\":null,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":2,\"title\":\"Hackathon: boards for agent teams\",\"url\":\"https://github.com/acme/hack-boards/issues/1\"}"
     "{\"assignees\":[\"ldeck\"],\"body\":\"The buffer people look at.\",\"id\":\"I_kwDOAAAA02\",\"issueType\":null,\"labels\":[\"type:epic\"],\"number\":2,\"parent\":1,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":1,\"title\":\"Board UI\",\"url\":\"https://github.com/acme/hack-boards/issues/2\"}"
     "{\"assignees\":[],\"body\":\"\",\"id\":\"I_kwDOAAAA03\",\"issueType\":null,\"labels\":[\"type:epic\",\"backend\"],\"number\":3,\"parent\":1,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":1,\"title\":\"Backends\",\"url\":\"https://github.com/acme/hack-boards/issues/3\"}"
     "{\"assignees\":[\"ldeck\",\"ye\"],\"body\":\"Render goal, epics and stories as a foldable tree.\",\"id\":\"I_kwDOAAAA04\",\"issueType\":null,\"labels\":[\"type:story\"],\"number\":4,\"parent\":2,\"prs\":[{\"isDraft\":true,\"number\":20,\"state\":\"OPEN\",\"url\":\"https://github.com/acme/hack-boards/pull/20\"}],\"state\":\"OPEN\",\"subDone\":1,\"subTotal\":1,\"title\":\"Render the tree\",\"url\":\"https://github.com/acme/hack-boards/issues/4\"}"
     "{\"assignees\":[],\"body\":\"\",\"id\":\"I_kwDOAAAA05\",\"issueType\":null,\"labels\":[\"type:task\"],\"number\":5,\"parent\":4,\"prs\":[{\"isDraft\":false,\"number\":21,\"state\":\"MERGED\",\"url\":\"https://github.com/acme/hack-boards/pull/21\"}],\"state\":\"CLOSED\",\"subDone\":0,\"subTotal\":1,\"title\":\"Fold rows\",\"url\":\"https://github.com/acme/hack-boards/issues/5\"}"
     "{\"assignees\":[],\"body\":\"\",\"id\":\"I_kwDOAAAA06\",\"issueType\":null,\"labels\":[\"type:subtask\"],\"number\":6,\"parent\":5,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":0,\"title\":\"TAB folds\",\"url\":\"https://github.com/acme/hack-boards/issues/6\"}"
     "{\"assignees\":[],\"body\":\"\",\"id\":\"I_kwDOAAAA07\",\"issueType\":\"Feature\",\"labels\":[],\"number\":7,\"parent\":3,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":0,\"title\":\"Jira backend\",\"url\":\"https://github.com/acme/hack-boards/issues/7\"}"
     "{\"assignees\":[],\"body\":\"Noticed while demoing.\",\"id\":\"I_kwDOAAAA08\",\"issueType\":null,\"labels\":[\"type:task\"],\"number\":8,\"parent\":null,\"prs\":[],\"state\":\"OPEN\",\"subDone\":0,\"subTotal\":0,\"title\":\"Stray fix\",\"url\":\"https://github.com/acme/hack-boards/issues/8\"}")
   "\n")
  "Shaped issues of acme/hack-boards, one JSON object per line.")

(provide 'decknix-board-fixture)
;;; decknix-board-fixture.el ends here
