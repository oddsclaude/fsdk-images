# List available commands
[group('info')]
default:
    @just --list

# -- Configuration ---------------------------------------------------------
export image_name := env("BUILD_IMAGE_NAME", "base")
export image_registry := env("BUILD_IMAGE_REGISTRY", "ghcr.io/oci-shipyard")
# The tag the local build/verify/push recipes hand between each other. It is
# never published: keeping it distinct from any registry tag means a local
# working image can never be mistaken for, or accidentally pushed as, a
# released one.
local_tag := "build"

# Same bst2 container image FSDK CI uses -- pinned by SHA.
export bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")

# OCI metadata (dynamic labels), injected at export time.
export OCI_IMAGE_CREATED := env("OCI_IMAGE_CREATED", "")
export OCI_IMAGE_REVISION := env("OCI_IMAGE_REVISION", "")

# Prefix for podman calls: empty when rootless podman works, "sudo" otherwise.
sudo_cmd := if `podman info >/dev/null 2>&1 && echo 1 || echo 0` == "1" { "" } else { "sudo" }

# FSDK release parsed from the pinned junction ref -- the single source of truth
# for image versioning. e.g. "25.08.14", "26.08beta.1", or "26.08.0".
export fsdk_version := `grep -E '^\s*ref:' elements/freedesktop-sdk.bst | head -1 | sed -E 's/.*freedesktop-sdk-//; s/-[0-9]+-g[0-9a-f]+$//'`
# Exact junction commit ref (full ref: value), for provenance.
export fsdk_ref := `grep -E '^\s*ref:' elements/freedesktop-sdk.bst | head -1 | sed -E 's/^\s*ref:\s*//'`

# -- BuildStream wrapper ------------------------------------------------------
# Runs any bst command inside the bst2 container via podman.
# Baseline x86_64 (no x86_64_v3) so the base image runs on the widest CPU set.
[group('dev')]
bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    # Regenerated on every invocation from {{fsdk_version}} (this Justfile's
    # own single source of truth, parsed from elements/freedesktop-sdk.bst's
    # pinned ref) so BuildStream elements can consume the exact point
    # release via `(@): include/fsdk-version.yml`. Gitignored; never
    # hand-edited.
    cat > include/fsdk-version.yml <<'EOF'
    fsdk-version: "{{fsdk_version}}"
    EOF
    echo "==> BuildStream local execution (bst2 container)"
    # shellcheck disable=SC2086
    {{sudo_cmd}} podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{justfile_directory()}}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{bst2_image}}" \
        bash -c 'bst --colors "$@"' -- --no-interactive ${BST_FLAGS:-} {{ARGS}}

# Print the tag set derived from the FSDK release: minor line and point
# release/beta tag. Deliberately no "latest": a mutable rolling alias invites
# consumers to deploy an unpinned image and silently changes what they run.
[group('info')]
tags:
    #!/usr/bin/env bash
    set -euo pipefail
    V="{{fsdk_version}}"
    MINOR="$(echo "$V" | grep -oE '^[0-9]+\.[0-9]+')"
    if [ "$V" = "$MINOR" ]; then
        printf '%s\n' "$V"
    else
        printf '%s\n%s\n' "$MINOR" "$V"
    fi

# Print the OCI image names from the canonical manifest (elements/targets.json),
# one per line. Single source of truth for the GHA build/manifest matrices,
# `just validate`, and `just sbom`.
[group('info')]
image-list:
    @jq -r '.oci_images[]' elements/targets.json

# Print the OCI image names as a JSON array, for GitHub Actions `fromJson()` matrices.
[group('info')]
image-matrix:
    @jq -c '.oci_images' elements/targets.json

# Print the OCI build targets affected by the changes between BASE and HEAD as
# one JSON object: {"oci_images":[...]}. This is the pull-request build gate: a
# PR builds and verifies only what it can break. Path ownership lives in
# elements/targets.json, never in a workflow.
[group('info')]
changed-targets BASE HEAD="HEAD":
    #!/usr/bin/env bash
    set -euo pipefail
    MANIFEST=elements/targets.json

    # Compare against the merge base so a PR is judged on its own changes, not
    # on whatever landed on the base branch since it was opened.
    MERGE_BASE="$(git merge-base "{{BASE}}" "{{HEAD}}")"
    mapfile -t FILES < <(git diff --name-only "${MERGE_BASE}" "{{HEAD}}")

    # A prefix ending in '/' matches everything beneath it; anything else must
    # match the path exactly, so `elements/oci/base.bst` never matches
    # `elements/oci/base-extra.bst`.
    matches_any() {
        local file="$1"; shift
        local prefix
        for prefix in "$@"; do
            case "${prefix}" in
                */) [[ "${file}" == "${prefix}"* ]] && return 0 ;;
                *)  [[ "${file}" == "${prefix}" ]] && return 0 ;;
            esac
        done
        return 1
    }

    mapfile -t SHARED < <(jq -r '.shared_paths[]' "${MANIFEST}")
    CANARY="$(jq -r '.canary_image' "${MANIFEST}")"

    SELECTED=()
    SHARED_HIT=false
    for file in "${FILES[@]:-}"; do
        [ -n "${file}" ] || continue
        if matches_any "${file}" "${SHARED[@]}"; then
            SHARED_HIT=true
        fi
        while IFS= read -r img; do
            mapfile -t IMG_PATHS < <(jq -r --arg i "${img}" '.image_paths[$i][]' "${MANIFEST}")
            if matches_any "${file}" "${IMG_PATHS[@]}"; then
                SELECTED+=("${img}")
            fi
        done < <(jq -r '.oci_images[]' "${MANIFEST}")
    done

    if [ "${SHARED_HIT}" = true ]; then
        SELECTED+=("${CANARY}")
    fi

    # Deduplicate while keeping manifest order, so the matrix is stable.
    SELECTED_LINES="$(printf '%s\n' "${SELECTED[@]:-}" | grep -v '^$' || true)"
    OCI_JSON="$(printf '%s' "${SELECTED_LINES}" \
        | jq -Rsc --slurpfile m <(jq '{oci_images}' "${MANIFEST}") \
            'split("\n") | map(select(length > 0)) | unique as $sel
             | $m[0].oci_images | map(select(. as $i | $sel | index($i)))')"

    jq -cn --argjson oci "${OCI_JSON}" '{oci_images: $oci}'

# -- Validate ------------------------------------------------------------
[group('dev')]
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    ELEMENTS=()
    while IFS= read -r img; do
        ELEMENTS+=("oci/${img}.bst")
    done < <(just image-list)
    just bst show --deps all "${ELEMENTS[@]}"

# -- Build ---------------------------------------------------------------
# Build one OCI image (controlled by BUILD_IMAGE_NAME) and load into podman.
[group('build')]
build:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Building oci/{{image_name}}.bst with BuildStream..."
    just bst build "oci/{{image_name}}.bst"
    just export

# -- Export --------------------------------------------------------------
# Checkout the built OCI image and squash into a single layer in podman.
[group('build')]
export:
    #!/usr/bin/env bash
    set -euo pipefail
    FINAL_REF="{{image_registry}}/{{image_name}}:{{local_tag}}"

    echo "==> Exporting OCI image -> ${FINAL_REF}..."
    rm -rf .build-out
    just bst artifact checkout "oci/{{image_name}}.bst" --directory /src/.build-out

    IMAGE_ID=$({{sudo_cmd}} podman pull -q oci:.build-out)
    rm -rf .build-out

    case "{{image_name}}" in
        base)       DESC="Minimal, high-integrity distroless base image built on freedesktop-sdk" ;;
        static)     DESC="Static-tier runner for compiled Go/Rust binaries built on freedesktop-sdk" ;;
        *)          DESC="OCI-Shipyard distroless container image" ;;
    esac

    LABEL_ARGS=()
    [ -n "${OCI_IMAGE_CREATED}" ]  && LABEL_ARGS+=(--label "org.opencontainers.image.created=${OCI_IMAGE_CREATED}")
    [ -n "${OCI_IMAGE_REVISION}" ] && LABEL_ARGS+=(--label "org.opencontainers.image.revision=${OCI_IMAGE_REVISION}")
    LABEL_ARGS+=(--label "org.opencontainers.image.version={{fsdk_version}}")
    LABEL_ARGS+=(--label "org.opencontainers.image.title={{image_name}}")
    LABEL_ARGS+=(--label "org.opencontainers.image.description=${DESC}")
    LABEL_ARGS+=(--label "org.opencontainers.image.source=https://github.com/HuntedRaven7/fsdk-images")
    LABEL_ARGS+=(--label "org.opencontainers.image.licenses=Apache-2.0")
    LABEL_ARGS+=(--label "io.oci-shipyard.fsdk.version={{fsdk_version}}")
    LABEL_ARGS+=(--label "io.oci-shipyard.fsdk.ref={{fsdk_ref}}")

    # Squash to a single layer and apply dynamic labels.
    printf 'FROM %s\n' "$IMAGE_ID" \
      | {{sudo_cmd}} podman build --pull=never --squash-all "${LABEL_ARGS[@]}" -t "${FINAL_REF}" -f - .
    echo "==> Built ${FINAL_REF}"

# Push the locally built image under all derived tags to a given repo ref.
# The FSDK point-release tag (e.g. :25.08.15) is treated as immutable: if it
# already exists at the destination it is skipped, never overwritten.
# Usage: just tag-push ghcr.io/oci-shipyard/base
[group('build')]
tag-push REPO:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{image_registry}}/{{image_name}}:{{local_tag}}"
    while read -r t; do
        if [ "$t" = "{{fsdk_version}}" ] && skopeo inspect --no-tags "docker://{{REPO}}:$t" >/dev/null 2>&1; then
            echo "==> skipping {{REPO}}:$t (point-release tag already published, immutable)"
            continue
        fi
        {{sudo_cmd}} podman tag "$SRC" "{{REPO}}:$t"
        {{sudo_cmd}} podman push "{{REPO}}:$t"
        echo "==> pushed {{REPO}}:$t"
    done < <(just tags)

# -- Verify --------------------------------------------------------------
# Assert the image meets its contract: distroless images have no shell;
# all images ship CA certs + tzdata.
[group('test')]
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    REF="{{image_registry}}/{{image_name}}:{{local_tag}}"
    IMG="{{image_name}}"

    # Guard against silent size creep. These are uncompressed local Podman
    # sizes (not registry transfer sizes), with headroom for FSDK growth.
    case "$IMG" in
        base)       MAX_BYTES=$((64 * 1024 * 1024)) ;;
        static)     MAX_BYTES=$((80 * 1024 * 1024)) ;;
        *)          echo "FAIL: no size threshold configured for $IMG" >&2; exit 1 ;;
    esac
    SIZE_BYTES=$({{sudo_cmd}} podman image inspect --format '{{"{{.Size}}"}}' "$REF")
    if ! [[ "$SIZE_BYTES" =~ ^[0-9]+$ ]] || [ "$SIZE_BYTES" -gt "$MAX_BYTES" ]; then
        echo "FAIL: $IMG image size ${SIZE_BYTES} bytes exceeds ${MAX_BYTES} bytes" >&2
        exit 1
    fi
    echo "OK: image size ${SIZE_BYTES} bytes (limit ${MAX_BYTES})"

    {{sudo_cmd}} podman create --name verify-base "$REF" /verify-placeholder >/dev/null
    trap '{{sudo_cmd}} podman rm -f verify-base >/dev/null 2>&1 || true' EXIT
    LISTING="$(mktemp)"
    {{sudo_cmd}} podman export verify-base | tar -tf - > "$LISTING"

    TOTAL=5
    echo "==> [1/${TOTAL}] distroless: no shell present"
    if grep -qE '(^|/)(ba)?sh$' "$LISTING"; then
        echo "FAIL: a shell binary is present in the rootfs"; exit 1
    fi
    echo "OK: no shell"

    echo "==> [2/${TOTAL}] CA certificate bundle present"
    if ! grep -qE '^etc/(pki/tls/certs/ca-bundle\.crt|ssl/certs/ca-certificates\.crt)$' "$LISTING"; then
        echo "FAIL: no CA bundle file found"; exit 1
    fi
    echo "OK: CA bundle present"

    echo "==> [3/${TOTAL}] tzdata present"
    if ! grep -qE '^usr/share/zoneinfo/UTC$' "$LISTING"; then
        echo "FAIL: tzdata (zoneinfo/UTC) missing"; exit 1
    fi
    echo "OK: tzdata present"

    echo "==> [4/${TOTAL}] slim: bloat must NOT be present (terminfo, sanitizers, fortran)"
    if grep -qE 'usr/share/terminfo/|/lib(asan|tsan|lsan|ubsan|hwasan|gfortran)\.so' "$LISTING"; then
        echo "FAIL: slim bloat present -- slim recipe regressed"; exit 1
    fi
    echo "OK: slim bloat removed"

    echo "==> [5/${TOTAL}] slim: locale/build-tool bloat must NOT be present"
    if grep -qE 'usr/lib(/[^/]*)?/locale/locale-archive$|usr/share/i18n/charmaps/|/(localedef|sln|iconvconfig|ldconfig|pcre2test|pcre2grep)$|libpcre2-(16|32|posix)\.so' "$LISTING"; then
        echo "FAIL: locale/build-tool bloat present -- slim recipe regressed"; exit 1
    fi
    echo "OK: locale/build-tool bloat removed"

    echo "==> verify passed (${IMG})"

# Generate SBOMs (SPDX 2.3 JSON + CycloneDX JSON) for a variant using syft.
# SOURCE is optional; it defaults to the locally built image, which is saved
# from podman to an OCI archive so syft needs no daemon/socket. Published
# images can be scanned directly with an explicit transport, e.g.
#   just sbom base registry:ghcr.io/oci-shipyard/base:25.08.15
# Requires `syft` (>= 1.x) on PATH; CI installs it via taiki-e/install-action.
[group('test')]
sbom variant="base" source="":
    #!/usr/bin/env bash
    set -euo pipefail
    if jq -e --arg v "{{variant}}" '.oci_images | index($v) != null' elements/targets.json >/dev/null; then
        NAME="{{variant}}"
    else
        echo "ERROR: unknown variant '{{variant}}' (not in elements/targets.json)" >&2
        exit 1
    fi

    SOURCE="{{source}}"
    ARCHIVE=""
    trap 'rm -f "${ARCHIVE}"' EXIT
    if [ -z "${SOURCE}" ]; then
        SOURCE="{{image_registry}}/${NAME}:{{local_tag}}"
    fi
    if [[ "${SOURCE}" != registry:* && "${SOURCE}" != oci-archive:* && "${SOURCE}" != dir:* ]]; then
        ARCHIVE=".sbom-source.oci"
        rm -f "${ARCHIVE}"
        echo "==> Saving local image ${SOURCE} to an OCI archive..."
        {{sudo_cmd}} podman save --format oci-archive -o "${ARCHIVE}" "${SOURCE}"
        SOURCE="oci-archive:${ARCHIVE}"
    fi

    echo "==> Generating SBOMs for ${NAME} from ${SOURCE} (syft)"
    syft scan "${SOURCE}" \
        --source-name "{{image_registry}}/${NAME}" \
        --source-supplier "OCI-Shipyard" \
        --source-version "{{fsdk_version}}" \
        --output spdx-json="${NAME}.spdx.json" \
        --output cyclonedx-json="${NAME}.cyclonedx.json"
    echo "==> Wrote ${NAME}.spdx.json and ${NAME}.cyclonedx.json"

# Grype CVE scan of a variant image. Always writes the full JSON report to
# grype-<variant>.json; by default fails (exit 2) when a vulnerability at or
# above GRYPE_FAIL_ON (default high) has a fix available. Set GRYPE_GATE=false
# to report without failing (used by the weekly scan of published images).
# SOURCE resolution matches the `sbom` recipe. Requires `grype` on PATH.
[group('test')]
scan variant="base" source="":
    #!/usr/bin/env bash
    set -euo pipefail
    if jq -e --arg v "{{variant}}" '.oci_images | index($v) != null' elements/targets.json >/dev/null; then
        NAME="{{variant}}"
    else
        echo "ERROR: unknown variant '{{variant}}' (not in elements/targets.json)" >&2
        exit 1
    fi

    SOURCE="{{source}}"
    ARCHIVE=""
    trap 'rm -f "${ARCHIVE}"' EXIT
    if [ -z "${SOURCE}" ]; then
        SOURCE="{{image_registry}}/${NAME}:{{local_tag}}"
    fi
    if [[ "${SOURCE}" != registry:* && "${SOURCE}" != oci-archive:* && "${SOURCE}" != dir:* ]]; then
        ARCHIVE=".scan-source.oci"
        rm -f "${ARCHIVE}"
        echo "==> Saving local image ${SOURCE} to an OCI archive..."
        {{sudo_cmd}} podman save --format oci-archive -o "${ARCHIVE}" "${SOURCE}"
        SOURCE="oci-archive:${ARCHIVE}"
    fi

    echo "==> Scanning ${NAME} from ${SOURCE} (grype)"
    GRYPE_RC=0
    set +e
    grype "${SOURCE}" -o json --file "grype-${NAME}.json"
    GRYPE_RC=$?
    set -e
    if [ "${GRYPE_RC}" -ne 0 ]; then
        echo "FAIL: grype scan error for ${NAME} (rc=${GRYPE_RC})" >&2
        exit 1
    fi

    echo "==> Findings by severity (${NAME})"
    jq -r '.matches | group_by(.vulnerability.severity)[] | "\(.[0].vulnerability.severity): \(length)"' "grype-${NAME}.json"
    jq -r '"\ntotal: \(.matches | length)"' "grype-${NAME}.json"

    if [ "${GRYPE_GATE:-true}" = "true" ]; then
        SEV="${GRYPE_FAIL_ON:-high}"
        FAIL_COUNT=$(jq -r --arg sev "${SEV}" '
            ["negligible", "low", "medium", "high", "critical"] as $order
            | ($order | index($sev)) as $min
            | [.matches[]
                | .vulnerability.fix.state as $state
                | .vulnerability.severity as $severity
                | select(($state // "unknown") == "fixed")
                | select(($order | index($severity // "" | ascii_downcase)) >= $min)
              ] | length' "grype-${NAME}.json")
        if [ "${FAIL_COUNT}" -gt 0 ]; then
            echo "FAIL: ${NAME} has ${FAIL_COUNT} ${SEV}+ vulnerability(ies) with a fix available (see grype-${NAME}.json)" >&2
            exit 2
        fi
        echo "OK: no ${SEV}+ vulnerabilities with a fix available (${NAME})"
    else
        echo "==> Gate disabled (GRYPE_GATE=false): reporting only"
    fi
