"""Choose a bounded rehearsal scenario; the archive stays unchanged."""
import base64
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2] / ".build/update-rehearsal"
mode = sys.argv[1]
assert mode in ("empty", "unavailable", "bad-signature", "valid")
feed = root / "public/appcast.xml"
if mode == "unavailable":
    feed.unlink(missing_ok=True)
    print("Feed unavailable (HTTP 503).")
    raise SystemExit(0)
ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", ns)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "CodexGauge update rehearsal"
if mode != "empty":
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Rehearsal build 2"
    ET.SubElement(item, "description").text = "Disposable update test. No Codex data is accessed."
    signature = root.joinpath("signature.txt").read_text().strip()
    if mode == "bad-signature":
        raw = bytearray(base64.b64decode(signature)); raw[0] ^= 1
        signature = base64.b64encode(raw).decode()
    ET.SubElement(item, "enclosure", {
        "url": root.joinpath("base-url.txt").read_text().strip() + "/update.zip",
        "length": str(root.joinpath("public/update.zip").stat().st_size),
        "type": "application/octet-stream",
        f"{{{ns}}}version": "2", f"{{{ns}}}shortVersionString": "1.0.2",
        f"{{{ns}}}edSignature": signature,
    })
temporary = feed.with_suffix(".tmp")
ET.ElementTree(rss).write(temporary, encoding="utf-8", xml_declaration=True)
temporary.replace(feed)
print(f"Feed scenario: {mode}")
