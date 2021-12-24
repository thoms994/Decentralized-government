/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../interfaces/IFactory.sol";
import "../interfaces/IRouter.sol";
import "../../governor/contracts/Manageable.sol";
import "../../token/contracts/Token.sol";

/**    
    The router manager initiates the interface to access UniswapV2Router02 and create the Token/ETH pair.
    It also creates a path array to let the router know if we want to exchange a token for an eth or an eth for a token.    
*/
abstract contract RouterManager {

    /// @notice ERC20 token interface.
    Token internal TOKEN;

    /// @notice Router's interface.
    IRouter internal ROUTER;    

    /// @notice Manageable contract.
    Manageable internal MANAGEABLE;

    /// @notice Set to true to lock the pool process.
    bool internal _inThePoolFillingProcess;

    /// @notice Minimum amount require to process fee transfer.
    uint256 internal _amountToProcessFees;

    /// @notice token/eth Pair's address.
    address internal PAIR;

    /// @notice Path to swap token in eth.
    address[] internal _pathTokenToEth;

    /// @notice Allow access to Automate only.
    /// @custom:require 1 Allow access to Auomate only
    modifier onlyAutomate {        
        require(MANAGEABLE.getAutomate() == msg.sender, "Only Automate");
        _;
    }

    /// @notice Allow access to President only.
    /// @custom:require 1 Allow access to President only
    modifier onlyPresident {
        require(MANAGEABLE.getPresident() == msg.sender, "Only President");
        _;
    }

    /// @notice Lock Swap and liquify.
    /// @custom:require Lock swap
    modifier lockTheSwap {
        require(!_inThePoolFillingProcess, "Swap locked");

        _inThePoolFillingProcess = true;
        _;
        _inThePoolFillingProcess = false;
    }
    
    /// @notice Set amount to swap and liquify
    /// @dev This is the amount to be transferred, not the contract balance. We have Elected and liquidity share if one of both is different from zero 
    /// and less than the amount to process fees the function swapLiquifyAndTransferFees() revert.
    /// @param amount Amount.
    /// @custom:modifier onlyPresident Only Accessible to President's address.
    function setAmountToProcessFees(uint256 amount) external onlyPresident { _amountToProcessFees = amount * 10**TOKEN.decimals(); }

    /// @notice Return the amount of fees require to swap transfer and liquify fees.
    /// @return uint256 amount of token. 
    function getAmountToProcessFees() external view returns (uint256) { return _amountToProcessFees; }

    /// @notice Return Pair's address.
    function getPairAddress() external view returns (address) { return PAIR; }
}