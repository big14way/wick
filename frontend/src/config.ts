// Everything the dashboard reads comes from here. Two live deployments; the
// header switcher picks one via the ?chain= URL parameter (default unichain).

export type NetworkConfig = {
  key: string;
  label: string;
  rpcUrl: string;
  chainId: number;
  chainName: string;
  explorerUrl: string;
  hookAddress: `0x${string}`;
  routerAddress: `0x${string}`;
  walletConnectProjectId: string;
  randomness: { kind: "vrf" | "blockhash"; address: `0x${string}` };
  poolKey: {
    currency0: `0x${string}`;
    currency1: `0x${string}`;
    fee: number;
    tickSpacing: number;
    hooks: `0x${string}`;
  };
  poolId: `0x${string}`;
  deployBlock: bigint;
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  pollMs: number;
};

const WC_PROJECT_ID = "1eebe528ca0ce94a99ceaa2e915058d7";

export const networks: Record<string, NetworkConfig> = {
  unichain: {
    key: "unichain",
    label: "Unichain Sepolia",
    rpcUrl: "https://sepolia.unichain.org",
    chainId: 1301,
    chainName: "Unichain Sepolia",
    explorerUrl: "https://sepolia.uniscan.xyz",
    hookAddress: "0xdb51948ce7b6E6C038004c924bdb4851e57430c8",
    routerAddress: "0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba",
    walletConnectProjectId: WC_PROJECT_ID,
    // Demo chain: Chainlink VRF does not serve Unichain Sepolia, so the candle
    // draws from a blockhash provider here. The VRF path runs on Base Sepolia.
    randomness: { kind: "blockhash", address: "0xd046d5a5302ff997c81275c61bf64e1eef02fc93" },
    poolKey: {
      currency0: "0x0FC24a0C237C5970e210b1338Ca2dA20d7Fd7831", // WICKA
      currency1: "0xa97c20Fd92efeb66DD7458c9C5dfd3F2b7B2BA7e", // WICKB
      fee: 8388608, // LPFeeLibrary.DYNAMIC_FEE_FLAG
      tickSpacing: 60,
      hooks: "0xdb51948ce7b6E6C038004c924bdb4851e57430c8",
    },
    poolId: "0xccd0fae511172bd494561750f3310e280531898f4ac4b82e6da76cc5892c3115",
    deployBlock: 60116497n,
    token0Symbol: "WICKA",
    token1Symbol: "WICKB",
    token0Decimals: 18,
    token1Decimals: 18,
    pollMs: 4000,
  },
  base: {
    key: "base",
    label: "Base Sepolia (VRF)",
    rpcUrl: "https://sepolia.base.org",
    chainId: 84532,
    chainName: "Base Sepolia",
    explorerUrl: "https://sepolia.basescan.org",
    hookAddress: "0x749F507e5EA97588Ce1d97868399e294037a70C8",
    routerAddress: "0x71cD4Ea054F9Cb3D3BF6251A00673303411A7DD9",
    walletConnectProjectId: WC_PROJECT_ID,
    // Production randomness path: Chainlink VRF 2.5.
    randomness: { kind: "vrf", address: "0x631100C996aBFea0d81233D4DF446a816E124C97" },
    poolKey: {
      // On this chain WICKB sorts below WICKA, so currency0 is WICKB.
      currency0: "0x55D4e4714fbcE432A1B15f23FBD28E299AE5037d", // WICKB
      currency1: "0x581B822B34bEf5138f2CE6EaCE81384D553F70a8", // WICKA
      fee: 8388608,
      tickSpacing: 60,
      hooks: "0x749F507e5EA97588Ce1d97868399e294037a70C8",
    },
    poolId: "0x4225440c775b36d1e5e4794cff503e8619d0a2ff21d2771af82f2c4b91a8dae3",
    deployBlock: 45724610n,
    token0Symbol: "WICKB",
    token1Symbol: "WICKA",
    token0Decimals: 18,
    token1Decimals: 18,
    pollMs: 4000,
  },
};

const param = new URLSearchParams(window.location.search).get("chain");
export const activeNetworkKey = param && networks[param] ? param : "unichain";
export const config = networks[activeNetworkKey];

export function switchNetwork(key: string) {
  if (!networks[key] || key === activeNetworkKey) return;
  const url = new URL(window.location.href);
  url.searchParams.set("chain", key);
  window.location.assign(url.toString());
}
