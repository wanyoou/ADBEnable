#!/usr/bin/env python3
"""Build the ADB Enable Magisk module into dist/ADB-Enable-<version>.zip.

Only the Python standard library is used.  Executable bits are written into
the zip entries so that the module works when flashed from a custom recovery
(the Magisk app replaces update-binary with its own copy anyway).
"""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "module"
DIST = ROOT / "dist"

EXECUTABLE = {
    "post-fs-data.sh",
    "service.sh",
    "action.sh",
    "uninstall.sh",
    "bin/adb-enable",
    "META-INF/com/google/android/update-binary",
}

TEXT_SUFFIXES = {".sh", ".prop", ".txt", ".md", ""}
SKIP_CRLF_CHECK = {"keys/README.txt"}  # pure documentation, never parsed


def read_module_prop() -> dict[str, str]:
    raw = (SRC / "module.prop").read_bytes()
    if b"\r\n" in raw:
        raise SystemExit("module.prop must use LF line endings")
    fields = {}
    for line in raw.decode("utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value
    required = ("id", "name", "version", "versionCode", "author", "description")
    missing = [k for k in required if not fields.get(k)]
    if missing:
        raise SystemExit("module.prop missing: " + ", ".join(missing))
    if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9._-]+", fields["id"]):
        raise SystemExit("invalid module id: " + fields["id"])
    if not fields["versionCode"].isdigit():
        raise SystemExit("versionCode must be an integer")
    return fields


def collect() -> list[Path]:
    files = [p for p in sorted(SRC.rglob("*")) if p.is_file()]
    if not files:
        raise SystemExit("module/ is empty")
    return files


def check_line_endings(files: list[Path]) -> None:
    problems = []
    for path in files:
        rel = path.relative_to(SRC).as_posix()
        if rel in SKIP_CRLF_CHECK:
            continue
        if path.suffix not in TEXT_SUFFIXES and rel not in EXECUTABLE:
            continue
        if b"\r\n" in path.read_bytes():
            problems.append(rel)
    if problems:
        raise SystemExit("CRLF line endings in: " + ", ".join(problems))


def main() -> int:
    fields = read_module_prop()
    files = collect()
    check_line_endings(files)

    DIST.mkdir(exist_ok=True)
    out = DIST / f"ADB-Enable-{fields['version']}.zip"
    if out.exists():
        out.unlink()

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            rel = path.relative_to(SRC).as_posix()
            info = zipfile.ZipInfo(rel, date_time=(2024, 1, 1, 0, 0, 0))
            info.create_system = 3  # Unix, so the exec bits are honoured
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if rel in EXECUTABLE else 0o644
            info.external_attr = (0o100000 | mode) << 16
            zf.writestr(info, path.read_bytes())

    size = out.stat().st_size
    print(f"module : {fields['name']} {fields['version']} ({fields['versionCode']})")
    print(f"output : {out.relative_to(ROOT)}")
    print(f"files  : {len(files)}")
    print(f"size   : {size} bytes ({size / 1024:.1f} KiB)")
    for path in files:
        rel = path.relative_to(SRC).as_posix()
        mark = "x" if rel in EXECUTABLE else "-"
        print(f"  {mark} {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
