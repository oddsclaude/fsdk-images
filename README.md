# fsdk-images

This is a fork-style downstream of [projectbluefin/fsdk-containers](https://github.com/projectbluefin/fsdk-containers)
for Edward's own Package-Image set.

## Images

| Image | Size | Description |
| ----- | ---- | ----------- |
| `ghcr.io/HuntedRaven7/base` | TBD | Distroless base: glibc, coreutils, CA certificates, timezone data. No shell, no package manager. Multi-arch: linux/amd64, linux/arm64. [¹](#base-contract) |
| `ghcr.io/HuntedRaven7/static` | TBD | Static tier for compiled Go/Rust binaries (`CGO_ENABLED=0`): CA certificates + tzdata only, no libc. Multi-arch: linux/amd64, linux/arm64. |
| `ghcr.io/HuntedRaven7/arch` | TBD | Minimal Arch Linux rootfs carved from the official `archlinux:base` image, with `pacman`/`pacman-key` intact. Slimmed of docs, translations, and static libs. Multi-arch: linux/amd64, linux/arm64. |
| `ghcr.io/HuntedRaven7/bootc` | TBD | Distroless bootc (bootable container) runtime: systemd PID 1, bootc binary, ostree storage, libsystemd, composefs. No shell. Multi-arch: linux/amd64, linux/arm64. |

## Adding an image

Each image is a `stack` (deps) -> `compose` (chisel) -> `script` (slim + OCI)
triple under `elements/<name>/` plus `elements/oci/<name>.bst`, registered once
in `elements/targets.json` (`oci_images` + `image_paths`). See the `base` and
`static` elements for working examples.

## License

Apache-2.0.