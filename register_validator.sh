#!/usr/bin/env bash

# Exit script on error
set -e

basedir=$(
    cd $(dirname $0)
    pwd
)

WORKDIR=${basedir}
source ${WORKDIR}/chain.env
OP_KEY="${1:-${OPERATOR_PRIVATE_KEY}}"
[ -z "${OP_KEY}" ] && echo "Error: operator private key required" && exit 1


DORSEN_DIR="${WORKDIR}/.${CHAIN_NAME}"

if [ -z "$(ls ${DORSEN_DIR}/keystore/*UTC--* 2>/dev/null)" ] || [ ! -d "${DORSEN_DIR}/bls" ]; then
    echo "Error: Missing keys. Please generate keys first by running ./generate_keys.sh"
    exit 1
fi

${WORKDIR}/create-validator/create-validator \
    --consensus-key-dir "${DORSEN_DIR}" \
    --vote-key-dir "${DORSEN_DIR}" \
    --password-path "${DORSEN_DIR}/password.txt" \
    --operator-key "${OP_KEY}" \
    --amount 51 \
    --moniker "${DESCRIPTION_MONIKER}" \
    --identity "${DESCRIPTION_IDENTITY}" \
    --website "${DESCRIPTION_WEBSITE}" \
    --details "${DESCRIPTION_DETAILS}" \
    --rpc-url "${RPC_URL:-http://127.0.0.1:8545}"