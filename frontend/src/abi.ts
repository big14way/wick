// Hand trimmed ABIs. Only what the dashboard reads and the trade panel writes.

const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

export const routerAbi = [
  {
    type: "function",
    name: "swapExactTokensForTokens",
    stateMutability: "payable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      { name: "poolKey", type: "tuple", components: poolKeyComponents },
      { name: "hookData", type: "bytes" },
      { name: "receiver", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "delta", type: "int256" }],
  },
] as const;

export const wickAbi = [
  {
    type: "function",
    name: "redeem",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: poolKeyComponents },
      { name: "blockNumber", type: "uint64" },
      { name: "zeroForOne", type: "bool" },
      { name: "to", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "cancel",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: poolKeyComponents },
      { name: "blockNumber", type: "uint64" },
      { name: "zeroForOne", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "id", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "epochOfBlock",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "blockNumber", type: "uint256" },
    ],
    outputs: [{ type: "uint40" }],
  },
  {
    type: "function",
    name: "pools",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "epochStart", type: "uint64" },
      { name: "revealedClose", type: "uint64" },
      { name: "phase", type: "uint8" },
      { name: "epochCount", type: "uint40" },
      { name: "snapshotSqrtPriceX96", type: "uint160" },
      { name: "snapshotTick", type: "int24" },
      { name: "lastTick", type: "int24" },
      { name: "lastTickBlock", type: "uint64" },
      { name: "volEma", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "minSpan",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "function",
    name: "instantBaseFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "volFeePerTick",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "roundTripSurcharge",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "batchFee",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint24" }],
  },
  {
    type: "function",
    name: "maxSpan",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint64" }],
  },
  {
    type: "event",
    name: "OrderPlaced",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "blockNumber", type: "uint64", indexed: false },
      { name: "zeroForOne", type: "bool", indexed: false },
      { name: "amountIn", type: "uint128", indexed: false },
      { name: "claimId", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "OrderCancelled",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "blockNumber", type: "uint64", indexed: false },
      { name: "zeroForOne", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CandleLit",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "epochStart", type: "uint64", indexed: false },
      { name: "windowLastBlock", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CandleDrawing",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "epochStart", type: "uint64", indexed: false },
      { name: "requestId", type: "uint256", indexed: false },
      { name: "snapshotTick", type: "int24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "CandleRevealed",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "epochStart", type: "uint64", indexed: false },
      { name: "closeBlock", type: "uint64", indexed: false },
    ],
  },
  {
    type: "event",
    name: "EpochSettled",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "epochId", type: "uint40", indexed: true },
      { name: "startBlock", type: "uint64", indexed: false },
      { name: "closeBlock", type: "uint64", indexed: false },
      { name: "in0", type: "uint128", indexed: false },
      { name: "in1", type: "uint128", indexed: false },
      { name: "out1For0", type: "uint128", indexed: false },
      { name: "out0For1", type: "uint128", indexed: false },
      { name: "refund0", type: "uint128", indexed: false },
      { name: "refund1", type: "uint128", indexed: false },
      { name: "keeper", type: "address", indexed: false },
    ],
  },
  {
    type: "event",
    name: "InstantFeeCharged",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "origin", type: "address", indexed: true },
      { name: "fee", type: "uint24", indexed: false },
      { name: "roundTrip", type: "bool", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Redeemed",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "blockNumber", type: "uint64", indexed: false },
      { name: "zeroForOne", type: "bool", indexed: false },
      { name: "out", type: "uint256", indexed: false },
      { name: "refund", type: "uint256", indexed: false },
    ],
  },
] as const;
