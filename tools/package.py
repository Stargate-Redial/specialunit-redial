#!/usr/bin/env python3
"""Build the release zip: specialunit-redial-v<VERSION>.zip and its .sha256, in the current folder.

Usage: python3 -I tools/package.py <folder with SUBotFix.u, SUBotFix.ucl, SUTweaks.u, SUTweaks.ucl>

The packages come from a build (tools/build.sh): <UT2004>/SpecialUnit/System. SUTweaks.u must be the
released one (players download it from servers: a rebuilt one has another GUID), so pass the folder that
holds it. Windows files get CRLF line ends, Linux scripts LF.
"""
import hashlib
import os
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CRLF = {".bat", ".ps1", ".txt", ".ini"}
FILES = [
    "install.bat", "install.ps1", "uninstall.bat", "servers.txt", "VERSION",
    "README.md", "LICENSE", "THIRD-PARTY.txt",
    "docs/DETAILS.md", "docs/LINUX_SERVER.md",
    "linux/install-server.sh", "linux/run-server.sh", "linux/sgsu.service",
    "linux/server-settings.ini", "linux/su-ini.py",
]
PACKAGES = ["SUBotFix.u", "SUBotFix.ucl", "SUTweaks.u", "SUTweaks.ucl"]


def text(path):
    with open(os.path.join(REPO, path), "rb") as f:
        data = f.read().replace(b"\r\n", b"\n")
    ext = os.path.splitext(path)[1].lower()
    if ext in CRLF or path in ("LICENSE",):
        data = data.replace(b"\n", b"\r\n")
    return data


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    built = sys.argv[1]
    version = open(os.path.join(REPO, "VERSION")).read().strip()
    name = f"specialunit-redial-v{version}.zip"
    with zipfile.ZipFile(name, "w", zipfile.ZIP_DEFLATED) as z:
        for path in FILES:
            info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            if path.endswith(".sh") or path.endswith(".py"):
                info.external_attr = 0o755 << 16
            else:
                info.external_attr = 0o644 << 16
            z.writestr(info, text(path))
        for p in PACKAGES:
            src = os.path.join(built, p)
            if not os.path.isfile(src):
                sys.exit(f"missing {src}")
            z.write(src, f"files/SpecialUnit/System/{p}")
    digest = hashlib.sha256(open(name, "rb").read()).hexdigest()
    with open(name + ".sha256", "w", newline="\n") as f:
        f.write(f"{digest}  {name}\n")
    print(f"{name}  {digest}")


if __name__ == "__main__":
    main()
