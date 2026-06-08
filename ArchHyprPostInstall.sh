#!/bin/bash
# ==============================================================================
# Arch Linux Post-Installation Script — v3
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
readonly SCRIPT_VERSION="5"
readonly DOTFILES_REPO="https://github.com/Stars-Hiker/dotfiles"
readonly DOTFILES_DIR="$HOME/.dotfiles"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly AUR_DIR="$HOME/AUR"

# Reflector: country used for mirror selection and the reflector timer unit.
readonly REFLECTOR_COUNTRY="France"

# Set to "laptop" or "desktop".
#   laptop  → installs TLP for battery management, disables tuned
#   desktop → uses tuned with the "balanced" profile, skips TLP
readonly MACHINE_TYPE="laptop"

# Set to 1 if your root filesystem is Btrfs and you want automatic snapshots.
# The script auto-detects this, but you can force-disable it by setting to 0.
readonly ENABLE_SNAPPER="auto"

# ==============================================================================
# COLOURS & LOGGING
# All output goes to the terminal AND to $LOG_FILE for post-run review.
# ==============================================================================

readonly BLUE="\e[1;34m"
readonly GREEN="\e[1;32m"
readonly YELLOW="\e[1;33m"
readonly RED="\e[1;31m"
readonly RESET="\e[0m"

log()     { echo -e "${BLUE}   >> $1${RESET}"   | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}   OK $1${RESET}"  | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW} WARN $1${RESET}" | tee -a "$LOG_FILE"; }

error_exit() {
    # Pipe to tee first, THEN redirect combined output to stderr.
    # (echo ... >&2 | tee) does NOT work — >&2 fires before tee sees anything.)
    echo -e "${RED}  ERR $1${RESET}" | tee -a "$LOG_FILE" >&2
    echo -e "${RED}  See $LOG_FILE for the full run log.${RESET}" >&2
    exit 1
}

section() {
    echo -e "\n${BLUE}============================================${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}  $1${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}============================================${RESET}" | tee -a "$LOG_FILE"
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
    ( while true; do sudo -n true; sleep 50; done ) &
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

    sudo pacman -Syy
    success "pacman.conf configured."
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
    # pkglists/pkgs-{native,aur}.txt always reflect reality. The generator runs
    # as root (hooks always do) and chowns the files back to the repo owner.
    # The [ -d ] guard makes it a no-op on a machine where the dotfiles repo
    # isn't cloned yet (e.g. mid-bootstrap). Absolute path is required: hooks
    # have no $HOME and no working directory guarantees.
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
Exec = /bin/bash -c '[ -x "${snapshot}" ] && "${snapshot}" || true'
EOF

    success "pacman hooks installed."
}

# ==============================================================================
# MIRRORS
# ==============================================================================

setup_mirrors() {
    section "Configuring pacman mirrors"

    if ! pkg_installed reflector; then
        # This is the one and only full system upgrade in the script.
        # All subsequent installs use -S (no repeated -Syu).
        sudo pacman -Syu --needed --noconfirm reflector \
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

    local paru_dir="${AUR_DIR}/paru"
    (
        if ! dir_exists "$paru_dir"; then
            git clone https://aur.archlinux.org/paru.git "$paru_dir" \
                || error_exit "Failed to clone paru."
        fi
        cd "$paru_dir"
        makepkg -si --noconfirm || error_exit "makepkg failed for paru."
    )
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
restore_secrets() {
    section "Restoring encrypted secrets"

    local unseal="$DOTFILES_DIR/bin/secrets-unseal.sh"
    local identity="$HOME/.config/age/keys.txt"

    if ! file_exists "$unseal"; then
        warn "No unseal script at $unseal — skipping secrets restore."
        return 0
    fi

    if file_exists "$identity"; then
        log "Age identity found — decrypting secrets..."
        bash "$unseal" \
            || warn "secrets-unseal.sh failed — restore your secrets manually."
        success "Secrets restored."
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
    sudo virt-host-validate qemu 2>&1 | tee -a "$LOG_FILE" \
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
# FONTS
# Installed early — no ordering dependency and they're slow to download.
# ==============================================================================

install_fonts() {
    section "Installing fonts"
    local pkgs=(
        noto-fonts
        noto-fonts-emoji        # Emoji rendering — missing by default on Arch
        otf-monaspace-nerd
        ttf-jetbrains-mono-nerd
        otf-font-awesome
    )
    sudo pacman -S --needed --noconfirm "${pkgs[@]}" \
        || { warn "Some fonts failed to install — continuing (icons/emoji may be missing)."; return 0; }

    # Rebuild font cache so new fonts are usable immediately without a reboot.
    fc-cache -fv &>/dev/null
    success "Fonts installed and cache rebuilt."
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
    sudo ufw allow ssh
    sudo ufw allow Deluge

    # Allow all traffic from your LAN. Adjust the subnet if yours differs.
    sudo ufw allow from 192.168.0.0/24 comment "LAN"

    # Rate-limit SSH: max 6 new connections per 30s per source IP.
    sudo ufw limit ssh comment "SSH rate-limit"

    # Deluge BitTorrent — no built-in UFW profile exists on Arch.
    #sudo ufw allow 6881/tcp comment "Deluge TCP"
    #sudo ufw allow 6881/udp comment "Deluge UDP"

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
    sudo ufw status verbose | tee -a "$LOG_FILE"
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
# HYPRLAND — compositeur Wayland + ecosysteme complet
# Tous les paquets passent par paru (gere official + AUR en une commande).
# firefox, yazi, wl-clipboard et ttf-jetbrains-mono-nerd arrivent deja via les
# pkglists et install_fonts — exclus ici pour eviter les doublons.
# ==============================================================================

install_hyprland() {
    section "Installing Hyprland & Wayland ecosystem"

    if ! cmd_exists paru; then
        warn "paru not found — cannot install the Hyprland packages. Skipping."
        warn "Install paru, then re-run, or: paru -S hyprland waybar rofi kitty ..."
        return 0
    fi

    # ── Core — Hyprland et ecosysteme natif Hypr ─────────────────────────────
    local pkgs_core=(
        hyprland                    # Compositeur Wayland
        hyprlock                    # Ecran de verrouillage
        hypridle                    # Daemon inactivite (verrouillage + veille auto)
        hyprsunset                  # Filtre lumiere bleue
        hyprpolkitagent             # Agent Polkit natif (remplace polkit-kde)
        hyprshot                    # Captures d ecran
        xdg-desktop-portal-hyprland # Partage d ecran Wayland (OBS, Discord, Zoom)
    )

    # ── Interface ─────────────────────────────────────────────────────────────
    local pkgs_ui=(
        waybar                      # Barre de statut
        rofi                        # Launcher (supporte Wayland)
        papirus-icon-theme          # Icones pour rofi --show-icons
        #wlogout                     # Menu deconnexion/extinction
        swaync                      # Daemon notifications + panel
    )

    # ── Terminal & environnement ───────────────────────────────────────────────
    local pkgs_env=(
        kitty                       # Terminal principal
        swww                        # Daemon wallpaper avec transitions
        cliphist                    # Gestionnaire presse-papiers
    )

    # ── Audio — PipeWire ──────────────────────────────────────────────────────
    # NOTE: pipewire, wireplumber et pipewire-pulse sont aussi installes par
    # ArchWizard dans le chroot. paru --needed les ignore s ils sont deja presents.
    local pkgs_audio=(
        pipewire                    # Serveur audio moderne
        wireplumber                 # Session manager (requis par wpctl)
        pipewire-pulse              # Compatibilite PulseAudio
    )

    # ── Peripheriques ─────────────────────────────────────────────────────────
    local pkgs_hw=(
        brightnessctl               # Controle luminosite ecran
        playerctl                   # Controle lecture media
    )

    # ── Optionnels recommandes ────────────────────────────────────────────────
    local pkgs_optional=(
        nwg-look                    # Reglage theme GTK sous Wayland
        qt6ct                       # Reglage theme Qt6 sous Wayland
        qt5-wayland                 # Support Wayland pour apps Qt5
        qt6-wayland                 # Support Wayland pour apps Qt6
        hyprcursor                  # Format curseur natif Hypr (HiDPI)
        hyprpicker                  # Pipette couleur Wayland
        wallust                     # Theming auto depuis le fond d ecran
        grim                        # Backend screenshot (dep de hyprshot region)
        slurp                       # Selection zone ecran (dep de hyprshot region)
        libnotify                   # Fournit notify-send (utilise par hypridle)
    )

    # ── Installation groupee via paru ─────────────────────────────────────────
    local all_pkgs=(
        "${pkgs_core[@]}"
        "${pkgs_ui[@]}"
        "${pkgs_env[@]}"
        "${pkgs_audio[@]}"
        "${pkgs_hw[@]}"
        "${pkgs_optional[@]}"
    )

    log "Installing ${#all_pkgs[@]} Hyprland packages via paru..."
    paru -S --needed --noconfirm "${all_pkgs[@]}" \
        || warn "Some Hyprland packages failed to install (see paru output above) — continuing."

    success "Hyprland ecosystem step done."

    # ── Plugin hyprexpo via hyprpm ────────────────────────────────────────────
    # hyprpm est installe avec hyprland. Il gere les plugins officiels.
    #if cmd_exists hyprpm; then
    #    log "Installing hyprexpo plugin via hyprpm..."
    #    hyprpm add https://github.com/hyprwm/hyprland-plugins 2>/dev/null || true
    #    hyprpm enable hyprexpo 2>/dev/null \
    #        && success "hyprexpo plugin enabled." \
    #        || warn "hyprexpo could not be enabled — run 'hyprpm enable hyprexpo' after first Hyprland boot."
    #else
    #    warn "hyprpm not found — install hyprexpo manually after first Hyprland boot:"
    #    warn "  hyprpm add https://github.com/hyprwm/hyprland-plugins"
    #    warn "  hyprpm enable hyprexpo"
    #fi

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
# MAIN — execution order
# ==============================================================================

# Truncate / create the log file for this run.
: > "$LOG_FILE"

log "Starting ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date)"
log "Log: $LOG_FILE"

# Pre-flight
check_not_root
check_sudo_access
check_internet
check_dependencies

# Pacman config first — all subsequent installs benefit from ParallelDownloads
# and the multilib repo being available.
configure_pacman        # Color, ParallelDownloads, VerbosePkgLists, multilib
setup_pacman_hooks      # incl. the pkglist-snapshot hook (keeps lists fresh)

# Mirrors: intentionally disabled. CachyOS ships its own ranked mirrorlist, so
# running reflector here is redundant. Uncomment on a plain Arch install.
#setup_mirrors
#setup_mirror_timer

# AUR helper (needed before install_from_pkglists for the AUR list).
# paru.conf now ships from the dotfiles 'paru' stow package (deployed by
# deploy_dotfiles below), so it is no longer generated here.
install_paru

# Bootstrap: minimal toolchain to fetch the dotfiles repo + decrypt secrets.
install_essentials
install_fonts           # moved early — no ordering dep, slow to download

# Bring the source of truth onto the machine, THEN install everything from it.
deploy_dotfiles         # clone dotfiles repo + stow configs (runs install.sh)
install_from_pkglists   # install the FULL package set from pkglists/*
restore_secrets         # decrypt ~/.ssh etc. (if age key is present)

# Virtualisation: packages came from the list above; this only does
# service/group/network setup.
configure_qemu_kvm

# Shell: the zsh config itself comes from the stowed dotfiles zsh/.zshrc; this
# only clones the plugins it sources (into ~/AUR) and sets zsh as the default.
install_zsh_plugins
set_default_shell_zsh

# Security
setup_firewall
harden_ssh

# Power
install_power_management   # laptop → TLP (masks tuned); desktop → tuned

# Snapshots (no-op if root is not Btrfs)
setup_snapper              # auto pre/post-pacman Btrfs snapshots via snap-pac

# Hyprland + ecosysteme Wayland
install_hyprland

# User directories (screenshot target referenced by HYPRSHOT_DIR in .zshrc)
setup_user_dirs

print_summary
