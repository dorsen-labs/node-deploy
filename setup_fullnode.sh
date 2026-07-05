#!/usr/bin/env bash

# Exit script on error
set -e


basedir=$(cd `dirname $0`; pwd)
WORKDIR=${basedir}
GETH="${WORKDIR}/bin/geth"

stateScheme="path"
syncmode="snap"
gcmode="full"
extraflags=""

src=${WORKDIR}/config/chain.txt
if [ ! -f "$src" ] ;then
	echo "chain not found, build new chain first"
	exit 1
fi
if [ ! -z "$2" ] ;then
	syncmode=$2
fi

if [ ! -z "$3" ] ;then
	gcmode=$3
fi

if [ ! -z "$4" ] ;then
	extraflags=$4
fi

# Read content and clean it
chain_name=$(<"$src" tr -d '\n\r' | sed 's/ //g' | tr '[:upper:]' '[:lower:]')
[ -z "$chain_name" ] && echo "Error: chain.txt is empty" && exit 1

dst=${WORKDIR}/.${chain_name}/fullnode
mkdir -pv $dst/

function init() {
    cp ${WORKDIR}/config/genesis.json $dst/genesis.json
    cp ${WORKDIR}/config/config.toml $dst/config.toml
    if [ -f "${GETH}" ]; then
        ${GETH} init --state.scheme ${stateScheme} --datadir ${dst}/ ${dst}/genesis.json
    else
        echo "Error: geth not found at ${GETH}. Build dorsen-chain first."
        exit 1
    fi
}

function start() {
    nohup ${GETH} \
        --config $dst/config.toml \
        --datadir $dst \
        --rpc.allow-unprotected-txs \
        --allow-insecure-unlock \
        --ws.addr 0.0.0.0 \
        --ws.port 8545 \
        --http.addr 0.0.0.0 \
        --http.port 8545 \
        --http.corsdomain "*" \
        --metrics \
        --metrics.addr 0.0.0.0 \
        --metrics.port 6060 \
        --metrics.expensive \
        --gcmode $gcmode \
        --syncmode $syncmode \
        --state.scheme $stateScheme \
        $extraflags \
        >> $dst/${chain_name}-node.log 2>&1 &
    echo $! > $dst/pid
}


function stop() {
  if [ ! -f "$dst/pid" ]; then
    echo "$dst/pid not exist"
    return 0
  fi
  
  local pid=$(cat "$dst/pid")
  
  # Check if process exists
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping process with PID: $pid"
    kill "$pid"
    rm -f "$dst/pid"
    sleep 5
  else
    echo "Process with PID $pid no longer exists (cleaning up pid file)"
    rm -f "$dst/pid"
  fi
}

function clean() {
  stop
  rm -rf $dst/*
}

CMD=$1
case ${CMD} in
reset)
    echo "===== reset ===="
    clean
    init
    start
    echo "===== end ===="
    ;;
stop)
    echo "===== stop ===="
    stop
    echo "===== end ===="
    ;;
restart)
    echo "===== restart ===="
    stop || true
    start
    echo "===== end ===="
    ;;
clean)
    echo "===== clean ===="
    clean
    echo "===== end ===="
    ;;
*)
    echo "Usage: setup_fullnode.sh reset|stop|restart|clean syncmode gcmode"
    echo "like: setup_fullnode.sh reset snap full, it will startup a snapsync fullnode"
    ;;
esac