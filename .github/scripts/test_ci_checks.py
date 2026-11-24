"""Tests for the CI guard scripts in this directory.

Run: python3 -m unittest discover -s .github/scripts -p 'test_*.py' -v
"""

import importlib.util
import io
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
        "Test Case '-[MishMailTests.FooTests testBar]' started.\n"
        "Test Case '-[MishMailTests.FooTests testBar]' passed (0.001 seconds).\n"
        "\t Executed 2425 tests, with 0 failures (0 unexpected) in 61.0 (63.0) seconds\n"
    )

    def test_clean_run_passes(self):
        self.assertEqual(self.run_check(self.PASSED)[0], 0)

    def test_allowlisted_skip_passes(self):
        log = self.PASSED + (
            "Test Case '-[MishMailTests.HTMLBodyHeightLoopTests "
            "testViewportLengthsArePinnedNotCollapsed]' skipped (4.460 seconds).\n")
        self.assertEqual(self.run_check(log)[0], 0)

    def test_unlisted_skip_fails(self):
        log = self.PASSED + (
            "Test Case '-[MishMailTests.UpdateVerifySmokeTests testBuiltAppVerifies]' "
            "skipped (0.001 seconds).\n")
        status, out = self.run_check(log)
        self.assertEqual(status, 1)
        self.assertIn("UpdateVerifySmokeTests.testBuiltAppVerifies was skipped", out)

    def test_ui_test_target_skip_fails(self):
        log = self.PASSED + (
            "Test Case '-[MishMailUITests.SmokeTests testLaunch]' skipped (0.1 seconds).\n")
        self.assertEqual(self.run_check(log)[0], 1)

    def test_log_without_tests_fails(self):
        self.assertEqual(self.run_check("** BUILD SUCCEEDED **\n")[0], 1)
        self.assertEqual(self.run_check("\t Executed 0 tests, with 0 failures\n")[0], 1)

    def test_repository_allowlist_parses(self):
        entries = check_test_skips.read_allowlist(check_test_skips.DEFAULT_ALLOWLIST)
        self.assertTrue(entries)
        for entry in entries:
            self.assertRegex(entry, r"^\w+\.test\w+$")


if __name__ == "__main__":
    unittest.main()
