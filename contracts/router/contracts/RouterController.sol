/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "./RouterManager.sol";
import "../../fee/contracts/FeeController.sol";
import "../../fee/contracts/FeeManager.sol";
import "../../token/contracts/Token.sol";

/**
    Router is used to exchange token for eth.
    When eth are withdrawn from this contract, it adds the percentage reserved for liquidity
    to the liquidity pool by swaping back half of the eth allocated into tokens.

    This contract has to be exculde from fee.
*/
contract RouterController is RouterManager {

    /// @notice Fee manager contract.
    FeeManager immutable private FEE_MANAGER;

    /// @notice FeeController contract.
    FeeController immutable private FEE_CONTROLLER;

    /// @notice Notify distribution of fees between liquidity and feeController.
    event SwapLiquifyAndTransferFee(uint256 liquidityAmount, uint256 electedShare);

    /// @notice Init contract and passes parameters to RouterManager.
    /// @param token Token.sol contract address.
    /// @param router Router contract address Uniswap.
    constructor(address payable token, address router) {
        TOKEN = Token(token);
        FEE_MANAGER = FeeManager(token);
        FEE_CONTROLLER = FeeController(token);

        MANAGEABLE = Manageable(token);

        IRouter _pancakeRouter = IRouter(router);
        PAIR = IFactory(_pancakeRouter.factory()).createPair(address(this), _pancakeRouter.WETH());
        ROUTER = _pancakeRouter;

        _pathTokenToEth = new address[](2);
        _pathTokenToEth[0] = address(token);
        _pathTokenToEth[1] = ROUTER.WETH();
    }

    /// @notice Swap token in eth transfer a part to feeController and other to liquidity.
    /// @dev This is the minimum amount to be transferred, not the contract balance. We have Elected and liquidity share if one of both is different from zero 
    /// and less than the minimum amount to process fees the function revert.
    /// @custom:modifier onlyAutomate Automate.
    /// @custom:modifier lockTheSwap Avoid reentrency.
    /// @custom:require 1 Amount must be greater or equals than than the amount to process fee.
    function swapLiquifyAndTransferFees() 
    external  
    onlyAutomate 
    lockTheSwap 
    {
        require(TOKEN.balanceOf(address(this)) >= _amountToProcessFees, "Amount to low");
        
        TOKEN.approve(address(ROUTER), TOKEN.balanceOf(address(this)));

        (uint256 electedShare, uint256 liquidityAmount) = getLiquidityShare(_amountToProcessFees);

        if (electedShare != 0) _swapExactTokensForETHSupportingFeeOnTransferTokens(payable (address(TOKEN)), electedShare);

        if(liquidityAmount != 0){
            uint256 halfToken = liquidityAmount / 2;
            uint256 halfToSwap = liquidityAmount - halfToken;
            
            _swapExactTokensForETHSupportingFeeOnTransferTokens(payable (address(this)), halfToSwap);
            
            _addLiquidity(halfToken, address(this).balance);
        }

        emit SwapLiquifyAndTransferFee(liquidityAmount, electedShare);
    }
    
    /// @notice Function that receive ETH. 
    /// @dev Needed for swap and liquify
    receive() external payable { }

    /// @notice Extract the liquidity share of an amount.
    /// @param amount Amount on which the share due to liquidity is subtracted.
    /// @return amountHF Amount without the share due to the liquidity pool.
    /// @return liquidity Share due to liquidity pool.
    function getLiquidityShare(uint256 amount) internal view returns(uint256 amountHF,uint256 liquidity){
        uint256 feeValue  = FEE_MANAGER.getFeeValue(4);
        uint256 sumOfFee = FEE_MANAGER.getSumOfFee();
        liquidity = (amount * feeValue) / sumOfFee;
        amountHF = amount - liquidity;

        return (amountHF, liquidity);
    }

    /// @notice Swap token for eth supporting fee on Transfer.
    /// @param recipient Address that receive the eth.
    /// @param amount Amount exchanged in eth.
    /// @custom:doc Uniswap https://docs.uniswap.org/protocol/V2/reference/smart-contracts/router-02#swapexacttokensforethsupportingfeeontransfertokens
    function _swapExactTokensForETHSupportingFeeOnTransferTokens(address payable recipient, uint256 amount) private {
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 
            0, 
            _pathTokenToEth, 
            recipient, 
            block.timestamp 
        );
    }

    /// @notice Add liquidity to the pool, half eth, half token.
    /// @dev To cover all possible scenarios we give an allowance of the amount to the router.
    /// @param amountToken Amount of token added to the pool.
    /// @param amountETH Amount of eth added to the pool.
    /// @custom:doc Uniswap https://docs.uniswap.org/protocol/V2/reference/smart-contracts/router-02#addliquidityeth
    function _addLiquidity(uint256 amountToken, uint256 amountETH) private {
        ROUTER.addLiquidityETH
        {
            value: amountETH
        }
        (
            address(TOKEN), 
            amountToken, 
            0, 
            0, 
            address(TOKEN), 
            block.timestamp 
        );
    }
}