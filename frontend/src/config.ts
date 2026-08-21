// Edit these after deploying. Everything the dashboard reads comes from here.

export const config = {
  // Any JSON RPC endpoint for the chain the hook is deployed on.
  rpcUrl: "https://sepolia.unichain.org",

  // Chain metadata, used for wallet connect and network switching.
  chainId: 1301,
  chainName: "Unichain Sepolia",
  explorerUrl: "https://sepolia.uniscan.xyz",

  // The deployed WickHook address, printed by script/00_DeployHook.s.sol.
  hookAddress: "0xdb51948ce7b6E6C038004c924bdb4851e57430c8" as `0x${string}`,

  // Hookmate v4 swap router for this chain, see AddressConstants.sol.
  routerAddress: "0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba" as `0x${string}`,

  // WalletConnect Cloud project id. Injected wallets connect directly; this
  // enables the QR modal for mobile wallets. Empty string disables it.
  walletConnectProjectId: "1eebe528ca0ce94a99ceaa2e915058d7",

  // Randomness provider wired into the hook on this chain.
  // kind "vrf" for ChainlinkVRFProvider, "blockhash" for the demo BlockhashProvider.
  randomness: {
    kind: "blockhash" as "vrf" | "blockhash",
    address: "0xd046d5a5302ff997c81275c61bf64e1eef02fc93" as `0x${string}`,
  },

  // The pool key the hook was initialized with. currency0 must sort below currency1.
  poolKey: {
    currency0: "0x0FC24a0C237C5970e210b1338Ca2dA20d7Fd7831" as `0x${string}`, // WICKA
    currency1: "0xa97c20Fd92efeb66DD7458c9C5dfd3F2b7B2BA7e" as `0x${string}`, // WICKB
    fee: 8388608, // LPFeeLibrary.DYNAMIC_FEE_FLAG
    tickSpacing: 60,
    hooks: "0xdb51948ce7b6E6C038004c924bdb4851e57430c8" as `0x${string}`,
  },

  // PoolId of the pool you initialized with the hook (bytes32).
  // script/01_CreatePoolAndAddLiquidity.s.sol prints it, or compute keccak256(abi.encode(poolKey)).
  poolId: "0xccd0fae511172bd494561750f3310e280531898f4ac4b82e6da76cc5892c3115" as `0x${string}`,

  // Block the hook was deployed at. Event scans start here.
  deployBlock: 60116497n,

  // Display only.
  token0Symbol: "WICKA",
  token1Symbol: "WICKB",
  token0Decimals: 18,
  token1Decimals: 18,

  // How often the dashboard refreshes, in milliseconds.
  pollMs: 4000,
};
