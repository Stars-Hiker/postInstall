#!/bin/bash
# ==============================================================================
# Arch Linux Post-Installation Script (version: see SCRIPT_VERSION below)
# Run as a regular user with sudo privileges, NOT as root.
# ==============================================================================
set -euo pipefail
# set -e  : exit immediately on any command returning non-zero
# set -u  : treat unset variables as errors (prevents silent $var typos)
# set -o pipefail : a pipe fails if ANY command in it fails, not just the last

# ==============================================================================
# CONFIGURATION
# Edit this section to personalise the script before running.
# ==============================================================================

readonly SCRIPT_NAME="postInstall"
readonly SCRIPT_VERSION="6"
readonly DOTFILES_REPO="https://github.com/Stars-Hiker/dotfiles"
readonly DOTFILES_DIR="$HOME/.dotfiles"
# In $HOME (not /tmp) so the log survives the post-install reboot, with a
# timestamp so re-runs don't clobber the previous run's log.
readonly LOG_FILE="$HOME/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
readonly AUR_DIR="$HOME/AUR"

# ── Tunables: defaults below; override with flags or the wizard (see --help) ──
# Reflector country for mirror selection / the reflector timer unit.
REFLECTOR_COUNTRY="France"

# "laptop" → TLP for battery management (disables tuned)
# "desktop" → tuned with the "balanced" profile (skips TLP)
MACHINE_TYPE="laptop"

# "auto" → snapshots only if root is Btrfs · "1" → force on · "0" → off
ENABLE_SNAPPER="auto"

# Source subnet allowed through the firewall (your LAN). The wizard auto-detects
# a sensible default; override with --lan.
LAN_SUBNET="192.168.0.0/24"

# ── Runtime flags (set by parse_args / the wizard) ───────────────────────────
DRY_RUN=0          # --dry-run  : print the plan, change nothing, no sudo
ASSUME_YES=0       # --yes      : skip the confirmation prompt
RUN_WIZARD=1       # --no-wizard: disable the interactive setup wizard
LIST_STEPS=0       # --list-steps: print the numbered step list and exit
FROM_STEP=""       # --from     : start at this step (name or number)
ONLY_STEP=""       # --only     : run just this step
SKIP_STEPS=()      # --skip     : steps to skip (repeatable)
STEP_NUM=0         # current step index (for the [N/TOTAL] progress prefix)
STEP_TOTAL=0       # total steps (set once the STEPS list is built)
CURRENT_STEP_LABEL=""       # label of the running step (for the ERR trap)
declare -A SET_BY_FLAG=()   # which tunables a flag set, so the wizard skips them
declare -a WARNINGS=()      # every warn() message, replayed in print_summary

# ==============================================================================
# COLOURS & LOGGING
# Once the run is confirmed, main redirects ALL output (script messages AND
# pacman/paru/makepkg output) through tee into $LOG_FILE — see the exec line.
# The helpers below are therefore plain echos.
# ==============================================================================

readonly BLUE="\e[1;34m"
readonly GREEN="\e[1;32m"
readonly YELLOW="\e[1;33m"
readonly RED="\e[1;31m"
readonly RESET="\e[0m"

log()     { echo -e "${BLUE}   >> $1${RESET}"; }
success() { echo -e "${GREEN}   OK $1${RESET}"; }
warn()    { echo -e "${YELLOW} WARN $1${RESET}"; WARNINGS+=("$1"); }

error_exit() {
    echo -e "${RED}  ERR $1${RESET}" >&2
    # Only point at the log once it actually exists (logging starts post-confirm).
    [[ -f "$LOG_FILE" ]] && echo -e "${RED}  See $LOG_FILE for the full run log.${RESET}" >&2
    exit 1
}

section() {
    local label="$1"
    [[ "$STEP_TOTAL" -gt 0 ]] && label="[${STEP_NUM}/${STEP_TOTAL}] $1"
    echo -e "\n${BLUE}============================================${RESET}"
    echo -e "${BLUE}  ${label}${RESET}"
    echo -e "${BLUE}============================================${RESET}"
}
# NOTE: Plain = characters instead of Unicode box-drawing (==) so the log
# file renders correctly regardless of terminal locale / encoding.

# ==============================================================================
# IDEMPOTENCY HELPERS
# Every step must be safe to re-run on an already-configured system.
# ==============================================================================

dir_exists()  { [[ -d "$1" ]]; }
file_exists() { [[ -f "$1" ]]; }
cmd_exists()  { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
    # Query pacman's local DB — more reliable than command -v for packages
    # that don't install a binary (fonts, libraries, etc.).
    pacman -Qi "$1" &>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

is_cachyos() {
    # CachyOS ships its own ranked mirrorlist (and cachyos-rate-mirrors), so
    # mirror management belongs to it — reflector would fight that. NOTE: it
    # reports ID=arch in /etc/os-release (verified), so detect it by its
    # mirrorlist file / repo sections instead.
    [[ -f /etc/pacman.d/cachyos-mirrorlist ]] \
        || grep -q '^\[cachyos' /etc/pacman.conf 2>/dev/null
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

check_not_root() {
    [[ "$EUID" -eq 0 ]] && error_exit "Do not run as root. Use a regular user with sudo."
    success "Running as user '$USER'."
}

check_sudo_access() {
    # Cache credentials upfront so no password prompt fires mid-run.
    sudo -v || error_exit "sudo access is required but could not be obtained."
    # Keep the sudo timestamp alive for the duration of the script.
    # `|| true`: the subshell inherits set -e, so one transient sudo failure
    # would otherwise kill the keepalive silently → password prompt mid-run.
    ( while true; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    # Kill the keepalive on exit (success or failure).
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
    success "sudo credentials cached."
}

check_internet() {
    log "Checking internet connectivity..."
    # curl is more reliable than ping — ICMP is blocked on some networks/VPNs.
    curl -s --max-time 5 https://archlinux.org > /dev/null \
        || error_exit "No internet access. Check your connection before running this script."
    success "Internet is reachable."
}

check_dependencies() {
    local missing=()
    for dep in git curl sudo pacman; do
        cmd_exists "$dep" || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && error_exit "Missing required tools: ${missing[*]}"
    success "All pre-flight dependencies found."
}
# NOTE: check_internet uses curl, so check_dependencies must run before it
# (main enforces this order).

# ==============================================================================
# PACMAN CONFIGURATION
# Done before any installs so all subsequent pacman calls benefit from it.
# ==============================================================================

configure_pacman() {
    section "Hardening pacman.conf"

    local conf="/etc/pacman.conf"

    # Enable colour output.
    sudo sed -i 's/^#Color/Color/' "$conf"

    # Show old → new package versions during upgrades.
    sudo sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$conf"

    # Parallel downloads — dramatically speeds up large install runs like this.
    sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$conf"

    # Enable the multilib repository (Wine, Steam, 32-bit libs).
    # The sed pattern matches the [multilib] header line, advances to the next
    # line, then uncomments the Include directive.
    if grep -q "^\[multilib\]" "$conf"; then
        sudo sed -i '/^\[multilib\]/{n;s/^#Include/Include/}' "$conf"
        log "multilib repository enabled."
    else
        warn "[multilib] section not found in pacman.conf — skipping."
    fi

    # The ONE full sync+upgrade of the run, done early: every later install uses
    # plain -S, and installing into a stale system risks the classic Arch
    # partial-upgrade breakage (real on re-runs months after install).
    sudo pacman -Syu --noconfirm || error_exit "Full system upgrade failed."
    success "pacman.conf configured and system upgraded."
}

setup_pacman_hooks() {
    section "Installing pacman hooks"

    sudo mkdir -p /etc/pacman.d/hooks

    # Warn after every transaction if orphaned packages exist.
    sudo tee /etc/pacman.d/hooks/orphans.hook > /dev/null <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Checking for orphaned packages...
When = PostTransaction
Exec = /bin/bash -c 'orphans=$(pacman -Qdtq 2>/dev/null); [ -n "$orphans" ] && echo "WARNING: Orphaned packages found: $orphans" || true'
EOF

    # Auto-refresh the dotfiles package lists after every transaction so
    # pkglists/pkgs-{native,aur}.txt always reflect reality. Hooks run as root,
    # but the snapshot script is USER-WRITABLE — executing it as root would let
    # anything that compromises the user account escalate to root on the next
    # pacman transaction. runuser drops to the repo owner: pacman -Q needs no
    # root, and the files come out owned by the user (no chown hack needed).
    # The [ -x ] guard makes it a no-op on a machine where the dotfiles repo
    # isn't cloned yet (e.g. mid-bootstrap). Absolute path is required: hooks
    # have no HOME and no working-directory guarantees.
    # (runuser is in util-linux — always present on Arch.)
    local snapshot="${DOTFILES_DIR}/bin/pkg-snapshot.sh"
    sudo tee /etc/pacman.d/hooks/95-pkglist-snapshot.hook > /dev/null <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Snapshotting explicit package lists to dotfiles...
When = PostTransaction
Exec = /bin/bash -c '[ -x "${snapshot}" ] && /usr/bin/runuser -u ${USER} -- "${snapshot}" || true'
EOF

    success "pacman hooks installed."
}

# ==============================================================================
# MIRRORS
# ==============================================================================

setup_mirrors() {
    section "Configuring pacman mirrors"

    # Vanilla Arch only — see is_cachyos().
    if is_cachyos; then
        log "CachyOS detected — keeping its ranked mirrorlist; skipping reflector."
        return 0
    fi

    if ! pkg_installed reflector; then
        # DBs are fresh: configure_pacman already did the full -Syu.
        sudo pacman -S --needed --noconfirm reflector \
            || error_exit "Failed to install reflector."
    fi

    # Back up the original mirrorlist only once.
    local backup="/etc/pacman.d/mirrorlist.backup"
    if ! file_exists "$backup"; then
        sudo cp /etc/pacman.d/mirrorlist "$backup"
        log "Original mirrorlist backed up to $backup"
    fi

    sudo reflector \
        --country "$REFLECTOR_COUNTRY" \
        --age 12 \
        --protocol https \
        --sort rate \
        --fastest 10 \
        --save /etc/pacman.d/mirrorlist \
        || error_exit "Reflector failed to fetch mirrors."

    sudo pacman -Syy || error_exit "pacman DB refresh failed."
    success "Mirrors configured."
}

setup_mirror_timer() {
    section "Setting up reflector systemd timer"

    if is_cachyos; then
        log "CachyOS detected — no reflector timer needed; skipping."
        return 0
    fi

    # sudo tee avoids nested heredoc quoting issues with sudo bash -c.
    sudo tee /etc/systemd/system/reflector.service > /dev/null <<EOF
[Unit]
Description=Update Arch Linux Mirrorlist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/reflector --country ${REFLECTOR_COUNTRY} --age 12 --protocol https --sort rate --fastest 10 --save /etc/pacman.d/mirrorlist
EOF

    sudo tee /etc/systemd/system/reflector.timer > /dev/null <<'EOF'
[Unit]
Description=Run Reflector Weekly

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    # RandomizedDelaySec: staggers the run by up to 1h so multiple machines
    # don't all hammer the mirror servers at the exact same second.

    sudo systemctl daemon-reload
    service_enabled reflector.timer \
        || sudo systemctl enable --now reflector.timer \
        || error_exit "Failed to enable reflector timer."
    success "reflector.timer enabled."
}

# ==============================================================================
# AUR HELPER — paru
# ==============================================================================

install_paru() {
    section "Installing paru (AUR helper)"

    if cmd_exists paru; then
        log "paru is already installed, skipping."
        return 0
    fi

    # base-devel is a mandatory makepkg dependency.
    # --needed is safe to re-run; it's a no-op if already installed.
    sudo pacman -S --needed --noconfirm base-devel \
        || error_exit "Failed to install base-devel (required by makepkg)."

    mkdir -p "$AUR_DIR"

    # paru-bin repackages the prebuilt release binary — same paru, but skips
    # compiling it (and pulling the whole Rust toolchain) on a fresh machine.
    local paru_dir="${AUR_DIR}/paru-bin"
    if ! dir_exists "$paru_dir"; then
        git clone https://aur.archlinux.org/paru-bin.git "$paru_dir" \
            || error_exit "Failed to clone paru-bin."
    fi
    ( cd "$paru_dir" && makepkg -si --noconfirm ) \
        || error_exit "makepkg failed for paru-bin."
    success "paru installed."
}

# ==============================================================================
# PACKAGE INSTALLATION
# Packages are grouped by purpose — easy to add or remove a whole category.
# ==============================================================================

install_essentials() {
    section "Installing bootstrap packages"

    # MINIMAL bootstrap set — just enough to clone the dotfiles repo, stow it,
    # decrypt secrets, and then let install_from_pkglists() pull EVERYTHING else
    # from dotfiles/pkglists/. The full curated package set is no longer hardcoded
    # here; the package lists in the dotfiles repo are the single source of truth.
    #   git/curl  → clone the repo
    #   stow      → deploy the configs
    #   base-devel→ makepkg deps (also pulled by install_paru, kept for safety)
    #   openssh   → ssh client/agent (keys restored by restore_secrets)
    #   age       → decrypt secrets/secrets.tar.age
    local pkgs=(
        git curl stow base-devel openssh age
    )

    sudo pacman -S --needed --noconfirm "${pkgs[@]}" \
        || error_exit "Failed to install bootstrap packages."
    success "Bootstrap packages installed."
}

# Install the FULL package set from the dotfiles repo's lists. This runs AFTER
# deploy_dotfiles() so $DOTFILES_DIR/pkglists/ exists. These two files are the
# single source of truth for "what is installed on this machine" and are kept
# fresh automatically by the pacman hook (setup_pacman_hooks) + `dotsync`.
install_from_pkglists() {
    section "Installing packages from dotfiles lists"

    local native="$DOTFILES_DIR/pkglists/pkgs-native.txt"
    local aur="$DOTFILES_DIR/pkglists/pkgs-aur.txt"
    # Curated AUR extras: packages we want from the AUR that the auto-snapshot
    # can't capture as foreign (e.g. tools installed from a third-party repo like
    # BlackArch on the source machine, so pacman -Qqem misses them). Not touched
    # by pkg-snapshot.sh — edit by hand.
    local aur_extra="$DOTFILES_DIR/pkglists/pkgs-aur-extra.txt"
    local -a failed=()

    # CRITICAL: read the lists into memory BEFORE installing anything. The
    # pkglist-snapshot pacman hook rewrites these very files on every transaction
    # during this run, so iterating the files directly races with the rewrite —
    # the loop reads a truncated file and stops early, leaving most packages
    # uninstalled (and no failure trace, since the list got overwritten).
    # Snapshotting the names up front makes us immune to that.
    local -a native_pkgs=() aur_pkgs=()
    [[ -f "$native" ]] && mapfile -t native_pkgs < <(sed 's/#.*//' "$native" | tr -d '[:blank:]' | grep -v '^$')
    [[ -f "$aur"    ]] && mapfile -t aur_pkgs    < <(sed 's/#.*//' "$aur"    | tr -d '[:blank:]' | grep -v '^$')
    [[ -f "$aur_extra" ]] && mapfile -t -O "${#aur_pkgs[@]}" aur_pkgs < <(sed 's/#.*//' "$aur_extra" | tr -d '[:blank:]' | grep -v '^$')

    # install_batch <installer...> : install the `batch` array in ONE transaction
    # (fast; fires the snapshot hook just once); if that fails (e.g. a renamed or
    # dropped package aborts the whole transaction), retry per-package to isolate
    # the offenders into `failed` so recovery still installs everything that
    # resolves. </dev/null prevents the installer from consuming our stdin.
    local -a batch
    install_batch() {
        [[ ${#batch[@]} -gt 0 ]] || return 0
        if "$@" --needed --noconfirm "${batch[@]}" </dev/null; then
            return 0
        fi
        warn "Batch install failed — retrying per-package to isolate bad packages..."
        local p
        for p in "${batch[@]}"; do
            "$@" --needed --noconfirm "$p" </dev/null >/dev/null 2>&1 \
                || { warn "  ✗ failed: $p"; failed+=("$p"); }
        done
    }

    if [[ ${#native_pkgs[@]} -gt 0 ]]; then
        log "Installing ${#native_pkgs[@]} native (repo) packages..."
        batch=("${native_pkgs[@]}"); install_batch sudo pacman -S
        success "Native package pass complete."
    else
        warn "No native package list at $native — skipping."
    fi

    if [[ ${#aur_pkgs[@]} -gt 0 ]]; then
        if cmd_exists paru; then
            log "Installing ${#aur_pkgs[@]} AUR/foreign packages..."
            batch=("${aur_pkgs[@]}"); install_batch paru -S
            success "AUR package pass complete."
        else
            warn "paru not found — skipping AUR list: $aur"
        fi
    else
        warn "No AUR package list at $aur — skipping."
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "${#failed[@]} package(s) could not be installed (renamed, dropped,"
        warn "or temporarily unavailable). Install/replace these manually later:"
        warn "  ${failed[*]}"
    else
        success "All packages from the lists installed."
    fi
}

# Restore encrypted secrets (~/.ssh etc.) from the dotfiles repo.
# Requires the PRIVATE age identity at ~/.config/age/keys.txt, which is NEVER in
# git — restore it from Bitwarden/USB first. If absent, warn and continue so the
# rest of the bootstrap still completes.
# After secrets (SSH keys) are restored, switch the dotfiles remote from HTTPS to
# SSH so `dotsync` can push without a GitHub credential or `gh` login.
switch_dotfiles_remote_ssh() {
    dir_exists "$DOTFILES_DIR/.git" || return 0
    local url; url=$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null) || return 0
    case "$url" in
        https://github.com/*)
            local path="${url#https://github.com/}"; path="${path%.git}"
            if git -C "$DOTFILES_DIR" remote set-url origin "git@github.com:${path}.git"; then
                log "dotfiles remote switched to SSH (push needs no gh login)."
            else
                warn "Could not switch dotfiles remote to SSH — do it manually if needed."
            fi
            ;;
    esac
}

restore_secrets() {
    section "Restoring encrypted secrets"

    local unseal="$DOTFILES_DIR/bin/secrets-unseal.sh"
    local identity="$HOME/.config/age/keys.txt"

    if ! file_exists "$unseal"; then
        warn "No unseal script at $unseal — skipping secrets restore."
        return 0
    fi

    # The age key is the one step people forget — and the only thing that makes
    # recovery actually work. If it's missing and we're interactive, offer to
    # paste it right now instead of bailing out with a reminder.
    if ! file_exists "$identity" && [[ -t 0 ]]; then
        log "No age identity at $identity yet."
        local key=""
        read -rsp "Paste your AGE-SECRET-KEY line now (or Enter to skip): " key || true
        echo
        if [[ -n "$key" ]]; then
            if [[ "$key" == AGE-SECRET-KEY-* ]]; then
                mkdir -p "$HOME/.config/age" && chmod 700 "$HOME/.config/age"
                printf '%s\n' "$key" > "$identity" && chmod 600 "$identity"
                success "Age identity saved to $identity."
            else
                warn "That doesn't look like an AGE-SECRET-KEY — nothing saved."
            fi
        fi
        unset key
    fi

    if file_exists "$identity"; then
        log "Age identity found — decrypting secrets..."
        if bash "$unseal"; then
            success "Secrets restored."
            switch_dotfiles_remote_ssh
        else
            warn "secrets-unseal.sh failed — restore your secrets manually."
        fi
    else
        warn "No age identity at $identity — secrets NOT restored."
        warn "  Copy your age key from Bitwarden/USB to $identity, then run:"
        warn "    $unseal"
    fi
}

configure_qemu_kvm() {
    section "Configuring QEMU/KVM virtualisation stack"

    # NOTE: the QEMU/KVM PACKAGES (qemu-full, libvirt, virt-manager, swtpm,
    # edk2-ovmf, guestfs-tools, dnsmasq, …) are now installed from the dotfiles
    # package lists by install_from_pkglists(). This function only handles the
    # service/group/network setup that the lists can't capture. It runs after
    # install_from_pkglists(), so the binaries are already present.

    if ! cmd_exists virsh; then
        warn "libvirt/virsh not found — it likely failed to install (check the"
        warn "install_from_pkglists failure summary above). Skipping KVM config."
        return 0
    fi

    # Enable libvirt daemon — but do NOT enable tuned here.
    # tuned is managed exclusively in install_power_management() so the
    # laptop vs desktop logic stays in one place.
    service_enabled libvirtd.service \
        || sudo systemctl enable --now libvirtd.service \
        || warn "Could not enable libvirtd — continuing (VMs unavailable until fixed)."

    # Add user to required groups.
    # libvirt → manage VMs without sudo
    # kvm     → direct access to /dev/kvm
    for grp in libvirt kvm; do
        if ! id -nG "$USER" | grep -qw "$grp"; then
            sudo usermod -aG "$grp" "$USER" \
                && log "Added '$USER' to group '$grp'." \
                || warn "Could not add $USER to group '$grp' — add it later: usermod -aG $grp $USER"
        else
            log "User '$USER' already in group '$grp'."
        fi
    done

    # Enable the default NAT network so VMs have internet access immediately.
    if sudo virsh net-info default &>/dev/null; then
        sudo virsh net-autostart default 2>/dev/null || true
        sudo virsh net-start default 2>/dev/null || true
        log "libvirt 'default' NAT network enabled."
    fi

    log "KVM host validation:"
    sudo virt-host-validate qemu \
        || warn "Some KVM checks failed — review $LOG_FILE."

    success "QEMU/KVM stack installed."
}

# ==============================================================================
# ZSH
# ==============================================================================

install_zsh_plugins() {
    section "Installing ZSH plugins"

    # Format: "folder-name|clone-url"
    local plugins=(
        "fzf-tab|https://github.com/Aloxaf/fzf-tab"
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting"
        "zsh-history-substring-search|https://github.com/zsh-users/zsh-history-substring-search"
    )
    # fzf-tab: replaces zsh's plain completion menu with an fzf picker (with
    # previews). The .zshrc _load's it from ~/AUR/fzf-tab — without this clone it
    # silently vanishes on a fresh machine.
    # zsh-history-substring-search: type part of a past command, press Up/Down
    # to cycle through all history entries that match.

    for entry in "${plugins[@]}"; do
        local name="${entry%%|*}"
        local url="${entry##*|}"
        local dest="${AUR_DIR}/${name}"

        if dir_exists "$dest"; then
            log "Plugin '$name' already cloned — pulling latest..."
            git -C "$dest" pull --ff-only || warn "Could not update '$name' — skipping."
        else
            git clone "$url" "$dest" \
                || warn "Failed to clone '$name' — that plugin will be inactive. Continuing."
        fi
    done
    success "ZSH plugins step done."
}

set_default_shell_zsh() {
    section "Setting ZSH as default shell"

    local zsh_path
    zsh_path=$(command -v zsh) \
        || { warn "zsh not found in PATH — leaving the default shell unchanged."; return 0; }

    if [[ "$SHELL" == "$zsh_path" ]]; then
        log "ZSH is already the default shell."
        return 0
    fi

    # chsh requires the shell to be listed in /etc/shells.
    grep -qxF "$zsh_path" /etc/shells \
        || echo "$zsh_path" | sudo tee -a /etc/shells > /dev/null

    # Use `sudo chsh` (root changing the user's shell) so it never prompts for a
    # password — works non-interactively and drops a prompt from recovery.
    sudo chsh -s "$zsh_path" "$USER" \
        && success "Default shell set to ZSH for $USER. Re-login to apply." \
        || warn "Could not set ZSH as default shell — change it later: chsh -s $zsh_path"
}

# ==============================================================================
# FIREWALL (UFW)
# ==============================================================================

setup_firewall() {
    section "Configuring UFW firewall"

    # NOTE: ufw peut deja etre installe et active par ArchWizard.
    # Si c est le cas, on saute le reset et on applique seulement les regles
    # manquantes (--needed + check "Status: active" gerent l idempotence).
    pkg_installed ufw \
        || sudo pacman -S --needed --noconfirm ufw \
        || { warn "Failed to install UFW — skipping firewall setup. Configure it later."; return 0; }

    # Only reset if UFW has never been configured (clean install).
    # Resetting on re-runs would silently destroy manually added rules.
    if ! sudo ufw status | grep -q "Status: active"; then
        sudo ufw --force reset
        log "UFW reset to a clean state."
    fi

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw default deny forward

    # Deluge BitTorrent — the "Deluge" application profile ships with the ufw
    # package itself (/etc/ufw/applications.d/ufw-bittorent).
    sudo ufw allow Deluge

    # Allow all traffic from your LAN (set via --lan or the wizard).
    sudo ufw allow from "$LAN_SUBNET" comment "LAN"

    # Rate-limit SSH: max 6 new connections per 30s per source IP.
    # (limit implies allow — no separate `ufw allow ssh` needed.)
    sudo ufw limit ssh comment "SSH rate-limit"

    # libvirt/KVM virtual networking. With "deny incoming" + "deny forward",
    # ufw otherwise drops guest DHCP requests to dnsmasq (no IP lease) and the
    # NAT forwarding (no internet in guests). These rules let the default
    # network (virbr0) work. Guarded so it's a no-op when libvirt isn't set up.
    if ip link show virbr0 &>/dev/null; then
        sudo ufw allow in on virbr0        comment "libvirt DHCP/DNS"
        sudo ufw route allow in on virbr0  comment "libvirt NAT in"
        sudo ufw route allow out on virbr0 comment "libvirt NAT out"
        log "Added libvirt virbr0 firewall rules (VM networking)."
    else
        log "virbr0 not present — skipping libvirt firewall rules."
    fi

    service_enabled ufw \
        || sudo systemctl enable ufw \
        || warn "Could not enable the UFW service — continuing."

    sudo ufw --force enable || warn "Could not activate UFW — continuing (firewall may be inactive)."
    sudo ufw status verbose
    success "Firewall step done."
}

harden_ssh() {
    section "Hardening SSH daemon"

    local cfg="/etc/ssh/sshd_config.d/99-hardening.conf"

    if file_exists "$cfg"; then
        log "SSH hardening config already exists — skipping."
        return 0
    fi

    sudo mkdir -p /etc/ssh/sshd_config.d
    sudo tee "$cfg" > /dev/null <<'EOF'
# Generated by postInstall — edit manually as needed.
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3

# NOTE: PasswordAuthentication is left ON intentionally.
# Disabling it before key-based auth is confirmed working will lock you out.
# Once SSH keys are configured, set this to "no" manually.
PasswordAuthentication yes
EOF

    # Restart sshd only if it's already running (not all desktops run it).
    if service_enabled sshd; then
        sudo systemctl restart sshd || warn "sshd restart failed — review manually."
    else
        log "sshd is not enabled — config written but daemon not restarted."
    fi

    success "SSH hardening config written to $cfg"
}

# ==============================================================================
# POWER MANAGEMENT
# tuned (installed in install_qemu_kvm) is enabled or disabled here depending
# on MACHINE_TYPE. All power-management logic lives in this one function.
# ==============================================================================

install_power_management() {
    section "Configuring power management (MACHINE_TYPE=${MACHINE_TYPE})"

    if [[ "$MACHINE_TYPE" == "laptop" ]]; then
        # TLP and tuned both compete for CPU governor control — running both
        # causes unpredictable behaviour and systemd service failures.
        #
        # We mask tuned unconditionally (not just when enabled) because:
        #   1. systemd presets or pacman hooks can auto-enable tuned when it
        #      is installed, even without an explicit "systemctl enable".
        #   2. "mask" prevents any future accidental start (stronger than disable).
        # The || true guards ensure we never exit on a double-mask or a
        # stop-when-not-running error.
        warn "Ensuring tuned is stopped and masked before enabling TLP..."
        sudo systemctl stop    tuned.service 2>/dev/null || true
        sudo systemctl disable tuned.service 2>/dev/null || true
        sudo systemctl mask    tuned.service 2>/dev/null || true
        log "tuned masked — will not interfere with TLP."

        # Power management is a nice-to-have — NEVER abort the whole recovery if
        # it fails (e.g. inside a VM there is no battery and TLP won't start).
        if ! pkg_installed tlp; then
            sudo pacman -S --needed --noconfirm tlp tlp-rdw \
                || { warn "Could not install TLP — skipping power management."; return 0; }
        fi

        # TLP manages radio kill switches directly — mask the systemd units
        # that would otherwise fight it.
        sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true

        if ! service_enabled tlp.service; then
            sudo systemctl enable --now tlp.service \
                && success "TLP enabled for laptop power management." \
                || warn "Could not enable TLP (expected inside a VM — no battery). Continuing."
        else
            success "TLP already enabled."
        fi

    else
        # Desktop mode: install and enable tuned with the "balanced" profile.
        # tuned is now installed here (not in install_qemu_kvm) so that it is
        # never present on laptop systems where it would conflict with TLP.
        # Same principle: never fatal.
        if ! pkg_installed tuned; then
            sudo pacman -S --needed --noconfirm tuned \
                || { warn "Could not install tuned — skipping power management."; return 0; }
        fi
        service_enabled tuned.service \
            || sudo systemctl enable --now tuned.service \
            || warn "Could not enable tuned. Continuing."

        if cmd_exists tuned-adm; then
            sudo tuned-adm profile balanced \
                || warn "Could not set tuned profile — run 'tuned-adm profile' manually."
            log "tuned profile set to 'balanced'."
        fi

        success "Power management step done (tuned)."
    fi
}

# ==============================================================================
# BTRFS SNAPSHOTS (snapper)
# Only runs if the root filesystem is Btrfs (or ENABLE_SNAPPER is forced on).
# ==============================================================================

setup_snapper() {
    section "Setting up Btrfs snapshots (snapper)"

    local root_fs
    root_fs=$(findmnt -n -o FSTYPE /)

    if [[ "$ENABLE_SNAPPER" == "0" ]]; then
        log "Snapper disabled by configuration — skipping."
        return 0
    fi

    if [[ "$ENABLE_SNAPPER" == "auto" && "$root_fs" != "btrfs" ]]; then
        log "Root filesystem is '$root_fs', not Btrfs — skipping snapper."
        return 0
    fi

    # NOTE: snapper et snap-pac sont aussi installes par ArchWizard si Btrfs
    # est detecte. --needed les ignore silencieusement s ils sont deja presents.
    # Snapshots are a safety net, not a hard requirement — never abort recovery
    # if this fails (e.g. an installer-made Btrfs layout snapper dislikes).
    sudo pacman -S --needed --noconfirm snapper snap-pac \
        || { warn "Could not install snapper — skipping snapshot setup."; return 0; }

    # Create a snapper config for root if one doesn't exist yet.
    if ! sudo snapper list-configs | grep -q "^root "; then
        sudo snapper -c root create-config / \
            || { warn "Could not create snapper root config (often a subvolume"; \
                 warn "layout snapper rejects) — skipping. Configure manually later."; \
                 return 0; }
        log "Snapper root config created."
    else
        log "Snapper root config already exists — skipping create-config."
    fi

    # snap-pac creates pre/post snapshots automatically around every
    # pacman install/upgrade/remove operation.
    service_enabled snapper-timeline.timer \
        || sudo systemctl enable --now snapper-timeline.timer
    service_enabled snapper-cleanup.timer \
        || sudo systemctl enable --now snapper-cleanup.timer

    success "Snapper configured. Automatic snapshots active."
}

# ==============================================================================
# DESKTOP SESSION
# Hyprland, Waybar, kitty, PipeWire, fonts, SDDM, … are all INSTALLED from the
# dotfiles pkglists (single source of truth — see install_from_pkglists). This
# step only configures what package lists can't capture: the font cache, the
# PipeWire user services, and the display manager.
# ==============================================================================

configure_desktop() {
    section "Configuring desktop session (font cache, PipeWire, SDDM)"

    # ── Font cache ────────────────────────────────────────────────────────────
    # Rebuild so fonts from the pkglist pass are usable without a re-login.
    if cmd_exists fc-cache; then
        fc-cache -f >/dev/null \
            && log "Font cache rebuilt." \
            || warn "fc-cache failed — fonts may need a re-login to appear."
    fi

    # ── Services PipeWire ─────────────────────────────────────────────────────
    log "Enabling PipeWire user services..."
    systemctl --user enable --now pipewire.service 2>/dev/null \
        && success "pipewire.service enabled." \
        || warn "pipewire.service: already active or needs a reboot to start."
    systemctl --user enable --now wireplumber.service 2>/dev/null \
        && success "wireplumber.service enabled." \
        || warn "wireplumber.service: already active or needs a reboot to start."

    # ── Display manager ───────────────────────────────────────────────────────
    # Enable SDDM so the machine boots to a graphical login (→ Hyprland) instead
    # of a bare TTY. A minimal install ships no enabled DM, so without this a
    # recovered machine would come up text-only. Guarded on sddm being installed.
    if pkg_installed sddm; then
        if service_enabled sddm.service; then
            log "SDDM already enabled — graphical login on next boot."
        elif sudo systemctl enable sddm.service; then
            log "SDDM enabled — graphical login on next boot."
        else
            warn "Could not enable SDDM — enable it manually: systemctl enable sddm"
        fi
    else
        warn "sddm not installed — no display manager enabled (boot will be text-only)."
    fi
}

# ==============================================================================
# DOTFILES — déploiement via GitHub + GNU Stow
# Appelé en fin de script. Propose le clone du repo GitHub (ou un fallback
# offline depuis une clé USB si internet n'est pas disponible).
# ==============================================================================

deploy_dotfiles() {
    section "Deploying dotfiles (Hyprland config)"

    # ── Prérequis : git et stow ───────────────────────────────────────────────
    local missing_deps=()
    cmd_exists git  || missing_deps+=(git)
    cmd_exists stow || missing_deps+=(stow)

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "Installing missing dotfile deps: ${missing_deps[*]}"
        sudo pacman -S --needed --noconfirm "${missing_deps[@]}" \
            || error_exit "Failed to install: ${missing_deps[*]}"
    fi

    # ── Repo déjà présent ? ───────────────────────────────────────────────────
    if dir_exists "$DOTFILES_DIR"; then
        log "Dotfiles repo already at $DOTFILES_DIR — pulling latest..."
        git -C "$DOTFILES_DIR" pull --ff-only \
            || warn "git pull failed — continuing with existing version."
    else
        # ── Tentative clone GitHub ────────────────────────────────────────────
        if curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
            log "Cloning dotfiles from $DOTFILES_REPO ..."
            # GIT_TERMINAL_PROMPT=0: on a fresh machine a PRIVATE repo would
            # otherwise hang waiting for a username/password prompt — fail fast
            # instead and explain what to do.
            local clone_log
            if clone_log="$(GIT_TERMINAL_PROMPT=0 git clone "$DOTFILES_REPO" "$DOTFILES_DIR" 2>&1)"; then
                success "Dotfiles cloned from GitHub."
            else
                echo "$clone_log" | sed 's/^/    /'
                warn "Could not clone $DOTFILES_REPO."
                if echo "$clone_log" | grep -qiE 'authentication|could not read username|terminal prompts disabled|repository not found|403|access denied|permission denied'; then
                    warn "This looks like an AUTH problem: the repo is likely PRIVATE and there"
                    warn "is no GitHub credential on this fresh machine yet. Fix one way, then"
                    warn "re-run this script (it reuses an existing $DOTFILES_DIR):"
                    warn "  • Make the repo public — it's safe: secrets are age-encrypted."
                    warn "  • Or authenticate:  install github-cli, run 'gh auth login', re-run."
                    warn "  • Or clone it yourself to $DOTFILES_DIR, then re-run."
                else
                    warn "Check network/DNS and that $DOTFILES_REPO exists, then re-run."
                fi
                warn "  • Offline option: put a 'dotfiles-offline' copy on a USB key, then re-run."
                error_exit "Dotfiles clone failed — see guidance above."
            fi

        # ── Fallback : copie depuis clé USB ───────────────────────────────────
        else
            warn "GitHub unreachable — looking for offline copy on USB..."

            # Cherche un dossier dotfiles-offline sur les partitions montées
            local usb_src
            usb_src=$(find /run/media /mnt -maxdepth 3 -name "dotfiles-offline" \
                      -type d 2>/dev/null | head -1)

            if [[ -n "$usb_src" ]]; then
                cp -r "$usb_src" "$DOTFILES_DIR"
                success "Dotfiles copied from USB: $usb_src"
            else
                warn "No offline dotfiles found. Mount your USB key and run:"
                warn "  bash $DOTFILES_DIR/install.sh"
                warn "Skipping dotfiles deployment."
                return 0
            fi
        fi
    fi

    # ── Lancer install.sh du repo ─────────────────────────────────────────────
    local installer="$DOTFILES_DIR/install.sh"

    if file_exists "$installer"; then
        log "Running dotfiles installer..."
        bash "$installer" \
            || warn "install.sh returned an error — check output above."
        success "Dotfiles deployed via stow."
    else
        warn "install.sh not found in $DOTFILES_DIR — stow not run."
        warn "Run manually: cd $DOTFILES_DIR && ./install.sh"
    fi
}

# ==============================================================================
# USER DIRECTORIES
# ==============================================================================

setup_user_dirs() {
    section "Creating user directories"
    # hyprshot saves screenshots here (HYPRSHOT_DIR in the dotfiles .zshrc); make
    # it up front so the first capture on a fresh machine doesn't fail.
    mkdir -p "$HOME/ScreenShots"
    success "User directories ready."
}

# ==============================================================================
# SUMMARY REPORT
# ==============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}  Post-installation v${SCRIPT_VERSION} complete!${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo -e "  Log file    : ${LOG_FILE}"
    echo -e "  Machine type: ${MACHINE_TYPE}"
    echo -e "  Dotfiles    : ${DOTFILES_DIR}"
    echo ""

    # Replay every warning from the run — they scroll out of sight behind
    # hundreds of lines of pacman/paru output, and on an unattended run this
    # recap is the only practical way to see what needs manual follow-up.
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}${#WARNINGS[@]} warning(s) during this run:${RESET}"
        local w
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW} WARN ${w}${RESET}"
        done
        echo ""
    else
        echo -e "  ${GREEN}No warnings — clean run.${RESET}"
        echo ""
    fi
    echo -e "  ${YELLOW}Action required after reboot:${RESET}"
    echo -e "  1. Reboot — required for group membership (libvirt, kvm) and ZSH shell."
    echo -e "  2. Open virt-manager — VMs should work without sudo."
    echo -e "     (Optional) In Hyprland, enable the hyprexpo plugin:"
    echo -e "       ${BLUE}hyprpm add https://github.com/hyprwm/hyprland-plugins && hyprpm enable hyprexpo${RESET}"
    echo -e "  3. Run ${BLUE}ufw status verbose${RESET} to review firewall rules."
    echo -e "  4. Once SSH keys are set up, edit ${BLUE}/etc/ssh/sshd_config.d/99-hardening.conf${RESET}"
    echo -e "     and set ${BLUE}PasswordAuthentication no${RESET}."
    echo -e "  5. Run ${BLUE}nvim${RESET} to verify your editor config (deployed from dotfiles)."
    echo ""
    echo -e "  Useful commands:"
    echo -e "    paru -Syu          — upgrade official + AUR packages"
    echo -e "    paru <name>        — search and install from AUR"
    echo -e "    pacman -Qdtq       — list orphaned packages"
    echo -e "    snapper list       — list Btrfs snapshots (if Btrfs)"
    echo -e "    tuned-adm profile  — show active tuned profile (desktop)"
    echo -e "    tlp-stat           — show TLP battery status (laptop)"
    echo -e "    cd ~/.dotfiles && git pull && ./install.sh"
    echo -e "                       — mettre a jour les dotfiles"
    echo ""
}

# ==============================================================================
# CLI ARGS, WIZARD & RUN CONTROL
# ==============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Arch/CachyOS + Hyprland post-install bootstrapper

Usage: ./ArchHyprPostInstall.sh [options]

Options:
  --laptop | --desktop     Machine type (default: ${MACHINE_TYPE}).
                           laptop = TLP, desktop = tuned.
  --country <name>         Reflector mirror country (default: ${REFLECTOR_COUNTRY}).
                           Ignored on CachyOS (ships its own ranked mirrorlist).
  --lan <cidr>            LAN subnet allowed by the firewall
                           (default: ${LAN_SUBNET}; the wizard auto-detects one).
  --snapper <auto|on|off>  Btrfs snapshots (default: auto = on only if root is Btrfs).
  --from <step>            Start at the given step; earlier steps are skipped.
                           <step> is a function name or number — see --list-steps.
  --only <step>            Run a single step, nothing else.
  --skip <step>            Skip a step (repeatable).
  --list-steps             Print the numbered step list and exit.
  -n, --dry-run            Print the resolved config + ordered steps, then exit.
                           Changes nothing and needs no sudo.
  -y, --yes                Skip the confirmation prompt (unattended runs).
  --no-wizard              Skip the interactive wizard; use flags/defaults.
  -h, --help               Show this help and exit.

With no flags on a terminal, a short wizard asks for the machine type, mirror
country (vanilla Arch only), and LAN subnet, then previews the plan before
changing anything. Steps are idempotent, so --from/--only re-runs are safe.
EOF
}

# CLI usage errors: concise message + pointer to --help, exit 2 (no run log).
arg_error() {
    echo -e "${RED}error:${RESET} $1" >&2
    echo    "Run './ArchHyprPostInstall.sh --help' for usage." >&2
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --laptop)  MACHINE_TYPE="laptop";  SET_BY_FLAG[machine]=1 ;;
            --desktop) MACHINE_TYPE="desktop"; SET_BY_FLAG[machine]=1 ;;
            --country) shift; [[ $# -gt 0 ]] || arg_error "--country needs a value."
                       REFLECTOR_COUNTRY="$1"; SET_BY_FLAG[country]=1 ;;
            --lan)     shift; [[ $# -gt 0 ]] || arg_error "--lan needs a value."
                       LAN_SUBNET="$1"; SET_BY_FLAG[lan]=1 ;;
            --snapper) shift; [[ $# -gt 0 ]] || arg_error "--snapper needs a value."
                       case "$1" in
                           auto) ENABLE_SNAPPER="auto" ;;
                           on)   ENABLE_SNAPPER="1" ;;
                           off)  ENABLE_SNAPPER="0" ;;
                           *)    arg_error "--snapper must be auto|on|off." ;;
                       esac ;;
            --from)    shift; [[ $# -gt 0 ]] || arg_error "--from needs a value."
                       ONLY_STEP="" FROM_STEP="$1" ;;
            --only)    shift; [[ $# -gt 0 ]] || arg_error "--only needs a value."
                       FROM_STEP="" ONLY_STEP="$1" ;;
            --skip)    shift; [[ $# -gt 0 ]] || arg_error "--skip needs a value."
                       SKIP_STEPS+=("$1") ;;
            --list-steps) LIST_STEPS=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -y|--yes)     ASSUME_YES=1 ;;
            --no-wizard)  RUN_WIZARD=0 ;;
            -h|--help)    usage; exit 0 ;;
            *) arg_error "Unknown option: $1" ;;
        esac
        shift
    done
}

# Best-effort default LAN: the /24 of the default-route interface.
detect_lan_subnet() {
    local iface addr ipaddr
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}') || true
    [[ -n "$iface" ]] || return 1
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}') || true
    [[ "$addr" == */* ]] || return 1
    ipaddr="${addr%/*}"
    printf '%s.0/24\n' "${ipaddr%.*}"
}

# Interactive setup: only fills tunables not already pinned by a flag, and only
# when attached to a terminal (so unattended runs keep flags/defaults).
run_wizard() {
    [[ "$RUN_WIZARD" -eq 1 ]] || return 0
    [[ -t 0 ]] || return 0

    section "Setup wizard (press Enter to accept the [default])"
    local ans

    if [[ -z "${SET_BY_FLAG[machine]:-}" ]]; then
        read -r -p "Machine type — laptop/desktop [${MACHINE_TYPE}]: " ans || true
        case "${ans,,}" in
            laptop|desktop) MACHINE_TYPE="${ans,,}" ;;
            "") : ;;
            *)  warn "Unrecognised '${ans}' — keeping ${MACHINE_TYPE}." ;;
        esac
    fi

    # Mirror country only matters where reflector actually runs (vanilla Arch).
    if [[ -z "${SET_BY_FLAG[country]:-}" ]] && ! is_cachyos; then
        read -r -p "Mirror country [${REFLECTOR_COUNTRY}]: " ans || true
        [[ -n "$ans" ]] && REFLECTOR_COUNTRY="$ans"
    fi

    if [[ -z "${SET_BY_FLAG[lan]:-}" ]]; then
        local guess; guess=$(detect_lan_subnet) || guess="$LAN_SUBNET"
        read -r -p "LAN subnet allowed by the firewall [${guess}]: " ans || true
        LAN_SUBNET="${ans:-$guess}"
    fi
}

# Resolve a --from/--only/--skip value (function name or 1-based number from
# --list-steps) to an index into the FULL step list; usage error if unknown.
resolve_step() {
    local want="$1" i
    for i in "${!STEPS[@]}"; do
        if [[ "$want" == "${STEPS[$i]%%|*}" || "$want" == "$((i + 1))" ]]; then
            echo "$i"; return 0
        fi
    done
    arg_error "Unknown step '$want' — see --list-steps for names and numbers."
}

print_step_list() {
    local i
    for i in "${!STEPS[@]}"; do
        printf "%3d  %-26s %s\n" "$((i + 1))" "${STEPS[$i]%%|*}" "${STEPS[$i]#*|}"
    done
}

# Narrow STEPS according to --from/--only/--skip. Numbers always refer to the
# full list as shown by --list-steps; the [N/TOTAL] progress then re-counts
# over what's left. Idempotent steps make any partial run safe.
apply_step_filters() {
    local -a kept=()
    local i s idx from_idx=0

    # Validate every --skip value up front (a typo should be a usage error,
    # not a silently ignored filter).
    for s in "${SKIP_STEPS[@]}"; do
        resolve_step "$s" >/dev/null
    done

    if [[ -n "$ONLY_STEP" ]]; then
        idx=$(resolve_step "$ONLY_STEP")
        kept=("${STEPS[$idx]}")
    else
        [[ -n "$FROM_STEP" ]] && from_idx=$(resolve_step "$FROM_STEP")
        for i in "${!STEPS[@]}"; do
            (( i < from_idx )) && continue
            local skip=0
            for s in "${SKIP_STEPS[@]}"; do
                [[ "$s" == "${STEPS[$i]%%|*}" || "$s" == "$((i + 1))" ]] && skip=1
            done
            (( skip )) && continue
            kept+=("${STEPS[$i]}")
        done
    fi

    [[ ${#kept[@]} -gt 0 ]] || arg_error "Step filters left nothing to run."
    STEPS=("${kept[@]}")
}

# One-screen preview of the resolved config and the ordered steps.
print_plan() {
    local snap_desc
    case "$ENABLE_SNAPPER" in
        0)    snap_desc="off" ;;
        auto) snap_desc="auto (Btrfs only)" ;;
        *)    snap_desc="on" ;;
    esac
    local country_desc="$REFLECTOR_COUNTRY"
    is_cachyos && country_desc="n/a (CachyOS ranked mirrors — reflector skipped)"
    echo -e "\n${BLUE}================ planned run ================${RESET}"
    echo -e "  Machine type  : ${MACHINE_TYPE}"
    echo -e "  Mirror country: ${country_desc}"
    echo -e "  LAN subnet    : ${LAN_SUBNET}"
    echo -e "  Snapshots     : ${snap_desc}"
    echo -e "  Dotfiles      : ${DOTFILES_REPO} -> ${DOTFILES_DIR}"
    echo -e "  Log file      : ${LOG_FILE}"
    echo -e "  Steps (${#STEPS[@]}):"
    local i=1 entry
    for entry in "${STEPS[@]}"; do
        printf "    %2d. %s\n" "$i" "${entry#*|}"
        i=$((i + 1))
    done
    echo ""
}

confirm_run() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    [[ -t 0 ]] || return 0
    local ans
    read -r -p "Proceed with this plan? [Y/n]: " ans || true
    case "${ans,,}" in
        n|no) error_exit "Aborted by user." ;;
    esac
}

# ==============================================================================
# MAIN — execution order
# ==============================================================================

parse_args "$@"

# Ordered steps as "function|Label" — the single source of truth for the run
# loop, the [N/TOTAL] progress counter, the --dry-run plan preview, and the
# --from/--only/--skip filters. The mirror steps self-skip on CachyOS (which
# ships its own ranked mirrorlist) and run on vanilla Arch.
STEPS=(
    "configure_pacman|Harden pacman.conf + full system upgrade"
    "setup_mirrors|Rank pacman mirrors with reflector (skipped on CachyOS)"
    "setup_mirror_timer|Weekly reflector refresh timer (skipped on CachyOS)"
    "setup_pacman_hooks|Install pacman hooks (orphans + pkglist snapshot)"
    "install_paru|Install paru (AUR helper)"
    "install_essentials|Install bootstrap packages"
    "deploy_dotfiles|Clone + stow dotfiles (source of truth)"
    "install_from_pkglists|Install the full package set from pkglists/"
    "restore_secrets|Restore encrypted secrets (SSH keys)"
    "configure_qemu_kvm|Configure QEMU/KVM (services, groups, network)"
    "install_zsh_plugins|Install zsh plugins into ~/AUR"
    "set_default_shell_zsh|Set zsh as the default shell"
    "setup_firewall|Configure the UFW firewall"
    "harden_ssh|Harden the SSH daemon"
    "install_power_management|Power management (laptop=TLP / desktop=tuned)"
    "setup_snapper|Btrfs snapshots via snapper (no-op if not Btrfs)"
    "configure_desktop|Configure desktop session (font cache, PipeWire, SDDM)"
    "setup_user_dirs|Create user directories (~/ScreenShots)"
)

if [[ "$LIST_STEPS" -eq 1 ]]; then
    print_step_list
    exit 0
fi

apply_step_filters
STEP_TOTAL=${#STEPS[@]}

# Fail fast BEFORE the wizard: neither check needs sudo or network, and a root
# user shouldn't have to answer every question just to be turned away.
# Skipped for --dry-run, which must work anywhere (even a pacman-less CI box)
# since it changes nothing.
if [[ "$DRY_RUN" -eq 0 ]]; then
    check_not_root
    check_dependencies
fi

run_wizard          # interactive: fill anything not set by a flag

print_plan

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo -e "${YELLOW}Dry run — nothing was changed.${RESET}"
    exit 0
fi

confirm_run

# Past this point we actually change the system. Log EVERYTHING from here on —
# the script's own messages AND full pacman/paru/makepkg output — to $LOG_FILE
# while still printing to the terminal.
exec > >(tee -a "$LOG_FILE") 2>&1
log "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date)"
log "Log: $LOG_FILE"

# Pre-flight needing sudo/network (check_dependencies already verified curl).
check_sudo_access
check_internet

# Safety net for any unguarded command: the failing step's own stderr is right
# above (and in the log); this names the step so the run never dies silently.
# Deliberately NOT using `set -E` — inheriting the ERR trap into functions,
# command substitutions, and process substitutions fires it on guarded,
# expected failures. At the top level it only triggers when a step fails.
trap 'error_exit "Step ${STEP_NUM}/${STEP_TOTAL} failed: ${CURRENT_STEP_LABEL}"' ERR

# Run each step in order; section() shows the [N/TOTAL] progress prefix.
for entry in "${STEPS[@]}"; do
    STEP_NUM=$((STEP_NUM + 1))
    CURRENT_STEP_LABEL="${entry#*|}"
    "${entry%%|*}"
done
trap - ERR

print_summary
