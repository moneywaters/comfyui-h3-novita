#!/usr/bin/env python3
"""Location picker for ppio.sh, built on questionary (prompt_toolkit).

Reads a JSON array of {"id", "cols": [...]} on argv[1] (or stdin), draws a selectable
menu, and prints the chosen `id` on stdout.

Two things this has to get right:

* **The UI cannot be drawn on stdout.** The caller captures the result with `$(...)`,
  which makes stdout a pipe — the menu would be swallowed into the variable instead of
  displayed. So stdout is temporarily pointed at the controlling terminal for the
  duration of the prompt, then restored, and only the id is written to the real stdout.
* **Column widths must count display cells, not characters.** Chinese place names are
  double-width, so `%-18s` padding misaligns every row after the first. wcswidth +
  explicit padding keeps the columns straight.

Note: questionary does not bind Esc to abort, so the prompt advertises Ctrl-C.

With no controlling terminal it prints the options to stderr and reads a number, so it
still works from a script.
"""
import json
import os
import sys

try:
    from wcwidth import wcswidth
except ImportError:                                   # pragma: no cover
    def wcswidth(s):
        return len(s)


def display_width(s):
    w = wcswidth(s)
    return len(s) if w < 0 else w


def pad(s, width):
    return s + " " * max(0, width - display_width(s))


def open_tty(mode):
    try:
        return open("/dev/tty", mode, buffering=1)
    except Exception:
        return None


def format_rows(items, gap="   "):
    """Join each item's columns into a single display-aligned title."""
    ncols = max((len(it["cols"]) for it in items), default=0)
    widths = [0] * ncols
    for it in items:
        for i, c in enumerate(it["cols"]):
            widths[i] = max(widths[i], display_width(c))
    rows = []
    for it in items:
        cells = [pad(c, widths[i]) for i, c in enumerate(it["cols"])]
        rows.append((it["id"], gap.join(cells).rstrip()))
    return rows


def choose(items):
    try:
        import questionary
    except ImportError:
        print("ppio_pick: questionary is not installed.\n"
              "  fix: python3 -m pip install --user questionary", file=sys.stderr)
        return None, 1

    tty = open_tty("w")
    if tty is None:
        return choose_plain(items), 0

    rows = format_rows(items)
    real_stdout = sys.stdout
    sys.stdout = tty                                  # menu to the terminal...
    try:
        answer = questionary.select(
            "PPIO — which location?",
            choices=[questionary.Choice(title=title, value=rid) for rid, title in rows],
            qmark="",
            pointer="▸",
            instruction="  (↑/↓ · Enter · Ctrl-C cancels)",
        ).ask()
    except KeyboardInterrupt:
        answer = None
    finally:
        sys.stdout = real_stdout                      # ...and the result back to the pipe
        tty.close()
    return answer, 0


def choose_plain(items):
    """No terminal: menu to stderr, number from stdin."""
    rows = format_rows(items)
    e = sys.stderr
    e.write("PPIO — which location?\n")
    for i, (_, title) in enumerate(rows):
        e.write(f"  {i+1:>2}. {title}\n")
    e.flush()
    try:
        raw = input("select number (Enter to cancel): ").strip()
    except EOFError:
        return None
    if not raw:
        return None
    try:
        idx = int(raw) - 1
    except ValueError:
        return None
    return items[idx]["id"] if 0 <= idx < len(items) else None


def main():
    raw = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
    try:
        items = json.loads(raw)
    except Exception as e:
        print(f"ppio_pick: bad input: {e}", file=sys.stderr)
        return 1
    if not items:
        print("ppio_pick: nothing to choose from", file=sys.stderr)
        return 1

    picked, rc = choose(items)
    if rc:
        return rc
    if not picked:
        print("cancelled", file=sys.stderr)
        return 130
    print(picked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
