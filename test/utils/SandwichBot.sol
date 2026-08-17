// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

/// @notice A textbook sandwich attacker for tests: front-run in the victim's
/// direction, let the victim swap, then back-run the opposite way. Against a vanilla
/// pool this nets a profit. Against Wick's protected lane the victim never touches the
/// curve, so the front-run and back-run round-trip at a loss (fees plus spread).
contract SandwichBot {
    IUniswapV4Router04 public immutable router;

    constructor(IUniswapV4Router04 _router) {
        router = _router;
    }

    /// @notice Front-run leg: buy the same direction as the victim.
    function frontRun(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return router.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    /// @notice Back-run leg: sell everything gained back the other way.
    function backRun(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return router.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: hookData,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function balance(Currency c) external view returns (uint256) {
        return c.balanceOf(address(this));
    }
}
