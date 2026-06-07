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

## Rebuild a machine

On a fresh Arch/CachyOS install, as your normal user (not root):

```sh
git clone https://github.com/Stars-Hiker/postInstall ~/postInstall
cd ~/postInstall
./ArchHyprPostInstall.sh
```

Then place your private age key at `~/.config/age/keys.txt` (from Bitwarden/USB)
and run `~/.dotfiles/bin/secrets-unseal.sh` to restore your SSH keys. Reboot when
done. See the GUIDE for the full walkthrough.
