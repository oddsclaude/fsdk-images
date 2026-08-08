"""
docker_image - stage the rootfs of a container image
=====================================================

**Usage:**

.. code:: yaml

   kind: docker_image

   # The image to import, as docker://<repository>[:<tag>]. A repository
   # without a namespace is assumed to live in the 'library' namespace on
   # Docker Hub (e.g. 'archlinux' == 'library/archlinux').
   url: docker://archlinux:base

   # The ref is the sha256 digest of the image manifest (the platform
   # variant selected by `architecture`). 'bst source track' resolves the
   # tag to the current manifest digest and writes it back here.
   ref: sha256:a674898d53cc63b1af4023a468ccddc25ed9d7aecc3996f16171838a57085999

   # The platform architecture to select for multi-arch images, in
   # Docker/OCI naming (amd64, arm64, ...). Defaults to amd64.
   architecture: amd64

All layers of the selected image manifest are downloaded and extracted in
order; the staged output is the concatenation of every layer rootfs.
"""

import json
import os
import shutil
import tarfile
import urllib.error
import urllib.parse
import urllib.request

from buildstream import Source, SourceError
from buildstream import utils

# Docker Hub anonymous token endpoint and registry host
_TOKEN_URL = "https://auth.docker.io/token"
_REGISTRY = "registry-1.docker.io"
_ACCEPT = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json, "
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)


def _download_blob(blob_url, token, local_file, expected_sha):
    request = urllib.request.Request(blob_url)
    request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30 * 60) as response:
            with open(local_file, "wb") as destination:
                shutil.copyfileobj(response, destination)
    except (urllib.error.URLError, OSError, ValueError) as e:
        return None, "download failed: {}".format(e)

    sha256 = utils.sha256sum(local_file)
    if sha256 != expected_sha:
        return None, "blob digest mismatch: got '{}', expected '{}'".format(sha256, expected_sha)

    return local_file, None


class DockerImageSource(Source):
    BST_MIN_VERSION = "2.0"

    def configure(self, node):
        self.original_url = node.get_str("url")
        self.ref = node.get_str("ref", None)
        self.architecture = node.get_str("architecture", "amd64")

        node.validate_keys(Source.COMMON_CONFIG_KEYS + ["url", "ref", "architecture"])

        self.repository, self.tag = self._split_image_url(self.original_url)

        self._mirror_dir = os.path.join(
            self.get_mirror_directory(), utils.url_directory_name(self.original_url)
        )
        os.makedirs(self._mirror_dir, exist_ok=True)

    def preflight(self):
        pass

    def get_unique_key(self):
        return [self.original_url, self.ref, self.architecture]

    def is_cached(self):
        return self.ref is not None and os.path.isfile(self._manifest_file())

    def load_ref(self, node):
        self.ref = node.get_str("ref", None)

    def get_ref(self):
        return self.ref

    def set_ref(self, ref, node):
        node["ref"] = self.ref = ref

    def track(self, *, previous_sources_dir=None):
        digest, manifest = self._load_manifest(self.tag)
        self.ref = digest
        self._ensure_mirror(manifest)
        return digest

    def fetch(self, *, previous_sources_dir=None):
        if self.ref is None:
            raise SourceError("{}: No ref specified, run 'bst source track'.".format(self))
        if self.is_cached():
            return
        _, manifest = self._load_manifest(self.ref)
        self._ensure_mirror(manifest)

    def stage(self, directory):
        if self.ref is None:
            raise SourceError("{}: No ref specified, run 'bst source track'.".format(self))
        try:
            with open(self._manifest_file()) as manifest_file:
                manifest = json.load(manifest_file)
            for layer in manifest.get("layers", []):
                blob_file = self._blob_file(layer["digest"])
                with tarfile.open(blob_file, mode="r:gz") as tar:
                    tar.extractall(path=directory)
        except (tarfile.TarError, OSError, json.JSONDecodeError) as e:
            raise SourceError("{}: Error staging source: {}".format(self, e)) from e

    # ------------------------------------------------------------------ #
    #                    Private Methods Implementations                 #
    # ------------------------------------------------------------------ #

    def _split_image_url(self, url):
        if not url.startswith("docker://"):
            raise SourceError(
                "{}: docker_image url must be of the form docker://<repository>[:<tag>]".format(self)
            )
        reference = url[len("docker://"):]
        repository, separator, tag = reference.rpartition(":")
        if not separator:
            repository = reference
            tag = "latest"
        if "/" not in repository:
            repository = "library/" + repository
        return repository, tag

    def _registry_token(self):
        scope = "repository:{}:pull".format(self.repository)
        query = urllib.parse.urlencode({"service": "registry.docker.io", "scope": scope})
        request = urllib.request.Request("{}?{}".format(_TOKEN_URL, query))
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)["token"]
        except (urllib.error.URLError, ValueError, KeyError) as e:
            raise SourceError(
                "{}: Error obtaining registry token: {}".format(self, e), temporary=True
            ) from e

    def _registry_get(self, url, token):
        request = urllib.request.Request(url)
        request.add_header("Authorization", "Bearer " + token)
        request.add_header("Accept", _ACCEPT)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except (urllib.error.URLError, ValueError) as e:
            raise SourceError(
                "{}: Error querying registry: {}".format(self, e), temporary=True
            ) from e

    def _manifest_url(self, reference):
        return "https://{}/v2/{}/manifests/{}".format(_REGISTRY, self.repository, reference)

    def _blob_url(self, digest):
        return "https://{}/v2/{}/blobs/{}".format(_REGISTRY, self.repository, digest)

    def _safe(self, name):
        return name.replace(":", "_")

    def _manifest_file(self):
        return os.path.join(self._mirror_dir, self._safe(self.ref) + ".json")

    def _blob_file(self, digest):
        return os.path.join(self._mirror_dir, self._safe(digest) + ".tar.gz")

    def _load_manifest(self, reference):
        token = self._registry_token()
        manifest = self._registry_get(self._manifest_url(reference), token)

        # Image index / manifest list: select the platform variant.
        if "manifests" in manifest:
            selected = None
            for entry in manifest["manifests"]:
                platform = entry.get("platform", {})
                if platform.get("os") == "linux" and platform.get("architecture") == self.architecture:
                    selected = entry
                    break
            if selected is None:
                raise SourceError(
                    "{}: Image '{}' has no linux/{} variant".format(self, self.original_url, self.architecture)
                )
            digest = selected["digest"]
            manifest = self._registry_get(self._manifest_url(digest), token)
        else:
            digest = reference

        return digest, manifest

    def _ensure_mirror(self, manifest):
        # Called directly rather than through self.blocking_activity(): that
        # runs the given callable in a separate forkserver subprocess, and
        # pickles it by module path + name. This plugin is loaded dynamically
        # by pluginbase under a runtime-generated internal module name that
        # only exists in this process's module cache, so a fresh forkserver
        # worker can never import it back and dies with ModuleNotFoundError
        # before attempting the fetch. _download_blob is already synchronous
        # (plain urllib), so there's no concurrency to lose by calling it
        # in-process.
        for layer in manifest.get("layers", []):
            blob_file = self._blob_file(layer["digest"])
            if os.path.isfile(blob_file):
                continue

            with self.tempdir() as tempdir:
                local_file = os.path.join(tempdir, "layer.tar.gz")
                local_file, error = _download_blob(
                    self._blob_url(layer["digest"]),
                    self._registry_token(),
                    local_file,
                    layer["digest"][len("sha256:"):],
                )
                if error:
                    raise SourceError(
                        "{}: Error mirroring {}: {}".format(self, self.original_url, error), temporary=True
                    )
                os.rename(local_file, blob_file)

        # Only record the manifest once every layer is verified in place.
        with self.tempdir() as tempdir:
            manifest_file = os.path.join(tempdir, "manifest.json")
            with open(manifest_file, "w") as destination:
                json.dump(manifest, destination)
            os.rename(manifest_file, self._manifest_file())


def setup():
    return DockerImageSource
