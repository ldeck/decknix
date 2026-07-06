# Foundation (Layer 1)

The foundation layer provides the core shell infrastructure that everything else builds on.

## Core Components

### shell-maker

The underlying comint-like buffer management library. Handles prompt rendering, input submission, scroll behaviour, and process lifecycle. Agent Shell inherits its robust terminal semantics.

### ACP (Augment Code Protocol)

The `acp` package implements the wire protocol between Emacs and the `auggie` CLI. Unlike HTTP-based integrations, ACP runs auggie as a subprocess — no server, no ports, no latency.

### agent-shell.el

The main interface package. Provides:
- Agent configuration and model selection
- Session lifecycle (start, interrupt, rename)
- Mode-line status display
- Buffer management

## Tiered Package Sourcing

Packages are sourced from the most stable channel available:

```
Priority 1: stable nixpkgs     → (nothing currently — all are too new)
Priority 2: unstable nixpkgs   → shell-maker, acp, agent-shell
Priority 3: custom derivations → agent-shell-manager, workspace, attention
```

Custom derivations use `trivialBuild` with pinned GitHub revisions and hashes:

```nix
agent-shell-manager-el = pkgs.emacsPackages.trivialBuild {
  pname = "agent-shell-manager";
  version = "0-unstable-2026-03-17";
  src = pkgs.fetchFromGitHub {
    owner = "jethrokuan";
    repo = "agent-shell-manager";
    rev = "53b73f1...";
    hash = "sha256-JPB/OnOhYbM0LMirSYQhpB6hW8SAg0Ri6buU8tMP7rA=";
  };
  packageRequires = [ agent-shell ];
};
```

As packages mature into nixpkgs, they'll migrate up the priority chain automatically.

## Default Behaviour

| Setting | Value | Why |
|---------|-------|-----|
| `agent-shell-preferred-agent-config` | `'auggie` | Skip agent selection prompt |
| `agent-shell-session-strategy` | `'new` | Always start fresh; session management via our picker |
| `agent-shell-header-style` | `'text` | Model/mode in mode-line, not graphical header |
| `agent-shell-show-session-id` | `t` | Show session ID for resume/history |

## Welcome Message

Every new session displays a custom welcome with a quick-reference keybinding card:

```
Welcome to Auggie (opus4.6, agent mode)
────────────────────────────────────────────────────
 Quick Reference

  C-c e     Compose     Open multi-line prompt editor
  C-c s     Sessions    Pick / resume / start session
  C-c q     Quit        Save and quit session
  C-c h     History     View conversation history
  C-c t t   Template    Insert a prompt template
  C-c c c   Command     Pick & insert a slash command
  C-c T t   Tag         Tag this session
  C-c T l   By tag      Filter sessions by tag
  C-c ?     Help        Full keybinding reference
────────────────────────────────────────────────────
```

The welcome is implemented as an `:override` advice on `agent-shell-auggie--welcome-message`, preserving the original auggie welcome while appending the reference card.

## Nix Options

```nix
programs.emacs.decknix.agentShell.enable = true;  # Enable the entire ecosystem
```

Disabling this single option removes all agent-shell packages and configuration.

## Model Selection

This section covers **Auggie**, whose model is fully driven by decknix
(default, per-quickaction, and per-conversation override re-applied on
resume). Claude and Pi select models differently — see
[Model selection by agent](productivity.md#model-selection-by-agent).

Auggie exposes several model families.  The framework default is
`prism-a` — Augment's hybrid router that mixes Opus 4.7, Sonnet 4.6,
and Gemini Flash per turn (around 28 % cheaper than uniform Opus 4.7
on review-shaped workloads without losing depth where it matters).

### Recommended Models by Task

| Task                                  | Recommended | Why |
|---------------------------------------|-------------|-----|
| PR review (`/review-service-pr`)      | `prism-a`   | Router picks Opus on hard diffs, cheaper models on skim — best $/quality tradeoff. |
| Implementation against a defined spec | `sonnet4.6` | Mechanical work doesn't need flagship reasoning; ~46 % cheaper than Opus. |
| Debugging in a familiar codebase      | `sonnet4.6` | Same — context is local, reasoning is bounded. |
| Architecture / planning               | `opus4.7`   | Long-horizon reasoning, opinionated codegen — earns its 167 % credit cost. |
| Triage / classification               | `haiku4.5`  | ~33 % credit cost; fine for short, well-bounded prompts. |
| Framework iteration (decknix)         | `prism-a`   | Varied workload — let the router pick. |

### Override Levers

Three layers, narrowest wins:

1. **Per-session** — `C-c C-v` inside any agent-shell buffer picks a
   model for the running conversation; persisted in
   `~/.config/decknix/agent-sessions.json` and re-applied on resume.
   This is the right lever for one-off task adjustments.  The
   persistence works for **every** provider; only the resume mechanism
   differs — Auggie pins it at launch via `--model <id>`, while
   Claude/Pi (which take no model launch flag) replay it over ACP
   (`session/set_model`) once the resumed session reports ready.  See
   [Model selection by agent](productivity.md#model-selection-by-agent).
2. **Per-purpose (Nix)** —
   `programs.emacs.decknix.agentShell.purposes.<name>.{provider,model,mode}`
   pins the **provider**, **model**, and permission **mode** for every
   launch of a given purpose.  Three purposes ship today:
   - `pr-review` — human-authored PR review (`C-c A c r`, sidebar
     Requests row, batch processor).  Default: `provider =
     "claude-code"`, `model = "sonnet"`, `mode = "auto"`.
   - `bot-pr-review` — PR whose author is a bot (auto-dispatched via
     the `A` auto-review toggle, or matched by author heuristic).
     Default: `provider = "claude-code"`, `model = "sonnet"`, `mode =
     "auto"` — `sonnet` rather than the cheapest tier because an
     unattended `auto` review needs a model that honours `auto`.
   - `new-session` — interactive / QUICK `C-c A n`.  Default: `provider
     = "claude-code"`, `model = null`, `mode = "auto"`.  Its `provider`
     also feeds `decknix-agent-default-provider`.

   Example — pin PR reviews to Claude with opus for depth, route bot
   diffs to the cheaper haiku on the same provider, and start new
   sessions in `auto`:

   ```nix
   programs.emacs.decknix.agentShell.purposes = {
     pr-review     = { provider = "claude-code"; model = "opus"; mode = "auto"; };
     bot-pr-review = { provider = "claude-code"; model = "haiku"; mode = "auto"; };
     new-session   = { provider = "claude-code"; mode = "auto"; };
   };
   ```

   Set `model = null` to defer to the provider's own default (no
   `--model` flag is added and no ACP replay runs).  Values are
   validated at daemon start: an unknown provider coerces to
   `decknix-agent-default-provider`, and an unknown model drops to
   `nil`; both cases log a warning to `*Warnings*`.

3. **Framework default** — `decknix.cli.auggie.settings.model` is
   written to `~/.augment/settings.json` and used when no `--model`
   flag is supplied.  Org and personal layers can override with
   `lib.mkDefault` or plain assignment.  Framework defaults for
   Claude / Pi are provider-native — see [Model selection by
   agent](productivity.md#model-selection-by-agent).

Per-conversation overrides set via `C-c C-v` always win over the
purpose and framework defaults.  On resume the persisted model is
re-applied automatically: for Auggie it flows through
`decknix--resume-command-build` and is appended to the ACP command as
`--model <id>`; for Claude/Pi it is replayed over ACP
(`session/set_model`) by `decknix--agent-model-replay-on-ready` after
the session reports ready.

Purposes that are **not** pinned via Nix (interactive `C-c A n`, fork,
worktree `w s`) keep `decknix-agent-default-provider` with no model
pin — they use the provider's own default until you make a
per-session choice with `C-c C-v`.

### Permission mode

The session **permission mode** follows the same narrowest-wins
hierarchy as the model, on providers that expose it (today Claude,
whose modes are `default`, `auto`, `acceptEdits`, `bypassPermissions`,
and `plan`):

1. **Per-session** — `C-c C-m` inside any agent-shell buffer switches
   the running conversation's mode; the choice is persisted in
   `~/.config/decknix/agent-sessions.json` and **re-applied on both
   resume and fork**, so a session left in `auto` doesn't fall back to
   per-command permission prompts when you return to it.
2. **Per-purpose (Nix)** — `purposes.<name>.mode` seeds the mode for
   new launches of that purpose.  `new-session.mode` (default `"auto"`)
   is what fresh `C-c A n` sessions start on, and it's the fallback for
   resume/fork when a conversation has no saved mode override.
3. **Provider default** — used when no purpose mode is set and the
   conversation has no override.

Providers without session modes (Auggie, Pi) ignore the mode entirely —
it can never break a launch.

