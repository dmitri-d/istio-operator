#!/usr/bin/env bash

set -e

: ${MAISTRA_VERSION:=0.10.0}
: ${MAISTRA_BRANCH:=0.10}

SOURCE_DIR=$(pwd)
DIR=$(pwd)/tmp/_output/helm

ISTIO_VERSION=1.1.0
#ISTIO_BRANCH=release-1.1

RELEASES_DIR=${DIR}/istio-releases

PLATFORM=linux

ISTIO_NAME=istio-${ISTIO_VERSION}
ISTIO_FILE="maistra-${MAISTRA_BRANCH}.zip"
ISTIO_URL="https://github.com/Maistra/istio/archive/maistra-${MAISTRA_BRANCH}.zip"
EXTRACT_CMD="unzip ${ISTIO_FILE} istio-maistra-${MAISTRA_BRANCH}/install/kubernetes/helm/*"
RELEASE_DIR="${RELEASES_DIR}/${ISTIO_NAME}"

ISTIO_NAME=${ISTIO_NAME//./-}

HELM_DIR=${RELEASE_DIR}

if [[ "${ISTIO_VERSION}" =~ ^1\.0\..* ]]; then
  PATCH_1_0="true"
fi

COMMUNITY=${COMMUNITY:-true}

function retrieveIstioRelease() {
  if [ -d "${RELEASE_DIR}" ] ; then
    rm -rf "${RELEASE_DIR}"
  fi
  mkdir -p "${RELEASE_DIR}"

  if [ ! -f "${RELEASES_DIR}/${ISTIO_FILE}" ] ; then
    (
      echo "downloading Istio Release: ${ISTIO_URL}"
      cd "${RELEASES_DIR}"
      curl -LO "${ISTIO_URL}"
    )
  fi

  (
      echo "extracting Istio Helm charts to ${RELEASES_DIR}"
      cd "${RELEASES_DIR}"
      ${EXTRACT_CMD}
      mv istio-maistra-${MAISTRA_BRANCH}/install/kubernetes/helm/* ${RELEASE_DIR}
      rm -rf ${RELEASE_DIR}/istio/charts/kiali/templates/*.yaml
      rm -rf ${RELEASE_DIR}/istio/charts/kiali/templates/tests
      #(
      #  cd "${HELM_DIR}/istio"
      #  helm dep update
      #)
  )
}

retrieveIstioRelease

source $(dirname ${BASH_SOURCE})/patch-charts.sh
