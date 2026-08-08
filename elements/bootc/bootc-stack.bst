kind: stack
description: |
  bootc runtime stack: the distroless FSDK base plus the bootc binary and the
  system libraries it links against at runtime (libostree, libsystemd) and
  the helper tools it execs (composefs-ctl for composefs images, the
  util-linux core for `bootc install`). Includes the full systemd init
  system because bootc containers boot systemd as PID 1.

depends:
  - base/base-stack.bst
  - bootc/bootc-build.bst
  - freedesktop-sdk.bst:components/ostree.bst
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/composefs.bst
  - freedesktop-sdk.bst:components/util-linux.bst
