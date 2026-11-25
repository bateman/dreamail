#!/usr/bin/env python3
"""One-off rename of the product from MishMail to DreaMail (DEC-065).

Reproducible record of the mechanical part of the rename. Run from the
repository root on a clean tree:

    python3 scripts/rename-dreamail.py            # app names, paths, switches
    python3 scripts/rename-dreamail.py --library  # also the OpenPGP library's
                                                  # module, header and symbols

The script only does exact, case-sensitive replacements of whole known
forms (never a bare substring such as "mish"), then moves files with
`git mv` so history follows. Everything it does not touch is reviewed by
hand afterwards: archives, released CHANGELOG entries, the decision
register's past entries, references to the upstream project, and the
guards that must name the old forms they forbid.

Order matters: longer forms first, so "Handle with Mish" is not caught by
a shorter rule, and the upstream identifiers are masked before the
product rules run.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# Paths never rewritten: dated archives, the rebranding study itself, and
# documents whose past entries are history (edited by hand).
EXCLUDED_PREFIXES = (
    "docs/codex-reviews/",
    "docs/plans/",
    "docs/superpowers/",
    "docs/studi/",
    "reviews/",
    "docs/security-review",
)
EXCLUDED_FILES = {
    "CHANGELOG.md",
    "docs/registro-decisioni.md",
    "docs/piano-sviluppo.md",
    "docs/naming.md",
    "LICENSE",
    "scripts/rename-dreamail.py",
    # The guard against the old name: it must spell the forms it forbids.
    "Tests/MishMailTests/OldProductNameTests.swift",
    "Tests/DreaMailTests/OldProductNameTests.swift",
}

# Upstream identifiers: another product, still called MishMail. Masked so
# the product rules below leave them alone. The bundle id prefix is split so
# ForkIdentityTests' scan for it does not match this file.
PROTECTED = (
    "github.com/ronboger/mishmail",
    "ronboger/mishmail",
    "dev." "ronboger.MishMail",
)

# The app's own names. Exact forms, applied in this order.
RULES = (
    ("Handle-with-Mish", "Handle-with-AI"),
    ("Handle with Mish", "Handle with AI"),
    ("ThreadWithMish", "ThreadWithAI"),
    ("Ask Mish", "Ask AI"),
    ("AskMish", "AskAI"),
    ("askMish", "askAI"),
    ("askmish", "askai"),
    ("MishMail", "DreaMail"),
    ("mishmail", "dreamail"),
    ("MISHMAIL", "DREAMAIL"),
)

# The OpenPGP library (bateman/dreamail-openpgp v0.2.0): module, header,
# static library and C symbols. Applied only with --library, together with
# the new pin in project.yml.
LIBRARY_RULES = (
    ("MishMailRPGP", "DreaMailRPGP"),
    ("libmishmail_rpgp", "libdreamail_rpgp"),
    ("mishmail_rpgp", "dreamail_rpgp"),
    ("mm_pgp_", "dm_pgp_"),
    ("MMResult", "DMResult"),
    ("MMBuffer", "DMBuffer"),
)
# Library forms that the product rules would otherwise rewrite early.
LIBRARY_FORMS = ("MishMailRPGP", "libmishmail_rpgp", "mishmail_rpgp")


def git(*args: str) -> str:
    return subprocess.run(("git",) + args, check=True, text=True,
                          capture_output=True).stdout


def excluded(path: str) -> bool:
    return path in EXCLUDED_FILES or path.startswith(EXCLUDED_PREFIXES)


def rewrite(text: str, library: bool) -> str:
    masks: dict[str, str] = {}

    def mask(token: str) -> None:
        nonlocal text
        key = f"\x00{len(masks)}\x00"
        masks[key] = token
        text = text.replace(token, key)

    for token in PROTECTED:
        mask(token)
    if library:
        for old, new in LIBRARY_RULES:
            text = text.replace(old, new)
    else:
        for token in LIBRARY_FORMS:
            mask(token)
    for old, new in RULES:
        text = text.replace(old, new)
    for key, token in masks.items():
        text = text.replace(key, token)
    return text


def new_path(path: str) -> str:
    for old, new in (("AskMish", "AskAI"), ("MishMail", "DreaMail"),
                     ("mishmail", "dreamail")):
        path = path.replace(old, new)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--library", action="store_true",
                        help="also rename the OpenPGP library's names")
    args = parser.parse_args()

    if git("status", "--porcelain").strip():
        print("rename-dreamail: working tree not clean", file=sys.stderr)
        return 1

    changed = 0
    for path in git("ls-files", "-z").split("\0"):
        if not path or excluded(path) or os.path.islink(path):
            continue
        with open(path, "rb") as f:
            raw = f.read()
        if b"\0" in raw:
            continue  # binary
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        out = rewrite(text, args.library)
        if out != text:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(out)
            changed += 1

    moved = 0
    for path in git("ls-files", "-z").split("\0"):
        if not path or excluded(path):
            continue
        target = new_path(path)
        if target != path:
            os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
            git("mv", path, target)
            moved += 1

    print(f"rename-dreamail: {changed} files rewritten, {moved} moved; "
          "review what is left with `git grep -i -n mishmail` and "
          "`git grep -n Mish`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
