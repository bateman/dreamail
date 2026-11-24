"""Shared MCP client for the MishMail helper scripts."""

import ipaddress
import json
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DISCOVERY = (Path.home() / "Library/Containers/io.github.bateman.MishMail/Data"
             / "Library/Application Support/MishMail/mcp.json")
# Preferred: a copy of the token outside the app container. Reading the
# container itself needs Full Disk Access, and on a Mac without it the read
# BLOCKS on a TCC prompt rather than failing — so try this first.
TOKEN_FILE = Path.home() / ".config/mishmail/mcp-token"
DEFAULT_PORT = "41888"


class EndpointError(ValueError):
    """A destination these scripts refuse to send mail text or keys to."""


def _is_literal_loopback(host):
    """True for an IP literal in 127.0.0.0/8 or ::1. A name such as
    `localhost` is not literal: it resolves through whatever the system says."""
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def origin(url):
    """(scheme, host, port) with default ports filled in."""
    parts = urllib.parse.urlsplit(url)
    scheme = (parts.scheme or "").lower()
    host = (parts.hostname or "").lower()
    port = parts.port or {"http": 80, "https": 443}.get(scheme)
    return scheme, host, port


def validate_endpoint(url):
    """Every request these scripts make carries mail text, a model API key or
    the MCP bearer token, so: plain HTTP only to a literal loopback address,
    HTTPS everywhere else, and no credentials inside the URL. Raises
    EndpointError; returns the URL unchanged when it is acceptable."""
    try:
        parts = urllib.parse.urlsplit(url)
        parts.port  # raises ValueError on a malformed port
    except ValueError as e:
        raise EndpointError(f"{url!r} is not a valid URL: {e}") from None
    scheme = (parts.scheme or "").lower()
    host = parts.hostname or ""
    if not host:
        raise EndpointError(f"{url!r} has no host")
    if parts.username is not None or parts.password is not None:
        raise EndpointError(f"{url!r} carries credentials; pass keys in the environment")
    if scheme == "https":
        return url
    if scheme == "http" and _is_literal_loopback(host):
        return url
    if scheme == "http":
        raise EndpointError(
            f"{url!r} is plain HTTP to a host that is not a loopback address "
            "(127.0.0.1 or ::1); mail and keys would travel unencrypted. Use https://")
    raise EndpointError(f"{url!r}: only https:// (or http:// to 127.0.0.1) is allowed")


class _ValidatingRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to a destination `validate_endpoint` accepts
    and on the same origin: urllib would otherwise resend the Authorization
    header to wherever the server points."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        newurl = urllib.parse.urljoin(req.full_url, newurl)
        validate_endpoint(newurl)
        if origin(newurl) != origin(req.full_url):
            raise EndpointError(
                f"refusing redirect from {req.full_url!r} to another origin {newurl!r}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


# urllib consults macOS system proxy settings, so a VPN or PAC file can make
# even a 127.0.0.1 request hang. The MCP server is always loopback — never
# proxy it.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                      _ValidatingRedirectHandler())


def post_json(url, payload, headers=None, timeout=180):
    validate_endpoint(url)
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **(headers or {})})
    with _OPENER.open(req, timeout=timeout) as r:
        return json.loads(r.read())


class MCP:
    """Minimal JSON-RPC client against the in-app MishMail MCP server."""

    def __init__(self, discovery=DISCOVERY):
        # Env wins over the discovery file: a launchd agent (or any process
        # without Full Disk Access) cannot read another app's sandbox
        # container, but the port is fixed and the token is stable, so both
        # can simply be supplied.
        token = os.environ.get("MISHMAIL_MCP_TOKEN")
        port = os.environ.get("MISHMAIL_MCP_PORT", DEFAULT_PORT)
        if not token and TOKEN_FILE.exists():
            token = TOKEN_FILE.read_text().strip() or None
        cfg = None
        if Path(discovery).exists():
            try:
                cfg = json.loads(Path(discovery).read_text())
            except PermissionError:
                cfg = None
            except json.JSONDecodeError:
                cfg = None
        if cfg and cfg.get("port") is not None and "MISHMAIL_MCP_PORT" not in os.environ:
            port = cfg["port"]
        if not token and cfg and cfg.get("token"):
            # Legacy mcp.json that still stored the bearer token.
            token = cfg["token"]
        if not token:
            sys.exit("MISHMAIL_MCP_TOKEN is unset, ~/.config/mishmail/mcp-token "
                     "is missing, and mcp.json has no token. Copy the token "
                     "from Settings → AI → MCP.")
        self.url = f"http://127.0.0.1:{port}/mcp"
        self.headers = {"Authorization": f"Bearer {token}"}
        self._id = 0
        # Callers may summarize concurrently (--jobs); keep ids unique.
        self._lock = threading.Lock()

    def call(self, tool, args=None):
        with self._lock:
            self._id += 1
            rpc_id = self._id
        resp = post_json(self.url, {
            "jsonrpc": "2.0", "id": rpc_id, "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }, self.headers)
        if "error" in resp:
            raise RuntimeError(f"{tool}: {resp['error']['message']}")
        result = resp["result"]
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {text}")
        return text
