#!/usr/bin/env python3
"""Serve Verso's HTML output locally.

Verso's pages do not work over file:// — code hovers are deduplicated into a JSON file the page
fetches at runtime, and the browser blocks that fetch from a local file. So the output has to be
served.

Python's own http.server sends caching headers that keep a rebuilt page from showing up on reload,
which reads as "my edit did nothing". This sends no-store instead.

Usage: serve.py [PORT] [-d DIR]
"""

import argparse
import http.server
import os
import socketserver
import sys


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # A line per successful request is noise while iterating; anything else still surfaces.
        # log_error routes here too, with a different argument shape, so index defensively.
        code = str(args[1]) if len(args) > 1 else ""
        if not code.startswith("2"):
            super().log_message(fmt, *args)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", nargs="?", type=int, default=8000)
    parser.add_argument("-d", "--directory", default="_out/html-multi")
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"error: {args.directory} does not exist", file=sys.stderr)
        print("       build first: cd docs/manual && lake exe docs", file=sys.stderr)
        return 1

    handler = lambda *a, **kw: NoCacheHandler(*a, directory=args.directory, **kw)
    socketserver.TCPServer.allow_reuse_address = True

    try:
        with socketserver.TCPServer(("", args.port), handler) as httpd:
            print(f"Serving {args.directory} at http://localhost:{args.port}")
            print("Rebuild with `lake exe docs` and reload; nothing is cached.")
            print("Ctrl-C to stop.")
            httpd.serve_forever()
    except OSError as e:
        print(f"error: could not bind port {args.port}: {e}", file=sys.stderr)
        print(f"       try another port: serve.py {args.port + 1} -d {args.directory}",
              file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print()
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
