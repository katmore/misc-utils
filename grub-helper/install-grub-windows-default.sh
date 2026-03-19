#!/usr/bin/env bash
# https://github.com/katmore/misc-utils/tree/master/install-grub-windows-default.sh
#
# install-grub-windows-default.sh
# Sets up GRUB to always default to Windows, surviving major updates.
# Backs up every file it touches before modifying it.

set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}  →${RESET} $*"; }
ok()      { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET} $*"; }
die()     { echo -e "${RED}  ✗ ERROR:${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}$*${RESET}"; }

backup() {
    local src="$1"
    local bak="${src}.bak-$(date '+%Y%m%d-%H%M%S')"
    cp "$src" "$bak"
    echo -e "  ${YELLOW}↳ backup:${RESET} ${bak}"
    BACKED_UP+=("$bak")
}

# ── Root check ───────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run this script with sudo: sudo $0"

BACKED_UP=()
INSTALLER="install-grub-windows-default.sh"
INSTALLED_ON="$(date '+%Y-%m-%d %H:%M:%S')"

# ── 1. /etc/default/grub ────────────────────────────────────────────────────

section "1/3  Patching /etc/default/grub"

GRUB_DEFAULT_FILE="/etc/default/grub"
[[ -f "$GRUB_DEFAULT_FILE" ]] || die "$GRUB_DEFAULT_FILE not found"

backup "$GRUB_DEFAULT_FILE"

# Build the comment block to insert above GRUB_DEFAULT
GRUB_DEFAULT_COMMENT="# Modified by ${INSTALLER} on ${INSTALLED_ON}
# GRUB_DEFAULT=saved tells GRUB to boot whichever entry was last written
# by grub-set-default. The apt hook in
# /etc/apt/apt.conf.d/99-grub-windows-default re-runs grub-set-default
# after every package update, keeping Windows as the persistent default
# even when kernel or grub updates regenerate /boot/grub/grub.cfg."

if grep -q '^GRUB_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i "s|^GRUB_DEFAULT=.*|${GRUB_DEFAULT_COMMENT}\nGRUB_DEFAULT=saved|" "$GRUB_DEFAULT_FILE"
    info "GRUB_DEFAULT → saved (replaced existing, comment added)"
else
    printf '\n%s\nGRUB_DEFAULT=saved\n' "$GRUB_DEFAULT_COMMENT" >> "$GRUB_DEFAULT_FILE"
    info "GRUB_DEFAULT=saved (appended with comment)"
fi

# Remove GRUB_SAVEDEFAULT if present — causes "sparse file not allowed" on
# Ubuntu 24.04 EFI systems. grub-set-default handles this explicitly instead.
if grep -q '^GRUB_SAVEDEFAULT=' "$GRUB_DEFAULT_FILE"; then
    sed -i "s|^GRUB_SAVEDEFAULT=.*|# Removed by ${INSTALLER} on ${INSTALLED_ON}: GRUB_SAVEDEFAULT causes\n# 'sparse file not allowed' on Ubuntu 24.04 EFI. The apt hook calls\n# grub-set-default explicitly after updates, making this unnecessary.|" \
        "$GRUB_DEFAULT_FILE"
    info "GRUB_SAVEDEFAULT removed (commented out with explanation)"
fi

ok "/etc/default/grub patched"

# ── 2. /usr/local/sbin/set-grub-windows-default ─────────────────────────────

section "2/3  Installing /usr/local/sbin/set-grub-windows-default"

HOOK_SCRIPT="/usr/local/sbin/set-grub-windows-default"

if [[ -f "$HOOK_SCRIPT" ]]; then
    backup "$HOOK_SCRIPT"
fi

# Note: variables inside EOF are intentionally escaped so they evaluate at
# hook runtime, not at install time — except INSTALLER and INSTALLED_ON
# which are install-time metadata baked into the script header.
cat > "$HOOK_SCRIPT" << EOF
#!/usr/bin/env bash
# set-grub-windows-default
# Installed by ${INSTALLER} on ${INSTALLED_ON}
#
# Re-asserts Windows as the GRUB default boot entry after package updates.
# Triggered automatically by the apt/dpkg post-invoke hook at:
#   /etc/apt/apt.conf.d/99-grub-windows-default
#
# Requires GRUB_DEFAULT=saved in /etc/default/grub.
# Does NOT use GRUB_SAVEDEFAULT (causes 'sparse file not allowed' on Ubuntu 24.04 EFI).

set -euo pipefail
LOG="/var/log/grub-windows-default.log"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

echo "\$(timestamp) — Running grub-windows-default hook" >> "\$LOG"

# Regenerate menu first so entry titles are current
update-grub >> "\$LOG" 2>&1

# Find the first menuentry containing "Windows" and extract its title
WINDOWS_ENTRY=\$(grep -m1 "menuentry '.*[Ww]indows" /boot/grub/grub.cfg \
    | sed "s/menuentry '\([^']*\)'.*/\1/")

if [[ -z "\$WINDOWS_ENTRY" ]]; then
    echo "\$(timestamp) — WARNING: No Windows entry found in grub.cfg, skipping." >> "\$LOG"
    exit 0
fi

echo "\$(timestamp) — Found Windows entry: \${WINDOWS_ENTRY}" >> "\$LOG"

# Write the Windows entry as the saved default.
# grub-set-default writes to /boot/grub/grubenv, which GRUB reads at boot
# when GRUB_DEFAULT=saved is set in /etc/default/grub.
grub-set-default "\${WINDOWS_ENTRY}" >> "\$LOG" 2>&1
echo "\$(timestamp) — Default set to: \${WINDOWS_ENTRY}" >> "\$LOG"
EOF

chmod +x "$HOOK_SCRIPT"
ok "$HOOK_SCRIPT installed and made executable"

# ── 3. /etc/apt/apt.conf.d/99-grub-windows-default ──────────────────────────

section "3/3  Installing apt post-invoke hook"

APT_HOOK="/etc/apt/apt.conf.d/99-grub-windows-default"

if [[ -f "$APT_HOOK" ]]; then
    backup "$APT_HOOK"
fi

cat > "$APT_HOOK" << EOF
// Installed by ${INSTALLER} on ${INSTALLED_ON}
// Runs /usr/local/sbin/set-grub-windows-default after every apt/dpkg operation.
// This re-runs update-grub and calls grub-set-default to keep Windows as the
// persistent GRUB default, even after kernel or grub package updates that
// regenerate /boot/grub/grub.cfg and would otherwise reset the boot order.
DPkg::Post-Invoke { "/usr/local/sbin/set-grub-windows-default 2>/dev/null || true"; };
EOF

ok "$APT_HOOK installed"

# ── Initial run ──────────────────────────────────────────────────────────────

section "Running initial update-grub and setting Windows as default..."

update-grub 2>&1 | sed 's/^/  /'

WINDOWS_ENTRY=$(grep -m1 "menuentry '.*[Ww]indows" /boot/grub/grub.cfg \
    | sed "s/menuentry '\([^']*\)'.*/\1/") || true

if [[ -z "${WINDOWS_ENTRY:-}" ]]; then
    warn "No Windows entry found in grub.cfg yet."
    warn "The hook will find it automatically once Windows is detected by grub-mkconfig."
else
    grub-set-default "$WINDOWS_ENTRY"
    ok "GRUB default set to: ${BOLD}${WINDOWS_ENTRY}${RESET}"
    info "Verify with: grub-editenv list"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD}  Done.${RESET} Backups written:\n"
for f in "${BACKED_UP[@]}"; do
    echo -e "  ${YELLOW}${f}${RESET}"
done
echo -e "\n  Hook log (after first apt run): ${CYAN}/var/log/grub-windows-default.log${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
