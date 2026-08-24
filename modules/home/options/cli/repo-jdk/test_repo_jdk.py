#!/usr/bin/env python3
"""Tests for repo-jdk's declaration parsing and JDK selection.

Run: python3 -m unittest discover -s <this dir> -p 'test_*.py'

Everything here is filesystem-only — no JVM is started and no network is used,
so the suite is safe to run anywhere.
"""

import tempfile
import unittest
from pathlib import Path

import repo_jdk
from repo_jdk import Declaration, Jdk


class MajorOf(unittest.TestCase):
    def test_modern_versions(self):
        self.assertEqual(repo_jdk.major_of("25"), 25)
        self.assertEqual(repo_jdk.major_of("25.0.1"), 25)
        self.assertEqual(repo_jdk.major_of("21.0.9+10-LTS"), 21)

    def test_legacy_1_x_naming(self):
        # "1.8.0_402" is Java 8, not Java 1.
        self.assertEqual(repo_jdk.major_of("1.8.0_402"), 8)
        self.assertEqual(repo_jdk.major_of("1.8"), 8)

    def test_vendor_prefixed(self):
        self.assertEqual(repo_jdk.major_of("25.0.1-zulu"), 25)

    def test_unparseable(self):
        self.assertEqual(repo_jdk.major_of("nonsense"), 0)


class Detection(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, name: str, content: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_java_version_file(self):
        self.write(".java-version", "25\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 25)

    def test_sdkmanrc_carries_an_exact_install(self):
        self.write(".sdkmanrc", "# comment\njava=25.0.1-zulu\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 25)
        self.assertEqual(declaration.exact, "25.0.1-zulu")

    def test_tool_versions_with_vendor_prefix(self):
        self.write(".tool-versions", "nodejs 20.0.0\njava temurin-21.0.9\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 21)

    def test_mise_toml(self):
        self.write(".mise.toml", '[tools]\njava = "17"\n')
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 17)

    def test_gradle_kts_toolchain(self):
        self.write("build.gradle.kts", "kotlin {\n    jvmToolchain(25)\n}\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 25)

    def test_gradle_java_language_version(self):
        self.write(
            "build.gradle.kts",
            "java {\n  toolchain {\n    languageVersion.set(JavaLanguageVersion.of(21))\n  }\n}\n",
        )
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 21)

    def test_gradle_source_compatibility(self):
        self.write("build.gradle", "sourceCompatibility = JavaVersion.VERSION_17\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 17)

    def test_maven_release(self):
        self.write(
            "pom.xml",
            "<project><properties>"
            "<maven.compiler.release>21</maven.compiler.release>"
            "</properties></project>",
        )
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 21)

    def test_explicit_pin_outranks_build_file(self):
        # The build file states a language level; .java-version states an
        # install. When they disagree the install wins.
        self.write("build.gradle.kts", "kotlin { jvmToolchain(17) }\n")
        self.write(".java-version", "25\n")
        declaration = repo_jdk.detect(self.root)
        self.assertEqual(declaration.major, 25)
        self.assertEqual(declaration.source.name, ".java-version")

    def test_walks_up_to_a_parent(self):
        self.write(".java-version", "21\n")
        nested = self.root / "module" / "src"
        nested.mkdir(parents=True)
        declaration = repo_jdk.detect(nested)
        self.assertEqual(declaration.major, 21)

    def test_nearest_declaration_wins(self):
        self.write(".java-version", "21\n")
        self.write("module/.java-version", "17\n")
        declaration = repo_jdk.detect(self.root / "module")
        self.assertEqual(declaration.major, 17)

    def test_nothing_declared(self):
        (self.root / "src").mkdir()
        self.assertIsNone(repo_jdk.detect(self.root / "src"))

    def test_empty_declaration_is_ignored(self):
        self.write(".java-version", "\n")
        self.assertIsNone(repo_jdk.detect(self.root))


class Selection(unittest.TestCase):
    def jdk(self, version, origin, name=None):
        return Jdk(Path(f"/fake/{name or version}"), version, origin)

    def test_matches_declared_major(self):
        jdks = [
            self.jdk("17.0.12", "nix (gradle installations)"),
            self.jdk("21.0.8", "nix (gradle installations)"),
            self.jdk("25.0.0", "nix (gradle installations)"),
        ]
        chosen = repo_jdk.select(Declaration(21, Path("x"), "21"), jdks)
        self.assertEqual(chosen.version, "21.0.8")

    def test_prefers_reproducible_origin_over_newer_patch(self):
        # A Nix 25.0.0 beats an SDKMAN 25.0.1: the Nix one survives a reimage.
        jdks = [
            self.jdk("25.0.0", "nix (gradle installations)", "nix25"),
            self.jdk("25.0.1", "sdkman", "sdk25"),
        ]
        chosen = repo_jdk.select(Declaration(25, Path("x"), "25"), jdks)
        self.assertEqual(chosen.origin, "nix (gradle installations)")

    def test_newest_patch_within_one_origin(self):
        jdks = [
            self.jdk("21.0.1", "sdkman", "a"),
            self.jdk("21.0.9", "sdkman", "b"),
            self.jdk("21.0.4", "sdkman", "c"),
        ]
        chosen = repo_jdk.select(Declaration(21, Path("x"), "21"), jdks)
        self.assertEqual(chosen.version, "21.0.9")

    def test_exact_pin_wins_over_origin_preference(self):
        # .sdkmanrc names an install, so honour it verbatim even though the
        # Nix JDK would otherwise be preferred.
        jdks = [
            self.jdk("25.0.0", "nix (gradle installations)", "nix25"),
            self.jdk("25.0.1", "sdkman", "25.0.1-zulu"),
        ]
        declaration = Declaration(25, Path("x"), "java=25.0.1-zulu", exact="25.0.1-zulu")
        chosen = repo_jdk.select(declaration, jdks)
        self.assertEqual(chosen.origin, "sdkman")

    def test_exact_pin_falls_back_when_not_installed(self):
        jdks = [self.jdk("25.0.0", "nix (gradle installations)", "nix25")]
        declaration = Declaration(25, Path("x"), "java=25.0.9-zulu", exact="25.0.9-zulu")
        chosen = repo_jdk.select(declaration, jdks)
        self.assertEqual(chosen.version, "25.0.0")

    def test_no_matching_major(self):
        jdks = [self.jdk("21.0.8", "nix (gradle installations)")]
        self.assertIsNone(repo_jdk.select(Declaration(25, Path("x"), "25"), jdks))

    def test_does_not_substitute_a_newer_major(self):
        # 26 is not an acceptable stand-in for a repo that asked for 25.
        jdks = [self.jdk("26.0.1", "gradle auto-provisioned")]
        self.assertIsNone(repo_jdk.select(Declaration(25, Path("x"), "25"), jdks))


if __name__ == "__main__":
    unittest.main()
