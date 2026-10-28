# Background Services

decknix runs a few launchd jobs. This page lists every one the framework defines, its default and how to turn it off. Repo sync, session GC and the Linux builder belong to [tier 3](../configuration/adoption.md) and the Emacs daemon to tier 4; installs without an `adoption.toml` get them all. Full option lists are in the [Configuration Hub](../hub.md).

## Summary

| launchd label | Kind | Default | Option | Defined in |
|---------------|------|---------|--------|------------|
| `org.nixos.emacs-server` | user agent, KeepAlive | on | `services.emacs.decknix.enable` | `modules/darwin/emacs.nix` |
| `org.nixos.decknix-hub` | user agent | off | `decknix.services.hub.enable` | `modules/darwin/hub.nix` |
| `org.nixos.decknix-repo-sync` | user agent, every 3h | on | `services.decknix.repoSync.enable` | `modules/darwin/repo-sync.nix` |
| `org.nixos.decknix-session-gc` | user agent, weekly | on | `services.decknix.sessionGc.enable` | `modules/darwin/session-gc.nix` |
| `org.nixos.iap-proxy-<name>` | user agent per instance | off | `decknix.services.iap-proxy.enable` | `modules/darwin/iap-proxy.nix` |
| `org.nixos.linux-builder` and helpers | system daemons, on demand | on | `decknix.linuxBuilder.enable` | `modules/darwin/linux-builder/` |
| `org.nix-community.home.gortex` | home-manager agent | on when a roster is set | `decknix.ai.gortex.daemon.enable` | `modules/home/options/ai/gortex.nix` |

nix-darwin prefixes its launchd labels with `org.nixos.`, so `launchctl print gui/$(id -u)/org.nixos.decknix-repo-sync` shows a job's state.

## Repo sync

Keeps the primary checkout of every clone in your workspaces fresh by running `decknix repos sync` (see [Core Commands](../cli/core-commands.md#decknix-repos)). It fetches and fast-forwards each repo's default branch and never touches a dirty tree or a checked-out feature branch.

```nix
services.decknix.repoSync = {
  enable = true;        # default
  intervalHours = 3;    # launchd StartInterval
  runAtLoad = true;     # also run shortly after login or a switch
  jobs = null;          # concurrency; null lets the CLI pick min(8, CPUs)
};
```

Logs go to `/tmp/decknix-repo-sync.out` and `.err`. The workspaces to scan come from `[repos].workspaces` in `~/.config/decknix/settings.toml`.

## Session GC

Runs `decknix session gc` once a week: sessions inactive longer than `[session].archive_after` (default four weeks) are compressed into the session archive and removed from the agent's live directory; archives inactive longer than `[session].trash_after` move to the Trash. Both thresholds live in `~/.config/decknix/settings.toml`.

```nix
services.decknix.sessionGc = {
  enable = true;   # default
  weekday = 0;     # Sunday
  hour = 3;
  minute = 30;
};
```

Logs go to `/tmp/decknix-session-gc.out` and `.err`. `decknix session restore <id>` brings an archived session back.

## IAP proxy

Local HTTP proxies that add Google Identity-Aware Proxy authentication, so tools on your machine can reach an IAP-protected service at `http://localhost:<port>`. Each named instance is its own launchd agent with its own port and token store. Off by default; an org config overlay usually turns it on.

```nix
decknix.services.iap-proxy = {
  enable = true;
  src = inputs.iap-proxy-src;            # the proxy's source, as a non-flake input
  oauthClientId = "...";                 # shared desktop OAuth client
  oauthClientSecret = "...";
  instances = {
    ci = {
      port = 58080;
      targetUrl = "https://ci.example.com";
      iapClientId = "000000000000-xxxx.apps.googleusercontent.com";
    };
    production = {
      port = 59090;
      targetUrl = "https://app.example.com";
      iapClientId = "000000000001-xxxx.apps.googleusercontent.com";
      autoStart = false;                 # installed but dormant until kickstarted
    };
  };
};
```

On-demand instances are started and stopped with:

```bash
launchctl kickstart -k gui/$(id -u)/org.nixos.iap-proxy-production
launchctl kill TERM   gui/$(id -u)/org.nixos.iap-proxy-production
```

Each instance logs to `/tmp/iap-proxy-<name>.log` and keeps its refresh token in `~/.config/iap-proxy/<name>-tokens.json` unless `tokenStorePath` says otherwise. On first start it opens the browser for consent (`autoOpenBrowser`).
