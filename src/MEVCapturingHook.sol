// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

struct PoolConfig {
    uint256 feeUnit;
    uint256 priorityThreshold;
}

contract MEVCapturingHook is BaseHook, Ownable {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    error MustUseDynamicFee();

    uint256 public constant DEFAULT_FEE_UNIT = 1 wei; // ?? this is too low
    uint256 public constant DEFAULT_PRIORITY_THRESHOLD = 10 wei; // ?? this is too low

    mapping(PoolId => PoolConfig) poolConfig;
    mapping(PoolId => uint256) lastTradedBlock;

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager, address _initialOwner) BaseHook(_manager) Ownable(_initialOwner) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
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

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        poolConfig[key.toId()] = PoolConfig(DEFAULT_FEE_UNIT, DEFAULT_PRIORITY_THRESHOLD);

        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // take a fee based on the priority fee
        // and donate it to LP

        uint256 priorityFee = _getPriorityFee();

        if (priorityFee < poolConfig[key.toId()].priorityThreshold || block.number == lastTradedBlock[key.toId()]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        lastTradedBlock[key.toId()] = block.number;
        uint256 fee = priorityFee * poolConfig[key.toId()].feeUnit;

        if (params.zeroForOne) {
            poolManager.donate(key, fee, 0, "");
        } else {
            poolManager.donate(key, 0, fee, "");
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _getPriorityFee() internal view returns (uint256) {
        return tx.gasprice - block.basefee;
    }

    function setConfig(PoolId pool, PoolConfig memory config) public onlyOwner {
        poolConfig[pool] = config;
    }
}
