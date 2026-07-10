# Agent Guidelines (User-level)

These rules apply globally across ALL workspaces. Workspace-level
AGENTS.md files may add project-specific rules but should not need
to repeat these.

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
