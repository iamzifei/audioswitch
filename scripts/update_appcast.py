#!/usr/bin/env python3
"""Insert or replace a Sparkle appcast <item> for one release.

Signs the archive with Sparkle's EdDSA key and rewrites appcast.xml so it contains
exactly one <item> per version (newest first). Intended to run in CI right
after a signed and notarised archive has been published to a GitHub release.

Usage:
  update_appcast.py --appcast appcast.xml --archive AudioSwitch.zip \
    --version 1.3.0 --build 6 --url <download-url> \
    --sign-tool /path/to/sign_update --key-file /path/to/ed_private.key \
    --min-system 14.0

The EdDSA signature comes from `sign_update -p`; the enclosure length is just
the archive's byte size.
"""
import argparse
import os
import subprocess
import sys
from email.utils import formatdate
from xml.sax.saxutils import quoteattr, escape

APPCAST_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>AudioSwitch</title>
    <link>https://raw.githubusercontent.com/iamzifei/audioswitch/main/appcast.xml</link>
    <description>Most recent AudioSwitch updates.</description>
    <language>en</language>
  </channel>
</rss>
"""


def ed_signature(sign_tool: str, key_file: str, archive: str) -> str:
    """Return the base64 EdDSA signature for the archive via sign_update -p."""
    out = subprocess.check_output(
        [sign_tool, archive, "--ed-key-file", key_file, "-p"],
        text=True,
    ).strip()
    if not out:
        raise SystemExit("sign_update produced no signature")
    return out


def build_item(args, signature: str, length: int) -> str:
    pub = formatdate(usegmt=False)  # RFC 822, local/CI time
    url = escape(args.url)
    return (
        "    <item>\n"
        f"      <title>{escape(args.version)}</title>\n"
        f"      <pubDate>{escape(pub)}</pubDate>\n"
        f"      <sparkle:version>{escape(args.build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{escape(args.min_system)}</sparkle:minimumSystemVersion>\n"
        f"      <enclosure url={quoteattr(args.url)} "
        f"sparkle:edSignature={quoteattr(signature)} "
        f'length="{length}" type="application/octet-stream"/>\n'
        "    </item>\n"
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--archive", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--sign-tool", required=True)
    p.add_argument("--key-file", required=True)
    p.add_argument("--min-system", default="14.0")
    args = p.parse_args()

    if not os.path.exists(args.appcast):
        with open(args.appcast, "w") as f:
            f.write(APPCAST_TEMPLATE)

    length = os.path.getsize(args.archive)
    signature = ed_signature(args.sign_tool, args.key_file, args.archive)
    item = build_item(args, signature, length)

    with open(args.appcast) as f:
        xml = f.read()

    # Drop any existing item for this version so re-runs stay idempotent.
    marker = f"<title>{args.version}</title>"
    if marker in xml:
        start = xml.rfind("    <item>", 0, xml.index(marker))
        end = xml.index("</item>", xml.index(marker)) + len("</item>\n")
        xml = xml[:start] + xml[end:]

    # Insert the new item right after the </language> line (top of the list).
    anchor = "    </channel>"
    insert_at = xml.index("</language>") + len("</language>\n")
    xml = xml[:insert_at] + item + xml[insert_at:]

    with open(args.appcast, "w") as f:
        f.write(xml)
    print(f"appcast updated: {args.version} (build {args.build}, {length} bytes)")


if __name__ == "__main__":
    main()
