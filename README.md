# postInstall

Post-installation bootstrapper for an Arch/CachyOS + Hyprland laptop. A single
script, `ArchHyprPostInstall.sh`, that turns a fresh base install into my full
working setup: base tools + paru, then it clones my
[`dotfiles`](https://github.com/Stars-Hiker/dotfiles) repo, stows the configs,
installs every package from the saved lists, restores encrypted secrets, and
sets up services, firewall, and Hyprland.

> 📖 **How does the whole backup/recovery system work?** Read the plain-language
> **[GUIDE.md](https://github.com/Stars-Hiker/dotfiles/blob/main/GUIDE.md)** in
> the `dotfiles` repo. It explains the two-repo design, secrets, and what to do.

## TL;DR recovery

```sh
git clone https://github.com/Stars-Hiker/postInstall ~/postInstall
cd ~/postInstall
./ArchHyprPostInstall.sh              # add --desktop on a desktop
# → a wizard asks machine type / country / LAN, then previews a numbered plan
# → when prompted, paste your AGE-SECRET-KEY to restore SSH keys (or skip it)
sudo reboot
```

Want to see what it would do first? `./ArchHyprPostInstall.sh --dry-run` prints
the resolved config and the ordered steps and changes nothing.

## Options

| Flag | Effect |
|------|--------|
| `--laptop` / `--desktop` | Machine type (default `laptop`): TLP vs tuned. |
| `--country <name>` | Reflector mirror country (default `France`). |
| `--lan <cidr>` | LAN subnet allowed by the firewall (wizard auto-detects one). |
| `--snapper <auto\|on\|off>` | Btrfs snapshots (default `auto` = on only if root is Btrfs). |
| `-n`, `--dry-run` | Print the resolved config + ordered steps, then exit. |
| `-y`, `--yes` | Skip the confirmation prompt (unattended runs). |
| `--no-wizard` | Skip the interactive wizard; use flags/defaults. |
| `-h`, `--help` | Show usage. |

With no flags on a terminal a short **wizard** asks for the machine type, mirror
country, and LAN subnet, shows a **numbered plan**, and asks to confirm before
touching the system. `--yes` (or a non-interactive shell) runs unattended.

## Secrets (the age key)

During the run the script offers to take your `AGE-SECRET-KEY` and restore your
SSH keys. If you skip it, place the key later at `~/.config/age/keys.txt` and run
`~/.dotfiles/bin/secrets-unseal.sh`. Once secrets are restored the script switches
the dotfiles remote to SSH so `dotsync` can push without a GitHub login. See the
GUIDE for the full walkthrough.
