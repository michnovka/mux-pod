#!/usr/bin/env python3

import argparse
import os
import sys


def _trim_file(path: str, max_bytes: int) -> None:
    try:
        size = os.path.getsize(path)
    except FileNotFoundError:
        return

    if size <= max_bytes:
        return

    with open(path, "rb+") as handle:
        handle.seek(size - max_bytes)
        tail = handle.read()
        handle.seek(0)
        handle.write(tail)
        handle.truncate()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Keep a bounded rolling raw byte capture from tmux pipe-pane.",
    )
    parser.add_argument("output_path")
    parser.add_argument("--max-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(args.output_path)), exist_ok=True)

    with open(args.output_path, "ab", buffering=0) as output:
        while True:
            chunk = sys.stdin.buffer.read(64 * 1024)
            if not chunk:
                break
            output.write(chunk)
            output.flush()
            _trim_file(args.output_path, args.max_bytes)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
