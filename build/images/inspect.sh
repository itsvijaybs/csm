#!/usr/bin/env bash

set -euo pipefail

ROOTDIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")/../..")
source "${ROOTDIR}/common.sh"
source "${ROOTDIR}/vendor/github.hpe.com/hpe/hpc-shastarelm-release/lib/release.sh"

function usage() {
    echo >&2 "usage: ${0##*/} IMAGE..."
    exit 255
}

function resolve_canonical() {
    local image="${1#docker://}"
    if [[ "${image}" != *.*:* ]]; then
        # alpine:latest > docker.io/library/alpine:latest
        echo "docker.io/library/${image}"
    else
        # nothing needs to be changed
        echo "${image}"
    fi
}

# All images must come from artifactory.algol60.net/csm-docker/stable. Otherwise, we
# can't guarantee reproducibility of builds, when CSM_BASE_VERSION is set.
function resolve_mirror() {
    local image="${1#docker://}"
    if [[ "$image" == artifactory.algol60.net/csm-docker/stable/* ]]; then
        # nothing needs to be changed
        echo "${image}"
    else
        # docker.io/library/alpine:latest > artifactory.algol60.net/csm-docker/stable/docker.io/library/alpine:latest
        # quay.io/skopeo/stable:v1.4.1 > artifactory.algol60.net/csm-docker/stable/quay.io/skopeo/stable:v1.4.1
        echo "artifactory.algol60.net/csm-docker/stable/${image}"
    fi
}

function resolve_globs_in_tag() {
    local image="${1}"
    local repo path tag
    IFS=/ read -r repo path <<< "${image#artifactory.algol60.net/}"
    IFS=: read -e path tag <<< "${path}"
    if [[ "${tag}" == *\** ]]; then
        if [[ "${path}" == *\** ]]; then
            echo "ERROR: globs in image names are not supported, only image tags may have globs: ${image}" >&2
            exit 1
        fi
        # Tag is stored as folder in artifactory. May contain either manifest.json or list.manifest.json.
        manifest_path=$(resolve_globs "${repo}" "${path}/${tag}" "*manifest.json")
        # Drop /*manifest.json
        manifest_path=$(dirname "${manifest_path}")
        echo "artifactory.algol60.net/${repo}/$(dirname "${manifest_path}"):$(basename "${manifest_path}")"
    else
        echo "${image}"
    fi
}

[[ $# -gt 0 ]] || usage

while [[ $# -gt 0 ]]; do
    # Resolve image to canonical form, e.g., alpine -> docker.io/library/alpine
    image="$(resolve_canonical "${1#docker://}")"

    # Resolve image as an artifactory.algol60.net mirror
    image_mirror="$(resolve_mirror "$image")"

    # Resolve globs in image tag
    image_mirror="$(resolve_globs_in_tag "$image_mirror")"

    ref=""

    # Try to re-use image digest from base version, if we are building patch release.
    if [ -n "${CSM_BASE_VERSION:-}" ]; then
        base_images=$(realpath "${ROOTDIR}/dist/csm-${CSM_BASE_VERSION}-images.txt")
        image_record=$(cat "${base_images}" | tr '\t' ',' | grep -F "${image},"  || true)
        if [ -z "${image_record}" ]; then
            echo "+ WARNING: image ${image} was not part of CSM build ${CSM_BASE_VERSION}, will calculate new digest" >&2
        else
            IFS=, read -r logical_image physical_image <<< "${image_record}"
            # manifest_file=$(realpath "${ROOTDIR}/dist/csm-${CSM_BASE_VERSION}/docker/${image}/manifest.json")
            # sha256sum_expected=$(echo "${physical_image}" | cut -f2 -d:)
            # sha256sum_actual=$(sha256sum "${manifest_file}" | cut -f 1 -d ' ')
            # # Checksum mismatch happens when multi-arch digest is recorded in images.txt, but single-arch digest is stored in tarball.
            # # We can re-enable this when we run skopeo-copy during build with "--all", which will store multi-platform manifest with right checksum
            # # and all of it's references, not just a single reference for specific arch/os.
            # if [ "${sha256sum_expected}" != "${sha256sum_actual}" ]; then
            #     echo "+ WARNING: sha256sum for image ${image} in ${base_images} (${sha256sum_expected}) does not match actual sha256sum of ${manifest_file} (${sha256sum_actual})" >&2
            #     exit 255
            # fi
            ref="${physical_image}"
            echo "+ INFO: reusing $ref from $CSM_BASE_VERSION for $image" >&2
        fi
    fi

    if [[ -z "$ref" ]]; then
        ref=$(skopeo-inspect "docker://$image_mirror")
    fi

    # Output maps "logical" refs to "physical" digest-based refs
    printf '%s\t%s\n' "$image_mirror" "$ref"

    shift
done
