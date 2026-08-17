// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockRandomnessProvider} from "./utils/MockRandomnessProvider.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {WickHook} from "../src/WickHook.sol";
import {IRandomnessProvider} from "../src/interfaces/IRandomness.sol";

/// @notice Core behavior of the candle auction hook. Everything a judge cares about
/// is asserted here: custody without a curve trade, one uniform clearing price per
/// side, internal netting that never touches the pool, the instant lane premium, and
/// the cancel and rollover bookkeeping.
contract WickHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    WickHook internal hook;
    MockRandomnessProvider internal randomness;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint64 internal constant MIN_SPAN = 2;
    uint64 internal constant MAX_SPAN = 8;
    int24 internal constant TICK_SPACING = 60;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        randomness = new MockRandomnessProvider();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        uint160 namespaced = uint160(0x4444) << 144;
        address flagAddr = address(flags ^ namespaced);

        deployCodeTo(
            "WickHook.sol:WickHook", abi.encode(poolManager, IRandomnessProvider(address(randomness)), MIN_SPAN, MAX_SPAN), flagAddr
        );
        hook = WickHook(flagAddr);
        randomness.setConsumer(address(hook));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        _addFullRangeLiquidity(100e18, 100e18);
    }

    // ---------------------------------------------------------------
    // Custody: a protected swap parks input and never crosses the curve
    // ---------------------------------------------------------------

    function test_protected_takesCustodyAndMintsClaim() public {
        uint256 amountIn = 1e18;
        (uint160 priceBefore,,,) = poolManager.getSlot0(poolId);

        _placeProtected(true, amountIn, alice);

        // Alice holds a claim for exactly what she put in.
        uint256 id = hook.orderId(poolId, uint64(block.number), true);
        assertEq(hook.balanceOf(alice, id), amountIn, "claim minted to owner");

        // The hook is holding the input as its own 6909 claim.
        uint256 c0Id = uint256(uint160(Currency.unwrap(currency0)));
        assertEq(poolManager.balanceOf(address(hook), c0Id), amountIn, "hook holds input as claims");

        // The bucket recorded the order on the zeroForOne side.
        (uint128 in0, uint128 in1) = hook.buckets(poolId, block.number);
        assertEq(in0, amountIn, "bucket in0");
        assertEq(in1, 0, "bucket in1");

        // The pool price did not move: no swap happened.
        (uint160 priceAfter,,,) = poolManager.getSlot0(poolId);
        assertEq(priceAfter, priceBefore, "price unchanged by protected order");
    }

    function test_protected_rejectsExactOutput() public {
        // Exact output sends a positive amountSpecified, which the protected lane
        // refuses in v1. The hook revert bubbles up through the pool manager.
        bytes memory hookData = abi.encode(uint8(0), alice);
        vm.expectRevert();
        swapRouter.swapTokensForExactTokens({
            amountOut: 1e18,
            amountInMax: type(uint256).max,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    // ---------------------------------------------------------------
    // Uniform price: same-side orders in one epoch clear at one rate
    // ---------------------------------------------------------------

    function test_candle_uniformPricePerSide() public {
        uint64 start = uint64(block.number);

        // Alice at the start block, Bob two blocks later, both buying currency1.
        _placeProtected(true, 1e18, alice);
        vm.roll(start + 2);
        _placeProtected(true, 2e18, bob);

        // Elapse the window, draw a close that covers both blocks, settle.
        vm.roll(start + MAX_SPAN);
        // close = start + minSpan - 1 + (word % span). word = 1 lands close at start+2.
        _drawAndSettle(1);

        uint256 aliceOut = _redeem(alice, start, true);
        uint256 bobOut = _redeem(bob, start + 2, true);

        assertGt(aliceOut, 0, "alice filled");
        assertGt(bobOut, 0, "bob filled");
        // Bob put in twice as much, so at a single clearing price he gets twice out.
        assertApproxEqAbs(bobOut, aliceOut * 2, 4, "uniform price per side");
    }

    // ---------------------------------------------------------------
    // Netting: opposing flow matches internally, curve untouched
    // ---------------------------------------------------------------

    function test_candle_nettingSkipsTheCurve() public {
        uint64 start = uint64(block.number);
        (uint160 priceBefore,,,) = poolManager.getSlot0(poolId);

        // Equal and opposite at a 1:1 price. Everything nets, nothing crosses.
        _placeProtected(true, 5e18, alice); // gives currency0, wants currency1
        _placeProtected(false, 5e18, bob); // gives currency1, wants currency0

        vm.roll(start + MAX_SPAN);
        _drawAndSettle(0);

        // The pool never saw a settlement swap, so its price is exactly the snapshot.
        (uint160 priceAfter,,,) = poolManager.getSlot0(poolId);
        assertEq(priceAfter, priceBefore, "curve untouched by fully netted epoch");

        uint256 aliceOut = _redeem(alice, start, true); // receives currency1
        uint256 bobOut = _redeem(bob, start, false); // receives currency0

        // A clean 1:1 match with no fee and no price impact.
        assertEq(aliceOut, 5e18, "alice receives matched currency1");
        assertEq(bobOut, 5e18, "bob receives matched currency0");
    }

    // ---------------------------------------------------------------
    // Instant lane: dynamic premium, higher on a same-block round trip
    // ---------------------------------------------------------------

    function test_instant_roundTripCostsMore() public {
        // First instant swap sets the direction seen this block for this origin.
        vm.recordLogs();
        _swapInstant(true, 1e18);
        _swapInstant(false, 1e18); // opposite direction, same block, same origin

        (uint24 fee1, bool rt1, uint24 fee2, bool rt2) = _twoInstantFees();
        assertFalse(rt1, "first leg not a round trip");
        assertTrue(rt2, "second leg flagged as round trip");
        assertGt(fee2, fee1, "round trip pays a surcharge");
    }

    // ---------------------------------------------------------------
    // Cancel: pull an unsettled order and get the input back
    // ---------------------------------------------------------------

    function test_cancel_refundsBeforeSettlement() public {
        uint64 start = uint64(block.number);
        uint256 balBefore = currency0.balanceOf(address(this));

        _placeProtected(true, 1e18, address(this));
        assertEq(currency0.balanceOf(address(this)), balBefore - 1e18, "input taken");

        hook.cancel(poolKey, start, true);

        assertEq(currency0.balanceOf(address(this)), balBefore, "input refunded");
        uint256 id = hook.orderId(poolId, start, true);
        assertEq(hook.balanceOf(address(this), id), 0, "claim burned");
        (uint128 in0,) = hook.buckets(poolId, start);
        assertEq(in0, 0, "bucket cleared");
    }

    // ---------------------------------------------------------------
    // Rollover: an order past the close waits for the next epoch
    // ---------------------------------------------------------------

    function test_rollover_lateOrderSettlesNextEpoch() public {
        uint64 start = uint64(block.number);

        _placeProtected(true, 1e18, alice); // epoch 1 candidate at the start block

        // Place a second order after the eventual close but before settlement.
        vm.roll(start + 3);
        _placeProtected(true, 1e18, bob);

        // Draw a close of start+1 (word 0), so Bob's block start+3 falls outside epoch 1.
        vm.roll(start + MAX_SPAN);
        _drawAndSettle(0);

        // Alice settled in epoch 1.
        assertEq(hook.epochOfBlock(poolId, start), 1, "alice block settled");
        // Bob has not settled yet.
        assertEq(hook.epochOfBlock(poolId, start + 3), 0, "bob block still open");
        vm.expectRevert();
        hook.redeem(poolKey, start + 3, true, bob);

        // Run the next candle. The new window opened right after the close.
        vm.roll(start + MAX_SPAN * 2);
        _drawAndSettle(0);

        assertEq(hook.epochOfBlock(poolId, start + 3), 2, "bob settled next epoch");
        uint256 bobOut = _redeem(bob, start + 3, true);
        assertGt(bobOut, 0, "bob filled in epoch 2");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _addFullRangeLiquidity(uint256 amount0, uint256 amount1) internal {
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        positionManager.mint(
            poolKey, tickLower, tickUpper, liquidity, amount0 + 1e18, amount1 + 1e18, address(this), block.timestamp + 1, ""
        );
    }

    function _placeProtected(bool zeroForOne, uint256 amountIn, address owner) internal {
        bytes memory hookData = abi.encode(uint8(0), owner);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _swapInstant(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        bytes memory hookData = abi.encode(uint8(1));
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _drawAndSettle(uint256 word) internal {
        hook.requestClose(poolKey);
        uint256 reqId = randomness.lastRequestId();
        randomness.fulfill(reqId, word);
        hook.settle(poolKey);
    }

    function _redeem(address who, uint256 blockNumber, bool zeroForOne) internal returns (uint256 received) {
        Currency out = zeroForOne ? currency1 : currency0;
        uint256 before = out.balanceOf(who);
        vm.prank(who);
        hook.redeem(poolKey, uint64(blockNumber), zeroForOne, who);
        received = out.balanceOf(who) - before;
    }

    /// @dev Pull the two InstantFeeCharged events out of the recorded logs.
    function _twoInstantFees() internal returns (uint24 fee1, bool rt1, uint24 fee2, bool rt2) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("InstantFeeCharged(bytes32,address,uint24,bool)");
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                (uint24 fee, bool rt) = abi.decode(logs[i].data, (uint24, bool));
                if (seen == 0) {
                    fee1 = fee;
                    rt1 = rt;
                } else {
                    fee2 = fee;
                    rt2 = rt;
                }
                seen++;
            }
        }
        require(seen >= 2, "expected two instant fee events");
    }
}
