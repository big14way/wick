// Edit these after deploying. Everything the dashboard reads comes from here.

export const config = {
  // Any JSON RPC endpoint for the chain the hook is deployed on.
  rpcUrl: "https://sepolia.base.org",

  // The deployed WickHook address, printed by script/00_DeployHook.s.sol.
  hookAddress: "0x0000000000000000000000000000000000000000" as `0x${string}`,

  // PoolId of the pool you initialized with the hook (bytes32).
  // script/01_CreatePoolAndAddLiquidity.s.sol prints it, or compute keccak256(abi.encode(poolKey)).
  poolId: "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,

  // Block the hook was deployed at. Event scans start here.
  deployBlock: 0n,

  // Display only.
  token0Symbol: "TOKEN0",
  token1Symbol: "TOKEN1",
  token0Decimals: 18,
  token1Decimals: 18,

  // How often the dashboard refreshes, in milliseconds.
  pollMs: 4000,
};
