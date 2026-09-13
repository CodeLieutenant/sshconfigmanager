#!/usr/bin/env python3
"""changelog.py — read, check and release the Keep a Changelog files.

One changelog, one release train: CHANGELOG.md, tags v*.

Section format. The date and the title are optional on [Unreleased] and
required on a numbered version:

    ## [1.1.0] - 2026-08-10 — Stronger crypto and failures you can read

    One paragraph. It becomes the first line of the App Store notes.

    ### Added
    - One change, written for the reader of that changelog.

Commands:
    check                        Validate the format. Exit 1 on any error.
    show [version]               Print one section (default: unreleased).
    notes [version] [--write] [--project]
                                 Render the section as App Store notes.
                                 --write updates fastlane release_notes.txt.
                                 --project takes the version from the Xcode
                                 project and falls back to [Unreleased]. This is
                                 what the fastlane lanes call.
    release <version> [--date YYYY-MM-DD]
                                 Promote [Unreleased] to a numbered section and
                                 open an empty [Unreleased] above it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CHANGELOG = ROOT / "CHANGELOG.md"

KINDS = ["added", "changed", "deprecated", "removed", "fixed", "security"]

RELEASE_NOTES = ROOT / "fastlane/metadata/en-US/release_notes.txt"
PBXPROJ = ROOT / "sshconfigmanager.xcodeproj/project.pbxproj"
NOTES_FOOTER = (
    "Found a bug or have an idea? Open an issue at "
    "https://github.com/CodeLieutenant/sshconfigmanager/issues"
)
NOTES_LIMIT = 4000  # App Store Connect rejects a longer "What's New".
# A bullet for a platform the App Store does not ship.
OTHER_PLATFORM = re.compile(r"^(Linux)\.\s")

HEADING = re.compile(
    r"^## \[(?P<version>[^\]]+)\]"
    r"(?: - (?P<date>\d{4}-\d{2}-\d{2}))?"
    r"(?:\s+[—-]\s+(?P<title>.+?))?\s*$"
)
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
MARKETING_VERSION = re.compile(r"MARKETING_VERSION = ([0-9.]+);")


@dataclass
class Section:
    version: str
    date: str | None
    title: str
    summary: str
    line: int
    changes: dict[str, list[str]] = field(default_factory=dict)

    @property
    def unreleased(self) -> bool:
        return self.version.lower() == "unreleased"

    @property
    def empty(self) -> bool:
        return not any(self.changes.values())


def parse(path: Path) -> tuple[list[Section], list[str]]:
    errors: list[str] = []
    sections: list[Section] = []
    current: Section | None = None
    kind: str | None = None
    summary: list[str] = []
    bullet: list[str] = []

    def flush_bullet() -> None:
        nonlocal bullet
        if bullet and current is not None and kind is not None:
            current.changes.setdefault(kind, []).append(" ".join(bullet).strip())
        bullet = []

    def flush_summary() -> None:
        if current is not None and not current.summary:
            current.summary = " ".join(s.strip() for s in summary if s.strip()).strip()

    where = path.relative_to(ROOT)
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip()
        if line.startswith("## "):
            flush_bullet()
            flush_summary()
            match = HEADING.match(line)
            if not match:
                errors.append(f"{where}:{number}: unparsable version heading: {line}")
                current, kind = None, None
                continue
            current = Section(
                version=match["version"].strip(),
                date=match["date"],
                title=(match["title"] or "").strip(),
                summary="",
                line=number,
            )
            sections.append(current)
            kind, summary[:] = None, []
            continue

        if line.startswith("### "):
            flush_bullet()
            flush_summary()
            if current is None:
                errors.append(f"{where}:{number}: change section outside a version")
                continue
            kind = line[4:].strip().lower()
            if kind not in KINDS:
                errors.append(
                    f"{where}:{number}: unknown section '{line[4:].strip()}'."
                    f" Use one of: {', '.join(k.capitalize() for k in KINDS)}"
                )
            continue

        if current is None:
            continue

        if line.startswith("- ") or line.startswith("* "):
            flush_bullet()
            if kind is None:
                errors.append(
                    f"{where}:{number}: bullet outside a ### section"
                    f" in [{current.version}]"
                )
                continue
            bullet = [line[2:].strip()]
        elif bullet and line.strip() and line.startswith((" ", "\t")):
            bullet.append(line.strip())
        elif kind is None and line.strip():
            summary.append(line)
        else:
            flush_bullet()

    flush_bullet()
    flush_summary()
    return sections, errors


def check() -> list[str]:
    where = CHANGELOG.relative_to(ROOT)
    sections, errors = parse(CHANGELOG)

    if not sections:
        return errors + [f"{where}: no version sections"]

    seen: set[str] = set()
    for index, section in enumerate(sections):
        at = f"{where}:{section.line}"
        if section.unreleased:
            if index != 0:
                errors.append(f"{at}: [Unreleased] must be the first section")
            continue
        if not SEMVER.match(section.version):
            errors.append(f"{at}: '{section.version}' is not a X.Y.Z version")
        if not section.date:
            errors.append(f"{at}: [{section.version}] needs a release date")
        if section.version in seen:
            errors.append(f"{at}: duplicate version {section.version}")
        seen.add(section.version)
        if section.empty and not section.summary:
            errors.append(f"{at}: [{section.version}] has no entries and no summary")
        if not section.title:
            errors.append(f"{at}: [{section.version}] needs a title after an em dash")

    dated = [s for s in sections if s.date]
    if dated != sorted(dated, key=lambda s: s.date or "", reverse=True):
        errors.append(f"{where}: versions must run newest first")

    return errors


def pick(version: str, or_unreleased: bool = False) -> Section:
    sections, errors = parse(CHANGELOG)
    if errors:
        sys.exit("\n".join(errors))
    wanted = version.lower().lstrip("v")
    for section in sections:
        if section.version.lower() == wanted:
            return section
    if or_unreleased and sections and sections[0].unreleased:
        print(f"no [{version}] section yet, using [Unreleased]", file=sys.stderr)
        return sections[0]
    sys.exit(f"no section for '{version}'")


def plain(text: str) -> str:
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"[`*_]", "", text)
    return text.strip()


def marketing_version() -> str | None:
    if not PBXPROJ.exists():
        return None
    found = MARKETING_VERSION.findall(PBXPROJ.read_text(encoding="utf-8"))
    return found[0] if found else None


def render_notes(section: Section) -> str:
    """App Store notes for one section.

    A bullet that opens with a platform name belongs to that platform alone. The
    App Store ships the Mac app, so a bullet marked for another platform is
    dropped rather than shown to a reader who cannot act on it.
    """
    parts: list[str] = []
    if section.summary:
        parts.append(plain(section.summary))
    bullets = [
        f"• {text}"
        for kind in KINDS
        for body in section.changes.get(kind, [])
        for text in [plain(body)]
        if not OTHER_PLATFORM.match(text)
    ]
    if bullets:
        parts.append("\n".join(bullets))
    parts.append(NOTES_FOOTER)
    return "\n\n".join(parts) + "\n"


def cmd_check(args: argparse.Namespace) -> int:
    errors = check()
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("changelog: OK")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    section = pick(args.version)
    head = f"[{section.version}]"
    if section.date:
        head += f" - {section.date}"
    if section.title:
        head += f" — {section.title}"
    print(head)
    if section.summary:
        print(f"\n{section.summary}")
    for kind in KINDS:
        for body in section.changes.get(kind, []):
            print(f"  [{kind}] {body}")
    return 0


def cmd_notes(args: argparse.Namespace) -> int:
    if args.project:
        version = marketing_version()
        if not version:
            sys.exit("cannot read MARKETING_VERSION from the Xcode project")
        section = pick(version, or_unreleased=True)
    else:
        section = pick(args.version)

    if section.empty and not section.summary:
        sys.exit(f"[{section.version}] has nothing to say — write the entries first")

    text = render_notes(section)
    if len(text) > NOTES_LIMIT:
        print(
            f"release notes are {len(text)} characters, over the"
            f" {NOTES_LIMIT} App Store limit",
            file=sys.stderr,
        )
        return 1
    if args.write:
        RELEASE_NOTES.write_text(text, encoding="utf-8")
        print(
            f"wrote {RELEASE_NOTES.relative_to(ROOT)} from [{section.version}]"
            f" ({len(text)} characters)",
            file=sys.stderr,
        )
        return 0
    sys.stdout.write(text)
    return 0


def cmd_release(args: argparse.Namespace) -> int:
    if not SEMVER.match(args.version):
        sys.exit(f"'{args.version}' is not a X.Y.Z version")
    path = CHANGELOG
    sections, errors = parse(path)
    if errors:
        sys.exit("\n".join(errors))
    if not sections or not sections[0].unreleased:
        sys.exit(f"{path.relative_to(ROOT)}: no [Unreleased] section to release")
    if sections[0].empty and not sections[0].summary:
        sys.exit(f"{path.relative_to(ROOT)}: [Unreleased] is empty")
    if any(s.version == args.version for s in sections):
        sys.exit(f"{path.relative_to(ROOT)}: {args.version} already exists")

    date = args.date or str(dt.date.today())
    lines = path.read_text(encoding="utf-8").splitlines()
    index = sections[0].line - 1
    title = sections[0].title
    heading = f"## [{args.version}] - {date}"
    if title:
        heading += f" — {title}"
    lines[index : index + 1] = ["## [Unreleased]", "", heading]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{path.relative_to(ROOT)}: released {args.version} ({date})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="changelog.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check", help="validate the changelog format")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("show", help="print one section")
    p.add_argument("version", nargs="?", default="unreleased")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("notes", help="render App Store release notes")
    p.add_argument("version", nargs="?", default="unreleased")
    p.add_argument("--write", action="store_true", help="update the fastlane file")
    p.add_argument(
        "--project",
        action="store_true",
        help="use MARKETING_VERSION from the Xcode project, else [Unreleased]",
    )
    p.set_defaults(func=cmd_notes)

    p = sub.add_parser("release", help="promote [Unreleased] to a version")
    p.add_argument("version")
    p.add_argument("--date", help="default today")
    p.set_defaults(func=cmd_release)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
