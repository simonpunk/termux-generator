# Paste this into Termux and send the full output.
PREFIX=/data/user/10/com.termux/files/usr

echo "=== which dpkg ==="
which -a dpkg

echo "=== bin/dpkg details ==="
ls -l "$PREFIX/bin/dpkg" "$PREFIX/bin/dpkg-real" 2>&1

echo "=== first lines of bin/dpkg ==="
head -n 3 "$PREFIX/bin/dpkg" 2>&1

echo "=== wrapper source in libexec ==="
ls -l "$PREFIX/libexec/termux-generator/dpkg-wrapper" 2>&1

echo "=== dpkg diversions ==="
cat "$PREFIX/var/lib/dpkg/diversions" 2>&1

echo "=== dpkg status ==="
grep -A5 '^Package: dpkg$' "$PREFIX/var/lib/dpkg/status" 2>&1 | head -8

echo "=== apt dpkg options ==="
grep -rn 'DPkg' "$PREFIX/etc/apt/apt.conf.d/" 2>/dev/null | head -10

echo "=== wrapper does rewrite busybox? (dry check) ==="
grep -c 'could not relocate paths' "$PREFIX/bin/dpkg" 2>&1
