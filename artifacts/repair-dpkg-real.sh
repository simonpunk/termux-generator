# Paste this into Termux to restore and patch bin/dpkg-real after a dpkg upgrade.
PREFIX=/data/user/10/com.termux/files/usr
APP_ROOT=/data/user/10/com.termux
CACHE=/data/user/10/com.termux/cache/apt/archives

if [ -x "$PREFIX/bin/dpkg-real" ]; then
  echo "dpkg-real is already present; patching it just in case."
else
  DEB=$(ls "$CACHE"/dpkg_*.deb 2>/dev/null | head -1)
  if [ -z "$DEB" ]; then
    echo "No cached dpkg .deb found; download it first with:"
    echo "  apt-get download dpkg"
    return 1 2>/dev/null || exit 1
  fi
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  "$PREFIX/bin/dpkg-deb" -x "$DEB" "$TMP"
  REAL="$TMP/data/data/com.termux/files/usr/bin/dpkg"
  if [ ! -f "$REAL" ]; then
    REAL=$(find "$TMP" -type f -path '*/usr/bin/dpkg' | head -1)
  fi
  if [ -z "$REAL" ] || [ ! -f "$REAL" ]; then
    echo "Could not find dpkg binary inside $DEB"
    return 1 2>/dev/null || exit 1
  fi
fi

# Short alias dirs let equal-length ELF paths resolve to the custom prefix.
mkdir -p "$APP_ROOT"
for d in "$PREFIX"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ ! -e "$APP_ROOT/$n" ] && [ ! -L "$APP_ROOT/$n" ]; then
    ln -s "$d" "$APP_ROOT/$n"
  fi
done

# Patch /data/data/... strings inside the ELF without changing their offsets.
"$PREFIX/bin/python3" - "$APP_ROOT" "$PREFIX/bin/dpkg-real" <<'PY'
import os
import re
import sys

app_root, path = sys.argv[1], sys.argv[2]
old_base = b"/data" + b"/data/com.termux/files/usr"
new_base = app_root.encode()
pattern = re.compile(re.escape(old_base) + rb"([A-Za-z0-9_.+/\-]*)")

data = bytearray(open(path, "rb").read())

def repl(m):
    new = new_base + m.group(1)
    if len(new) > len(m.group(0)):
        return m.group(0)
    return new.ljust(len(m.group(0)), b"\0")

new_data = pattern.sub(repl, bytes(data))
if new_data != bytes(data):
    with open(path, "r+b") as f:
        f.write(new_data)
    print("Patched ELF paths in", path)
PY

chmod 755 "$PREFIX/bin/dpkg-real"

if ! grep -Fqx "$PREFIX/bin/dpkg" "$PREFIX/var/lib/dpkg/diversions" 2>/dev/null; then
  "$PREFIX/bin/dpkg-divert" --local --divert "$PREFIX/bin/dpkg-real" --add "$PREFIX/bin/dpkg"
fi

echo "Restored and patched $PREFIX/bin/dpkg-real"
echo "Now run: apt-get install -f && pkg upgrade"
