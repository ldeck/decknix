# Agent Guidelines (User-level)

These rules apply globally across ALL workspaces. Workspace-level
AGENTS.md files may add project-specific rules but should not need
to repeat these.

## Durable Knowledge — Config Over Memory

When you learn something worth remembering, encode the FIX in a place
that reproduces on a fresh machine — never in machine-local memory
files. This system is rebuilt from `decknix` / `decknix-config` via
`decknix switch`; anything under `~/.claude/**/memory/` (or similar
per-agent memory stores) is lost on reimage and is not version
controlled.

1. **Prefer a real fix over a note about the problem.** If a discovered
   issue has a code or config fix, make the fix. A memory entry that
   merely describes the issue is redundant once the fix lands.
2. **Choose the reproducible home** for durable knowledge, in order:
   a code/default change in `decknix` / `decknix-config`; a workspace
   `AGENTS.md`; this user-level guidelines file; a slash command or
   skill; or `settings.json` (permissions/env/hooks).
3. **Do not accumulate memory files.** Treat per-agent memory as a
   last resort for genuinely non-reproducible, session-spanning context
   only — and promote it into version-controlled config as soon as it
   is actionable. Do not create a memory file for anything that a repo,
   its AGENTS.md, git history, or a config default already records (or
   should record).

## Command Execution — Prefer Nix-managed Tools

This is a Nix-managed macOS system. All tooling is installed via Nix.

1. **Never hardcode paths** to system binaries. Do not use
   `/usr/bin/python3`, `/usr/local/bin/node`, or similar. Use bare
   command names (`python3`, `node`, `ruby`, `java`) and let the
   user's Nix-first PATH resolve them.
2. **The PATH order is**: `~/.nix-profile/bin` →
   `/run/current-system/sw/bin` → `/nix/var/nix/profiles/default/bin`
   → `/usr/local/bin` → `/usr/bin` → `/bin` → `/usr/sbin` → `/sbin`.
   Nix paths come first deliberately.
3. To verify which version will run: `which python3` or
   `command -v node`.
4. In generated Nix code (scripts, launchd services), pin to a
   specific Nix package: `${pkgs.python3}/bin/python3`.
5. **Exception**: `#!/usr/bin/env bash` shebangs are acceptable —
   this is the standard portable idiom.

## Secrets

- Store secrets as **raw `0600` files under the org's secrets dir**:
  `~/.config/decknix/<org>/secrets/<name>` (e.g.
  `~/.config/decknix/nurturecloud/secrets/jira-token`). The dir is `0700`.
- **Never** route a secret through Nix `home.file.text` / a `secrets.nix`
  string — that copies it into the world-readable `/nix/store`. A raw file
  is both un-committed and out of the store. Reference it by *path* from
  config (e.g. a wrapper that `cat`s the file at runtime); `~/.claude.json`
  env values are literal strings and cannot read a file.
- Secrets are never committed. `~/.config/decknix` is not a git repo; the
  bootstrap scripts **prompt** for each secret and place it, so a machine
  rebuild re-collects them.

## Code Review

When prompting a model (Opus/Sonnet) for code review, ask it to **report
everything with a severity/confidence rating and filter downstream** — do
NOT instruct "be conservative / only high-severity". Recall-suppressing
framing measurably lowers bug-finding on current models; a missed bug costs
more than triaging an extra low-severity note.

## Response Formatting in Agent Shell

You are running inside an Emacs agent-shell — a comint buffer that
displays text as-is.  Markdown syntax is NOT rendered.  `**bold**`
shows literal asterisks; `| a | b |` table rows show literal pipes;
`# heading` shows a literal hash mark.

### HARD RULE — MUST NOT emit XML tool-call markup in chat

Do NOT narrate planned tool calls as XML in conversational responses.
Text like `<parallel_tool_calls>`, `<tool_call>`, `<str_replace_editor>`,
`<past_tool_call>`, or any other angle-bracket pseudo-invocation must
NEVER appear in the chat output.  If you intend to call tools, call
them natively — do not describe the calls as text first.

This failure mode occurs when a model "previews" its plan rather than
executing it.  The correct behaviour is to execute tool calls immediately
and then summarise what was done in plain prose, with no XML visible.

### HARD RULE — MUST NOT emit markdown tables in chat

Do NOT use pipe-delimited tables (`| col | col |`) or markdown
header-separator rows (`| --- | --- |`) in conversational
responses.  They render as a wall of pipes and dashes that is
actively unreadable inside the comint buffer.

Wrong (do NOT send this):

    | Key     | Action                   |
    | ------- | ------------------------ |
    | C-c A s | Open the session picker  |
    | C-c A n | Create a new session     |
    | C-c A q | Quit the current session |

Right (send this instead — space-aligned columns):

    Key       Action
    -------   ------------------------
    C-c A s   Open the session picker
    C-c A n   Create a new session
    C-c A q   Quit the current session

Pad cells with spaces so column starts line up vertically.  The
dashed separator row is optional; what matters is that the
columns align without pipe characters.

Markdown remains correct on surfaces that render it:

  - Files you create or edit (`*.md`, `*.mdx`)
  - Pull request descriptions, issue bodies, commit messages
  - Any tool input that explicitly accepts markdown

For conversational responses in the agent-shell, use plain text
formatted by alignment, not by syntax.

1. **No markdown emphasis in chat.**  Do not use `**bold**`,
   `*italic*`, or `__underline__` — they appear as literal
   characters.  Use prefix labels (`Note:`, `Warning:`) or sentence
   structure to carry emphasis instead.

2. **Tables — space-aligned columns, not pipes.**  See the HARD
   RULE above.  Never emit `| col | col |` rows in chat.

3. **Lists — plain dashes or numbers.**  `- item` and `1. item`
   read naturally as plain text and are fine.  Skip nested
   `**bold**` markers inside bullets.
