#!/usr/bin/env bash

# Exit script on error
set -e

basedir=$(
    cd $(dirname $0)
    pwd
)
WORKDIR=${basedir}
GETH="${WORKDIR}/bin/geth"
source ${WORKDIR}/chain.env

stateScheme="hash"
dbEngine="leveldb"
gcmode="full"
sleepBeforeStart=15
sleepAfterStart=10
extip=$(ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}')

# CHAIN_NAME already contains the value from chain.env
chain_name=$(echo "$CHAIN_NAME" | tr -d '\n\r' | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
[ -z "$chain_name" ] && echo "Error: CHAIN_NAME is empty" && exit 1

datadir="${WORKDIR}/.${chain_name}"

if [ -z "$(ls ${datadir}/keystore/*UTC--* 2>/dev/null)" ] || [ ! -d "${datadir}/bls" ]; then
    echo "Error: Missing keys. Please generate keys first by running ./generate_keys.sh"
    exit 1
fi


if [ ! -f "${GETH}" ]; then
    echo "Error: geth not found at ${GETH}. Build dorsen-chain first."
    exit 1
fi

if [ -z "${GENESIS_COMMIT}" ]; then
    echo "Error: GENESIS_COMMIT not set in chain.env"
    exit 1
fi

# reset genesis, but keep edited genesis-template.json
function reset_genesis() {
    if [ ! -f "${WORKDIR}/genesis/genesis-template.json" ]; then
        cd ${WORKDIR} && git submodule update --init --recursive genesis
        cd ${WORKDIR}/genesis && git reset --hard ${GENESIS_COMMIT}
    fi
    cd ${WORKDIR}/genesis
    cp genesis-template.json genesis-template.json.bk
    cp scripts/init_holders.template scripts/init_holders.template.bk
    git stash
    cd ${WORKDIR} && git submodule update --remote --recursive genesis && cd ${WORKDIR}/genesis
    git reset --hard ${GENESIS_COMMIT}
    mv genesis-template.json.bk genesis-template.json
    mv scripts/init_holders.template.bk scripts/init_holders.template

    poetry install --no-root
    npm install
    rm -rf lib/forge-std
    forge install foundry-rs/forge-std@v1.7.3
    cd lib/forge-std/lib
    rm -rf ds-test
    git clone https://github.com/dapphub/ds-test
}

function prepare_config() {
    cd ${WORKDIR}/genesis
    # Read consensus address and BLS pubkey from .dorsen keys
    cons_addr="0x$(jq -r .address ${datadir}/keystore/*)"
    vote_addr="0x$(jq -r .pubkey "$(ls ${datadir}/bls/keystore/*.json | head -1)")"
    # Generate validators.conf (single line for 1 validator)
    rm -f validators.conf
    powers="0000000BA43B7400" #50000000000 i.e, 50 voting power
    echo "${cons_addr},${cons_addr},${cons_addr},${powers},${vote_addr}" >> validators.conf
    # Generate validators.js from validators.conf
    poetry run python -m scripts.generate generate-validators
    # Generate init_holders.js (INIT_HOLDER + operator address)
    initHolders="${INIT_HOLDER}:${INIT_HOLDER_BALANCE},${OPERATOR_ADDRESS}:${OPERATOR_BALANCE}"
    poetry run python -m scripts.generate generate-init-holders "${initHolders}"
    # Run generate.py dorsen 
    poetry run python -m scripts.generate dorsen \
      --dorsen-chain-id "${CHAIN_ID}" \
      --stake-hub-protector "${INIT_HOLDER}" \
      --governor-protector "${INIT_HOLDER}" \
      --token-recover-portal-protector "${INIT_HOLDER}" \
      --maxwell-time "${MAXWELL_TIME}" \
      --fermi-time "${FERMI_TIME}" \
      --osaka-time "${OSAKA_TIME}" \
      --mendel-time "${MENDEL_TIME}"
    cp genesis-dorsen.json genesis.json
}

# Uses geth init-network to custom config.toml, then geth init to init chaindata:
function initNetwork() {
    cd ${WORKDIR}
    # Create geth dir and copy nodekey
    mkdir -p ${datadir}/geth

    cp ${datadir}/nodekey ${datadir}/geth/nodekey

    cp ${WORKDIR}/config.toml ${datadir}/config.toml

    sed -i '' "s/NetworkId = 714/NetworkId = ${CHAIN_ID}/" ${datadir}/config.toml
    sed -i '' "s/FilePath = bsc.log/FilePath = ${chain_name}.log/" ${datadir}/config.toml

    rm -f ${WORKDIR}/*${chain_name}.log*

    # Init genesis into chaindata
    initLog=${datadir}/init.log
    ${GETH} --datadir ${datadir} init \
        --state.scheme ${stateScheme} \
        --db.engine ${dbEngine} \
        ${WORKDIR}/genesis/genesis.json >> ${initLog} 2>&1
        cp ${WORKDIR}/genesis/genesis.json ${WORKDIR}/config/genesis.json
        
    cp ${datadir}/config.toml ${WORKDIR}/config/config.toml
    echo "${CHAIN_NAME}" > ${WORKDIR}/config/chain.txt
    
}
function start_node() {
    local cons_addr="0x$(jq -r .address ${datadir}/keystore/*)"

    nohup ${GETH} --config ${datadir}/config.toml \
        --datadir ${datadir} \
        --nodekey ${datadir}/geth/nodekey \
        --nat extip:${extip} \
        --rpc.allow-unprotected-txs --allow-insecure-unlock \
        --ws --ws.addr 0.0.0.0 --ws.port 8545 \
        --http --http.addr 0.0.0.0 --http.port 8545 --http.corsdomain "*" \
        --metrics --metrics.addr localhost --metrics.port 6060 \
        --pprof --pprof.addr localhost --pprof.port 7060 \
        --gcmode ${gcmode} --syncmode full --monitor.maliciousvote \
        --mine --vote --unlock ${cons_addr} --miner.etherbase ${cons_addr} --password ${datadir}/password.txt --blspassword ${datadir}/password.txt \
        >> ${datadir}/${chain_name}-node.log 2>&1 &

    echo $! > ${datadir}/pid
    echo "Started geth with PID $(cat ${datadir}/pid)"

    sleep ${sleepAfterStart}
}

function stop() {
    local pidfile="${datadir}/pid"
    if [ -f "${pidfile}" ]; then
        local pid=$(cat "${pidfile}")
        if kill -0 "${pid}" 2>/dev/null; then
            echo "Stopping geth (PID ${pid})..."
            kill "${pid}"
            rm -f "${pidfile}"
            sleep ${sleepBeforeStart}
        else
            echo "Process ${pid} not running (cleaning up)"
            rm -f "${pidfile}"
        fi
    else
        # Fallback: kill all geth processes for this chain
        ps -ef | grep "geth.*${datadir}" | grep -v grep | awk '{print $2}' | xargs -r kill 2>/dev/null || true
        sleep ${sleepBeforeStart}
    fi
}

function register_validator() {
    OP_KEY="${OPERATOR_PRIVATE_KEY}"
    [ -z "${OP_KEY}" ] && echo "Error: OPERATOR_PRIVATE_KEY not set in chain.env" && exit 1
    echo "Registering validator stake..."
    ${WORKDIR}/create-validator/create-validator \
        --consensus-key-dir "${datadir}" \
        --vote-key-dir "${datadir}" \
        --password-path "${datadir}/password.txt" \
        --operator-key "${OP_KEY}" \
        --amount 51 \
        --moniker "${DESCRIPTION_MONIKER}" \
        --identity "${DESCRIPTION_IDENTITY}" \
        --website "${DESCRIPTION_WEBSITE}" \
        --details "${DESCRIPTION_DETAILS}" \
        --rpc-url "${RPC_URL:-http://127.0.0.1:8545}"
}
    

# Case block
CMD=$1
case ${CMD} in
    reset)
        stop || true
        reset_genesis
        prepare_config
        initNetwork
        start_node
        ;;
    register)
        register_validator
        ;;
    stop)
        stop
        ;;
    restart)
        stop || true
        start_node
        ;;
    *)
        echo "Usage: build_new_chain.sh reset|stop|restart|register"
        ;;
esac
