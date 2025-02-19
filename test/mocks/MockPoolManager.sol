// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

contract MockPoolManager {
    struct Slot0Data {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 protocolFee;
        uint16 swapFee;
    }

    mapping(PoolId => Slot0Data) public slots;

    function setSlot0Data(PoolId poolId, uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint16 swapFee)
        external
    {
        slots[poolId] = Slot0Data({sqrtPriceX96: sqrtPriceX96, tick: tick, protocolFee: protocolFee, swapFee: swapFee});
    }

    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint16, uint16) {
        Slot0Data memory data = slots[poolId];
        return (data.sqrtPriceX96, data.tick, data.protocolFee, data.swapFee);
    }
}
