/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
    UniswapV2Factory is deployed at 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f
    on the Ethereum mainnet, and the Ropsten, Rinkeby, Görli, and Kovan testnets. It was built from commit 8160750.
 */
interface IFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}