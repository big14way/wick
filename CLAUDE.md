# CLAUDE.md

Read this whole file before touching anything. It is the handoff from the claude.ai session where this project was designed, built, and tested to green.

## Who and what

Owner: Gwill (Godswill Idolor Eseteru), solo entrant, GitHub big14way, X @big14teru.
Project: Wick, a Uniswap v4 hook for the Atrium UHI10 hookathon. Theme: Sustainable Liquidity and MEV Protection.
Deadlines: idea form due Aug 17 2026 11:59pm PST. Project updates roughly Aug 24 and Aug 31 (form tally.so/r/m6lP9e). Final submission Sept 3 (form tally.so/r/mVNEAE) with demo video under 5 minutes. Demo day Sept 11. Prize pool 15k USD.
Important: meaningful git commits must land inside the Aug 17 to Sept 3 window. Do not squash everything into one dump commit. Commit as work happens.

## Style rules, absolute

- No em dashes and no en dashes anywhere. Not in code, not in comments, not in UI copy, not in docs, not in commit messages, not in chat replies. Use commas, periods, or parentheses. Hyphens in ordinary hyphenated words are fine.
- Natural human prose. No AI sounding filler.
- Deliverables complete and paste ready. Verify before claiming anything works. Run the tests before saying tests pass.

## What Wick is

Candle auction settlement hook. Two lanes selected by hookData:

- empty or abi.encode(uint8(0), address owner): protected lane. beforeSwap takes custody of the input (NoOp via BeforeSwapDelta), mints an ERC6909 claim to the owner (tx.origin if empty hookData), buckets the amount by absolute block. Exact output swaps revert with ExactOutputNotProtected.
- abi.encode(uint8(1)): instant lane. Executes now, pays a dynamic LP fee override: instantBaseFee (3000) + volFeePerTick (25) * volEma + roundTripSurcharge (30000) if the same tx.origin swapped the opposite direction in the same block.

Candle lifecycle: first protected order sets epochStart. Window is [epochStart, epochStart + maxSpan - 1]. After the window, requestClose snapshots price and asks the randomness provider for a word. fulfillRandomness computes close = epochStart + minSpan - 1 + (word mod (maxSpan - minSpan + 1)). settle nets opposing flow at the snapshot price, pushes only the residual through the pool bounded by maxSettleDeviationTicks (default 200) around the snapshot tick, refunds the unfilled remainder pro rata, and opens the next epoch at close + 1. Orders in blocks after the close stay bucketed and roll into the next epoch. redeem burns the claim and pays out pro rata plus refund share. cancel works only while the order's block has not been settled and the phase allows it.

## Invariants, do not break these

1. Custody pairing: `specified.take(poolManager, address(this), specifiedAmount, true)` in beforeSwap must stay exactly paired with the settle and payout paths. This mirrors the audited BaseAsyncSwap pattern.
2. Buckets are keyed by absolute block number, never by epoch relative offsets.
3. Close block is always in [epochStart + minSpan - 1, epochStart + maxSpan - 1].
4. epochOfBlock is 0 until that block settles. redeem requires it nonzero. cancel requires it zero.
5. The hook recognizes its own settlement swap because in v4 the `sender` argument to beforeSwap is the router or unlocking contract, and the hook's settle path unlocks the manager itself, so sender == address(this) means pass through at batchFee.
6. via_ir = true in foundry.toml is required. Without it redeem and _settle hit stack too deep. Do not remove it.
7. Hook flags: beforeInitialize, afterInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta. The deployed address must encode exactly these.
8. Pools must be dynamic fee pools (fee = LPFeeLibrary.DYNAMIC_FEE_FLAG). beforeInitialize enforces it.

## Repository map

```
src/WickHook.sol                        main hook, about 650 lines
src/interfaces/IRandomness.sol          IRandomnessProvider, IRandomnessConsumer
src/randomness/ChainlinkVRFProvider.sol VRF 2.5, production
src/randomness/BlockhashProvider.sol    demo only, proposer biasable, labeled
script/00_DeployHook.s.sol              env driven deploy with HookMiner
script/base/BaseScript.sol              EDIT AFTER DEPLOY: token0, token1, hookContract
script/01_CreatePoolAndAddLiquidity.s.sol and 02, 03   template scripts, use after BaseScript is set
test/WickHook.t.sol                     7 unit tests, all pass
test/SandwichSim.t.sol                  3 adversarial tests, all pass, prints profit numbers
test/utils/MockRandomnessProvider.sol   deterministic randomness for tests
test/utils/SandwichBot.sol              helper contract, currently unused by the sim
frontend/                               Vite + React + viem dashboard
docs/DEMO_VIDEO_SCRIPT.md               the recording script
setup.sh                                clones the three libs and their submodules
```

## Environment and build

On this Mac: install Foundry if missing (`curl -L https://foundry.paradigm.xyz | bash && foundryup`), then:

```
bash setup.sh
forge build
forge test
```

Expected: 16 tests pass (7 WickHook, 3 SandwichSim, 6 template EasyPosm tests). foundry.toml pins solc 0.8.30, evm_version cancun, optimizer 200 runs, via_ir true. First build takes a few minutes because of via_ir.

Known good numbers from the container run on Aug 13 2026:

```
test_vanilla_sandwichTurnsAProfit    attacker profit +7875669133927923750 wei (+7.8757)
test_wick_protectedVictimStarvesTheSandwich   attacker profit -330079377247505705 wei (-0.3301)
```

If these drift slightly after dependency updates that is fine, the signs must not flip.

## Dependency setup detail

setup.sh clones forge-std, uniswap-hooks (OpenZeppelin), and hookmate into lib/, then runs nested `git submodule update --init --recursive --depth 1` inside each. Remappings resolve @uniswap/v4-core/ to lib/uniswap-hooks/lib/v4-core/. If forge complains about missing files, rerun the submodule step inside lib/uniswap-hooks.

## Task list, in order

1. Verify: run `forge build && forge test` locally. Fix anything environment specific before adding features.
2. Git: init repo if not already, first commit, push to a public GitHub repo under big14way. Commit regularly from here on.
3. Idea form (due Aug 17): answers were drafted in the claude.ai session. Project Name Wick, preferred name Gwill, solo (option A), theme yes, originally joined cohort UHI8. Gwill must add his Discord handle himself. Save the Project ID email (format HK-UHI10-XXXX).
4. Deploy to testnet. Recommended Base Sepolia. Steps:
   a. Verify the v4 PoolManager address at docs.uniswap.org/contracts/v4/deployments. Do not trust memory.
   b. For VRF: create a subscription at vrf.chain.link, fund with LINK or native, verify coordinator and keyhash at docs.chain.link/vrf/v2-5/supported-networks. Export VRF_COORDINATOR, VRF_KEYHASH, VRF_SUBSCRIPTION_ID.
   c. `forge script script/00_DeployHook.s.sol --rpc-url $RPC_URL --broadcast`. It mines the flag address with HookMiner, deploys the provider and hook, wires setConsumer, prints addresses.
   d. Add the deployed hook as a VRF consumer on the subscription page.
   e. Edit script/base/BaseScript.sol: set token0, token1 (deploy two test ERC20s or use existing testnet tokens), and hookContract to the deployed hook address. Then run 01_CreatePoolAndAddLiquidity.
   f. Put hook address, poolId, deployBlock, RPC into frontend/src/config.ts.
5. Frontend polish: `cd frontend && npm install && npm run dev`. It polls every 4s, shows the candle, lanes, order feed, settled epochs. Add a wallet connect + swap form only if time allows, the read only dashboard plus cast commands is enough for the video.
6. Keeper convenience: a tiny script or cast cron that calls requestClose and settle when phases allow would make the live demo smoother. Optional.
7. Demo video: follow docs/DEMO_VIDEO_SCRIPT.md. Record real voice, quiet room, under 5 minutes, unlisted YouTube is fine.
8. Project update forms around Aug 24 and Aug 31 at tally.so/r/m6lP9e.
9. Final submission Sept 3 at tally.so/r/mVNEAE: repo link, video link, description. Reuse README language.

## Novelty receipts

Dataset github.com/AtriumAcademy/UHI-Hook-Data, 715 rows of prior submissions. Zero matches for candle, uniform clearing, uniform price, probabilistic close. Nearest neighbors: Async Swap (UHI4), ZeanHook (UHI5), AsyncSwapHook (UHI7), VeiledBatch (UHI7). Differentiation is in README under Why this is new. Do not delete that section.

## Threat model notes for honest answers

The settle brick edge: an attacker can push price past the settlement bound to make settle revert until price returns. Funds stay custodied, this is griefing not theft. Say it plainly if judges ask. The blockhash provider is biasable and exists only for local demos. The protected lane costs a few blocks of latency by design.

## Discipline

Test before claiming. Never state a number that was not printed by a real run. Verify every external address against official docs at the moment of use. Keep replies and docs free of em and en dashes.
