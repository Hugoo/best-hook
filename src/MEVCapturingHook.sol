// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract MEVCapturingHook is BaseHook {
    IPoolManager manager;

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager) BaseHook(_manager) {
        manager = _manager;
    }

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // take a fee based on the priority fee
        // and donate it to LP


        uint256 BASE_AMOUNT = 1 wei; // ?? this is too low
        uint256 priorityFee = tx.gasprice - block.basefee;
        uint256 fee = priorityFee * BASE_AMOUNT;

        // TODO: only charge fee in first swap of the block
        // TODO: only charge dynamic fee if priority fee > some threshold

        if (params.zeroForOne) {
            manager.donate(key, fee, 0, "");
        } else {
            manager.donate(key, 0, fee, "");
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }
}
