#!/usr/bin/env bash
set -e

basedir=$(
    cd $(dirname $0)
    pwd
)
WORKDIR=${basedir}
GETH="${WORKDIR}/bin/geth"
source ${WORKDIR}/chain.env

if [ ! -f "${GETH}" ]; then
    echo "Error: geth not found at ${GETH}. Build dorsen-chain first."
    exit 1
fi

# CHAIN_NAME already contains the value from chain.env
chain_name=$(echo "$CHAIN_NAME" | tr -d '\n\r' | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
[ -z "$chain_name" ] && echo "Error: CHAIN_NAME is empty" && exit 1

DORSEN_DIR="${WORKDIR}/.${chain_name}"

if [ -n "$(ls ${DORSEN_DIR}/keystore/*UTC--* 2>/dev/null)" ] || [ -d "${DORSEN_DIR}/bls" ]; then
    echo ""
    echo "WARNING: Existing keys found in ${DORSEN_DIR}/"
    echo "  Keystore:  ${DORSEN_DIR}/keystore/"
    echo "  BLS:       ${DORSEN_DIR}/bls/"
    echo ""
    echo "Overwriting will DESTROY your existing keys permanently!"
    echo -n "Do you want to continue? (yes/no): "
    read CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
        echo "Aborted. No changes made."
        exit 0
    fi
    echo ""
    echo "Removing old keys..."
    rm -rf "${DORSEN_DIR}/keystore"
    rm -rf "${DORSEN_DIR}/bls"
    rm -f "${DORSEN_DIR}/nodekey"
fi
mkdir -p "${DORSEN_DIR}"
echo -n "Enter key password: "
read -s KEYPASS
echo ""
if [ -z "${KEYPASS}" ] || [ ${#KEYPASS} -lt 10 ]; then
    echo "Fatal: Password invalid: password too short (<10 characters)."
    exit 1
fi
echo "${KEYPASS}" > "${DORSEN_DIR}/password.txt"
echo "Generating ECDSA consensus key..."
${GETH} account new \
    --datadir "${DORSEN_DIR}" \
    --password "${DORSEN_DIR}/password.txt"
echo "Generating BLS vote key..."
${GETH} bls account new \
    --datadir "${DORSEN_DIR}" \
    --blspassword "${DORSEN_DIR}/password.txt"
echo "Generating P2P nodekey..."
openssl rand -hex 32 > "${DORSEN_DIR}/nodekey"
CONSENSUS_ADDR="0x$(cat ${DORSEN_DIR}/keystore/* | jq -r .address)"
BLS_PUBKEY=0x$(cat ${DORSEN_DIR}/bls/keystore/*json | jq .pubkey | sed 's/"//g')
echo ""
echo "=== Dorsen Keys Generated ==="
echo "Consensus Address:  ${CONSENSUS_ADDR}"
echo "BLS Public Key:     ${BLS_PUBKEY}"
echo "Keystore:           ${DORSEN_DIR}/keystore/"
echo "BLS Wallet:         ${DORSEN_DIR}/bls/wallet/"
echo "Nodekey:            ${DORSEN_DIR}/nodekey"
echo "Password:           ${DORSEN_DIR}/password.txt"

# Changes from previous version:
# - Added existence check: if [ -f "${DORSEN_DIR}/keystore"/*UTC--* ] || [ -d "${DORSEN_DIR}/bls" ]
# - Prompts Overwriting will DESTROY your existing keys permanently! Do you want to continue? (yes/no):
# - Only proceeds if user types exactly yes
# - Removes old keystore/, bls/, and nodekey before generating new