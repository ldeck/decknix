{
  # USER IDENTITY
  username = "REPLACE_ME";       # Your macOS username (run `whoami`)
  role     = "developer";        # 'developer', 'designer' or 'minimal'; informational only
  
  # MACHINE IDENTITY
  hostname = "deck-macbook";     # Your hostname (run `hostname -s`)
  system   = "aarch64-darwin";   # "aarch64-darwin" (Apple Silicon) or "x86_64-darwin" (Intel)

  # What gets installed is chosen by the adoption tier in adoption.toml next
  # to this file (tier 1 base, 2 AI agents, 3 workstation, 4 deckmacs). With
  # no adoption.toml you get everything (tier 4).
}
