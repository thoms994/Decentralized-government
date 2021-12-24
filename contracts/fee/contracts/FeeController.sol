/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "./FeeManager.sol";
import "../../governor/contracts/Manageable.sol";

/**
    Fee Controller manage fee distribution.        
 */
abstract contract FeeController is FeeManager {

    /// @notice Notify the withdrawal of fees from the router.
    event AmountOfEthReceived(address from, uint256 value);

    /// @notice Notify when parties withdraw their fees.
    /// @param position Which branch withdraws.
    event ShareWithdraw(uint256 position, uint256 amount);

    /// @notice Function that receive ETH.
    receive() external payable {
        _totalFeeReceived += msg.value;

        emit AmountOfEthReceived(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH from this contract.
    /// @custom:modifier onlyPresident Only the President can withdraw.
    /// @custom:modifier lockTransfer Prevent from other function to conflict.
    function withdraw() 
    external 
    onlyPresident 
    lockTransfer 
    {
        payable (msg.sender).transfer(address(this).balance);
        address payable t = payable(msg.sender);
        t.transfer(address(this).balance);
        _resetFee();
    }

    /// @notice Used by members to withdraw their share in eth.
    /// @param branch Sender position in the gouvernement. LEGISLATIVE, EXECUTIVE, JUDICIAL, PRESIDENT
    function withdrawFee(uint256 branch) external {
        (address legislative, address executive, address judicial, address president) = getElectedMembers();

        if (branch == LEGISLATIVE && legislative == msg.sender) _calculateAndSendPayment(LEGISLATIVE);
        if (branch == EXECUTIVE && executive == msg.sender) _calculateAndSendPayment(EXECUTIVE);
        if (branch == JUDICIAL && judicial == msg.sender) _calculateAndSendPayment(JUDICIAL);
        if (branch == PRESIDENT && president == msg.sender) _calculateAndSendPayment(PRESIDENT);
    }

    /// @notice Calculate and return the amount of fee from a transfer.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param amount Amount of tokens transfered.
    /// @return fee Amount of tokens charged on the transfer.
    /// @custom:condition if one of the parts is exclude from fee we return 0.
    function _getFeeAmount(address from, address to, uint256 amount) internal view returns (uint256){
        if (_isExcludeFromFees[from] || _isExcludeFromFees[to]) return 0;

        return amount * _sumOfFee / FEE_DIVISOR;
    }
    
    /// @notice Calculate and send the share amount.
    /// @param position Member position "EXECUTIVE, LEGISLATIVE, JUDICIAL, PRESIDENT".
    /// @custom:modifier lockTransfer Lock transfer.
    /// @custom:event ShareWithdraw Notify when parties withdraw their fees.
    /// @custom:info payment Total eth receive by this contract multiply by the share of the Elected concerned divide by the sum of all Elected share 
    /// @custom:test This function is tested by withdrawFee.
    /// minus what he already received from all former calls.
    function _calculateAndSendPayment(uint256 position) 
    private 
    lockTransfer
    {
        if (_fees[position].value == 0) return;

        uint256 payment = (_totalFeeReceived * _fees[position].value) 
            / (_sumOfFee - _fees[LIQUIDITY_INDEX].value)
            - _fees[position].alreadyReceived;

        _fees[position].alreadyReceived += payment;
        payable (msg.sender).transfer(payment);

        emit ShareWithdraw(position, payment);
    }
}