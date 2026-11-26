"""Tests for the CI guard scripts in this directory.

Run: python3 -m unittest discover -s .github/scripts -p 'test_*.py' -v
"""

import importlib.util
import io
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SHA = "11d5960a326750d5838078e36cf38b85af677262"


def load(name: str):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check_workflows = load("check-workflows")
check_test_skips = load("check-test-skips")
check_package_pins = load("check-package-pins")
needs_build = load("needs-build")
integrate_openpgp = load("integrate-openpgp")


class TempFiles(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)

    def write(self, name: str, text: str) -> Path:
        path = Path(self._dir.name) / name
        path.write_text(textwrap.dedent(text))
        return path


class CheckWorkflowsTests(TempFiles):
    HARDENED = textwrap.dedent(f"""\
        name: CI
        on: [push]
        permissions:
          contents: read
        jobs:
          build:
            runs-on: macos-26
            permissions:
              contents: write
            steps:
              - uses: actions/checkout@{SHA} # v4.4.0
              - name: Cache
                uses: actions/cache/restore@{SHA} # v4.3.0
              - run: |
                  make test \\
                    -j2
        """)
    STEP = "      - uses: actions/checkout@" + SHA + " # v4.4.0\n"

    def errors(self, text: str) -> list[str]:
        return check_workflows.check(self.write("workflow.yml", text))

    def assertRejected(self, text: str, fragment: str = ""):
        errors = self.errors(text)
        self.assertTrue(errors, "accepted:\n" + text)
        if fragment:
            self.assertTrue(any(fragment in e for e in errors), errors)

    def test_hardened_workflow_passes(self):
        self.assertEqual(self.errors(self.HARDENED), [])

    def test_repository_workflows_pass(self):
        workflows = sorted((REPO / ".github/workflows").glob("*.y*ml"))
        self.assertTrue(workflows)
        for path in workflows:
            with self.subTest(path=path.name):
                self.assertEqual(check_workflows.check(path), [])

    def test_missing_top_level_permissions_fails(self):
        text = self.HARDENED.replace("permissions:\n  contents: read\n", "")
        self.assertIn("no top-level `permissions:`", self.errors(text)[0])

    def test_job_level_block_does_not_count_as_top_level(self):
        text = self.HARDENED.replace("permissions:\n  contents: read\n", "")
        self.assertIn("permissions:\n      contents: write", text)
        self.assertIn("no top-level `permissions:`", self.errors(text)[0])

    def test_top_level_write_fails(self):
        text = self.HARDENED.replace("  contents: read", "  contents: write")
        self.assertRejected(text, "may only be `read` or `none`")

    def test_unsupported_permissions_forms_fail(self):
        for form in ("permissions: write-all", "permissions: read-all",
                     "permissions: { contents: read }", '"permissions": write-all',
                     "permissions : write-all"):
            for where in ("top", "job"):
                with self.subTest(form=form, where=where):
                    if where == "top":
                        text = self.HARDENED.replace("permissions:\n  contents: read", form)
                    else:
                        text = self.HARDENED.replace(
                            "    permissions:\n      contents: write", "    " + form)
                    self.assertRejected(text, "unsupported permissions form")

    def test_unpinned_or_unusual_uses_fail(self):
        variants = [
            "      - uses: actions/checkout@v4\n",
            "      - uses: actions/checkout@main\n",
            f"      - uses: actions/checkout@{SHA[:12]} # v4.4.0\n",
            f"      - uses: actions/checkout@{SHA}\n",
            f"      - uses: actions/checkout@{SHA} # pinned\n",
            f'      - uses: "actions/checkout@{SHA}" # v4.4.0\n',
            "      - { uses: actions/checkout@v4 }\n",
            '      - "uses": actions/cache@v4\n',
            "      - uses : actions/checkout@v4\n",
            "      - uses:\n          actions/checkout@v4\n",
            "      - uses: ./local-action\n",
            "      - uses: docker://alpine:3.20\n",
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertRejected(self.HARDENED.replace(self.STEP, variant), "`uses:`")

    def test_homebrew_fails(self):
        for run in ("brew install xcodegen", "brew reinstall xcodegen",
                    "brew upgrade", "brew bundle", "HOMEBREW_X=1 brew install x"):
            with self.subTest(run=run):
                self.assertRejected(self.HARDENED + f"      - run: {run}\n", "Homebrew")
        continued = self.HARDENED + "      - run: |\n          brew \\\n            install xcodegen\n"
        self.assertRejected(continued, "Homebrew")

    def test_dangerous_triggers_fail(self):
        for trigger in ("pull_request_target", "workflow_run"):
            with self.subTest(trigger=trigger):
                text = self.HARDENED.replace("on: [push]", f"on: [push, {trigger}]")
                self.assertRejected(text, "not allowed")

    def test_commented_lines_are_ignored(self):
        text = self.HARDENED + ("      # - uses: actions/checkout@v4\n"
                                "      # brew install x; permissions: write-all\n")
        self.assertEqual(self.errors(text), [])

    def test_workflow_before_the_hardening_fails(self):
        # The shape of ci.yml at 45e9507, before this check existed: the
        # regression this guards against.
        before = """\
            name: CI
            on:
              pull_request:
            concurrency:
              group: ci
            jobs:
              test:
                runs-on: macos-26
                steps:
                  - uses: actions/checkout@v4
                  - name: Install xcodegen
                    run: brew install xcodegen
                  - uses: actions/cache/restore@v4
            """
        errors = self.errors(before)
        self.assertEqual(len(errors), 4, errors)

    def test_main_reports_and_exits_nonzero(self):
        path = self.write("bad.yml", "on: [push]\njobs: {}\n")
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(check_workflows.main([str(path)]), 1)
        self.assertIn("1 workflow hardening violation", out.getvalue())


class CheckTestSkipsTests(TempFiles):
    ALLOWLIST = "# comment\nHTMLBodyHeightLoopTests.testViewportLengthsArePinnedNotCollapsed  # why\n"

    def run_check(self, log: str) -> tuple[int, str]:
        log_path = self.write("tests.log", log)
        allow_path = self.write("allow.txt", self.ALLOWLIST)
        out = io.StringIO()
        with redirect_stdout(out):
            status = check_test_skips.main([str(log_path), str(allow_path)])
        return status, out.getvalue()

    PASSED = (
        "Test Case '-[DreaMailTests.FooTests testBar]' started.\n"
        "Test Case '-[DreaMailTests.FooTests testBar]' passed (0.001 seconds).\n"
        "\t Executed 2425 tests, with 0 failures (0 unexpected) in 61.0 (63.0) seconds\n"
    )

    def test_clean_run_passes(self):
        self.assertEqual(self.run_check(self.PASSED)[0], 0)

    def test_allowlisted_skip_passes(self):
        log = self.PASSED + (
            "Test Case '-[DreaMailTests.HTMLBodyHeightLoopTests "
            "testViewportLengthsArePinnedNotCollapsed]' skipped (4.460 seconds).\n")
        self.assertEqual(self.run_check(log)[0], 0)

    def test_unlisted_skip_fails(self):
        log = self.PASSED + (
            "Test Case '-[DreaMailTests.UpdateVerifySmokeTests testBuiltAppVerifies]' "
            "skipped (0.001 seconds).\n")
        status, out = self.run_check(log)
        self.assertEqual(status, 1)
        self.assertIn("UpdateVerifySmokeTests.testBuiltAppVerifies was skipped", out)

    def test_ui_test_target_skip_fails(self):
        log = self.PASSED + (
            "Test Case '-[DreaMailUITests.SmokeTests testLaunch]' skipped (0.1 seconds).\n")
        self.assertEqual(self.run_check(log)[0], 1)

    def test_log_without_tests_fails(self):
        self.assertEqual(self.run_check("** BUILD SUCCEEDED **\n")[0], 1)
        self.assertEqual(self.run_check("\t Executed 0 tests, with 0 failures\n")[0], 1)

    def test_repository_allowlist_parses(self):
        entries = check_test_skips.read_allowlist(check_test_skips.DEFAULT_ALLOWLIST)
        self.assertTrue(entries)
        for entry in entries:
            self.assertRegex(entry, r"^\w+\.test\w+$")


class CheckPackagePinsTests(TempFiles):
    URL = "https://github.com/duckduckgo/GRDB.swift"
    REV = "46098847eeabdb008f238bef5750a8e64097b6ed"
    PACKAGE = f"  GRDB:\n    url: {URL}\n    revision: {REV}\n"
    PROJECT = textwrap.dedent(f"""\
        name: DreaMail
        options:
          bundleIdPrefix: io.github.bateman
        packages:
          # GRDB 3.0.0
          GRDB:
            url: {URL}
            revision: {REV}  # tag 3.0.0
        targets:
          DreaMail:
            type: application
            dependencies:
              - package: GRDB
              - target: DreaMailRelauncher
              - sdk: Security.framework
        """)

    def errors(self, text: str) -> list[str]:
        return check_package_pins.check(self.write("project.yml", text))

    def assertRejected(self, text: str, fragment: str = ""):
        errors = self.errors(text)
        self.assertTrue(errors, "accepted:\n" + text)
        if fragment:
            self.assertTrue(any(fragment in e for e in errors), errors)

    def test_repository_project_passes(self):
        self.assertEqual(check_package_pins.check(REPO / "project.yml"), [])

    def test_pinned_project_passes(self):
        self.assertEqual(self.errors(self.PROJECT), [])

    def test_version_rules_fail(self):
        # The shape of project.yml before this check: a movable tag.
        for rule in ("exactVersion: 3.0.0", "from: 3.0.0", "branch: main",
                     "minorVersion: 3.0.0", "version: 3.0.0", "path: ../GRDB"):
            with self.subTest(rule=rule):
                text = self.PROJECT.replace(f"revision: {self.REV}", rule)
                self.assertRejected(text, "tags and branches can move")
                self.assertRejected(text, "has no `revision:`")

    def test_extra_rule_next_to_revision_fails(self):
        self.assertRejected(self.PROJECT.replace(
            f"revision: {self.REV}", f"revision: {self.REV}\n    exactVersion: 3.0.0"),
            "unsupported form")

    def test_bad_values_fail(self):
        for old, new, fragment in (
                (self.REV, self.REV[:12], "40-hex"), (self.REV, "3.0.0", "40-hex"),
                (self.REV, f'"{self.REV}"', "40-hex"), (self.REV, "*pinned", "40-hex"),
                (self.URL, "http://github.com/x/y", "https://"),
                (self.URL, "*url", "https://")):
            with self.subTest(new=new):
                self.assertRejected(self.PROJECT.replace(old, new, 1), fragment)

    def test_duplicate_keys_fail(self):
        cases = {
            "package": self.PROJECT.replace("targets:", self.PACKAGE + "targets:"),
            "url": self.PROJECT.replace(f"    url: {self.URL}\n",
                                        f"    url: {self.URL}\n    url: https://x.org/y\n"),
            "revision": self.PROJECT.replace(f"    revision: {self.REV}",
                                             f"    revision: {self.REV}\n"
                                             f"    revision: {'0' * 40}"),
            "top-level": self.PROJECT + "packages:\n" + self.PACKAGE,
        }
        for what, text in cases.items():
            with self.subTest(what=what):
                self.assertRejected(text, "twice")

    def test_package_key_variants_fail(self):
        for key in ("'packages':", '"packages":', '"packages" :', "packages :",
                    "!!str packages:", "<<:", "? packages", "packages: {GRDB: {url: x}}"):
            with self.subTest(key=key):
                self.assertRejected(self.PROJECT.replace("packages:", key, 1))

    def test_anchors_and_merges_in_packages_fail(self):
        for old, new in (("  GRDB:", "  GRDB: &grdb"), ("  GRDB:", "  <<: *base"),
                         ("  GRDB:", "  'GRDB':"), ("  GRDB:", "  GRDB: {url: x}"),
                         (f"    url: {self.URL}", f"    url: {self.URL}\n    <<: *base")):
            with self.subTest(new=new):
                self.assertRejected(self.PROJECT.replace(old, new, 1))

    def test_imports_fail(self):
        for key in ("include:\n  - other.yml", "include: [other.yml]",
                    "localPackages:\n  - ../GRDB", "projectReferences:\n  Other: {}"):
            with self.subTest(key=key):
                self.assertRejected(self.PROJECT + key + "\n", "not allowed")

    def test_binary_dependencies_fail(self):
        for dep in ("- framework: Vendor/SQLCipher.xcframework", "- carthage: GRDB",
                    "- {framework: x.framework}", '- "carthage": GRDB'):
            with self.subTest(dep=dep):
                self.assertRejected(self.PROJECT + f"      {dep}\n", "`framework:`")

    def test_comments_are_ignored(self):
        text = self.PROJECT + "# include: other.yml\n      # - framework: x\n"
        self.assertEqual(self.errors(text), [])

    def test_main_reports_and_exits_nonzero(self):
        path = self.write("bad.yml", self.PROJECT.replace(f"revision: {self.REV}", "from: 3.0.0"))
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(check_package_pins.main([str(path)]), 1)
        self.assertIn("package pin violation", out.getvalue())


class NeedsBuildTests(TempFiles):
    def test_docs_only_changes_skip_the_build(self):
        for paths in (["docs/piano-sviluppo.md"], ["CHANGELOG.md", "CLAUDE.md"],
                      ["reviews/r.md", ".claude/skills/x/SKILL.md", "docs/screenshots/a.png"]):
            with self.subTest(paths=paths):
                self.assertFalse(needs_build.needs_build(paths))

    def test_anything_else_builds(self):
        # The unit tests read the top-level README, CONTRIBUTING and SECURITY,
        # and everything under scripts/ and .github/.
        for paths in ([], ["README.md"], ["CONTRIBUTING.md"], ["SECURITY.md"],
                      ["scripts/README.md"], [".github/workflows/ci.yml"],
                      ["docs/a.md", "Sources/DreaMail/App/MailStore.swift"],
                      ["docsx/a.md"], ["Tests/docs/a.md"], ["sub/CHANGELOG.md"]):
            with self.subTest(paths=paths):
                self.assertTrue(needs_build.needs_build(paths))

    def git(self, *args: str):
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                        "-c", "commit.gpgsign=false", *args],
                       cwd=self._dir.name, check=True, capture_output=True)

    def commit(self, files: dict[str, str]):
        for name, text in files.items():
            path = Path(self._dir.name) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "change")

    def run_script(self, base: str) -> str:
        return subprocess.run([sys.executable, str(HERE / "needs-build.py"), base],
                              cwd=self._dir.name, check=True, capture_output=True,
                              text=True).stdout

    def test_diff_in_a_repository(self):
        self.git("init", "-q")
        self.commit({"Sources/a.swift": "let a = 1\n", "docs/a.md": "# A\n"})
        self.commit({"docs/a.md": "# A, revised\n"})
        self.assertEqual(self.run_script("HEAD~1"), "build=false\n")
        # A move out of Sources/ must count as a change to Sources/.
        self.git("mv", "Sources/a.swift", "docs/a.swift")
        self.git("commit", "-q", "-m", "move")
        self.assertEqual(self.run_script("HEAD~1"), "build=true\n")

    def test_unusable_base_builds(self):
        self.git("init", "-q")
        self.commit({"docs/a.md": "# A\n"})
        for base in ("", "0" * 40, "HEAD", "no-such-commit"):
            with self.subTest(base=base):
                self.assertEqual(self.run_script(base), "build=true\n")

    def test_no_repository_reading_test_names_a_skipped_path(self):
        dirs = "|".join(re.escape(d.rstrip("/")) for d in needs_build.SKIP_DIRS)
        files = "|".join(re.escape(f) for f in needs_build.SKIP_FILES)
        pattern = re.compile(rf'"(?:{dirs})(?:/|")|"(?:{files})"')
        for text in ('repoFile("docs/RELEASING.md")', 'for dir in ["Sources", "docs"]',
                     '"CHANGELOG.md"'):
            self.assertTrue(pattern.search(text), text)

        scanned, offenders = 0, []
        for path in sorted((REPO / "Tests").rglob("*.swift")):
            text = path.read_text()
            if not any(key in text for key in ("repoRoot", "repoFile(", "#filePath")):
                continue
            scanned += 1
            offenders += [f"{path.relative_to(REPO)}: {m.group()}"
                          for m in pattern.finditer(text)]
        self.assertGreater(scanned, 0)
        self.assertEqual(offenders, [], "a test reads a path that needs-build.py skips")


class IntegrateOpenPGPTests(unittest.TestCase):
    """The edits of integrate-openpgp.py, on the repository's own files."""

    COMMIT = "a" * 40
    CHECKSUM = "b" * 64

    def setUp(self):
        self.project = (REPO / "project.yml").read_text()
        self.dependencies = (REPO / "docs" / "DEPENDENCIES.md").read_text()
        self.changelog = (REPO / "CHANGELOG.md").read_text()

    def new(self, **overrides):
        values = {"version": "9.8.7", "commit": self.COMMIT, "checksum": self.CHECKSUM,
                  "date": "1 January 2030", "pgp": "1.2.3", "licence": "MIT OR Apache-2.0",
                  "crates": 150, "advisories": []}
        return {**values, **overrides}

    def old(self):
        return {"version": integrate_openpgp.current_release(self.dependencies),
                "commit": integrate_openpgp.current_pin(self.project), "checksum": "c" * 64}

    def test_project_pin_and_comment(self):
        edited = integrate_openpgp.edit_project(self.project, "9.8.7", self.COMMIT)
        self.assertEqual(integrate_openpgp.current_pin(edited), self.COMMIT)
        self.assertIn("Release v9.8.7, pinned", edited)
        # GRDB's pin is untouched.
        grdb = re.search(r"^  GRDB:\n    url: \S+\n    revision: (\S+)$", self.project, re.M).group(0)
        self.assertIn(grdb, edited)

    def test_dependencies_only_the_openpgp_section(self):
        edited = integrate_openpgp.edit_dependencies(self.dependencies, self.old(), self.new())
        start, end = integrate_openpgp.openpgp_section(self.dependencies)
        self.assertEqual(edited[:start], self.dependencies[:start])
        self.assertTrue(edited.endswith(self.dependencies[end:]))
        section = integrate_openpgp.section(edited)
        for text in ("| Release | `v9.8.7` |", f"`{self.COMMIT}`", f"`{self.CHECKSUM}`",
                     "| Recorded | 1 January 2030 |", "(`pgp` =1.2.3, MIT OR Apache-2.0) and 150 crates",
                     "from the `v9.8.7` GitHub release", "Recorded for `v9.8.7`"):
            self.assertIn(text, section)
        self.assertEqual(integrate_openpgp.current_release(edited), "9.8.7")
        self.assertTrue(all(len(line) <= 76 for line in section.split("Recorded for `v9.8.7`")[1]
                            .split("\n\n")[0].splitlines()))

    def test_advisories_read_from_the_table(self):
        self.assertEqual(integrate_openpgp.table_advisories(self.dependencies),
                         ["RUSTSEC-2023-0071", "RUSTSEC-2026-0387"])

    def test_changelog_entry_first_under_unreleased(self):
        edited = integrate_openpgp.edit_changelog(self.changelog, "9.8.7", "1.2.3")
        after = edited.split("## [Unreleased]\n\n", 1)[1]
        self.assertTrue(after.startswith("- The OpenPGP library moves to v9.8.7"))

    def test_missing_row_fails(self):
        with self.assertRaises(integrate_openpgp.Failure):
            integrate_openpgp.edit_dependencies(
                self.dependencies.replace("| Recorded |", "| Noted |"), self.old(), self.new())

    def test_package_fields(self):
        manifest = 'let version = "1.2.3"\nlet checksum = "' + self.CHECKSUM + '"\n'
        self.assertEqual(integrate_openpgp.package_fields(manifest), ("1.2.3", self.CHECKSUM))
        with self.assertRaises(integrate_openpgp.Failure):
            integrate_openpgp.package_fields("let version = v\n")


    def test_pinning_commit_is_the_one_that_set_the_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)

            def commit(manifest):
                (repo / "Package.swift").write_text(manifest)
                subprocess.run(["git", "add", "Package.swift"], cwd=repo, check=True)
                subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                                "commit", "-qm", "c"], cwd=repo, check=True)
                return subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True,
                                      capture_output=True, text=True).stdout.strip()

            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            commit('let version = "0.0.0"  // no release yet\n')
            setter = commit('let version = "1.0.0"\nlet checksum = "' + self.CHECKSUM + '"\n')
            commit('// renamed\nlet version = "1.0.0"\nlet checksum = "' + self.CHECKSUM + '"\n')
            self.assertEqual(integrate_openpgp.pinning_commit(repo, "1.0.0", "HEAD"), setter)
            with self.assertRaisesRegex(integrate_openpgp.Failure, "pull request merged"):
                integrate_openpgp.pinning_commit(repo, "2.0.0", "HEAD")

    def test_pipeline_paths(self):
        for path in (".github", "scripts", ".cargo", "rust/.cargo", "rust/deny.toml",
                     "rust/rust-toolchain.toml", "rust/rust-toolchain"):
            self.assertIn(path, integrate_openpgp.PIPELINE)

    def test_manifest_shape_ignores_only_version_and_checksum(self):
        a = 'let version = "1.0.0"\nlet checksum = "' + self.CHECKSUM + '"\nproducts\n'
        b = 'let version = "1.0.1"\nlet checksum = "' + "d" * 64 + '"\nproducts\n'
        self.assertEqual(integrate_openpgp.manifest_shape(a), integrate_openpgp.manifest_shape(b))
        self.assertNotEqual(integrate_openpgp.manifest_shape(a),
                            integrate_openpgp.manifest_shape(b + '.package(url: "x", branch: "main")\n'))

    def test_deny_advisories_both_forms(self):
        text = ('[advisories]\nignore = [\n  { id = "RUSTSEC-2023-0071", reason = "r" },\n'
                '  "RUSTSEC-2026-0001",\n  # { id = "RUSTSEC-1999-0001" },\n]\n')
        self.assertEqual(integrate_openpgp.deny_advisories(text),
                         ["RUSTSEC-2023-0071", "RUSTSEC-2026-0001"])

    def test_values_are_inserted_literally(self):
        edited = integrate_openpgp.edit_dependencies(
            self.dependencies, self.old(), self.new(licence="MIT \\g<0> \\n"))
        self.assertIn("(`pgp` =1.2.3, MIT \\g<0> \\n) and 150 crates", edited)

    def test_licence_and_version_patterns(self):
        self.assertTrue(integrate_openpgp.LICENCE.match("MIT OR Apache-2.0"))
        self.assertFalse(integrate_openpgp.LICENCE.match("MIT\n## Injected"))
        self.assertFalse(integrate_openpgp.LICENCE.match("MIT [x](https://e.invalid) @someone"))
        self.assertFalse(integrate_openpgp.SEMVER.match("\u0663.0.0"))

    def test_review_reasons(self):
        m = 'let version = "1.0.0"\nlet checksum = "' + self.CHECKSUM + '"\nproducts\n'
        m2 = m.replace("1.0.0", "1.0.1")
        adv = ["RUSTSEC-2023-0071"]
        reasons = integrate_openpgp.review_reasons
        self.assertEqual(reasons(m2, m, [], adv, adv), [])
        self.assertEqual(len(reasons(m2 + "targets\n", m, [], adv, adv)), 1)
        self.assertIn("`.github/workflows/release.yml`",
                      reasons(m2, m, [".github/workflows/release.yml"], adv, adv)[0])
        self.assertIn("advisories", reasons(m2, m, [], adv, adv + ["RUSTSEC-2026-0001"])[0])
        self.assertEqual(len(reasons(m2 + "x\n", m, ["scripts/a.sh"], adv, [])), 3)

    def test_deny_advisories_rejects_free_text(self):
        with self.assertRaises(integrate_openpgp.Failure):
            integrate_openpgp.deny_advisories('[advisories]\nignore = ["approved in DEC-051 @someone"]\n')

if __name__ == "__main__":
    unittest.main()
