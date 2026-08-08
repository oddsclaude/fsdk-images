kind: import
description: Import the official Arch Linux base image rootfs.

# The official archlinux:base image on Docker Hub is amd64-only (its image
# index carries just the linux/amd64 manifest plus an in-toto attestation),
# so the architecture is pinned rather than following the build host.
sources:
  - kind: docker_image
    url: docker://archlinux:base
    ref: sha256:a674898d53cc63b1af4023a468ccddc25ed9d7aecc3996f16171838a57085999
    architecture: amd64
