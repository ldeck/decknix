# Linux Builder

Decknix enables nix-darwin's Linux builder: a small aarch64-linux NixOS VM that
Nix uses as a remote builder, so a Mac can build Linux derivations such as
`dockerTools` container images.

The VM is **available by default but only runs when needed**. It boots on the
first build that needs it and powers itself off after 20 idle minutes, so its
6 GiB of RAM is only held while you are actually building Linux derivations.

## How it works

nix-darwin points Nix at the builder through the `linux-builder` SSH alias,
which resolves to `localhost:31022`. Decknix keeps that address and puts a
small socket-activated launchd job on it:

1. A build connects to port 31022. launchd starts `linux-builder-activator`
   for that connection.
2. If the VM is not answering SSH, the activator starts it
   (`launchctl kickstart system/org.nixos.linux-builder`) and waits until the
   guest's SSH banner appears on the VM's own port, 31023.
3. It then relays the connection to the VM. Nix sees the same host key and
   alias as before.
4. Every 5 minutes `linux-builder-idle-stop` checks for open connections to the
   VM. Once there have been none for `idleMinutes`, it powers the guest off
   cleanly over SSH (falling back to stopping qemu if the guest does not shut
   down within a minute). The VM stays down until the next build.

Both helpers run as root, because starting a system launchd job requires it.
Logs: `/var/log/linux-builder-activator.log` and
`/var/log/linux-builder-idle-stop.log`.

## First-build delay

A build that finds the VM stopped waits while it boots: the start script first
packs the guest's Nix store image, then the guest boots and starts sshd. Expect
roughly half a minute to a minute (unmeasured; slower under memory pressure).
If the VM has not answered within `startTimeoutSeconds` (default 120), the
connection fails and Nix reports the builder as unavailable rather than
hanging. Later builds within the idle window connect immediately.

## Starting and stopping by hand

```bash
# Start now (e.g. before a batch of builds)
sudo launchctl kickstart system/org.nixos.linux-builder

# Stop now, cleanly (guest poweroff)
sudo linux-builder-stop

# Stop now, forcefully (signals qemu; use only if the guest is wedged)
sudo launchctl kill SIGTERM system/org.nixos.linux-builder
```

A VM started by hand is still stopped after `idleMinutes` without a build.

## Options

```nix
{
  decknix.linuxBuilder = {
    enable = true;             # false also deletes the VM disk on the next switch
    onDemand = true;           # false: nix-darwin's always-on daemon
    idleMinutes = 20;
    startTimeoutSeconds = 120;
    memoryMiB = 6144;
    cores = 6;
    backendPort = 31023;       # VM's own SSH port when onDemand is set
  };
}
```

To go back to an always-running builder, set `decknix.linuxBuilder.onDemand =
false;` and run `decknix switch`.

## Memory

The VM is given 6 GiB, but an always-on qemu process was observed at a ~12 GB
footprint after 56 days, almost all of it compressed or swapped. Guest memory
that Linux has touched (page cache included) is never returned to macOS while
the VM runs, because no memory balloon is configured. Why the footprint reached
twice the configured RAM is unverified. Powering the VM off when idle releases
all of it; a virtio balloon with free-page reporting was not added because its
effect under the macOS hvf accelerator is unverified.
