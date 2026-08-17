// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockRandomnessProvider} from "./utils/MockRandomnessProvider.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

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

/// @notice The MEV story, in numbers a judge can read off the terminal.
///
/// One vanilla pool and one Wick pool over the same tokens and the same liquidity.
/// On the vanilla pool a textbook sandwich turns a profit. On the Wick pool the same
/// attacker, facing a victim who used the protected lane, loses money, because the
/// victim never moved the price for the attacker to capture.
contract SandwichSimTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    WickHook internal hook;
    MockRandomnessProvider internal randomness;

    Currency internal currency0;
    Currency internal currency1;

    PoolKey internal vanillaKey;
    PoolKey internal wickKey;

    int24 internal constant TICK_SPACING = 60;
    uint64 internal constant MIN_SPAN = 2;
    uint64 internal constant MAX_SPAN = 8;

    address internal victim = makeAddr("victim");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Vanilla pool: no hook, standard 0.30 percent fee.
        vanillaKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);
        _addLiquidity(vanillaKey, 100e18, 100e18);

        // Wick pool: candle auction hook, dynamic fee.
        randomness = new MockRandomnessProvider();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        address flagAddr = address(flags ^ (uint160(0x4444) << 144));
        deployCodeTo(
            "WickHook.sol:WickHook",
            abi.encode(poolManager, IRandomnessProvider(address(randomness)), MIN_SPAN, MAX_SPAN),
            flagAddr
        );
        hook = WickHook(flagAddr);
        randomness.setConsumer(address(hook));

        wickKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(wickKey, Constants.SQRT_PRICE_1_1);
        _addLiquidity(wickKey, 100e18, 100e18);

        _fundAndArm(victim, 200e18);
    }

    // ---------------------------------------------------------------
    // Baseline: the vanilla pool is sandwichable
    // ---------------------------------------------------------------

    function test_vanilla_sandwichTurnsAProfit() public {
        uint256 front = 10e18;
        uint256 victimIn = 40e18;

        uint256 c0Start = currency0.balanceOf(address(this));
        uint256 c1Start = currency1.balanceOf(address(this));

        // Front-run in the victim's direction.
        _swap(vanillaKey, true, front, "", address(this));

        // Victim buys into a price the attacker just pushed.
        vm.prank(victim);
        _swapAs(victim, vanillaKey, true, victimIn, "");

        // Back-run: dump everything gained back the other way.
        uint256 c1Gained = currency1.balanceOf(address(this)) - c1Start;
        _swap(vanillaKey, false, c1Gained, "", address(this));

        int256 profit = int256(currency0.balanceOf(address(this))) - int256(c0Start);
        console2.log("vanilla sandwich attacker currency0 profit (wei):");
        console2.logInt(profit);

        assertGt(profit, 0, "vanilla pool lets the sandwich profit");
    }

    // ---------------------------------------------------------------
    // Wick: the same sandwich against a protected victim loses money
    // ---------------------------------------------------------------

    function test_wick_protectedVictimStarvesTheSandwich() public {
        uint256 front = 10e18;
        uint256 victimIn = 40e18;

        uint256 c0Start = currency0.balanceOf(address(this));
        uint256 c1Start = currency1.balanceOf(address(this));

        // Attacker front-runs through the instant lane (the only way to trade now).
        _swap(wickKey, true, front, abi.encode(uint8(1)), address(this));

        // Victim routes through the protected lane. This parks the order and moves no
        // price at all, so there is nothing for the attacker to sit around.
        vm.prank(victim);
        _swapAs(victim, wickKey, true, victimIn, abi.encode(uint8(0), victim));

        // Attacker back-runs, selling the currency1 it bought.
        uint256 c1Gained = currency1.balanceOf(address(this)) - c1Start;
        _swap(wickKey, false, c1Gained, abi.encode(uint8(1)), address(this));

        int256 profit = int256(currency0.balanceOf(address(this))) - int256(c0Start);
        console2.log("wick sandwich attacker currency0 profit (wei):");
        console2.logInt(profit);

        assertLt(profit, 0, "protected victim makes the sandwich a loss");
    }

    // ---------------------------------------------------------------
    // Settlement is price bounded: an oversized batch fills partially
    // ---------------------------------------------------------------

    function test_settlement_isBoundedAndRefundsTheRest() public {
        // Tighten the bound so a large batch clearly exceeds it.
        hook.setMaxSettleDeviationTicks(60);

        uint64 start = uint64(block.number);
        address trader = makeAddr("trader");

        // A big one-sided protected order. With no opposing flow, settlement must cross
        // the curve, and a 60 tick cap is far less than this order would move it.
        _swapAs2(wickKey, true, 40e18, abi.encode(uint8(0), trader));

        vm.roll(start + MAX_SPAN);
        hook.requestClose(wickKey);
        randomness.fulfill(randomness.lastRequestId(), 0);
        hook.settle(wickKey);

        (,, uint128 in0,,,, uint128 refund0,) = hook.epochs(wickKey.toId(), 1);
        assertGt(refund0, 0, "batch partially refunded, not dumped past the bound");
        assertGt(refund0, in0 / 2, "most of an oversized order is refunded");

        (, int24 tickAfter,,) = poolManager.getSlot0(wickKey.toId());
        assertGe(tickAfter, int24(-61), "settlement never pushed price past the bound");
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _addLiquidity(PoolKey memory key, uint256 amount0, uint256 amount1) internal {
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
            key, tickLower, tickUpper, liquidity, amount0 + 1e18, amount1 + 1e18, address(this), block.timestamp + 1, ""
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData, address receiver)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hookData,
            receiver: receiver,
            deadline: block.timestamp + 1
        });
    }

    // Same as _swap but the call is made by `who` (already pranked by the caller).
    function _swapAs(address who, PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hookData,
            receiver: who,
            deadline: block.timestamp + 1
        });
    }

    // Swap from this contract, used where the receiver is this contract.
    function _swapAs2(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return _swap(key, zeroForOne, amountIn, hookData, address(this));
    }

    function _fundAndArm(address who, uint256 amount) internal {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(who, amount);
        t1.mint(who, amount);

        vm.startPrank(who);
        t0.approve(address(permit2), type(uint256).max);
        t1.approve(address(permit2), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(t0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(address(t1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
