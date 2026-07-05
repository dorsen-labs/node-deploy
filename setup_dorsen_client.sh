#!/usr/bin/env bash
set -e
basedir=$(
    cd $(dirname $0)
    pwd
)
WORKDIR=${basedir}
GETH="${WORKDIR}/bin/geth"
DORSEN_CHAIN_REPO="https://github.com/dorsen-labs/dorsen-chain.git"
BUILD_DIR="${WORKDIR}/dorsen-chain"
if [ -f "${GETH}" ]; then
    echo "geth found at ${GETH}"
    ${GETH} version
    exit 0
fi
echo "geth not found. Building dorsen-chain..."
if ! command -v go &> /dev/null; then
    echo "Error: Go is not installed."
    echo "Install Go: https://go.dev/dl/"
    exit 1
fi
if [ -d "${BUILD_DIR}" ]; then
    echo "Updating dorsen-chain..."
    cd "${BUILD_DIR}"
    git pull
else
    echo "Cloning dorsen-chain..."
    git clone ${DORSEN_CHAIN_REPO}
    cd "${BUILD_DIR}"
fi
echo "Building geth..."
make geth
cp "${BUILD_DIR}/build/bin/geth" "${GETH}"
chmod +x "${GETH}"
echo ""
echo "=== Dorsen Client Setup Complete ==="
${GETH} version