#!/usr/bin/env python3
"""Resolve the JDK a repository declares, and run commands against it.

The machine default `java` is whatever lands first on PATH, which on a system
running both Nix and SDKMAN is a coin toss — SDKMAN prepends its `current`
candidate late in shell init and quietly shadows the Nix JDK. A build then runs
on a JDK its own build files never asked for, and the failure surfaces somewhere
unhelpful (an annotation processor rejecting a class file version, say) rather
than as "wrong Java".

So don't assume. Read what the repository itself declares, resolve that to an
installed JDK, and run against it.

Detection walks upward from the starting directory to the repository root,
taking the first declaration it finds. Within a directory the sources are
ordered most-explicit first: a pinned toolchain manager beats a build file,
because the build file states a language level while the manager states an
install.

Resolution never downloads anything. It looks only at JDKs already on the
machine, and reads each one's `release` file rather than starting a JVM.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HOME = Path.home()


@dataclass(frozen=True)
class Declaration:
    """A version a repository asked for, and where it said so."""

    major: int
    source: Path
    detail: str
    # Some sources name an exact install (".sdkmanrc" pins "25.0.1-zulu")
    # rather than just a language level. Preferred verbatim when it resolves.
    exact: str | None = None


# Where a JDK came from, best first. Nix leads because it is the only origin
# that reproduces on a fresh machine; SDKMAN and Gradle's auto-provisioned
# downloads are local state that a reimage would not restore.
ORIGIN_PRIORITY = (
    "nix (gradle installations)",
    "sdkman",
    "gradle auto-provisioned",
    "system",
    "JAVA_HOME",
    "PATH",
)


@dataclass(frozen=True)
class Jdk:
    home: Path
    version: str
    origin: str

    @property
    def major(self) -> int:
        return major_of(self.version)

    @property
    def sort_key(self) -> tuple:
        return tuple(int(p) for p in re.findall(r"\d+", self.version)[:4])

    @property
    def origin_rank(self) -> int:
        try:
            return ORIGIN_PRIORITY.index(self.origin)
        except ValueError:
            return len(ORIGIN_PRIORITY)


def major_of(version: str) -> int:
    """8 from "1.8.0_402", 25 from "25.0.1", 21 from "21"."""
    version = version.strip()
    if version.startswith("1."):
        parts = version.split(".")
        if len(parts) > 1 and parts[1].isdigit():
            return int(parts[1])
    match = re.match(r"(\d+)", version)
    return int(match.group(1)) if match else 0


# ── Detection ────────────────────────────────────────────────────────────────


def _read(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def from_sdkmanrc(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == "java":
            value = value.strip()
            return Declaration(major_of(value), path, f"java={value}", exact=value)
    return None


def from_tool_versions(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "java":
            spec = fields[1]
            # asdf spells these "temurin-25.0.1" / "zulu-21.0.9"; the digits
            # are what matter for resolution.
            digits = re.search(r"(\d[\d._]*)", spec)
            if digits:
                return Declaration(major_of(digits.group(1)), path, f"java {spec}")
    return None


def from_java_version(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    value = text.strip().splitlines()[0].strip() if text.strip() else ""
    if not value:
        return None
    return Declaration(major_of(value), path, value)


def from_mise_toml(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    match = re.search(r'^\s*java\s*=\s*["\']([^"\']+)["\']', text, re.M)
    if not match:
        return None
    spec = match.group(1)
    digits = re.search(r"(\d[\d._]*)", spec)
    if not digits:
        return None
    return Declaration(major_of(digits.group(1)), path, f'java = "{spec}"')


GRADLE_PATTERNS = (
    # Most authoritative first: a toolchain is a statement about which JDK runs,
    # whereas jvmTarget/sourceCompatibility only pin the bytecode level.
    (r"jvmToolchain\s*\(\s*(?:JavaLanguageVersion\.of\s*\(\s*)?(\d+)", "jvmToolchain({})"),
    (r"JavaLanguageVersion\.of\s*\(\s*(\d+)", "JavaLanguageVersion.of({})"),
    (r"JvmTarget\.JVM_(\d+)", "JvmTarget.JVM_{}"),
    (r"(?:source|target)Compatibility\s*=?\s*JavaVersion\.VERSION_(\d+)", "JavaVersion.VERSION_{}"),
    (r"(?:source|target)Compatibility\s*=\s*[\"'](\d+)[\"']", "sourceCompatibility {}"),
)


def from_gradle(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    for pattern, label in GRADLE_PATTERNS:
        match = re.search(pattern, text)
        if match:
            version = match.group(1)
            return Declaration(major_of(version), path, label.format(version))
    return None


MAVEN_PATTERNS = (
    ("maven.compiler.release", r"<maven\.compiler\.release>\s*([\d.]+)\s*</"),
    ("java.version", r"<java\.version>\s*([\d.]+)\s*</"),
    ("maven.compiler.source", r"<maven\.compiler\.source>\s*([\d.]+)\s*</"),
)


def from_pom(path: Path) -> Declaration | None:
    text = _read(path)
    if text is None:
        return None
    for label, pattern in MAVEN_PATTERNS:
        match = re.search(pattern, text)
        if match:
            version = match.group(1)
            return Declaration(major_of(version), path, f"<{label}>{version}</{label}>")
    return None


# Ordered: an explicit toolchain pin outranks a build file's language level.
DETECTORS = (
    (".sdkmanrc", from_sdkmanrc),
    (".tool-versions", from_tool_versions),
    (".java-version", from_java_version),
    (".mise.toml", from_mise_toml),
    ("build.gradle.kts", from_gradle),
    ("build.gradle", from_gradle),
    ("pom.xml", from_pom),
)


def repo_root(start: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return Path(result.stdout.strip())


def detect(start: Path) -> Declaration | None:
    """Walk up from `start`, stopping at the repository root."""
    start = start.resolve()
    root = repo_root(start)
    # Without a git root, still walk up — but not past the user's home, so a
    # stray declaration in / or ~ can't silently claim an unrelated directory.
    ceiling = root if root else HOME

    current = start
    while True:
        for filename, detector in DETECTORS:
            candidate = current / filename
            if candidate.is_file():
                declaration = detector(candidate)
                if declaration and declaration.major:
                    return declaration
        if current == ceiling or current == current.parent:
            return None
        current = current.parent


# ── Available JDKs ───────────────────────────────────────────────────────────


def version_of(home: Path) -> str | None:
    """Read the JDK's own `release` file; fall back to asking the binary."""
    release = home / "release"
    text = _read(release)
    if text:
        match = re.search(r'^JAVA_VERSION="?([^"\n]+)"?', text, re.M)
        if match:
            return match.group(1).strip()

    binary = home / "bin" / "java"
    if not binary.is_file():
        return None
    try:
        result = subprocess.run(
            [str(binary), "-version"], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r'version "([^"]+)"', result.stderr or result.stdout)
    return match.group(1) if match else None


def _normalise(home: Path) -> Path:
    """macOS bundles put the real JDK under Contents/Home."""
    inner = home / "Contents" / "Home"
    return inner if inner.is_dir() else home


def _gradle_declared_paths() -> list[Path]:
    """JDKs Nix has told Gradle about via org.gradle.java.installations.paths."""
    text = _read(HOME / ".gradle" / "gradle.properties")
    if not text:
        return []
    match = re.search(r"^org\.gradle\.java\.installations\.paths\s*=\s*(.+)$", text, re.M)
    if not match:
        return []
    return [Path(p.strip()) for p in match.group(1).split(",") if p.strip()]


def _glob_dirs(pattern_root: Path, pattern: str) -> list[Path]:
    try:
        return sorted(p for p in pattern_root.glob(pattern) if p.is_dir())
    except OSError:
        return []


def discover() -> list[Jdk]:
    sources: list[tuple[str, list[Path]]] = [
        ("nix (gradle installations)", _gradle_declared_paths()),
        # `current` is a symlink to one of the siblings; including it would
        # produce a duplicate under a misleading name.
        (
            "sdkman",
            [p for p in _glob_dirs(HOME / ".sdkman" / "candidates" / "java", "*") if p.name != "current"],
        ),
        ("gradle auto-provisioned", _glob_dirs(HOME / ".gradle" / "jdks", "*/*")),
        ("system", _glob_dirs(Path("/Library/Java/JavaVirtualMachines"), "*")),
    ]

    env_home = os.environ.get("JAVA_HOME")
    if env_home:
        sources.append(("JAVA_HOME", [Path(env_home)]))

    on_path = shutil.which("java")
    if on_path:
        sources.append(("PATH", [Path(on_path).resolve().parent.parent]))

    found: dict[Path, Jdk] = {}
    for origin, paths in sources:
        for path in paths:
            home = _normalise(path)
            if not (home / "bin" / "java").is_file():
                continue
            # SDKMAN candidates are symlinks into the same bundle the PATH entry
            # resolves to; key on the real path so one install is listed once,
            # under the first (highest-priority) origin that offered it.
            key = home.resolve()
            # A PATH or JAVA_HOME entry often points at the inner macOS bundle
            # of an install already listed under its outer directory. Same JDK,
            # so let the earlier, better-named origin keep it.
            if key in found or any(key.is_relative_to(k) for k in found):
                continue
            version = version_of(home)
            if version:
                found[key] = Jdk(home, version, origin)
    return sorted(found.values(), key=lambda j: (j.major, j.sort_key))


def select(declaration: Declaration, jdks: list[Jdk]) -> Jdk | None:
    if declaration.exact:
        for jdk in jdks:
            if jdk.home.name == declaration.exact:
                return jdk
    matching = [j for j in jdks if j.major == declaration.major]
    if not matching:
        return None
    # Reproducible origin first, then newest patch within it — a repo asking for
    # 25 is asking for the language level, and the latest 25.x from the origin
    # that survives a reimage is the safest install of it.
    return min(matching, key=lambda j: (j.origin_rank, [-n for n in j.sort_key]))


# ── Commands ─────────────────────────────────────────────────────────────────


def fail(message: str, code: int) -> int:
    print(f"repo-jdk: {message}", file=sys.stderr)
    return code


def resolve(directory: Path) -> tuple[Declaration, Jdk] | int:
    declaration = detect(directory)
    if declaration is None:
        return fail(
            f"no JDK declaration found in {directory} or any parent up to the repository root",
            3,
        )
    jdk = select(declaration, discover())
    if jdk is None:
        available = ", ".join(sorted({str(j.major) for j in discover()})) or "none"
        return fail(
            f"{declaration.source} declares Java {declaration.major} "
            f"({declaration.detail}), but no JDK {declaration.major} is installed "
            f"(available: {available})",
            4,
        )
    return declaration, jdk


def cmd_version(args) -> int:
    result = resolve(args.dir)
    if isinstance(result, int):
        return result
    print(result[0].major)
    return 0


def cmd_home(args) -> int:
    result = resolve(args.dir)
    if isinstance(result, int):
        return result
    print(result[1].home)
    return 0


def cmd_env(args) -> int:
    result = resolve(args.dir)
    if isinstance(result, int):
        return result
    home = result[1].home
    print(f'export JAVA_HOME="{home}"')
    print(f'export PATH="{home}/bin:$PATH"')
    return 0


def cmd_explain(args) -> int:
    declaration = detect(args.dir)
    jdks = discover()

    if declaration is None:
        print(f"declared: nothing found under {args.dir}")
    else:
        print(f"declared: Java {declaration.major}")
        print(f"  source: {declaration.source}")
        print(f"  syntax: {declaration.detail}")

    print()
    print("installed:")
    if not jdks:
        print("  (none found)")
    for jdk in jdks:
        marker = " "
        if declaration and select(declaration, jdks) == jdk:
            marker = "*"
        print(f" {marker} {jdk.version:<12} {jdk.origin:<28} {jdk.home}")

    if declaration:
        chosen = select(declaration, jdks)
        print()
        if chosen:
            print(f"selected: {chosen.home}")
        else:
            print(f"selected: none — no JDK {declaration.major} installed")
            return 4
    return 0


def cmd_exec(args) -> int:
    # argparse.REMAINDER keeps the "--" separator when it is the first token.
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        return fail("exec needs a command, e.g. repo-jdk exec -- ./gradlew build", 2)
    result = resolve(args.dir)
    if isinstance(result, int):
        return result
    declaration, jdk = result

    env = dict(os.environ)
    env["JAVA_HOME"] = str(jdk.home)
    env["PATH"] = f"{jdk.home}/bin:{env.get('PATH', '')}"

    if not args.quiet:
        print(
            f"repo-jdk: Java {declaration.major} "
            f"({jdk.version}) from {declaration.source.name} → {jdk.home}",
            file=sys.stderr,
        )

    try:
        return subprocess.call(args.command, env=env, cwd=str(args.dir))
    except FileNotFoundError:
        return fail(f"command not found: {args.command[0]}", 127)
    except KeyboardInterrupt:
        return 130


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="repo-jdk",
        description="Resolve and use the JDK a repository declares.",
    )
    parser.add_argument(
        "--dir",
        type=Path,
        default=Path.cwd(),
        help="directory to resolve from (default: current directory)",
    )

    subparsers = parser.add_subparsers(dest="subcommand")
    subparsers.add_parser("version", help="print the declared major version")
    subparsers.add_parser("home", help="print the resolved JAVA_HOME")
    subparsers.add_parser("env", help="print shell exports to eval")
    subparsers.add_parser("explain", help="show what was declared and what is installed")

    exec_parser = subparsers.add_parser("exec", help="run a command against the declared JDK")
    exec_parser.add_argument(
        "-q", "--quiet", action="store_true", help="do not print the resolved JDK"
    )
    exec_parser.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args(argv)

    if not args.dir.is_dir():
        return fail(f"not a directory: {args.dir}", 2)

    handlers = {
        "version": cmd_version,
        "home": cmd_home,
        "env": cmd_env,
        "explain": cmd_explain,
        "exec": cmd_exec,
    }
    # Bare `repo-jdk` is the question people actually have: which one is it?
    handler = handlers.get(args.subcommand or "explain")
    return handler(args)


if __name__ == "__main__":
    sys.exit(main())
