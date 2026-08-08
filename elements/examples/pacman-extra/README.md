# Example: baking extra Arch packages in for a bootc base

Reference example, not part of the published targets — nothing in
`elements/targets.json` references it, so CI never builds or publishes it.
It exists to show the pattern for growing the Arch image into a
[bootc](https://containers.github.io/bootc/) (bootable container) base.

## How it works

`arch-with-packages.bst` is a `script` element whose **sandbox OS is the Arch
rootfs itself**: `arch/arch-rootfs.bst` is staged at `/` (the default
`location`), so `pacman`/`libalpm` run natively inside the build. This is the
same mechanism the OCI elements already use — `elements/oci/base.bst` stages
freedesktop-sdk's `oci-builder` at `/` to get `build-oci`.

The commands:

1. `pacman-key --init && pacman-key --populate archlinux` — the official
   archlinux images strip the local signing key for security, and pacman
   refuses to verify signed packages without it. The keyring is initialized
   in the *build sandbox only*; the resulting image does **not** carry it and
   needs `pacman-key --init && pacman-key --populate archlinux` on first boot
   (same as upstream).
2. `pacman -r /layer -Syu --noconfirm` — sync **and** upgrade. Arch is a
   rolling release and the pinned base digest can be days stale; a bare
   `-Sy` risks a partial upgrade. `-r /layer` installs into the staging
   layer, not the sandbox root.
3. `pacman -r /layer -S --noconfirm --noscriptlet %{extra-packages}` — the
   package list lives in the `extra-packages` variable, edit freely.
4. `rm -rf /layer/var/cache/pacman/pkg` — never ship the downloaded cache.

The artifact is the modified rootfs at `/layer`, so it drops straight into
any OCI element as its layer.

## `--noscriptlet` caveat

Package `.INSTALL` post-install scripts are executed by pacman via a `chroot`
into the new root. The buildbox-run sandbox may not grant `CAP_SYS_CHROOT`,
so the example passes `--noscriptlet` to skip them (pure file install, no
chroot needed). If your sandbox allows chroot and you need scriptlets (user
creation, systemd unit enablement, ...), remove the flag and test in CI.

## Wiring it into an image

Copy `elements/oci/arch.bst` and swap the layer dependency:

```yaml
build-depends:
  - freedesktop-sdk.bst:components/oci-builder.bst
  - filename: examples/pacman-extra/arch-with-packages.bst
    config:
      location: /layer
```

Register the copy in `elements/targets.json` (`oci_images` + `image_paths` +
`archs`) and the repo's build/manifest/publish machinery picks it up with no
workflow edits.

## bootc notes

- The resulting image keeps `pacman`, so you can keep adding packages here,
  or users can `pacman -S` at runtime.
- For a bootc image, set the OCI config to boot `systemd` as PID 1, e.g.
  `config: Cmd: ["/usr/bin/systemd"]` in the `build-oci` heredoc.
- Rolling release: `bst source track` on `arch/arch-rootfs.bst` bumps the
  pinned base digest; the `-Syu` during build then pulls current packages.
  Rebuilds are therefore reproducible against the pinned digest but the
  package set moves with the mirrors.
- The image is amd64-only (`archs` in `targets.json` restricts it to the
  `x86_64` CI leg); official Arch container images have no arm64 variant.
