# Pair Protocol v1 (draft)

> Status: **draft / pre-implementation**.
> Reference implementation: [`UpsideRealty/experiment-ai-pairing`](https://github.com/UpsideRealty/experiment-ai-pairing) (not yet created at time of writing).
> Last updated: 2026-05-29.

A protocol for multi-human and multi-agent collaborative sessions layered on
top of an agent shell. Designed to be incrementally implementable, mode-
switchable, and tolerant of mixed clients (Emacs, web, MCP, CLI, Slack).

This document is the design reference; the implementation is owned by the
experiment repository above and may diverge ahead of doc updates while the
project is still in its early phases. Where the two disagree, the
implementation wins and a doc PR should follow.

## 1. Goals and non-goals

### Goals

- Multi-seat sessions where each seat is a `(participant, role)` pair; role
  is `human` or `agent`.
- Mode-switchable governance — conversational today, driver/multi-driver
  later — without protocol breaks.
- Two transcript surfaces: a **live** transcript over WebSocket/SSE, and a
  **long-lived** transcript mirrored to a Slack private channel.
- A first-class **artifact** model — specs, scopes, contracts, architectures
  — persisted to a durable backend (GCS by default; adapters for Slack,
  Google Drive, filesystem, git).
- An explicit **promote** action that takes finished artifacts and opens a
  draft pull request against the relevant code repository, with a polite
  request for `augmentcode` review baked into the workflow.
- Zero-config join for MCP-capable agents; a thin CLI for everyone else.
- Strong audit: every action attributable to a seat, every tool call logged.

### Non-goals (v1)

- External (non-staff) participants. Tailnet-only access in P1; Cloudflare
  Access can be added later if the need arises.
- A fully merged "drive my keyboard" remote-control experience. The
  protocol reserves driver modes but P1 ships conversational only.
- Replacing existing chat or code review tooling. Slack remains the human
  mirror; GitHub remains the code review surface.

## 2. Core concepts

### 2.1 Sessions and seats

A **session** is an addressable, time-bounded room with a unique id
(`ses_<ULID>`). It has:

- a **host** (the human who created it, holds admin rights in v1);
- zero or more additional **seats**, each `(participant_id, role)` where
  role is `human | agent`;
- a configured **mode** (see §2.3);
- one or more configured **artifact stores** (see §5);
- an optional **Slack mirror channel** (see §4.3);
- an optional **repo alias map** for `promote` (see §6).

Seats are the unit of attribution: every event, message, and tool call
carries the originating `seat_id`, never just the participant.

### 2.2 Participants

A **participant** is the identity behind a seat — a Slack user for humans,
or a named agent registration for agents (e.g. `alice/agent`, where the
agent runs on Alice's behalf). Identity is resolved against the existing
Slack identity cache so the same human looks the same across Emacs, CLI,
and web clients.

### 2.3 Modes

| Mode               | v1 status | Behaviour                                                                                       |
| ------------------ | --------- | ----------------------------------------------------------------------------------------------- |
| `conversational`   | shipped   | All seats may speak; no exclusive driver; agent posts are throttled and addressed-only.         |
| `driver-single`    | reserved  | One driver seat; others are readers and may post questions only.                                |
| `driver-handoff`   | reserved  | Driver may pass control to another seat by explicit gesture.                                    |
| `multi-driver`     | reserved  | Multiple driver seats, admin-curated; readers may ask but not drive.                            |

Mode is a session-level property; switching modes is an admin-only event.
The wire protocol is identical across modes — only the policy gate (§7)
differs.

### 2.4 Transports

The session is exposed over four transports, all of which see the same
underlying event stream:

| Transport                   | Audience                                  |
| --------------------------- | ----------------------------------------- |
| **WebSocket** (live)        | Web UI, Emacs, CLI subscribers.           |
| **Server-Sent Events**      | Lightweight read-only browser clients.    |
| **MCP server (per session)**| Agents (Claude Desktop, Augment, etc.).   |
| **Slack mirror**            | Humans for long-lived browsable history.  |

All inbound writes (post a message, publish an artifact, request a
promotion) flow through the relay's policy gate before being broadcast.

## 3. Event envelope

Every event on the wire shares the same JSON envelope:

```jsonc
{
  "v": 1,
  "id": "evt_01J8A9X0M3T4VWQ0B1C2D3E4F5",  // ULID, server-assigned
  "ts": "2026-05-29T01:23:45.678Z",
  "session_id": "ses_01J7Z8KX4VFWQ0M9N6R2H3D8AB",
  "seat_id": "seat_01J7Z8L1...",
  "type": "message",                         // see §3.1
  "payload": { /* type-specific */ },
  "in_reply_to": "evt_..."                   // optional, for threading
}
```

The envelope is stable; `payload` shape is per `type`. Unknown types must
be tolerated by clients (forward-compatibility).


### 3.1 Event types

| Type                     | Purpose                                                                |
| ------------------------ | ---------------------------------------------------------------------- |
| `session_started`        | Session created; carries mode, host seat, configured stores.           |
| `seat_joined`            | New seat enters the session.                                           |
| `seat_left`              | Seat exits (voluntary or evicted).                                     |
| `mode_changed`           | Admin changed the session mode.                                        |
| `message`                | Free-form text from a seat. Markdown-flavoured plain text.             |
| `tool_call`              | An agent seat ran a tool (name, args, result-hash).                    |
| `flag`                   | A seat flagged a moment for human attention (e.g. a question).         |
| `artifact_published`     | A seat published or superseded a session artifact (§5).                |
| `promotion_requested`    | A seat asked to open a PR with one or more artifacts (§6).             |
| `promotion_completed`    | Promotion succeeded or failed; carries the PR URL on success.          |
| `auggie_review_requested`| Relay posted the `auggie review` comment on a promoted PR (§6.4).      |
| `auggie_review_settled`  | Augmentcode replied with feedback or "nothing to add" (§6.4).          |
| `pr_ready_for_review`    | A draft PR was flipped to ready for human review (§6.4).               |
| `policy_denied`          | A request was blocked by the policy gate; carries a reason code.       |
| `audit`                  | Auxiliary audit record (rate-limit hit, admin action, etc.).           |

New types may be added; clients ignore unknown types.

### 3.2 Persistence

The relay writes every event to an append-only JSONL transcript at
`~/.local/state/pair-relay/sessions/<session_id>.jsonl` (or the equivalent
on a VM). This is the canonical record. The Slack mirror and the
WebSocket fan-out are both derived views. Transcripts are **not**
committed to VCS; they live on disk and (optionally) in the Slack mirror.

## 4. Transports

### 4.1 WebSocket / SSE (live transcript)

- One WebSocket endpoint per session, served by the relay over Tailscale.
- Clients authenticate with a short-lived bearer token minted at invite
  time (see §8).
- Server pushes events as they happen; clients may post inbound events of
  type `message`, `flag`, `artifact_published`, `promotion_requested`.
- SSE is the read-only fallback for clients that can't open a WebSocket.

### 4.2 MCP (agent transport)

Each session exposes an MCP server at a session-specific URL. Agents
join by pasting the URL plus bearer token into their MCP client config.

Tools exposed (initial set):

| Tool                       | Effect                                                                                        |
| -------------------------- | --------------------------------------------------------------------------------------------- |
| `pair.subscribe`           | Begin receiving the live event stream.                                                        |
| `pair.get_transcript`      | Fetch the transcript (or a tail) for context.                                                 |
| `pair.post_message`        | Post a `message` event (subject to policy).                                                   |
| `pair.ask`                 | Post a `flag` event explicitly tagged as a question for humans.                               |
| `pair.who`                 | List current seats.                                                                           |
| `pair.publish_artifact`    | Upload bytes and emit `artifact_published`.                                                   |
| `pair.promote_artifact`    | Request a promotion (§6); subject to admin approval.                                          |

Agents must obey the policy gate (§7); the relay enforces it independent
of client co-operation.

### 4.3 Slack mirror (long-lived transcript)

When a Slack channel is bound at session creation, the relay mirrors a
**human-readable** subset of events into it:

- `message` (rendered with the seat as the author),
- `flag` (rendered as a quoted question with a notification ping),
- `artifact_published` (file upload with a link to the canonical store),
- `promotion_requested` / `promotion_completed` (PR link as a pinned
  message on completion),
- `auggie_review_settled` and `pr_ready_for_review` (status updates).

Tool calls and low-level audit events are **not** mirrored by default;
they remain in the JSONL transcript for forensic use.

Humans may type slash commands into the channel:

```
/pair flag <text>
/pair publish <name> <text>
/pair promote <artifact-ref> to <repo> [as <path>]
```

The Slack bot parses these, authenticates the user against the bound
session, and emits the corresponding event on their seat's behalf.

### 4.4 CLI (`pair`)

A thin Rust CLI for humans who prefer the terminal. Same operations as
the slash commands plus session lifecycle:

```
pair create [--mode conversational] [--mirror-channel <id>] [--store <kind>:<config>]
pair join <session-id>
pair say <text>
pair flag <text>
pair publish <file> [--name <name>] [--kind <kind>]
pair promote <artifact-ref>... --to <repo> [--as <path>] [--title <s>] [--draft]
pair list
pair watch <session-id>
```

The CLI talks to the relay over the same WebSocket endpoint as the web UI.


## 5. Artifacts and durable storage

### 5.1 What an artifact is

An **artifact** is a named, typed blob produced during a session — a
scope, a spec, a contract, an architecture sketch, sometimes a transcript
snapshot. Artifacts carry:

- `id` — opaque (`art_<ULID>`);
- `name` — human label, unique within a session;
- `kind` — `scope | spec | contract | architecture | transcript | other`;
- `bytes` — opaque content;
- `meta` — content_type, summary, publishing_seat, optional `supersedes`;
- `ref` — backend-opaque locator returned by the store.

Artifacts are explicitly **session outputs**, not conversation history.
They want durable, shareable, queryable storage — not git unless the
content is genuinely document-like and worth diffing.

### 5.2 The `ArtifactStore` port

The relay holds artifacts through a trait-shaped adapter:

```rust
trait ArtifactStore {
    async fn put(
        &self,
        session_id: &SessionId,
        name: &str,
        kind: ArtifactKind,
        bytes: &[u8],
        meta: ArtifactMeta,
    ) -> Result<ArtifactRef>;

    async fn get(&self, r: &ArtifactRef) -> Result<Vec<u8>>;
    async fn list(&self, session_id: &SessionId) -> Result<Vec<ArtifactRef>>;
    async fn url(&self, r: &ArtifactRef) -> Result<String>;
}
```

A session may configure one or more stores; the relay writes to all of
them in order on `put` and reads from the first that resolves on `get`.

### 5.3 Built-in adapters

| Adapter         | Backing                                | Fits when…                                                                  |
| --------------- | -------------------------------------- | --------------------------------------------------------------------------- |
| `gcs`           | Google Cloud Storage bucket            | Default for NurtureCloud. Versioned objects, IAM via corporate Google.      |
| `s3`            | AWS S3                                 | Same shape on AWS.                                                          |
| `slack`         | A bound channel; artifacts as uploads  | Lowest-friction for small/transient sessions.                               |
| `gdrive`        | A shared Drive folder                  | Non-engineer participants want preview + native sharing.                    |
| `fs`            | A local (possibly synced) directory    | Laptop relay; quick dev/test.                                               |
| `git`           | Any git repo                           | Opt-in when an artifact will evolve and benefits from named diffs.          |

The protocol is store-agnostic; sessions declare what they want:

```toml
[[artifact_store]]
kind   = "gcs"
bucket = "nc-pair-artifacts"
prefix = "<session_id>/"

# Optional second store, written in parallel for human convenience:
[[artifact_store]]
kind        = "slack"
channel_id  = "C0XXXXXXXXX"
```

### 5.4 Defaults for NurtureCloud sessions

- **Primary store**: `gcs` against a bucket like `nc-pair-artifacts`,
  object versioning on, lifecycle rule to move >90-day objects to colder
  storage.
- **Secondary store** (always on by default): the same Slack channel
  bound for the transcript mirror. The Slack message carries a link back
  to the canonical GCS object.
- **Filesystem fallback** is used when the relay runs in laptop mode
  without GCS credentials (see §10, Phase D1).

The Slack channel becomes the human-discoverable index; GCS is the
durable archive.

## 6. Promotion — opening a PR with finished artifacts

### 6.1 What promotion is

`promote` is the **explicit** gesture that takes one or more session
artifacts and opens a draft pull request against a real code repository.
It is the only protocol-defined integration between the pair tool and a
code repo; everything else stays out of VCS.

Conceptually:

```
promote(artifact_ids: [Id], target_repo: Repo, target_path: Path,
        branch?: String, title?: String, body?: String, draft?: bool = true)
  -> PullRequestRef
```

### 6.2 Surfaces

**Slash command** (web UI and Slack mirror):

```
/pair promote <artifact-ref> to <repo> [as <path>] [titled "..."] [--draft|--ready]
/pair promote @last to upside as docs/specs/pair-protocol.md
/pair promote @kind:spec to upside           # bulk by kind
/pair promote scope-pair-protocol-v1 to nct-public-api as docs/scopes/
```

Artifact refs accepted: `art_<ULID>`, name, `@last`, `@last:N`, `@all`,
`@kind:<kind>`.

**CLI**:

```
pair promote <ref>... --to <repo> [--as <path>] [--branch <name>] \
                      [--title "..."] [--body-from <file>] [--draft|--ready]
```

**MCP tool**: `pair.promote_artifact` (same shape as the CLI).

### 6.3 Per-session repo aliases

Sessions may declare friendly repo aliases at create time so `to upside`
resolves correctly:

```toml
[repos]
upside          = "UpsideRealty/upside"
nct-public-api  = "UpsideRealty/nct-public-api"
reinz           = "UpsideRealty/nct-provider-reinz-service"
experiment      = "UpsideRealty/experiment-ai-pairing"
```

Aliases are resolved against this map; fully-qualified `org/repo` is
always accepted.


### 6.4 The draft → augmentcode → ready workflow

Every promotion follows the same polite, reviewer-friendly loop. The tone
across all relay-authored comments is soft and collaborative: the relay
is asking for help, not issuing orders.

**Step 1 — open as draft.** Promotions default to `draft = true`. The
PR title is taken from `--title` or derived from the artifact name; the
body summarises which artifacts landed and links back to the session.

**Step 2 — invite augmentcode.** Immediately after the draft PR is open
(and again after every subsequent push to the PR's branch), the relay
posts an `auggie review` comment. The exact phrasing is fixed so
augmentcode picks it up reliably; surrounding text stays gentle:

```
Hi @augmentcode — when you have a moment, would you mind taking a look?

auggie review
```

The relay emits an `auggie_review_requested` event so the session sees
that review has been asked for.

**Step 3 — wait for augmentcode to settle.** The relay polls the PR for
new review comments from augmentcode until one of two terminal states is
reached:

- **Comments to consider.** Augmentcode left suggestions or questions.
  The relay emits `auggie_review_settled { state: "has_feedback" }`
  with a short summary plus a link to the review. The host or driver
  decides which to apply as fixes and which to politely decline (with
  a reply explaining the reasoning). After any fix is pushed, Step 2
  fires again.
- **Nothing to add.** Augmentcode replied that it has no further
  feedback. The relay emits `auggie_review_settled { state: "clean" }`
  and proceeds to Step 4.

**Step 4 — flip to ready.** Once augmentcode is clean, the relay marks
the PR ready for human review and emits `pr_ready_for_review`. The
Slack mirror posts the PR link with a brief, polite note such as:

```
This one is ready for human eyes when you have time — thank you!
```

The relay does **not** request specific human reviewers automatically;
that remains a host gesture (or a follow-up Slack post). Human reviewer
assignment via `--reviewer @handle` on the original `promote` is a
reserved future option.

**Tone rule.** All relay-generated PR text — bodies, comments, replies
to augmentcode — uses soft, collaborative language: "would you mind",
"happy to revise", "thanks for taking a look". No directive or
adversarial phrasing.

### 6.5 Commit and PR shape

Commits opened by the relay carry attribution trailers so the human and
the requesting seat are both visible:

```
Author:  Lachlan Deck <lachlan@nurturecloud.com>
Pair-Session: ses_01J7Z8KX4VFWQ0M9N6R2H3D8AB
Pair-Promoted-By: lachlan/human
Pair-Requested-By: alice/agent
Pair-Artifacts: art_01J7..., art_01J7...
```

Per workspace policy, the relay does **not** add `Co-authored-by:`
footers naming itself or augmentcode.

PR body skeleton:

```markdown
This PR promotes the following artifacts from pair session
[`ses_01J7Z8KX...`](relay-url):

- `scope-pair-protocol-v1.md` → `docs/scopes/pair-protocol-v1.md`
- `spec-pair-protocol-v1.md` → `docs/specs/pair-protocol-v1.md`

It is open as a draft so augmentcode can take a first pass; once that
review settles it will be flipped to ready.

Thanks for taking a look.
```

### 6.6 Credentials — phased

| Phase | Mechanism                                                                          | Notes                                                                  |
| ----- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| D1    | Relay shells out to the host's local `gh` CLI.                                     | Laptop mode only; reuses existing host auth; trivially safe.           |
| D2    | A GitHub App in the `UpsideRealty` org with `contents:write` and `pull_requests:write`. | Tailnet VM mode. App opens the PR; trailers credit the human + seat. |
| D3    | Same App with finer scopes; per-user OAuth for non-host promoters if needed.       | Only if external participants ever land.                               |

Start at D1. Migrate to D2 when the relay moves off the laptop.

### 6.7 Direct push for `experiment-` repos

For repositories whose name starts with `experiment-` (e.g.
`UpsideRealty/experiment-ai-pairing`), the relay accepts an additional
`--direct` flag on `promote` that commits straight to the repo's default
branch without opening a PR. This is reserved for the implementation
repo itself while it iterates rapidly. If the project graduates out of
`experiment-` status (rename) the flag stops being honoured.

`--direct` and `--draft` are mutually exclusive; `--direct` skips the
augmentcode loop entirely. The commit trailers and tone rules of §6.5
still apply.


## 7. Governance and policy gate

Every inbound write passes through the relay's **policy gate** before
being broadcast. The gate is the only enforcement boundary; clients are
not trusted.

### 7.1 Decisions

Per (action, mode, seat-role) the gate decides one of:

- `ALLOW` — broadcast and persist.
- `DEFER → host` — emit a `flag` to the host; broadcast only after the
  host's `pair admit` event.
- `DENY` — emit a `policy_denied` event with a reason code; do not
  broadcast.

### 7.2 Matrix (v1)

| Action / Mode                              | conversational | driver-single   | driver-handoff  | multi-driver    |
| ------------------------------------------ | -------------- | --------------- | --------------- | --------------- |
| `message` (human, non-driver)              | ALLOW          | ALLOW           | ALLOW           | ALLOW           |
| `message` (agent, addressed-to-it)         | ALLOW          | ALLOW           | ALLOW           | ALLOW           |
| `message` (agent, unaddressed)             | RATE-LIMITED   | DENY            | DENY            | RATE-LIMITED    |
| `flag` (any seat)                          | ALLOW          | ALLOW           | ALLOW           | ALLOW           |
| `artifact_published` (any seat)            | ALLOW          | DRIVER ONLY     | DRIVER ONLY     | DRIVER ONLY     |
| `promotion_requested` (host-human)         | ALLOW          | ALLOW           | ALLOW           | ALLOW           |
| `promotion_requested` (driver, any role)   | n/a            | DEFER → host    | DEFER → host    | DEFER → host    |
| `promotion_requested` (other seat / agent) | DEFER → host   | DEFER → host    | DEFER → host    | DEFER → host    |
| `mode_changed` (any seat)                  | HOST ONLY      | HOST ONLY       | HOST ONLY       | HOST ONLY       |
| `evict` / `admit`                          | HOST ONLY      | HOST ONLY       | HOST ONLY       | HOST ONLY       |

Admin actions (`mode_changed`, `evict`, `admit`, and approval of any
`DEFER → host` decision) are restricted to the **host-human seat** in
v1. A future toggle may relax this to designated admin seats.

### 7.3 Defaults that protect against agent noise

- **Agents default to "silent + addressed-only"**: an agent only posts
  when a `message` is addressed to its handle, or when its host has
  asked it to opine via `pair.post_message` with an explicit gesture.
- **Rate limits** per agent seat: at most one `message` per N seconds
  (configurable; default 5s), with bursts up to 3 events.
- **Loop guard** (§9) prevents agents from auto-responding to other
  agents' messages.

## 8. Identity, auth, and network perimeter

### 8.1 Identity

Humans authenticate against Slack OIDC; their Slack user id is the
canonical participant id. Agent participants register with a
relay-issued handle of the form `<human>/agent` (e.g. `alice/agent`) so
each agent is tied to a responsible human.

### 8.2 Tokens

Joining a session uses a short-lived bearer token (default TTL 24h)
minted by the relay at invite time. Tokens are scoped to a single
`(session_id, seat_id)` pair. The relay rotates the signing key on a
fixed cadence.

### 8.3 Network perimeter

| Phase | Exposure                            | Notes                                                      |
| ----- | ----------------------------------- | ---------------------------------------------------------- |
| D1    | `localhost` only (laptop launchd)   | Host uses the relay directly; no remote participants.      |
| D2    | Tailscale (tailnet members only)    | Default for in-team pairing. ACLs restrict to staff.       |
| D3    | Cloudflare Access in front of D2    | Only if external participants ever need to join.           |

P1 ships D1 with a clear migration path to D2.

## 9. Loop guard and rate limiting

Two relay-side mechanisms prevent agent storms:

1. **Loop guard.** An agent seat may not respond to a `message` whose
   originating seat is also an agent unless that message explicitly
   `@`-mentions the responding agent's handle. The gate enforces this
   independent of client co-operation.
2. **Token-bucket rate limiting.** Each agent seat has a bucket
   (default: 3 token capacity, refill 1 token every 5s). Exhausted
   buckets cause `message` events to be dropped with a `policy_denied`
   event of reason `rate_limited`.

Both can be tuned per-session by the host; sane defaults ship in P1.

## 10. Phasing and roadmap

### 10.1 Protocol phasing (P*)

| Phase | Scope                                                                                                                       | Target           |
| ----- | --------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| **P0**| This spec, repo bootstrap (`UpsideRealty/experiment-ai-pairing`), CI skeleton.                                              | This week.       |
| **P1**| Relay daemon (Rust), conversational mode only, JSONL transcript, WebSocket transport, single-host launchd, basic web UI.   | This week / next.|
| **P2**| Slack mirror, `GcsArtifactStore` + `FilesystemArtifactStore`, `publish_artifact`, MCP transport.                            | Next.            |
| **P3**| `pair` CLI parity with web UI; `slack` artifact adapter; identity polish.                                                   | Following.       |
| **P3.5**| `promote` command end-to-end, including the augmentcode review loop (§6.4). Starts on D1 credentials.                     | Following.       |
| **P4**| Driver modes (`driver-single`, `driver-handoff`), eviction, admin polish.                                                   | When wanted.     |
| **P5**| `multi-driver`, `gdrive` and `git` artifact adapters, optional Cloudflare exposure (D3).                                    | Later.           |

P1 is the smallest thing that lets two people pair through the relay in
conversational mode with a JSONL transcript on disk. Everything else
plugs in behind the stable interfaces above.

### 10.2 Deployment phasing (D*)

D1 (laptop launchd) → D2 (tailnet VM) → D3 (Cloudflare Access on top).
These are independent of the protocol phases; D1 is the only one P1
requires.


## 11. Defaults summary

| Concern                       | Default                                                                      |
| ----------------------------- | ---------------------------------------------------------------------------- |
| Mode                          | `conversational`                                                             |
| Admin                         | Host-human seat only                                                         |
| Live transport                | WebSocket (SSE fallback)                                                     |
| Agent transport               | MCP                                                                          |
| Slack mirror                  | Enabled when a channel is bound; carries human-readable subset               |
| Primary artifact store        | `gcs` (`nc-pair-artifacts` bucket, versioning on)                            |
| Secondary artifact store      | `slack` (bound channel, file upload with link to canonical store)            |
| Promotion `draft`             | `true`                                                                       |
| Augmentcode review            | Always requested on every push to a promoted PR (`auggie review` comment)    |
| Ready-flip                    | Manual gesture if augmentcode has feedback; automatic when augmentcode is clean |
| Network perimeter             | D1 (localhost) for P1; D2 (Tailscale) when off-laptop                        |
| Agent rate limit              | 3 burst, 1 token / 5s refill                                                 |
| Loop guard                    | On                                                                           |
| Event ids                     | ULID                                                                         |
| Implementation language       | Rust (relay + CLI)                                                           |
| Implementation repo           | `UpsideRealty/experiment-ai-pairing` (direct-push allowed while named `experiment-`) |

## 12. Open questions

These remain for the next round (none of them block P1):

1. **Promoted-PR human-reviewer assignment.** Should `pair promote
   --reviewer @handle` (or a per-session default list) become part of
   P3.5, or do we keep that as a manual step after the relay flips the
   PR to ready?
2. **Multi-store consistency.** When `gcs` and `slack` are both
   configured and the Slack write fails after the GCS write succeeds,
   should the relay retry, log-and-continue, or surface a visible
   warning to the session? Default proposal: log-and-continue with an
   `audit` event.
3. **Augmentcode "settled" detection.** What's the most robust signal
   for "augmentcode has nothing further to add"? Options include a
   sentinel comment from the bot, a review with no comments and no
   change requests, or an explicit phrase match. Implementation will
   pick the most reliable available at the time and document it.
4. **Driver hand-off gesture.** P4 territory — slash command or button
   in the web UI? Both eventually, but which lands first?

## 13. Glossary

| Term                | Meaning                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| **Session**         | An addressable, time-bounded pair room with a stable id.                                 |
| **Seat**            | A `(participant, role)` tuple; the unit of attribution.                                  |
| **Participant**     | The identity behind one or more seats (a Slack user, or an agent registration).          |
| **Mode**            | The governance state of a session (`conversational`, `driver-*`, `multi-driver`).        |
| **Host**            | The human who created the session; in v1 also the sole admin.                            |
| **Driver**          | A seat with write-control authority in driver modes (not used in v1).                    |
| **Reader**          | A seat without write-control authority in driver modes (not used in v1).                 |
| **Artifact**        | A named, typed blob produced during a session.                                           |
| **Artifact store**  | Backend that durably persists artifacts; one of `gcs/s3/slack/gdrive/fs/git`.            |
| **Promote**         | Explicit action that opens a draft PR in a code repo from one or more artifacts.        |
| **Auggie review**   | The `auggie review` comment the relay posts to invite augmentcode feedback.              |
| **Policy gate**     | Relay-side enforcement layer that decides ALLOW / DEFER / DENY on every inbound write.   |
| **Loop guard**      | Prevents agents from auto-replying to other agents without an `@`-mention.               |
| **D1 / D2 / D3**    | Deployment phases (laptop / tailnet VM / Cloudflare Access).                             |
| **P0 / P1 / …**     | Protocol implementation phases.                                                          |
