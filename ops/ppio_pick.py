#!/usr/bin/env python3
"""Arrow-key dropdown selector for ppio.sh.

Reads a JSON array of {"id", "label"} objects (argv[1], or stdin when piped), draws the
menu on the **controlling terminal**, and prints only the chosen `id` on stdout. That
split is deliberate: callers capture stdout with `$(...)`, which makes it a pipe — so
the UI must not go there or it would be swallowed instead of displayed.

Keys:  ↑/↓ or j/k move · Enter select · 1-9 jump · q or Esc cancel
With no controlling terminal (piped, cron, CI) it prints the options to stderr and
reads a number, so it still works unattended.
"""
import json
import os
import sys

ESC = "\x1b"


def open_tty():
    """The controlling terminal as (read, write) handles, even when stdin/stdout are pipes.

    Opened twice on purpose: a tty is not seekable, so a single "r+" handle raises
    UnsupportedOperation ("File or stream is not seekable"). termios state is per-tty,
    not per-fd, so raw mode set via the read handle applies to the terminal as a whole.
    """
    try:
        return open("/dev/tty", "r"), open("/dev/tty", "w", buffering=1)
    except Exception:
        return None


def render(w, items, cur):
    w.write(f"{ESC}[?25l")                                    # hide cursor
    w.write(f"{ESC}[2K  {ESC}[1mPPIO — pick a location with a 4090{ESC}[0m\n")
    for i, it in enumerate(items):
        rev, off = (f"{ESC}[7m", f"{ESC}[0m") if i == cur else ("", "")
        arrow = "▸" if i == cur else " "
        w.write(f"{ESC}[2K  {rev}{arrow} {i+1:>2}. {it['label']}{off}\n")
    w.write(f"{ESC}[2K\n{ESC}[2K  {ESC}[2m↑/↓ move · Enter select · q quit{ESC}[0m\n")
    w.write(f"{ESC}[{len(items)+4}A")                          # park cursor to redraw
    w.flush()


def choose_tty(reader, writer, items):
    import termios
    import tty as ttymod

    fd = reader.fileno()

    def key():
        """Read one key as raw bytes.

        Deliberately os.read, not reader.read: a text-mode handle on a tty applies
        universal-newline translation, which rewrites a CR keypress so an Enter
        keypress never matches "\\r" and the menu appears to ignore Enter.
        """
        try:
            b = os.read(fd, 1)
        except OSError:
            return ""
        return b.decode("latin-1") if b else ""

    old = termios.tcgetattr(fd)
    cur = 0
    try:
        ttymod.setraw(fd)            # -icanon: one key at a time; -echo: we draw the highlight
        render(writer, items, cur)
        while True:
            ch = key()
            if ch in ("\r", "\n"):
                return items[cur]["id"]
            if ch in ("q", "\x03", "\x04"):
                return None
            if ch == ESC:
                nxt = key()
                if nxt == "[":
                    a = key()
                    if a == "A":
                        cur = (cur - 1) % len(items)
                    elif a == "B":
                        cur = (cur + 1) % len(items)
                    render(writer, items, cur)
                    continue
                return None                       # bare Esc
            if ch == "k":
                cur = (cur - 1) % len(items)
            elif ch == "j":
                cur = (cur + 1) % len(items)
            elif ch.isdigit() and ch != "0":
                idx = int(ch) - 1
                if idx < len(items):
                    cur = idx
            else:
                continue
            render(writer, items, cur)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        writer.write(f"{ESC}[?25h\n")
        writer.flush()


def choose_plain(items):
    """No terminal: menu to stderr, number from stdin."""
    e = sys.stderr
    e.write("PPIO — locations with a 4090:\n")
    for i, it in enumerate(items):
        e.write(f"  {i+1:>2}. {it['label']}\n")
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

    handles = open_tty()
    if handles:
        tty_in, tty_out = handles
        picked = choose_tty(tty_in, tty_out, items)
        tty_in.close()
        tty_out.close()
    elif sys.stdin.isatty():
        picked = choose_plain(items)
    else:
        print("ppio_pick: no terminal; launch a location explicitly "
              "(e.g. ./ppio.sh launch us-ca-6)", file=sys.stderr)
        return 1

    if picked is None:
        print("cancelled", file=sys.stderr)
        return 130
    print(picked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
