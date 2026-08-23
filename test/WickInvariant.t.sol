// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {WickFixture} from "./utils/WickFixture.sol";
import {MockRandomnessProvider} from "./utils/MockRandomnessProvider.sol";
import {WickHook} from "../src/WickHook.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Random walks over the whole lifecycle: orders, instants, cancels,
/// candle draws, settlements and redeems in arbitrary interleavings. After every
/// step the system must stay solvent, every drawn close must land in the window,
/// and every settled epoch must conserve value per side.
contract WickInvariantTest is WickFixture {
    WickHandler internal handler;

    function setUp() public {
        _setUpWick();
        handler = new WickHandler(hook, poolKey, poolId, swapRouter, poolManager, randomness);

        // Fund the handler and let it approve the router itself.
        MockERC20(Currency.unwrap(currency0)).transfer(address(handler), 2_000_000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(handler), 2_000_000e18);
        handler.approveAll();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = WickHandler.placeProtected.selector;
        selectors[1] = WickHandler.instantSwap.selector;
        selectors[2] = WickHandler.rollBlocks.selector;
        selectors[3] = WickHandler.closeAndSettle.selector;
        selectors[4] = WickHandler.cancelOrder.selector;
        selectors[5] = WickHandler.redeemOrder.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Claim liabilities in currency0 never exceed what the hook holds.
    function invariant_hookSolventCurrency0() public view {
        uint256 held = poolManager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(currency0))));
        assertGe(held, handler.ghostOwed0(), "currency0 claims unbacked");
    }

    /// @dev Claim liabilities in currency1 never exceed what the hook holds.
    function invariant_hookSolventCurrency1() public view {
        uint256 held = poolManager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(currency1))));
        assertGe(held, handler.ghostOwed1(), "currency1 claims unbacked");
    }

    /// @dev Every revealed close landed in [epochStart + minSpan - 1, epochStart + maxSpan - 1].
    function invariant_closeAlwaysInWindow() public view {
        assertFalse(handler.ghostCloseOutOfRange(), "a close left the window");
    }

    /// @dev Every settled epoch satisfied refund <= in per side.
    function invariant_epochConservation() public view {
        assertFalse(handler.ghostConservationBroken(), "epoch conservation broke");
    }
}

/// @notice Drives the hook with bounded random actions and keeps ghost accounting
/// of what the hook owes: custodied inputs before settlement, recorded outputs and
/// refunds after, decremented by what redeems and cancels actually paid.
contract WickHandler is Test {
    WickHook internal immutable hook;
    IUniswapV4Router04 internal immutable router;
    IPoolManager internal immutable manager;
    MockRandomnessProvider internal immutable randomness;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 public ghostOwed0;
    uint256 public ghostOwed1;
    bool public ghostCloseOutOfRange;
    bool public ghostConservationBroken;

    struct Order {
        uint64 blockNumber;
        bool zeroForOne;
        bool closed; // cancelled or redeemed
    }

    Order[] internal orders;
    uint40 internal lastAccountedEpoch;

    constructor(
        WickHook _hook,
        PoolKey memory _key,
        PoolId _pid,
        IUniswapV4Router04 _router,
        IPoolManager _manager,
        MockRandomnessProvider _randomness
    ) {
        hook = _hook;
        poolKey = _key;
        poolId = _pid;
        router = _router;
        manager = _manager;
        randomness = _randomness;
    }

    function approveAll() external {
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(router), type(uint256).max);
    }

    function placeProtected(bool zeroForOne, uint96 amountRaw) external {
        uint256 amountIn = bound(uint256(amountRaw), 1e9, 20e18);
        router.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: abi.encode(uint8(0), address(this)),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        if (zeroForOne) ghostOwed0 += amountIn;
        else ghostOwed1 += amountIn;
        orders.push(Order({blockNumber: uint64(block.number), zeroForOne: zeroForOne, closed: false}));
    }

    function instantSwap(bool zeroForOne, uint96 amountRaw) external {
        uint256 amountIn = bound(uint256(amountRaw), 1e9, 2e18);
        router.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: abi.encode(uint8(1)),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function rollBlocks(uint8 n) external {
        vm.roll(block.number + bound(uint256(n), 1, 12));
    }

    function closeAndSettle(uint64 word) external {
        (uint64 epochStart,, WickHook.Phase phase,,,,,,) = hook.pools(poolId);
        if (phase != WickHook.Phase.Open || epochStart == 0) return;
        if (block.number <= epochStart + hook.maxSpan() - 1) return;

        hook.requestClose(poolKey);
        (,, phase,,,,,,) = hook.pools(poolId);
        if (phase != WickHook.Phase.Drawing) return; // empty window relit, nothing drawn

        randomness.fulfill(randomness.lastRequestId(), word);

        (, uint64 close,,,,,,,) = hook.pools(poolId);
        if (close < epochStart + hook.minSpan() - 1 || close > epochStart + hook.maxSpan() - 1) {
            ghostCloseOutOfRange = true;
        }

        hook.settle(poolKey);

        (,,, uint40 epochCount,,,,,) = hook.pools(poolId);
        for (uint40 e = lastAccountedEpoch + 1; e <= epochCount; e++) {
            (,, uint128 in0, uint128 in1, uint128 out1For0, uint128 out0For1, uint128 refund0, uint128 refund1) =
                hook.epochs(poolId, e);
            if (refund0 > in0 || refund1 > in1) ghostConservationBroken = true;
            // Custodied inputs become recorded outputs and refunds.
            ghostOwed0 = ghostOwed0 - in0 + out0For1 + refund0;
            ghostOwed1 = ghostOwed1 - in1 + out1For0 + refund1;
        }
        lastAccountedEpoch = epochCount;
    }

    function cancelOrder(uint256 seed) external {
        uint256 idx = _pickOpen(seed);
        if (idx == type(uint256).max) return;
        Order storage o = orders[idx];
        if (hook.epochOfBlock(poolId, o.blockNumber) != 0) return; // settled, cannot cancel

        uint256 id = hook.orderId(poolId, o.blockNumber, o.zeroForOne);
        uint256 bal = hook.balanceOf(address(this), id);
        if (bal == 0) {
            o.closed = true;
            return;
        }

        try hook.cancel(poolKey, o.blockNumber, o.zeroForOne) {
            if (o.zeroForOne) ghostOwed0 -= bal;
            else ghostOwed1 -= bal;
            o.closed = true;
        } catch {
            // Phase forbids cancel right now. Fine, try again later.
        }
    }

    function redeemOrder(uint256 seed) external {
        uint256 idx = _pickOpen(seed);
        if (idx == type(uint256).max) return;
        Order storage o = orders[idx];
        if (hook.epochOfBlock(poolId, o.blockNumber) == 0) return; // not settled yet
        if (hook.balanceOf(address(this), hook.orderId(poolId, o.blockNumber, o.zeroForOne)) == 0) {
            o.closed = true;
            return;
        }

        uint256 bal0 = poolKey.currency0.balanceOf(address(this));
        uint256 bal1 = poolKey.currency1.balanceOf(address(this));
        hook.redeem(poolKey, o.blockNumber, o.zeroForOne, address(this));
        ghostOwed0 -= poolKey.currency0.balanceOf(address(this)) - bal0;
        ghostOwed1 -= poolKey.currency1.balanceOf(address(this)) - bal1;
        o.closed = true;
    }

    function _pickOpen(uint256 seed) internal view returns (uint256) {
        uint256 n = orders.length;
        if (n == 0) return type(uint256).max;
        uint256 first = seed % n;
        for (uint256 i = 0; i < n; i++) {
            uint256 idx = (first + i) % n;
            if (!orders[idx].closed) return idx;
        }
        return type(uint256).max;
    }
}
