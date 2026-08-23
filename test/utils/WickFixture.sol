// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {EasyPosm} from "./libraries/EasyPosm.sol";
import {MockRandomnessProvider} from "./MockRandomnessProvider.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {WickHook} from "../../src/WickHook.sol";
import {IRandomnessProvider} from "../../src/interfaces/IRandomness.sol";

/// @notice Shared deployment fixture for the hardening suites: same pool shape as
/// WickHookTest (dynamic fee, full range liquidity, mock randomness).
abstract contract WickFixture is BaseTest {
    using PoolIdLibrary for PoolKey;
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

    function _setUpWick() internal {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        randomness = new MockRandomnessProvider();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        uint160 namespaced = uint160(0x5555) << 144;
        address flagAddr = address(flags ^ namespaced);

        deployCodeTo(
            "WickHook.sol:WickHook",
            abi.encode(poolManager, IRandomnessProvider(address(randomness)), MIN_SPAN, MAX_SPAN),
            flagAddr
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
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1e18,
            amount1 + 1e18,
            address(this),
            block.timestamp + 1,
            ""
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

    function _swapInstant(bool zeroForOne, uint256 amountIn) internal {
        bytes memory hookData = abi.encode(uint8(1));
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
}
