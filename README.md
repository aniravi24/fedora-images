# fedora-images

Custom [Fedora](https://fedoraproject.org) images built with
[BlueBuild](https://blue-build.org).

| Recipe | Base | For |
| --- | --- | --- |
| `aurora-ani` | [Aurora](https://getaurora.dev) | desktop |
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
