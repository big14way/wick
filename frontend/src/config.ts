// Edit these after deploying. Everything the dashboard reads comes from here.

export const config = {
  // Any JSON RPC endpoint for the chain the hook is deployed on.
  rpcUrl: "https://sepolia.unichain.org",

  // The deployed WickHook address, printed by script/00_DeployHook.s.sol.
  hookAddress: "0xdb51948ce7b6E6C038004c924bdb4851e57430c8" as `0x${string}`,

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
