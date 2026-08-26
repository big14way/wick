#!/usr/bin/env bash
# Wick keeper. Polls the hook and advances the candle lifecycle whenever a
# phase transition is allowed: requestClose after the window ends, reveal on
# the blockhash provider when a request is pending, settle once revealed.
# All three calls are permissionless, the keeper just pays gas.
#
# Env:
#   PRIVATE_KEY   required, the gas payer
#   RPC_URL       default https://sepolia.unichain.org
#   HOOK          default the Unichain Sepolia WickHook
#   POOL_KEY      default the Unichain Sepolia WICKA/WICKB pool
#   PROVIDER      blockhash provider address, set empty when using Chainlink VRF
#   POLL          seconds between checks, default 5
set -u

RPC_URL="${RPC_URL:-https://sepolia.unichain.org}"
HOOK="${HOOK:-0x22916F75eDB48a3d66fEB680bB428a901e1D30c8}"
POOL_KEY="${POOL_KEY:-(0x0FC24a0C237C5970e210b1338Ca2dA20d7Fd7831,0xa97c20Fd92efeb66DD7458c9C5dfd3F2b7B2BA7e,8388608,60,0x22916F75eDB48a3d66fEB680bB428a901e1D30c8)}"
# Set PROVIDER to the blockhash provider address, or to empty (PROVIDER=) when
# the chain uses Chainlink VRF, which fulfills on its own.
PROVIDER="${PROVIDER-0x801A6D9eF9E96Fb2958B9F49E03cb73fA2CC5e11}"
POLL="${POLL:-5}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"

POOL_ID=$(cast keccak "$(cast abi-encode "f((address,address,uint24,int24,address))" "$POOL_KEY")")
MAX_SPAN=$(cast call "$HOOK" "maxSpan()(uint64)" --rpc-url "$RPC_URL")
echo "keeper watching pool $POOL_ID, maxSpan $MAX_SPAN, poll ${POLL}s"

SETTLE_FAILS=0

send() {
  if cast send "$HOOK" "$1((address,address,uint24,int24,address))" "$POOL_KEY" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null 2>&1; then
    echo "$(date +%T) $1 sent"
    [ "$1" = "settle" ] && SETTLE_FAILS=0
  else
    echo "$(date +%T) $1 reverted (fine, phase may have moved)"
    if [ "$1" = "settle" ]; then
      SETTLE_FAILS=$((SETTLE_FAILS + 1))
      if [ "$SETTLE_FAILS" -ge 3 ]; then
        echo "$(date +%T) settle has reverted $SETTLE_FAILS times. The price is likely outside the settlement bound around the snapshot. Push it back toward the snapshot tick and settle will go through. Funds stay custodied meanwhile."
      fi
    fi
  fi
}

while true; do
  STATE=$(cast call "$HOOK" "pools(bytes32)(uint64,uint64,uint8,uint40,uint160,int24,int24,uint64,uint24)" "$POOL_ID" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  if [ -z "$STATE" ]; then sleep "$POLL"; continue; fi
  EPOCH_START=$(echo "$STATE" | awk '{print $1}')
  PHASE=$(echo "$STATE" | awk '{print $3}')
  BLOCK=$(cast block-number --rpc-url "$RPC_URL")

  case "$PHASE" in
    0)
      if [ "$EPOCH_START" != "0" ] && [ "$BLOCK" -gt $((EPOCH_START + MAX_SPAN - 1)) ]; then
        # Only draw when the window actually holds orders. Without this the
        # empty relight path would burn keeper gas every poll.
        HAS_ORDERS=$(cast logs --rpc-url "$RPC_URL" --address "$HOOK" \
          --from-block "$EPOCH_START" --to-block $((EPOCH_START + MAX_SPAN - 1)) \
          "OrderPlaced(bytes32,address,uint64,bool,uint128,uint256)" 2>/dev/null | head -1)
        if [ -n "$HAS_ORDERS" ]; then
          send requestClose
        fi
      fi
      ;;
    1)
      if [ -n "$PROVIDER" ]; then
        NEXT=$(cast call "$PROVIDER" "nextRequestId()(uint256)" --rpc-url "$RPC_URL")
        LAST=$((NEXT - 1))
        if [ "$LAST" -ge 1 ]; then
          cast send "$PROVIDER" "reveal(uint256)" "$LAST" \
            --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null 2>&1 \
            && echo "$(date +%T) reveal($LAST) sent" || echo "$(date +%T) reveal($LAST) not ready"
        fi
      fi
      ;;
    2)
      send settle
      ;;
  esac
  sleep "$POLL"
done
