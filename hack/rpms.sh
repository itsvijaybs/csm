#!/usr/bin/env bash

set -eo pipefail

ROOTDIR=$(realpath "${ROOTDIR:-$(dirname "${BASH_SOURCE[0]}")/..}")
source "${ROOTDIR}/assets.sh"
source "${ROOTDIR}/common.sh"

if [ $# -ne 1 ] || ([ "${1}" != "--validate" ] && [ "${1}" != "--download" ]); then
    echo "Usage: $0 [--validate|--download]"
    exit 1
fi

[ "${1}" == "--validate" ] && VALIDATE=1 || VALIDATE=0
SIGNING_KEYS=""

function rpm-sync() {
    index="${1}"
    destdir="${2}"
    if [ "${VALIDATE}" == "1" ]; then
        docker run ${REPO_CREDS_DOCKER_OPTIONS} --rm -i -u "$(id -u):$(id -g)" \
            "${PACKAGING_TOOLS_IMAGE}" \
            rpm-sync ${REPO_CREDS_RPMSYNC_OPTIONS} -n 1 --dry-run -v - < "${index}"
    else
        mkdir -p "${destdir}"
        docker run ${REPO_CREDS_DOCKER_OPTIONS} --rm -i -u "$(id -u):$(id -g)" \
            -v "$(realpath "${index}"):/index.yaml:ro" \
            -v "$(realpath "${destdir}"):/data" \
            -v "$(realpath "${BUILDDIR}/security/keys/rpm/"):/keys" \
            "${PACKAGING_TOOLS_IMAGE}" \
            rpm-sync ${REPO_CREDS_RPMSYNC_OPTIONS} -n 1 -s -v ${SIGNING_KEYS} -d /data /index.yaml
    fi
}

function rpm-sync-with-csm-base() {
    path="${1}"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' RETURN
    if [ -n "${CSM_BASE_VERSION}" ]; then
        existing=$(cd "${ROOTDIR}/dist/csm-${CSM_BASE_VERSION}/${path}"; find . -name '*.rpm' | sort -u)
        cat "${ROOTDIR}/${path}/index.yaml" | yq e '.*.rpms.[] | ((path | (.[0])) + " " + .)' | sort -u | while read -r repo nevra; do
            if [[ "${nevra}" == *\** ]]; then
                echo "ERROR: CSM_BASE_VERSION is set, but RPM package spec ${nevra} in ${ROOTDIR}/${path}/index.yaml contains a glob."
                echo "       Globs are not supported in release mode."
                exit 1
            fi
            relpath=$(echo "${existing}" | grep -F "/${nevra}.rpm" | head -1 || true)
            if [ -n "${relpath}" ]; then
                if [ "${VALIDATE}" == "1" ]; then
                    echo "[INFO] Will use ${nevra} from CSM base ${CSM_BASE_VERSION}"
                else
                    echo "[INFO] Reusing ${nevra} from CSM base ${CSM_BASE_VERSION}"
                    relpath="${relpath#./}"
                    mkdir -p "${BUILDDIR}/${path}/$(dirname "${relpath}")"
                    cp -f "${ROOTDIR}/dist/csm-${CSM_BASE_VERSION}/${path}/${relpath}" "${BUILDDIR}/${path}/${relpath}"
                fi
            else
                echo "[WARNING] Did not find ${nevra} in CSM base ${CSM_BASE_VERSION}, will download from external location"
                test -f "${tmpdir}/index.txt" && (echo " |" >> "${tmpdir}/index.txt")
                echo -ne ".[\"${repo}\"].rpms += [\"${nevra}\"]" >> "${tmpdir}/index.txt"
            fi
            write_version_digest ".${path//\//.}.\"${url}\"" "${nevra}"
        done
        if [ -f "${tmpdir}/index.txt" ]; then
            yq -n --from-file "${tmpdir}/index.txt" > "${tmpdir}/index.yaml"
            rpm-sync "${tmpdir}/index.yaml" "${BUILDDIR}/${path}"
        fi
    else
        touch "${tmpdir}/index.yaml"
        cat "${ROOTDIR}/${path}/index.yaml" | yq e '.*.rpms.[] | ((path | (.[0])) + " " + .)' | sort -u | while read -r url nevra; do
            IFS=/ read repo relpath <<< "${url#https://artifactory.algol60.net/artifactory/}"
            if [[ "${nevra}" == *\** ]]; then
                rpm_path=$(resolve_globs "${repo}" "${relpath%/}/*" "${nevra}.rpm")
                new_nevra=$(basename "${rpm_path%.rpm}")
                echo "${nevra}.rpm is resolved as ${new_nevra}"
                nevra="${new_nevra}"
            fi
            yq -i ".[\"${url}\"].rpms += [\"${nevra}\"]" "${tmpdir}/index.yaml"
            write_version_digest ".${path//\//.}.\"${url}\"" "${nevra}"
        done
        rpm-sync "${tmpdir}/index.yaml" "${BUILDDIR}/${path}"
    fi
}

function createrepo() {
    local repodir="$1"
    if [[ ! -d "$repodir" ]]; then
        echo >&2 "error: no such directory: ${repodir}"
        return 1
    fi
    docker run --rm -u "$(id -u):$(id -g)" \
        -v "$(realpath "$repodir"):/data" \
        "${RPM_TOOLS_IMAGE}" \
        createrepo --verbose /data
}

if [ "${VALIDATE}" != "1" ]; then
    # Special processing for docs-csm, as we don't know exact version before build starts, so can't include it into rpm indexes.
    # Can't include docs-csm-latest either, because it is not unique. Get version from right docs-csm-latest, then download actual rpm file.
    DOCS_CSM_MAJOR_MINOR="${DOCS_CSM_MAJOR_MINOR:-${RELEASE_VERSION_MAJOR}.${RELEASE_VERSION_MINOR}}"
    DOCS_CSM_VERSION=$(acurl -sSL "https://artifactory.algol60.net/artifactory/api/storage/csm-rpms/hpe/stable/noos/docs-csm/${DOCS_CSM_MAJOR_MINOR}/noarch/docs-csm-latest.noarch.rpm?properties" | jq -r '.properties["rpm.metadata.version"][0] // ""')
    echo "Downloading docs-csm-${DOCS_CSM_VERSION}-1.noarch.rpm ..."
    mkdir -p "${BUILDDIR}/rpm/cray/csm/noos/noarch"
    acurl -sSL -o "${BUILDDIR}/rpm/cray/csm/noos/noarch/docs-csm-${DOCS_CSM_VERSION}-1.noarch.rpm" \
        "https://artifactory.algol60.net/artifactory/csm-rpms/hpe/stable/noos/docs-csm/${DOCS_CSM_MAJOR_MINOR}/noarch/docs-csm-${DOCS_CSM_VERSION}-1.noarch.rpm"

    # Download and store RPM signing keys.
    mkdir -p "${BUILDDIR}/security/keys/rpm"
    for key_url in "${HPE_RPM_SIGNING_KEYS[@]}"; do
        key=$(basename "${key_url}")
        if [ -f "${BUILDDIR}/security/keys/rpm/${key}" ]; then
            echo "Signing key ${key} is already downloaded"
        else
            echo "Downloading ${key} signing key"
            acurl -Ss -o "${BUILDDIR}/security/keys/rpm/${key}" "${key_url}"
        fi
        SIGNING_KEYS="${SIGNING_KEYS} -k /keys/${key}"
    done
fi

rpm-sync-with-csm-base "rpm/cray/csm/sle-15sp2"
rpm-sync-with-csm-base "rpm/cray/csm/sle-15sp3"
rpm-sync-with-csm-base "rpm/cray/csm/sle-15sp4"
rpm-sync-with-csm-base "rpm/cray/csm/sle-15sp5"
rpm-sync-with-csm-base "rpm/cray/csm/sle-15sp6"
rpm-sync-with-csm-base "rpm/cray/csm/noos"

if [ "${VALIDATE}" == "1" ]; then
    echo "RPM indexes validated successfully"
else
    echo "RPM indexes synchronized successfully"
    # Fix-up cray directories by removing misc subdirectories
    {
        find "${BUILDDIR}/rpm/cray" -name '*-team' -type d
        find "${BUILDDIR}/rpm/cray" -name 'github' -type d
    } | while read path; do
        mv "$path"/* "$(dirname "$path")/"
        rmdir "$path"
    done

    # Remove empty directories
    find "${BUILDDIR}/rpm/cray" -empty -type d -delete

    # Create CSM repositories
    mkdir -p "${BUILDDIR}/rpm/cray/csm/sle-15sp2" && createrepo "${BUILDDIR}/rpm/cray/csm/sle-15sp2"
    mkdir -p "${BUILDDIR}/rpm/cray/csm/sle-15sp3" && createrepo "${BUILDDIR}/rpm/cray/csm/sle-15sp3"
    mkdir -p "${BUILDDIR}/rpm/cray/csm/sle-15sp4" && createrepo "${BUILDDIR}/rpm/cray/csm/sle-15sp4"
    mkdir -p "${BUILDDIR}/rpm/cray/csm/sle-15sp5" && createrepo "${BUILDDIR}/rpm/cray/csm/sle-15sp5"
    mkdir -p "${BUILDDIR}/rpm/cray/csm/sle-15sp6" && createrepo "${BUILDDIR}/rpm/cray/csm/sle-15sp6"
    mkdir -p "${BUILDDIR}/rpm/cray/csm/noos" && createrepo "${BUILDDIR}/rpm/cray/csm/noos"
fi
