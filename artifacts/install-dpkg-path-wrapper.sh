# Paste this whole block into Termux. It replaces the existing dpkg wrapper
# with one that rewrites text files, ELF RUNPATHs, maintainer script modes and
# stale conffile entries in upstream .debs.

PREFIX=/data/user/10/com.termux/files/usr

if ! grep -Fqx "$PREFIX/bin/dpkg" "$PREFIX/var/lib/dpkg/diversions" 2>/dev/null; then
  if [ -x "$PREFIX/bin/dpkg-real" ]; then
    "$PREFIX/bin/dpkg-divert" --local --divert "$PREFIX/bin/dpkg-real" --add "$PREFIX/bin/dpkg"
  else
    "$PREFIX/bin/dpkg-divert" --local --divert "$PREFIX/bin/dpkg-real" --rename --add "$PREFIX/bin/dpkg"
  fi
fi

cat > "$PREFIX/bin/dpkg" <<'WRAPPER_EOF'
#!//data/user/10/com.termux/files/usr/bin/bash
# Rewrites paths in upstream .debs so they install into the custom user-data
# path instead of the primary user's /data/data/com.termux.
set -e
PREFIX=/data/user/10/com.termux/files/usr
REAL="$PREFIX/bin/dpkg-real"
# Kept split so the generator's /data/data substitution does not rewrite these.
OFFICIAL_DATA_ROOT="/data""/data"
CUSTOM_DATA_ROOT="/data/user/10"
APP_ROOT="$CUSTOM_DATA_ROOT/com.termux"
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

# Short alias directories let equal-length ELF RUNPATH strings resolve to the
# real prefix without changing the ELF string-table layout.
create_aliases() {
	mkdir -p "$APP_ROOT"
	for d in "$PREFIX"/*; do
		[ -d "$d" ] || continue
		local n
		n="$(basename "$d")"
		if [ ! -e "$APP_ROOT/$n" ] && [ ! -L "$APP_ROOT/$n" ]; then
			ln -s "$d" "$APP_ROOT/$n"
		fi
	done
}

patch_elfs() {
	"$PYTHON" - "$1" "$APP_ROOT" <<'PY'
import os
import re
import sys

root, app_root = sys.argv[1], sys.argv[2]
old_base = b"/data" + b"/data/com.termux/files/usr"
new_base = app_root.encode()
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
				mkdir -p "$D"
				"$PREFIX/bin/dpkg-deb" -R "$a" "$D"
				if [ -d "$D${OFFICIAL_DATA_ROOT}/com.termux" ]; then
					mkdir -p "$D${CUSTOM_DATA_ROOT}"
					mv "$D${OFFICIAL_DATA_ROOT}/com.termux" "$D${CUSTOM_DATA_ROOT}/"
					rmdir "$D${OFFICIAL_DATA_ROOT}" 2>/dev/null || true
					create_aliases
					# Rewrite embedded paths in text files (scripts, configs,
					# control files).
					find "$D" -type f -print0 | while IFS= read -r -d '' f; do
						if LC_ALL=C grep -Iq . "$f" 2>/dev/null; then
							# Write back into the existing file so permissions
							# (especially on maintainer scripts) are preserved.
							sedtmp="$(mktemp "$TMP/sed.XXXXXX")"
							sed "s|${OFFICIAL_DATA_ROOT}/com\\.termux|${CUSTOM_DATA_ROOT}/com.termux|g" "$f" > "$sedtmp"
							cat "$sedtmp" > "$f"
							rm -f "$sedtmp"
						fi
					done
					# Rewrite ELF RUNPATHs without changing their string-table
					# offsets.
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
				# archive (e.g. busybox service log/down files). dpkg
				# tolerates that, but dpkg-deb -b refuses to build.
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
WRAPPER_EOF

chmod +x "$PREFIX/bin/dpkg"
echo "Installed updated dpkg path-rewrite wrapper."
echo "Now run: apt-get install -f && pkg upgrade"
