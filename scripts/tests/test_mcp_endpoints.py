"""The helper scripts send mail text, a model API key and the MCP bearer
token: plain HTTP only to a literal loopback address, HTTPS otherwise,
redirects held to the same rule (finding F-05).

Run by Tests/MishMailTests/ScriptEndpointTests.swift, or directly:
    python3 -m unittest discover -s scripts/tests -v

No test touches the network: the shared opener is replaced by a recorder,
so "nothing was sent" is observable.
"""

import importlib.util
import io
import os
import sys
import unittest
import urllib.request
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

import mcp_common  # noqa: E402


def load_summarize():
    spec = importlib.util.spec_from_file_location("mcp_summarize", SCRIPTS / "mcp-summarize.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecordingOpener:
    """Stands in for the shared urllib opener and records every request."""

    def __init__(self):
        self.requests = []

    def open(self, req, timeout=None):
        self.requests.append(req)
        raise AssertionError(f"unexpected request to {req.full_url}")


class EndpointRuleTests(unittest.TestCase):
    def test_accepts_https_and_literal_loopback_http(self):
        for url in ["https://api.x.ai/v1",
                    "https://llm.example:8443/v1",
                    "http://127.0.0.1:11434",
                    "http://127.0.0.2:8080/v1",
                    "http://[::1]:11434"]:
            self.assertEqual(mcp_common.validate_endpoint(url), url)

    def test_refuses_remote_http_names_and_other_schemes(self):
        for url in ["http://203.0.113.5/v1",
                    "http://llm.example/v1",
                    # A name is not a literal: it resolves wherever DNS says.
                    "http://localhost:11434",
                    "http://127.0.0.1.evil.example/v1",
                    "http://10.0.0.5:11434",
                    "ftp://127.0.0.1/",
                    "file:///etc/passwd",
                    "https://sk-secret@api.example/v1",
                    "https://user:pass@api.example/v1",
                    "not a url",
                    ""]:
            with self.assertRaises(mcp_common.EndpointError, msg=url):
                mcp_common.validate_endpoint(url)


class NothingSentToRemoteHTTPTests(unittest.TestCase):
    """These assert on what reached the opener, not on the exception type,
    so they also fail (rather than error) against the pre-fix scripts."""

    def setUp(self):
        self.opener = RecordingOpener()
        patcher = mock.patch.object(mcp_common, "_OPENER", self.opener)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.summarize = load_summarize()

    def test_openai_backend_sends_neither_key_nor_mail_over_remote_http(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-not-real"}):
            with self.assertRaises(Exception):
                self.summarize.summarize_openai(
                    "http://203.0.113.5/v1", "some-model", "Subject: payroll\n\nprivate text")
        self.assertEqual(self.opener.requests, [])

    def test_ollama_backend_sends_no_mail_over_remote_http(self):
        with self.assertRaises(Exception):
            self.summarize.summarize_ollama(
                "http://gpu.example:11434", "llama3.2:3b", "private text")
        self.assertEqual(self.opener.requests, [])

    def test_mcp_client_refuses_a_non_loopback_url(self):
        with self.assertRaises(Exception):
            mcp_common.post_json("http://192.0.2.1:41888/mcp", {"jsonrpc": "2.0"},
                                 {"Authorization": "Bearer t"})
        self.assertEqual(self.opener.requests, [])

    def test_main_refuses_before_reading_any_mail(self):
        constructed = []

        class NoMCP:
            def __init__(self, *a, **k):
                constructed.append(True)
                raise AssertionError("MCP must not be contacted")

        argv = ["mcp-summarize.py", "--backend", "openai",
                "--api-base", "http://203.0.113.5/v1", "--model", "m"]
        with mock.patch.object(self.summarize, "MCP", NoMCP), \
                mock.patch.object(sys, "argv", argv), \
                mock.patch.dict(os.environ, {"OPENAI_API_KEY": "sk-test-not-real"}):
            with self.assertRaises(SystemExit) as exit_:
                self.summarize.main()
        self.assertIn("--api-base", str(exit_.exception.code))
        self.assertEqual(constructed, [])
        self.assertEqual(self.opener.requests, [])

    def test_ollama_default_base_is_accepted(self):
        argv = ["mcp-summarize.py", "--dry-run", "--limit", "0"]

        class EmptyMCP:
            def call(self, tool, args=None):
                return "[]"

        with mock.patch.object(self.summarize, "MCP", EmptyMCP), \
                mock.patch.object(sys, "argv", argv), \
                redirect_stderr(io.StringIO()):
            self.summarize.main()

    def test_no_api_key_option_on_the_command_line(self):
        argv = ["mcp-summarize.py", "--backend", "openai", "--api-base",
                "https://api.example/v1", "--model", "m", "--api-key", "sk-x"]
        with mock.patch.object(sys, "argv", argv), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as exit_:
                self.summarize.main()
        self.assertEqual(exit_.exception.code, 2)


class RedirectTests(unittest.TestCase):
    def redirect(self, start, target):
        handler = mcp_common._ValidatingRedirectHandler()
        req = urllib.request.Request(start, data=b"{}",
                                     headers={"Authorization": "Bearer sk-test"})
        return handler.redirect_request(req, None, 302, "Found", {}, target)

    def test_redirect_to_remote_http_is_refused(self):
        with self.assertRaises(mcp_common.EndpointError):
            self.redirect("https://api.example/v1/chat/completions",
                          "http://api.example/v1/chat/completions")

    def test_redirect_to_another_origin_is_refused(self):
        for target in ["https://collector.example/v1",
                       "https://api.example:8443/v1",
                       "http://127.0.0.1:11434/api/generate"]:
            with self.assertRaises(mcp_common.EndpointError, msg=target):
                self.redirect("https://api.example/v1/chat/completions", target)

    def test_same_origin_https_redirect_is_followed(self):
        # urllib turns a redirected POST into a GET; the point here is only
        # that the handler does not refuse it.
        new = self.redirect("https://api.example/v1/chat/completions",
                            "/v2/chat/completions")
        self.assertEqual(new.full_url, "https://api.example/v2/chat/completions")


if __name__ == "__main__":
    unittest.main()
