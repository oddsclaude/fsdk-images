# fsdk-images

This is a fork-style downstream of [projectbluefin/fsdk-containers](https://github.com/projectbluefin/fsdk-containers)
for Edward's own Package-Image set.

## Images

| Image | Size | Description |
| ----- | ---- | ----------- |
| `ghcr.io/oci-shipyard/base` | TBD | Distroless base: glibc, coreutils, CA certificates, timezone data. No shell, no package manager. Multi-arch: linux/amd64, linux/arm64. [¹](#base-contract) |
| `ghcr.io/oci-shipyard/static` | TBD | Static tier for compiled Go/Rust binaries (`CGO_ENABLED=0`): CA certificates + tzdata only, no libc. Multi-arch: linux/amd64, linux/arm64. |

## Adding an image

Each image is a `stack` (deps) -> `compose` (chisel) -> `script` (slim + OCI)
triple under `elements/<name>/` plus `elements/oci/<name>.bst`, registered once
in `elements/targets.json` (`oci_images` + `image_paths`). See the `base` and
`static` elements for working examples.

## License

Apache-2.0.
