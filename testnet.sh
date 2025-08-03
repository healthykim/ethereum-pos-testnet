#!/bin/bash

set -eu
set -o pipefail

# Check dependencies
for cmd in jq curl; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed. Please install $cmd first."
        exit 1
    fi
done


if [ -z "$1" ]; then
    echo "Usage: $0 <number_of_nodes>"
    exit 1
fi

NUM_NODES=$1
NUM_LOGS=$NUM_NODES

if [ $NUM_NODES -gt 2 ]; then
    if [ -z "$2" ]; then
        echo "Usage: $0 <number_of_nodes> <number_of_logs>"
        exit 1
    fi
    NUM_LOGS=$2
fi

# Load config.env
source config.env

trap 'echo "Error on line $LINENO"; exit 1' ERR

# Function to handle the cleanup
cleanup() {
    echo "Caught Ctrl+C. Cleaning up..."
    tmux kill-session -t ethnet 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
    exit
}
trap 'cleanup' SIGINT

echo ""
echo "🧹  Clean up previous runs"
echo "────────────────────────────────"
rm -rf "$NETWORK_DIR"
mkdir -p "$NETWORK_DIR/setup"
mkdir -p "$NETWORK_DIR/bootnode"
mkdir -p "$NETWORK_DIR/settings"
mkdir -p "$NETWORK_DIR/logs"
SETTINGS_DIR="$NETWORK_DIR/settings"
LOGS_DIR="$NETWORK_DIR/logs"

echo "✅ Cleared $NETWORK_DIR"
echo ""
if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION_NAME"
  echo "✅ tmux session terminated: $TMUX_SESSION_NAME"
  echo ""
else
  echo "✅ No tmux session found"
  echo ""
fi
pkill geth || true
pkill beacon-chain || true
pkill validator || true
pkill bootnode || true
echo "✅ Killed all running processes"
echo ""


echo ""
echo "🔧  Starting setup"
echo "────────────────────────────────"
echo ""

# Generate the genesis. This will generate validators based
# on https://github.com/ethereum/eth2.0-pm/blob/a085c9870f3956d6228ed2a40cd37f0c6580ecd7/interop/mocked_start/README.md
$PRYSM_CTL_BINARY testnet generate-genesis \
--fork=electra \
--num-validators=$NUM_NODES \
--chain-config-file=./config.yml \
--geth-genesis-json-in=./genesis.json \
--output-ssz=$NETWORK_DIR/genesis.ssz \
--geth-genesis-json-out=$NETWORK_DIR/genesis.json > "$NETWORK_DIR/setup/genesis.log" 2>&1

echo "✅ Genesis file generated"
echo ""

# The prysm bootstrap node is set after the first loop, as the first
# node is the bootstrap node. This is used for consensus client discovery
PRYSM_BOOTSTRAP_NODE=

# Calculate how many nodes to wait for to be in sync with. Not a hard rule
MIN_SYNC_PEERS=$((NUM_NODES/2))

declare -a enodes
# Create the validators in a loop
for (( i=0; i<$NUM_NODES; i++ )); do

    STORE_LOGS=false
    if [ $i -lt $NUM_LOGS ]; then
        STORE_LOGS=true
        NODE_LOGS_DIR=$LOGS_DIR/node-$i
        mkdir -p $NODE_LOGS_DIR
    fi

    # Create the node directories
    NODE_SETTINGS_DIR=$SETTINGS_DIR/node-$i
    mkdir -p $NODE_SETTINGS_DIR
    mkdir -p $NODE_SETTINGS_DIR/execution
    mkdir -p $NODE_SETTINGS_DIR/consensus

    echo ""
    echo "🚀 Setting up node-$i"
    echo "────────────────────────────────"
    echo ""
    # We use an empty password. Do not do this in production
    geth_pw_file="$NODE_SETTINGS_DIR/geth_password.txt"
    echo "" > "$geth_pw_file"

    # Copy the same genesis and initial config the node's directories
    # All nodes must have the same genesis otherwise they will reject eachother
    cp ./config.yml $NODE_SETTINGS_DIR/consensus/config.yml
    cp $NETWORK_DIR/genesis.ssz $NODE_SETTINGS_DIR/consensus/genesis.ssz
    cp $NETWORK_DIR/genesis.json $NODE_SETTINGS_DIR/execution/genesis.json

    # Create the secret keys for this node and other account details
    $GETH_BINARY account new --datadir "$NODE_SETTINGS_DIR/execution" --password "$geth_pw_file"

    echo "✅ Geth account created"
    echo ""

    # Initialize geth for this node
    $GETH_BINARY init \
      --datadir=$NODE_SETTINGS_DIR/execution \
      $NODE_SETTINGS_DIR/execution/genesis.json
    
    echo ""
    echo "✅ Geth initialized"
    echo ""

    # Start geth execution client for this node
    start_geth() {
      local log_file="$1"
      $GETH_BINARY \
        --networkid=${CHAIN_ID:-7052480736} \
        --http \
        --http.api=eth,engine,admin,net,web3 \
        --http.addr=127.0.0.1 \
        --http.corsdomain="*" \
        --http.port=$((GETH_HTTP_PORT + i)) \
        --port=$((GETH_NETWORK_PORT + i)) \
        --metrics.port=$((GETH_METRICS_PORT + i)) \
        --ws \
        --ws.api=eth,net,web3,subscribe \
        --ws.addr=127.0.0.1 \
        --ws.origins="*" \
        --ws.port=$((GETH_WS_PORT + i)) \
        --authrpc.vhosts="*" \
        --authrpc.addr=127.0.0.1 \
        --authrpc.jwtsecret=$NODE_SETTINGS_DIR/execution/jwtsecret \
        --authrpc.port=$((GETH_AUTH_RPC_PORT + i)) \
        --datadir=$NODE_SETTINGS_DIR/execution \
        --password=$geth_pw_file \
        --nodiscover \
        --identity=node-$i \
        --maxpendpeers=$NUM_NODES \
        --verbosity=4 \
        --syncmode=full > "$log_file" 2>&1 &
    }


    if [ "$STORE_LOGS" = true ]; then
      start_geth "$NODE_LOGS_DIR/geth.log"
    else
      start_geth "/dev/null"
    fi

    echo "✅ Geth started"
    echo ""
    sleep 5

    response=$(curl -s -X POST http://127.0.0.1:$((GETH_HTTP_PORT + i)) \
      -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
      | jq -r .result.enode)

    enodes[$i]=$response

    # Start prysm consensus client for this node
    start_beacon() {
      local log_file="$1"
      $PRYSM_BEACON_BINARY \
        --datadir=$NODE_SETTINGS_DIR/consensus/beacondata \
        --min-sync-peers=0 \
        --genesis-state=$NODE_SETTINGS_DIR/consensus/genesis.ssz \
        --bootstrap-node=$PRYSM_BOOTSTRAP_NODE \
        --chain-config-file=$NODE_SETTINGS_DIR/consensus/config.yml \
        --contract-deployment-block=0 \
        --chain-id=${CHAIN_ID:-7052480736} \
        --rpc-host=127.0.0.1 \
        --rpc-port=$((PRYSM_BEACON_RPC_PORT + i)) \
        --grpc-gateway-host=127.0.0.1 \
        --grpc-gateway-port=$((PRYSM_BEACON_GRPC_GATEWAY_PORT + i)) \
        --execution-endpoint=http://127.0.0.1:$((GETH_AUTH_RPC_PORT + i)) \
        --accept-terms-of-use \
        --jwt-secret=$NODE_SETTINGS_DIR/execution/jwtsecret \
        --suggested-fee-recipient=0x123463a4b065722e99115d6c222f267d9cabb524 \
        --minimum-peers-per-subnet=0 \
        --p2p-tcp-port=$((PRYSM_BEACON_P2P_TCP_PORT + i)) \
        --p2p-udp-port=$((PRYSM_BEACON_P2P_UDP_PORT + i)) \
        --monitoring-port=$((PRYSM_BEACON_MONITORING_PORT + i)) \
        --verbosity=debug \
        --slasher \
        --enable-debug-rpc-endpoints > "$log_file" 2>&1 &
    }

    if [ "$STORE_LOGS" = true ]; then
      start_beacon "$NODE_LOGS_DIR/beacon.log"
    else
      start_beacon "/dev/null"
    fi

    echo "✅ Prysm beacon started"
    echo ""

    # Start prysm validator for this node
    start_validator() {
      local log_file="$1"
      $PRYSM_VALIDATOR_BINARY \
        --beacon-rpc-provider=localhost:$((PRYSM_BEACON_RPC_PORT + i)) \
        --datadir=$NODE_SETTINGS_DIR/consensus/validatordata \
        --accept-terms-of-use \
        --interop-num-validators=1 \
        --interop-start-index=$i \
        --rpc-port=$((PRYSM_VALIDATOR_RPC_PORT + i)) \
        --grpc-gateway-port=$((PRYSM_VALIDATOR_GRPC_GATEWAY_PORT + i)) \
        --monitoring-port=$((PRYSM_VALIDATOR_MONITORING_PORT + i)) \
        --graffiti="node-$i" \
        --chain-config-file=$NODE_SETTINGS_DIR/consensus/config.yml > "$log_file" 2>&1 &
    }

    if [ "$STORE_LOGS" = true ]; then
      start_validator "$NODE_LOGS_DIR/validator.log"
    else
      start_validator "/dev/null"
    fi

    echo "✅ Prysm validator started"
    echo ""

    # Check if the PRYSM_BOOTSTRAP_NODE variable is already set
    if [[ -z "${PRYSM_BOOTSTRAP_NODE}" ]]; then
        sleep 5 # sleep to let the prysm node set up
        # If PRYSM_BOOTSTRAP_NODE is not set, execute the command and capture the result into the variable
        # This allows subsequent nodes to discover the first node, treating it as the bootnode
        PRYSM_BOOTSTRAP_NODE=$(curl -s localhost:4100/eth/v1/node/identity | jq -r '.data.enr')
            # Check if the result starts with enr
        if [[ $PRYSM_BOOTSTRAP_NODE == enr* ]]; then
            echo "✅ Prysm bootstrap ENR: $PRYSM_BOOTSTRAP_NODE"
        else
            echo "❌ Failed to obtain bootstrap ENR"
            exit 1
        fi
    fi
done

echo $enodes

for i in $(seq 0 $((NUM_NODES - 1))); do
  from_port=$((GETH_HTTP_PORT + i))
  echo "🔗 node $i (port $from_port) →"

  for j in $(seq 0 $((NUM_NODES - 1))); do
    if [[ $i -ne $j ]]; then
      enode="${enodes[$j]}"
      curl -s -X POST http://127.0.0.1:$from_port \
        -H "Content-Type: application/json" \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$enode\"],\"id\":1}" \
        > /dev/null
      echo "   ➤ addPeer(${j})"
    fi
  done
done

# ip_address=$(hostname -I | awk '{print $1}') # linux
ip_address=$(ifconfig | awk '/inet / && $2 != "127.0.0.1" { print $2; exit }') # mac
echo "Local IP address: $ip_address"

# print every node's info 
for (( i=0; i<$NUM_NODES; i++ )); do
  echo ""
  echo "🌐 Node-$i connection info"
  echo "────────────────────────────"
  echo "• Geth HTTP RPC:       http://$ip_address:$((GETH_HTTP_PORT + i))"
  echo "• Geth WS:             ws://$ip_address:$((GETH_WS_PORT + i))"
  echo "• Geth P2P:            $ip_address:$((GETH_NETWORK_PORT + i))"
  echo "• Prysm GRPC API:      http://$ip_address:$((PRYSM_BEACON_GRPC_GATEWAY_PORT + i))"
  echo "• Prysm P2P (TCP/UDP): $ip_address:$((PRYSM_BEACON_P2P_TCP_PORT + i)) / $((PRYSM_BEACON_P2P_UDP_PORT + i))"
  echo ""
done

# bootnode_pubkey=$($GETH_DEVP2P_BINARY nodekey $NETWORK_DIR/bootnode/nodekey -writeaddress)
# bootnode_enode_outside="enode://${bootnode_pubkey}@${ip_address}:${GETH_BOOTNODE_PORT}" # 확실하게 이 포트로 바인딩 된게 맞나 모르겠네

# echo "🌐 Bootnode info"
# echo "--------------------------------------"
# echo "• Bootnode ENODE:        $bootnode_enode_outside"
# echo "• Beacon ENR:            $PRYSM_BOOTSTRAP_NODE"


sleep 2
echo ""
echo "🖥️  Starting tmux session for log viewing"
echo "────────────────────────────────"
echo ""

tmux kill-session -t $TMUX_SESSION_NAME 2>/dev/null || true
tmux new-session -d -s $TMUX_SESSION_NAME -n "logs"

TOTAL_PANELS=$((NUM_LOGS * 2))
window_idx=0
panel_in_window=0

for (( i=0; i<$NUM_LOGS; i++ )); do
  NODE_LOGS_DIR="$LOGS_DIR/node-$i"
  GETH_LOG="$NODE_LOGS_DIR/geth.log"
  BEACON_LOG="$NODE_LOGS_DIR/beacon.log"

  if (( panel_in_window == 4 )); then
    window_idx=$((window_idx + 1))
    tmux new-window -t $TMUX_SESSION_NAME:$window_idx -n "logs-$window_idx"
    panel_in_window=0
  fi

  if (( panel_in_window == 0 )); then
    tmux send-keys -t $TMUX_SESSION_NAME:$window_idx "tail -f '$GETH_LOG'" C-m
    panel_in_window=$((panel_in_window + 1))
    tmux split-window -v -t $TMUX_SESSION_NAME:$window_idx
    tmux send-keys -t $TMUX_SESSION_NAME:$window_idx.$panel_in_window "tail -f '$BEACON_LOG'" C-m
    panel_in_window=$((panel_in_window + 1))
  else
    tmux select-layout -t $TMUX_SESSION_NAME:$window_idx tiled
    tmux split-window -h -t $TMUX_SESSION_NAME:$window_idx
    tmux send-keys -t $TMUX_SESSION_NAME:$window_idx.$panel_in_window "tail -f '$GETH_LOG'" C-m
    panel_in_window=$((panel_in_window + 1))
    tmux split-window -v -t $TMUX_SESSION_NAME:$window_idx
    tmux send-keys -t $TMUX_SESSION_NAME:$window_idx.$panel_in_window "tail -f '$BEACON_LOG'" C-m
    panel_in_window=$((panel_in_window + 1))
  fi
done

tmux select-layout -t $TMUX_SESSION_NAME:$window_idx tiled


echo "🟢 To view logs: tmux attach -t $TMUX_SESSION_NAME"
echo ""
echo "📘 tmux quick reference:"
echo "────────────────────────────"
echo "• Attach session:     tmux attach -t $TMUX_SESSION_NAME"
echo "• Detach session:     Ctrl + b, d"
echo "• Switch window:      Ctrl + b, n (next), Ctrl + b, p (previous)"
echo "• Move between panes: Ctrl + b + arrow keys (← ↑ ↓ →)"
echo "• Exit pane:          exit or Ctrl + d"
echo "• Kill session:       tmux kill-session -t $TMUX_SESSION_NAME"
echo "────────────────────────────"
echo ""
