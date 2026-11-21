#!/data/data/com.simonpunk.tm/files/usr/bin/bash
# Installs the dpkg path-rewriting wrapper into an already installed
# com.simonpunk.tm Termux prefix. Run from inside the app's Termux shell.
set -e
PREFIX=/data/data/com.simonpunk.tm/files/usr
REAL="$PREFIX/bin/dpkg-real"

if [ ! -x "$PREFIX/bin/dpkg" ]; then
	echo "ERROR: $PREFIX/bin/dpkg not found. Run this inside com.simonpunk.tm." >&2
	exit 1
fi

if [ ! -e "$REAL" ]; then
	cp -f "$PREFIX/bin/dpkg" "$REAL"
fi

mkdir -p "$PREFIX/libexec/termux-generator"

cat > "$PREFIX/libexec/termux-generator/dpkg-wrapper" <<'WRAPPER'
#!/data/data/com.simonpunk.tm/files/usr/bin/bash
# Rewrites paths in upstream .deb files so that packages downloaded from the
# official Termux repository install into this custom app's prefix instead of
# trying to create /data/data/com.termux, which is not writable by this app.
set -e
PREFIX=/data/data/com.simonpunk.tm/files/usr
REAL="$PREFIX/bin/dpkg-real"
# Kept split so the generator's bulk replacements cannot rewrite these.
OFFICIAL_DATA_ROOT="/data""/data"
CUSTOM_DATA_ROOT="/data/data"
CUSTOM_APP_NAME="com.simonpunk.tm"
APP_ROOT="$CUSTOM_DATA_ROOT/$CUSTOM_APP_NAME"
# Short alias base: its length (29) is less than the official prefix (31), so
# in-place ELF string-table rewrites always fit without shifting offsets.
ALIAS_BASE="$APP_ROOT/u"
# Safety net for binaries whose embedded RUNPATH cannot be patched.
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

has_deb=0
for a in "$@"; do
	case "$a" in *.deb) has_deb=1 ;; esac
done
if [ "$has_deb" -eq 0 ]; then
	exec "$REAL" "$@"
fi

if [ -x "$PREFIX/bin/python3" ]; then
	PYTHON="$PREFIX/bin/python3"
else
	PYTHON="$PREFIX/bin/python"
fi

# Create short alias directories so rewritten ELF RUNPATH strings resolve to
# the real prefix.
create_aliases() {
	mkdir -p "$ALIAS_BASE"
	for d in "$PREFIX"/*; do
		[ -d "$d" ] || continue
		local n
		n="$(basename "$d")"
		if [ ! -e "$ALIAS_BASE/$n" ] && [ ! -L "$ALIAS_BASE/$n" ]; then
			ln -s "$d" "$ALIAS_BASE/$n"
		fi
	done
}

patch_elfs() {
	"$PYTHON" - "$1" "$ALIAS_BASE" <<'PY'
import os
import re
import sys

root, alias_base = sys.argv[1], sys.argv[2]
old_base = b"/data" + b"/data/com.termux/files/usr"
new_base = alias_base.encode()
pattern = re.compile(re.escape(old_base) + rb"([A-Za-z0-9_.+/\-]*)")

for dirpath, _, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        try:
            with open(path, "rb") as f:
                if f.read(4) != b"\x7fELF":
                    continue
            data = open(path, "rb").read()
        except OSError:
            continue

        def repl(m):
            new = new_base + m.group(1)
            if len(new) > len(m.group(0)):
                return m.group(0)
            return new.ljust(len(m.group(0)), b"\0")

        new_data = pattern.sub(repl, data)
        if new_data != data:
            with open(path, "r+b") as f:
                f.write(new_data)
PY
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NEW=()
i=0
for a in "$@"; do
	i=$((i + 1))
	case "$a" in
		*.deb)
			if [ -f "$a" ]; then
				D="$TMP/$i"
				relocated=0
				mkdir -p "$D"
				"$PREFIX/bin/dpkg-deb" -R "$a" "$D"
				if [ -d "$D${OFFICIAL_DATA_ROOT}/com.termux" ]; then
					relocated=1
					mv "$D${OFFICIAL_DATA_ROOT}/com.termux" "$D${CUSTOM_DATA_ROOT}/$CUSTOM_APP_NAME"
					rmdir "$D${OFFICIAL_DATA_ROOT}" 2>/dev/null || true
					create_aliases
					# Rewrite embedded paths in text files (scripts, configs,
					# control files).
					find "$D" -type f -print0 | while IFS= read -r -d '' f; do
						if LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
							# Write back into the existing file so permissions
							# (especially on maintainer scripts) are preserved.
							sedtmp="$(mktemp "$TMP/sed.XXXXXX")"
							sed "s|${OFFICIAL_DATA_ROOT}/com[.]termux|${CUSTOM_DATA_ROOT}/$CUSTOM_APP_NAME|g" "$f" > "$sedtmp"
							cat "$sedtmp" > "$f"
							rm -f "$sedtmp"
						fi
					done
					# Rewrite ELF RUNPATHs without changing string-table offsets.
					patch_elfs "$D"
				fi
				# Termux repo debs ship maintainer scripts as 0644, which
				# dpkg accepts but dpkg-deb -b rejects. Restore 0755.
				if [ -d "$D/DEBIAN" ]; then
					for s in postinst preinst prerm postrm config; do
						if [ -f "$D/DEBIAN/$s" ]; then
							chmod 755 "$D/DEBIAN/$s"
						fi
					done
				fi
				# Some packages list conffiles that are absent from the
				# archive. dpkg tolerates that, but dpkg-deb -b refuses to
				# build, so drop those entries.
				if [ -f "$D/DEBIAN/conffiles" ]; then
					conf="$TMP/conffiles.$$"
					: > "$conf"
					while IFS= read -r c; do
						[ -n "$c" ] || continue
						case "$c" in
							\#*) printf '%s\n' "$c" >> "$conf" ;;
							*)
								rel="${c#/}"
								if [ -e "$D/$rel" ] || [ -L "$D/$rel" ]; then
									printf '%s\n' "$c" >> "$conf"
								fi
								;;
						esac
					done < "$D/DEBIAN/conffiles"
					if [ -s "$conf" ]; then
						cat "$conf" > "$D/DEBIAN/conffiles"
					else
						rm -f "$D/DEBIAN/conffiles"
					fi
					rm -f "$conf"
				fi
				# Never hand dpkg an archive that still targets the official
				# /data/data tree; fail with a clear message instead.
				if [ "$relocated" -eq 0 ] && "$PREFIX/bin/dpkg-deb" -c "$a" 2>/dev/null | grep -qE '\./data/data(/|$)'; then
					echo "dpkg wrapper: could not relocate paths in $a" >&2
					exit 1
				fi
				"$PREFIX/bin/dpkg-deb" -b "$D" "$TMP/$i.deb" >/dev/null
				NEW+=("$TMP/$i.deb")
			else
				NEW+=("$a")
			fi
			;;
		*)
			NEW+=("$a")
			;;
	esac
done
exec "$REAL" "${NEW[@]}"

WRAPPER
chmod +x "$PREFIX/libexec/termux-generator/dpkg-wrapper"

# Register diversion so future dpkg upgrades cannot overwrite the wrapper.
if ! grep -Fqx "$PREFIX/bin/dpkg" "$PREFIX/var/lib/dpkg/diversions" 2>/dev/null; then
	if [ -e "$REAL" ]; then
		"$PREFIX/bin/dpkg-divert" --local --divert "$REAL" --add "$PREFIX/bin/dpkg"
	else
		"$PREFIX/bin/dpkg-divert" --local --divert "$REAL" --rename --add "$PREFIX/bin/dpkg"
	fi
fi

cp -f "$PREFIX/libexec/termux-generator/dpkg-wrapper" "$PREFIX/bin/dpkg"
chmod +x "$PREFIX/bin/dpkg"

echo "dpkg path wrapper installed."
echo "dpkg: $("$PREFIX/bin/dpkg" --version | head -1)"
