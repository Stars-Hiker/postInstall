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

configure_paru() {
    section "Configuring paru"

    local conf="$HOME/.config/paru/paru.conf"
    mkdir -p "$(dirname "$conf")"

    if file_exists "$conf"; then
        log "paru.conf already exists — skipping."
        return 0
    fi

    cat > "$conf" <<'EOF'
[options]
# Show AUR results below official packages in search output
BottomUp
# Keep sudo alive during long AUR builds
SudoLoop
# Upgrade official + AUR packages in a single paru -Syu
CombinedUpgrade
# Remove build dirs after install to reclaim disk space
CleanAfter
EOF

    success "paru.conf written to $conf"
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

    # Failures from BOTH lists accumulate here so we can report them once at the
    # end. A package that was renamed or dropped from the repos (a routine event
    # on rolling Arch) must NOT abort the whole recovery — we install everything
    # that still resolves, then tell the user exactly what to look at by hand.
    local -a failed=()

    # install_pkg_list <installer-cmd...> -- reads package names (one per line,
    # '#' comments and blanks ignored) from stdin and installs them one at a
    # time, appending any that fail to the shared `failed` array.
    install_pkg_list() {
        local pkg
        while IFS= read -r pkg; do
            pkg="${pkg%%#*}"; pkg="${pkg// /}"   # strip comments + whitespace
            [[ -n "$pkg" ]] || continue
            if ! "$@" --needed --noconfirm "$pkg" >/dev/null 2>&1; then
                warn "  ✗ failed: $pkg"
                failed+=("$pkg")
            fi
        done
    }

    if file_exists "$native"; then
        log "Installing native (repo) packages one by one from $native ..."
        install_pkg_list sudo pacman -S < "$native"
        success "Native package pass complete."
    else
        warn "No native package list at $native — skipping."
    fi

    if file_exists "$aur"; then
        if cmd_exists paru; then
            log "Installing AUR/foreign packages one by one from $aur ..."
            install_pkg_list paru -S < "$aur"
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

install_custom_tools() {
    section "Installing custom tools"

    local pkgs=(
        # System monitoring / info
        btop fastfetch

        # Browser
        firefox

        # Archives
        unzip zip xz p7zip

        # Wayland clipboard
        wl-clipboard

        # Modern CLI replacements
        eza yazi bat fd ripgrep fzf zoxide lazygit

        # Media
        mpv imv

        # Neovim ecosystem
        tree-sitter-cli luarocks

        # Compilers & debuggers
        gcc gdb

        # Network / security tools
        nmap
        wireshark-qt
        aircrack-ng
        nikto
        john
        hashcat
        gobuster
        sqlmap
        proxychains-ng
        whois
        inetutils
        openbsd-netcat
        tcpdump
        traceroute

        # BitTorrent
        deluge-gtk

        # Disk management
        gparted
        xorg-xhost
    )

    sudo pacman -S --needed --noconfirm "${pkgs[@]}" \
        || error_exit "Failed to install custom tools."

    # AUR-only tools — requires paru installed first.
    local aur_pkgs=(
        netdiscover     # ARP-based network scanner (removed from official repos)
        thefuck         # command correction (AUR only)
    )

    if cmd_exists paru; then
        paru -S --needed --noconfirm "${aur_pkgs[@]}" \
            || warn "Some AUR tools failed to install: ${aur_pkgs[*]} — skipping."
    else
        warn "paru not found — skipping AUR tools: ${aur_pkgs[*]}"
    fi

    success "Custom tools installed."
}

configure_qemu_kvm() {
    section "Configuring QEMU/KVM virtualisation stack"

    # NOTE: the QEMU/KVM PACKAGES (qemu-full, libvirt, virt-manager, swtpm,
    # edk2-ovmf, guestfs-tools, dnsmasq, …) are now installed from the dotfiles
    # package lists by install_from_pkglists(). This function only handles the
    # service/group/network setup that the lists can't capture. It runs after
    # install_from_pkglists(), so the binaries are already present.

    if ! cmd_exists virsh; then
        warn "libvirt not installed (not in pkglists?) — skipping KVM config."
        return 0
    fi

    # Enable libvirt daemon — but do NOT enable tuned here.
    # tuned is managed exclusively in install_power_management() so the
    # laptop vs desktop logic stays in one place.
    service_enabled libvirtd.service \
        || sudo systemctl enable --now libvirtd.service \
        || error_exit "Failed to enable libvirtd."

    # Add user to required groups.
    # libvirt → manage VMs without sudo
    # kvm     → direct access to /dev/kvm
    for grp in libvirt kvm; do
        if ! id -nG "$USER" | grep -qw "$grp"; then
            sudo usermod -aG "$grp" "$USER" \
                || error_exit "Failed to add $USER to group $grp."
            log "Added '$USER' to group '$grp'."
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
            git clone "$url" "$dest" || error_exit "Failed to clone '$name'."
        fi
    done
    success "ZSH plugins ready."
}

configure_zsh() {
    section "Configuring .zshrc"

    local zshrc="$HOME/.zshrc"
    # Use a hard-coded marker string to keep the heredoc as <<'EOF' (no
    # variable expansion inside the block, eliminating backslash-escape bugs).
    local marker="# managed by ${SCRIPT_NAME}"

    if grep -q "$marker" "$zshrc" 2>/dev/null; then
        log ".zshrc already contains the managed block — skipping."
        return 0
    fi

    # Write the marker line before the heredoc so the block itself is <<'EOF'.
    echo "$marker" >> "$zshrc"

    cat >> "$zshrc" <<'ZSHEOF'

# ── Wayland environment ───────────────────────────────────────────────────────
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# ── Aliases ───────────────────────────────────────────────────────────────────
alias ll='eza -la --icons --git'          # eza-enhanced listing
alias lt='eza --tree --icons --level=2'   # directory tree (2 levels deep)
alias cat='bat --paging=never'            # bat instead of plain cat
alias grep='grep --color=auto'
alias pac='sudo pacman -S --needed'
alias update='sudo pacman -Syu'
alias szsh='source ~/.zshrc'
alias nzsh='nvim ~/.zshrc'

# ── Auto ls after cd ──────────────────────────────────────────────────────────
cd() { builtin cd "$@" && eza -la --icons --git; }

# ── History ───────────────────────────────────────────────────────────────────
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS     # don't record consecutive duplicate commands
setopt HIST_IGNORE_SPACE    # commands prefixed with a space are not recorded
setopt SHARE_HISTORY        # share history across all open ZSH sessions in real time

# ── Key bindings (history substring search) ───────────────────────────────────
bindkey '^[[A' history-substring-search-up    # Up arrow
bindkey '^[[B' history-substring-search-down  # Down arrow

# ── Plugins ───────────────────────────────────────────────────────────────────
[[ -f "${HOME}/AUR/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] \
    && source "${HOME}/AUR/zsh-autosuggestions/zsh-autosuggestions.zsh"

[[ -f "${HOME}/AUR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] \
    && source "${HOME}/AUR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

[[ -f "${HOME}/AUR/zsh-history-substring-search/zsh-history-substring-search.zsh" ]] \
    && source "${HOME}/AUR/zsh-history-substring-search/zsh-history-substring-search.zsh"
ZSHEOF

    log ".zshrc updated. Run 'source ~/.zshrc' after switching to ZSH."
    success ".zshrc configured."
}

set_default_shell_zsh() {
    section "Setting ZSH as default shell"

    local zsh_path
    zsh_path=$(command -v zsh) || error_exit "zsh not found in PATH."

    if [[ "$SHELL" == "$zsh_path" ]]; then
        log "ZSH is already the default shell."
        return 0
    fi

    # chsh requires the shell to be listed in /etc/shells.
    grep -qxF "$zsh_path" /etc/shells \
        || echo "$zsh_path" | sudo tee -a /etc/shells > /dev/null

    chsh -s "$zsh_path" || error_exit "Failed to set ZSH as default shell."
    success "Default shell set to ZSH. Re-login to apply."
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
        || error_exit "Failed to install fonts."

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
        || error_exit "Failed to install UFW."

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

    service_enabled ufw \
        || sudo systemctl enable ufw \
        || error_exit "Failed to enable UFW service."

    sudo ufw --force enable || error_exit "Failed to activate UFW."
    sudo ufw status verbose | tee -a "$LOG_FILE"
    success "Firewall configured."
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

        pkg_installed tlp \
            || sudo pacman -S --needed --noconfirm tlp tlp-rdw \
            || error_exit "Failed to install TLP."

        # TLP manages radio kill switches directly — mask the systemd units
        # that would otherwise fight it.
        sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket

        service_enabled tlp.service \
            || sudo systemctl enable --now tlp.service \
            || error_exit "Failed to enable TLP."

        success "TLP enabled for laptop power management."

    else
        # Desktop mode: install and enable tuned with the "balanced" profile.
        # tuned is now installed here (not in install_qemu_kvm) so that it is
        # never present on laptop systems where it would conflict with TLP.
        pkg_installed tuned \
            || sudo pacman -S --needed --noconfirm tuned \
            || error_exit "Failed to install tuned."
        service_enabled tuned.service \
            || sudo systemctl enable --now tuned.service \
            || error_exit "Failed to enable tuned."

        if cmd_exists tuned-adm; then
            sudo tuned-adm profile balanced \
                || warn "Could not set tuned profile — run 'tuned-adm profile' manually."
            log "tuned profile set to 'balanced'."
        fi

        success "tuned enabled for desktop power management."
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
    sudo pacman -S --needed --noconfirm snapper snap-pac \
        || error_exit "Failed to install snapper."

    # Create a snapper config for root if one doesn't exist yet.
    if ! sudo snapper list-configs | grep -q "^root "; then
        sudo snapper -c root create-config / \
            || error_exit "Failed to create snapper root config."
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
# firefox, yazi, wl-clipboard et ttf-jetbrains-mono-nerd sont deja installes
# dans install_custom_tools / install_fonts — exclus ici pour eviter les doublons.
# ==============================================================================

install_hyprland() {
    section "Installing Hyprland & Wayland ecosystem"

    if ! cmd_exists paru; then
        error_exit "paru is required for this step but was not found. Run install_paru first."
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
        || error_exit "paru failed to install Hyprland packages."

    success "Hyprland ecosystem installed."

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
}


# ==============================================================================
# NEOVIM
# ==============================================================================

configure_neovim() {
    section "Configuring Neovim"

    local nvim_dir="$HOME/.config/nvim"
    local nvim_file="$nvim_dir/init.lua"

    mkdir -p "$nvim_dir"

    if file_exists "$nvim_file"; then
        log "init.lua already exists — skipping."
        return 0
    fi

    cat > "$nvim_file" <<'EOF'
-- ===========================================================================
-- Neovim base configuration — generated by postInstall
-- ===========================================================================

-- ── Editor behaviour ─────────────────────────────────────────────────────────
vim.opt.number         = true       -- absolute line numbers
-- vim.opt.relativenumber = true    -- uncomment for relative line numbers
vim.opt.cursorline     = true       -- highlight the line the cursor is on
vim.opt.scrolloff      = 8          -- keep 8 lines of context above/below cursor
vim.opt.signcolumn     = "yes"      -- always show sign column (git signs, LSP)
vim.opt.wrap           = false      -- don't soft-wrap long lines
vim.opt.clipboard			 = "unnamedplus"

-- ── Indentation ──────────────────────────────────────────────────────────────
vim.opt.expandtab      = true       -- insert spaces instead of a tab character
vim.opt.shiftwidth     = 4
vim.opt.tabstop        = 4
vim.opt.softtabstop    = 4
vim.opt.smartindent    = true

-- ── Search ───────────────────────────────────────────────────────────────────
vim.opt.ignorecase     = true       -- case-insensitive by default
vim.opt.smartcase      = true       -- case-sensitive if the query has uppercase
vim.opt.hlsearch       = false      -- don't leave highlights after a search

-- ── Appearance ───────────────────────────────────────────────────────────────
vim.opt.termguicolors  = true       -- 24-bit colour (required by most themes)

-- ── Clipboard ────────────────────────────────────────────────────────────────
-- Syncs Neovim's clipboard with the OS clipboard.
-- Requires wl-clipboard (Wayland) — installed by install_custom_tools().
vim.opt.clipboard      = "unnamedplus"

-- ── Splits ───────────────────────────────────────────────────────────────────
vim.opt.splitright     = true       -- :vsplit opens to the right
vim.opt.splitbelow     = true       -- :split opens below

-- ── Leader key ───────────────────────────────────────────────────────────────
vim.g.mapleader        = " "        -- Space as the leader key

-- ── Key mappings ─────────────────────────────────────────────────────────────

-- Clear search highlights
vim.keymap.set("n", "<leader>/", "<cmd>nohlsearch<CR>", { desc = "Clear search highlights" })

-- Move selected lines up/down in visual mode and re-indent
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up" })

-- Keep the cursor centred when scrolling with Ctrl-d / Ctrl-u
vim.keymap.set("n", "<C-d>", "<C-d>zz", { desc = "Scroll down (centred)" })
vim.keymap.set("n", "<C-u>", "<C-u>zz", { desc = "Scroll up (centred)" })

-- Save with Ctrl-s (normal and insert mode)
vim.keymap.set("n", "<C-s>", "<cmd>w<CR>",      { desc = "Save file" })
vim.keymap.set("i", "<C-s>", "<Esc><cmd>w<CR>", { desc = "Save file" })

-- ── Next steps ───────────────────────────────────────────────────────────────
-- This is a minimal base config intentionally — no plugin manager is bundled.
-- To add plugins, install lazy.nvim:
--   https://github.com/folke/lazy.nvim
-- Recommended starter plugins: telescope, nvim-treesitter, nvim-lspconfig,
-- conform.nvim (formatter), catppuccin or tokyonight (theme).
EOF

    success "Neovim init.lua written to $nvim_file"
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
            git clone "$DOTFILES_REPO" "$DOTFILES_DIR" \
                || error_exit "git clone failed."
            success "Dotfiles cloned from GitHub."

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
        warn "Run manually: cd $DOTFILES_DIR && stow zsh hypr rofi waybar kitty"
    fi
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
		echo -e "     Start Hyprland, then install the hyprexpo plugin "
    echo -e "  3. Run ${BLUE}ufw status verbose${RESET} to review firewall rules."
    echo -e "  4. Once SSH keys are set up, edit ${BLUE}/etc/ssh/sshd_config.d/99-hardening.conf${RESET}"
    echo -e "     and set ${BLUE}PasswordAuthentication no${RESET}."
    echo -e "  5. Run ${BLUE}nvim${RESET} to verify the config; see init.lua comments to"
    echo -e "     add lazy.nvim and plugins."
    echo ""
    echo -e "  Useful commands:"
    echo -e "    paru -Syu          — upgrade official + AUR packages"
    echo -e "    paru <name>        — search and install from AUR"
    echo -e "    pacman -Qdtq       — list orphaned packages"
    echo -e "    snapper list       — list Btrfs snapshots (if Btrfs)"
    echo -e "    tuned-adm profile  — show active tuned profile (desktop)"
    echo -e "    tlp-stat           — show TLP battery status (laptop)"
    echo -e "    cd ~/.dotfiles && git pull && stow --restow hypr zsh rofi waybar kitty"
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

# Mirrors
#setup_mirrors
#setup_mirror_timer

# AUR helper (needed before install_from_pkglists for the AUR list)
install_paru
configure_paru

# Bootstrap: minimal toolchain to fetch the dotfiles repo + decrypt secrets.
install_essentials
install_fonts           # moved early — no ordering dep, slow to download

# Bring the source of truth onto the machine, THEN install everything from it.
deploy_dotfiles         # clone dotfiles repo + stow configs (runs install.sh)
install_from_pkglists   # install the FULL package set from pkglists/*
restore_secrets         # decrypt ~/.ssh etc. (if age key is present)

# NOTE: install_custom_tools is intentionally NOT called — its curated package
# list is now captured in dotfiles/pkglists/ and installed above. The function
# is kept defined for reference only.

# Virtualisation: packages came from the list above; this only does
# service/group/network setup.
configure_qemu_kvm

# Shell
install_zsh_plugins
configure_zsh
set_default_shell_zsh

# Security
setup_firewall
harden_ssh

# Power
install_power_management   # laptop → TLP (masks tuned); desktop → tuned

# Snapshots (no-op if root is not Btrfs)
setup_snapper              # auto pre/post-pacman Btrfs snapshots via snap-pac

# Editor
#configure_neovim

# Hyprland + ecosysteme Wayland
install_hyprland

print_summary
