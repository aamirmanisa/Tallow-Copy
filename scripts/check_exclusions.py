#!/usr/bin/env python3
"""Fail when a CI exclusion in .github/macos-x86-exclusion.txt has expired.

An exclusion that cannot fail is not a decision, it is a hole. Every line
carries a review date; this script exits non-zero once that date passes, so
the waiver has to be remade rather than silently renewed.
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

REGISTER = Path(__file__).resolve().parent.parent / ".github" / "macos-x86-exclusion.txt"


def main() -> int:
    if not REGISTER.is_file():
        print(f"exclusions: {REGISTER} is missing; nothing to check")
        return 0

    today = dt.date.today()
    expired: list[str] = []
    checked = 0
    for raw in REGISTER.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 3:
            print(f"exclusions: malformed entry (want 3 fields): {line}")
            return 2
        target, reason, deadline = parts
        # Accept both `2027-02-01` and the explicit `review-by 2027-02-01`.
        deadline = deadline.removeprefix("review-by").strip()
        try:
            review_by = dt.date.fromisoformat(deadline)
        except ValueError:
            print(f"exclusions: {target} has an unparseable review date: {deadline!r}")
            return 2
        if not reason:
            print(f"exclusions: {target} is excluded with no reason")
            return 2
        checked += 1
        if today > review_by:
            expired.append(f"  {target}: review was due {review_by.isoformat()}")

    if expired:
        print("exclusions: EXPIRED — re-decide or re-date these before merging:")
        print("\n".join(expired))
        return 1

    print(f"exclusions: {checked} entr{'y' if checked == 1 else 'ies'} inside their review date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
