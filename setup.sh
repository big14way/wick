#!/usr/bin/env bash
# Fetches the three dependency libraries and their nested submodules.
# Run once after unzipping, then forge build / forge test work normally.
set -e

mkdir -p lib
cd lib

clone() {
  local name="$1" url="$2"
  if [ -d "$name/.git" ] || [ -f "$name/foundry.toml" ] || [ -d "$name/src" ]; then
    echo "$name already present, skipping clone"
  else
    git clone --depth 1 "$url" "$name"
  fi
  (cd "$name" && git submodule update --init --recursive --depth 1) || true
}

clone forge-std https://github.com/foundry-rs/forge-std.git
clone uniswap-hooks https://github.com/OpenZeppelin/uniswap-hooks.git
clone hookmate https://github.com/akshatmittal/hookmate.git

cd ..
echo ""
echo "Dependencies ready. Next: forge build && forge test"
