//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IExchange {
    function swap(
        uint256 amountA,
        address tokenA,
        address tokenB,
        address to
    ) external returns (uint256 amountReceived);
}
