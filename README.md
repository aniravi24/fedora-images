# fedora-images

Custom [Fedora](https://fedoraproject.org) images built with
[BlueBuild](https://blue-build.org).

| Recipe | Base | For |
| --- | --- | --- |
| `aurora` | [Aurora](https://getaurora.dev) | desktop |
| `iot-devbox` | [Fedora IoT](https://fedoraproject.org/iot/) | headless dev box |

Both are signed with the same key and published to
`ghcr.io/aniravi24/<name>`.

## Layout

Each recipe owns its own file tree under `files/<recipe-name>/`, copied to `/`
at build time. Systemd units live there too (`usr/lib/systemd/system/`) rather
than in BlueBuild's shared `files/systemd/`, which is not per-recipe and would
copy every recipe's units into every image.

## Build an ISO

```bash
sudo ./scripts/build-iso.sh iso ghcr.io/aniravi24/<name> <variant> <name>.iso
```

Build from the published image, not from a recipe: a recipe build records the
wrong image as the update source.

## Verify a machine after installing

```bash
scp scripts/verify-install.sh <host>:/tmp/ && ssh -t <host> 'sudo bash /tmp/verify-install.sh'
```

Checks the image ref, registry reachability, update schedule, tailscale login,
kernel arguments, disk headroom and failed units.

## Verify an image signature

```bash
cosign verify --key cosign.pub ghcr.io/aniravi24/<name>
```

## Dotfiles

Managed with [chezmoi](https://chezmoi.io); `chezmoi` and `age` are installed by
this image. The dotfiles repo is separate and private.

On a fresh machine, after the first boot:

```bash
# 1. age key from your password manager, or nothing encrypted can be decrypted
mkdir -p ~/.config/chezmoi && $EDITOR ~/.config/chezmoi/key.txt && chmod 600 ~/.config/chezmoi/key.txt

# 2. zprezto first: chezmoi tracks only the runcoms, not the upstream modules
git clone --recursive https://github.com/sorin-ionescu/prezto.git ~/.zprezto

# 3. dotfiles
chezmoi init --apply git@github.com:aniravi24/dotfiles.git
```

Machine-specific aliases live in `.zshrc.local`, stored age-encrypted. Credential
stores and shell history are excluded from the repo entirely rather than
encrypted: they are regenerated per machine, not reproduced.
