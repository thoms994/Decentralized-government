/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../../governor/contracts/Manageable.sol";
import "../../token/interfaces/IERC20Metadata.sol";

/**
    Fee Manager Sets the fee amount for each position.
    To avoid restricting the holder from selling, the maximum fee is set at 20.
    The President has the ability to include/exclude addresses from fee.
    The fee recipient is the addresses that receives fees, it has to be exclude from fee and restricted from change is choices in Manageable.sol.

    Fee calcul: Every time an amount is sent to the RouterController, we increase the _totalFeeReceived and when a member wants to withdraw his share, 
    he takes the _totalFeeReceived, multiply by his fee value and divide the result by the sum of all members fee value and substract the amount of fee
    he already take the last time.
 */
abstract contract FeeManager is Manageable {

    /// @notice Fee details
    /// @custom:variable value Fee percent value.
    /// @custom:variable amountWithdrawable Amount withdrawable by the party attached to this fee.
    /// @custom:variable alreadyReceived Amount withdrawn since its existence.
    struct Fee {
        uint256 value;
        uint256 alreadyReceived;
    }
    
    /// @notice  True if a withdrawal is current processing.
    bool private _transferFeeOccur;

    /// @notice Maximum amount of fees that can be charged on a transfer.
    uint256 constant internal FEE_MAX = 20;

    /// @notice Used to calculate the token/fee ratio.
    /// @dev Fee are calculated on base 100, Amount transfered * sum of fee / fee divisor -> give the fee amount. 
    /// (transferAmount*_sumOfFee/FEE_DIVISOR=fee)(100*30/100=30) 30token are taken from a transfer of 100 tokens with 30% fee on the transaction.
    uint256 constant internal FEE_DIVISOR = 100;

    /// @notice index of the liquidity in the fees array.
    uint256 constant internal LIQUIDITY_INDEX = 4;

    /// @notice Sum of all fees, between (0-20).
    uint256 internal _sumOfFee;

    /// @notice Total amount of fee this contract receive.
    uint256 internal _totalFeeReceived;
    
    /// @notice List of _fees, 0->4 = 0:legislative; 1:executive; 2:judicial; 3:president; 4:liquidity;
    Fee[5] internal _fees;

    /// @notice Address for receiving fees.
    /// @dev The router controller receives the fees to facilitate the exchange.
    address internal _feeRecipient;

    /// @notice Map every addresses exclude from fee.
    /// @dev Fees should be excluded in some cases, such as when the deployer owns the entire supply and must distribute it or add to liquidity.
    mapping (address => bool) internal _isExcludeFromFees;    

    /// @notice Notify the amount in fee recipient.
    /// @param amount Current amount in the fee recipient balance.
    event FeeRecipientBalance(uint256 amount);

    /// @notice Notify in case the fee recipient changes.
    event FeeRecipient(address feeRecipient);

    /// @notice Notify when an address is excluded from the fee.
    event FeesExclusion(address excluded, bool isExclude);

    /// @notice Notify the updated fee amount.
    event UpdateFeeAmount(uint256 feeIndex, uint256 newAmount);

    /// @notice Lock the function withdrawFee() to avoid reantrancy.
    /// @custom:require 1 A transfer currently process !
    modifier lockTransfer {
        require(!_transferFeeOccur, "Transfer locked");

        _transferFeeOccur = true;
        _;
        _transferFeeOccur = false;
    }    

    /// @notice Exclude/reInclude an address from fee.
    /// @param adr Address to exclude/reInclude from fee.
    /// @custom:modifier onlyPresident Only the President can exclude an address from the fee.
    /// @custom:modifier lockExcludeList Lock access to the exclusion list to perform actions on it without conflicting.
    /// @custom:require 1 The address must not already be excluded/include.
    /// @custom:require 2 The address must not be fee recipient.
    /// @custom:event ExcludeFromFees Notify when an address is excluded from the fee.
    function feesExclusion(address adr, bool exclude) 
    external 
    onlyPresident
    {
        require(exclude != _isExcludeFromFees[adr], "Address already excluded");
        if (!exclude) require(adr != _feeRecipient, "Fee recipient can't be excluded");

        _isExcludeFromFees[adr] = exclude;
        
        emit FeesExclusion(adr, exclude);
    }

    /// @notice Update the amount of one fee.
    /// @param feeIndex Index of the fee in the list of fee.
    /// @param newAmount New ammount input to the fee.
    /// @custom:modifier onlyPresident Only President are able to update fee.
    /// @custom:modifier lockTransfer Locking the transfer when processing a change in the list of fees.
    /// @custom:require 1 The index of the fee need to be in the range, currently going from 0 to 5.
    /// @custom:require 2 The sum of fee need to be < to (maxFee = 20).
    /// @custom:event UpdateFeeAmount Notify about the new fee amount.
    function updateFeeAmount(uint256 feeIndex, uint256 newAmount) 
    external 
    onlyPresident 
    lockTransfer
    {
        require(feeIndex < _fees.length, "Index out of range");

        uint256 baseFee = _sumOfFee - _fees[feeIndex].value;
        require(baseFee + newAmount <=  FEE_MAX, "Max fee overflowed");

        _sumOfFee = baseFee + newAmount;
        _fees[feeIndex].value = newAmount;

        _resetFee();
        
        emit UpdateFeeAmount(feeIndex, newAmount);
    }

    /// @notice Change the address receiving fee from transaction.
    /// @dev The fee recipient it's generaly the router controller. We restrict the address to address(0) and to change its choices.
    /// @param feeRecipient New fee recipient address.
    /// @custom:modifier onlyPresident Only president are able to change the fee recipient.
    /// @custom:require 1 The fee recipient can't be modified during the monarchy time.
    function setFeeRecipient(address feeRecipient) 
    external 
    onlyPresident
    {
        require(_feeRecipient == address(0) || isRepublic(), "Restricted to Republic only");
        require(feeRecipient != address(0));

        _isExcludeFromFees[_feeRecipient] = false;
        _feeRecipient = feeRecipient;
        _isExcludeFromFees[feeRecipient] = true;
        _restrictAddress(feeRecipient);
        
        emit FeeRecipient(feeRecipient);
    }

    /// @notice Check if an address is excluded from fee.
    /// @param adr Address to check if exclude.
    function isExclude(address adr) external view returns(bool) { return _isExcludeFromFees[adr]; }

    /// @notice Get fee recipient.
    /// @return address Fee recipient's address.
    function getFeeRecipient() external view returns (address) { return address(_feeRecipient); }

    /// @notice Get fee value.
    /// @param index Fee index.    
    /// @custom:value 0 legislative legislative Legislative fee value.
    /// @custom:value 1 executive executive Executive fee value.
    /// @custom:value 2 judicial Judicial fee value.
    /// @custom:value 3 president President fee value.
    /// @custom:value 4 liquidity Liquidity fee value.
    /// @custom:require Index must be between [0-4].
    /// @return Value of the fee at the index passed in parameter.
    function getFeeValue(uint256 index) external view returns (uint256) { 
        require(index <= 4); 
        return _fees[index].value; 
    }

    /// @notice Get fees value
    /// @return LEGISLATIVE
    /// @return EXECUTIVE
    /// @return JUDICIAL
    /// @return PRESIDENT
    /// @return LIQUIDITY
    function getFeesValue() external view returns (uint256, uint256, uint256, uint256, uint256){
        return (
            _fees[LEGISLATIVE].value,
            _fees[EXECUTIVE].value,
            _fees[JUDICIAL].value,
            _fees[PRESIDENT].value,
            _fees[LIQUIDITY_INDEX].value
        );
    }
    
    /// @notice the current percentage of fee charged on each transaction.
    function getSumOfFee() external view returns(uint256){ return _sumOfFee; }

    /// @notice Reset the total amount of fees collected by members and contract.
    function _resetFee() internal {
        _totalFeeReceived = address(this).balance;
        _fees[LEGISLATIVE].alreadyReceived = 0;
        _fees[EXECUTIVE].alreadyReceived = 0;
        _fees[JUDICIAL].alreadyReceived = 0;
        _fees[PRESIDENT].alreadyReceived = 0;
    }
}