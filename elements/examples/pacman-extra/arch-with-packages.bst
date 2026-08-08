# EXAMPLE -- not in elements/targets.json, not built or published by CI.
#
# Bakes extra Arch packages into the rootfs with pacman, for a future bootc
# base. The trick: arch/arch-rootfs.bst is staged at "/", so the Arch rootfs
# itself becomes the sandbox OS -- exactly like the OCI elements stage
# freedesktop-sdk's oci-builder at "/" to get build-oci. pacman/libalpm then
# run natively, no chroot machinery required.
#
# Wire it into a (copy of) elements/oci/arch.bst by swapping the layer
# build-dependency:
#
#   - filename: arch/arch-rootfs.bst      ->   - filename: examples/pacman-extra/arch-with-packages.bst
#     config:                                 config:
#       location: /layer                        location: /layer
#
kind: script

description: (example) Install extra Arch packages into the rootfs with pacman.

build-depends:
  # Staged at "/" (default location): this rootfs is the sandbox OS.
  - arch/arch-rootfs.bst

# The artifact is the modified rootfs at /layer, ready to be staged as the
# layer of an OCI element downstream.
variables:
  install-root: /layer
  # Packages to bake in. Pick ones whose post-install scripts you can live
  # without, see the --noscriptlet note below. Edit freely -- this is the list
  # you'll grow for your bootc image.
  extra-packages: "jq ripgrep htop"

config:
  commands:
    - |
      set -eu

      # The official archlinux images strip the local signing key for security
      # (shared across every copy of the image otherwise). pacman refuses to
      # verify signed packages without it, so initialize it in the build
      # sandbox. The resulting image does NOT carry this keyring and needs
      # `pacman-key --init && pacman-key --populate archlinux` on first boot,
      # same as the upstream image.
      pacman-key --init
      pacman-key --populate archlinux

      # Rolling release: the pinned base digest may be a few days stale, so
      # sync AND upgrade before installing to avoid a partial upgrade.
      pacman -r /layer -Syu --noconfirm

      # Install into /layer, not the sandbox root.
      #
      # --noscriptlet: package .INSTALL post-install scripts are executed via
      # chroot into the new root, and the buildbox-run sandbox may not grant
      # CAP_SYS_CHROOT. The flag skips them (pure file install). If your
      # sandbox allows chroot and you need scriptlets (e.g. user creation,
      # systemd unit enablement), drop it.
      pacman -r /layer -S --noconfirm --noscriptlet %{extra-packages}

      # Never ship the downloaded package cache.
      rm -rf /layer/var/cache/pacman/pkg
