#!/usr/bin/env python3
"""Split the UI test classes into CI shards by measured duration.

The classes are found in the UI test sources (every `class X: XCTestCase`
in Tests/DreaMailUITests/**/*.swift, as project.yml compiles them), so a new test class lands in a shard with
no list to edit. Each class weighs its measured duration from
.github/ui-test-durations.txt; a class not listed there weighs
DEFAULT_SECONDS. The split is greedy longest-first: each class, slowest
first (ties by name), goes to the shard with the least time so far (ties to
the lowest shard). Same sources and durations, same split.

The last shard runs everything except what the other shards run
(-skip-testing), so a class this script fails to find still runs there.
After a shard's run, `check` reads its log and fails when a class assigned
to it ran no test, so no class can silently stop running.

Usage:
  ui-shards.py flags SHARD COUNT   xcodebuild arguments for shard SHARD of COUNT
  ui-shards.py check LOG SHARD COUNT
  ui-shards.py show COUNT          the split, with the expected time per shard
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SOURCES = REPO / "Tests" / "DreaMailUITests"
DURATIONS = REPO / ".github" / "ui-test-durations.txt"
TARGET = "DreaMailUITests"
# About the mean of the measured classes (November 2026).
DEFAULT_SECONDS = 60.0

# Attributes and modifiers may precede `class` on the same line
# (`@MainActor final class X: XCTestCase`). A subclass of another test class
# is not found: it runs in the last shard, and `check` warns about it.
CLASS = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)\n]*\))?[ \t]+)*"
    r"(?:(?:final|public|internal|open|private|fileprivate|nonisolated)[ \t]+)*"
    r"class[ \t]+(\w+)[ \t]*:[ \t]*XCTestCase\b", re.M)
TEST_CASE = re.compile(r"Test Case '-\[(?:\w+\.)?(?P<cls>\w+) \w+\]' (?:passed|failed|skipped)")


def find_classes(sources: Path = SOURCES) -> list[str]:
    classes = set()
    for path in sorted(sources.rglob("*.swift")):
        classes.update(CLASS.findall(path.read_text(errors="replace")))
    return sorted(classes)


def read_durations(path: Path = DURATIONS) -> dict[str, float]:
    durations = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) != 2:
            raise ValueError(f"{path}:{number}: expected 'Class seconds', got {line!r}")
        if fields[0] in durations:
            raise ValueError(f"{path}:{number}: {fields[0]} is listed twice")
        durations[fields[0]] = float(fields[1])
    return durations


def split(classes: list[str], durations: dict[str, float], count: int) -> list[list[str]]:
    if count < 1:
        raise ValueError(f"shard count must be at least 1, not {count}")
    shards: list[list[str]] = [[] for _ in range(count)]
    loads = [0.0] * count
    weight = lambda name: durations.get(name, DEFAULT_SECONDS)
    for name in sorted(classes, key=lambda name: (-weight(name), name)):
        index = loads.index(min(loads))
        shards[index].append(name)
        loads[index] += weight(name)
    return [sorted(shard) for shard in shards]


def shard_index(shard: str, count: str) -> tuple[int, int]:
    if not (shard.isdigit() and count.isdigit() and 1 <= int(shard) <= int(count)):
        raise ValueError(f"shard must be a number from 1 to COUNT, got shard {shard!r} of {count!r}")
    return int(shard) - 1, int(count)


def flags(shards: list[list[str]], index: int) -> list[str]:
    if index < len(shards) - 1:
        return [f"-only-testing:{TARGET}/{name}" for name in shards[index]]
    others = [name for i, shard in enumerate(shards) if i != index for name in shard]
    return [f"-skip-testing:{TARGET}/{name}" for name in others]


def check(log: str, shards: list[list[str]], index: int) -> int:
    ran: dict[str, int] = {}
    for match in TEST_CASE.finditer(log):
        ran[match["cls"]] = ran.get(match["cls"], 0) + 1
    assigned = shards[index]
    missing = [name for name in assigned if name not in ran]
    others = {name for i, shard in enumerate(shards) if i != index for name in shard}
    stray = sorted(set(ran) - set(assigned))
    print(f"Shard {index + 1} of {len(shards)}: {len(assigned)} classes assigned, "
          f"{len(ran)} ran, {sum(ran.values())} tests")
    for name in assigned:
        print(f"  {name}: {ran.get(name, 0)} tests{'  <- DID NOT RUN' if name in missing else ''}")
    status = 0
    for name in missing:
        print(f"::error::{name} is assigned to UI shard {index + 1} but ran no test "
              "(is the class name the one in its source file?)")
        status = 1
    for name in stray:
        if name in others:
            print(f"::error::{name} belongs to another UI shard but ran in shard {index + 1}")
            status = 1
        else:
            # Only the last shard can run a class it was not given.
            print(f"::warning::{name} ran but ui-shards.py did not find it in "
                  f"{SOURCES.relative_to(REPO)}; fix CLASS so it gets a shard by duration")
    return status


def main(argv: list[str]) -> int:
    try:
        command, args = argv[0], argv[1:]
        classes = find_classes()
        if not classes:
            print(f"::error::no XCTestCase class found in {SOURCES}", file=sys.stderr)
            return 1
        durations = read_durations()
        if command == "flags" and len(args) == 2:
            index, count = shard_index(*args)
            print(" ".join(flags(split(classes, durations, count), index)))
            return 0
        if command == "check" and len(args) == 3:
            index, count = shard_index(args[1], args[2])
            log = Path(args[0]).read_text(errors="replace")
            return check(log, split(classes, durations, count), index)
        if command == "show" and len(args) == 1:
            count = int(args[0])
            for number, shard in enumerate(split(classes, durations, count), 1):
                total = sum(durations.get(name, DEFAULT_SECONDS) for name in shard)
                print(f"shard {number}: {total / 60:.1f} min, {len(shard)} classes")
                for name in shard:
                    note = "" if name in durations else " (no measurement: default)"
                    print(f"  {durations.get(name, DEFAULT_SECONDS):6.0f} s  {name}{note}")
            return 0
    except (IndexError, ValueError) as error:
        if not isinstance(error, IndexError):
            print(f"ui-shards.py: {error}", file=sys.stderr)
            return 2
    print(__doc__.strip().split("Usage:")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
