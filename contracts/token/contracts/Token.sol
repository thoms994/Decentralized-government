/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Metadata.sol";
import "../../governor/contracts/Manageable.sol";
import "../../fee/contracts/FeeController.sol";
import "../../fee/contracts/FeeManager.sol";

/**
    Token contract is similar to an ERC20 but it takes fee during the transfer.
    Fee are send to the router's address and exchanged by eth before a sale occurs and when the pair's address is not the seller.
    Vote are transferred each time a transfer occurs.
    Sender's votes are substracted from the sender's choices and added to the reicever's choices. See: Manageable.sol.

    Router controller address can't be change during Monarchy time but for interoperability purpose we need to ba able to change it.
    By this fact we perform swap between token and eth by calling a function outside the blockchain.
    Every time the router reach an amount of token a swap is perform by calling the function on router
 */
contract Token is FeeController, IERC20Metadata {

    ///@notice Balance of each holder.
    mapping(address => uint256) private _balances;

    ///@notice Amount that an entity are autorized to spend from the holder's balance.
    mapping(address => mapping(address => uint256)) private _allowances;

    ///@notice Decimale of the current token.
    uint8 private constant DECIMALS = 18;

    ///@notice Total supply 1 000 trillion
    uint256 private constant TOTAL_SUPPLY = 1_000_000_000_000_000 * 10**DECIMALS;

    ///@notice Name and symbol of the token, can be change by president.
    string private _name = "Token";
    string private _symbol = "TOKEN";

    /// @notice Token name change.
    event NameSymbolUpdated(string newName);

    /// @dev Init contract
    /// @param monarchyPeriodeTime Time during which than president power can not be claimed.
    /// @custom:require monarchyPeriodeTime must be less than 365 days.
    constructor(uint256 monarchyPeriodeTime, address legislative, address executive, address judicial, address president)
    {
        require(monarchyPeriodeTime <= 365, "Monarchy to long");

        TOKEN = IERC20Metadata(payable (address(this)));

        uint256 dayInSecond = 1 days;
        _dateOfTheRevolution = block.timestamp + monarchyPeriodeTime * dayInSecond;
        
        _electedMembers.legislative = legislative;
        _electedMembers.executive = executive;
        _electedMembers.judicial = judicial;
        _electedMembers.president = president;
        
        _isVoting[address(0)] = true;
        
        _balances[msg.sender] = TOTAL_SUPPLY;
    }

    /// @notice Get the Token name.
    /// @return string Token name
    function name() public view virtual override returns (string memory) { return _name; }
    
    /// @notice Get the Token symbol.
    /// @return string Token symbol
    function symbol() public view virtual override returns (string memory) { return _symbol; }
    
    /// @notice Get the Token decimal.
    /// @return string Token decimal
    function decimals() public view virtual override returns (uint8) { return DECIMALS; }
    
    /// @notice Get the Token total supply.
    /// @return string Token total supply
    function totalSupply() public view virtual override returns (uint256) { return TOTAL_SUPPLY; }

    /// @notice Update Token name and/or symbol.
    /// @custom:modifier onlyPresident Only the President is able to update the name.
    /// @custom:event NameSymbolUpdated Notify update on name and/or symbol.
    function setNameSymbol(string memory newName, string memory newSymbol) 
    public 
    virtual 
    onlyPresident 
    {
        _name = newName;
        _symbol = newSymbol;

        emit NameSymbolUpdated(newName); 
    }

    /// @notice Returns the amount of tokens an address holds.
    /// @param account Address holding tokens.
    /// @return uint256 Amount of tokens held by the address.
    function balanceOf(address account) public view virtual override returns (uint256) { return _balances[account]; }

    /// @notice Transfer an amount of token from the sender to the receiver.
    /// @param recipient Address receiving the tokens.
    /// @param amount Amount of token sent to the recipient.
    /// @custom:require Sender and/or recipient can't be address(0): 0x0...0.
    /// @custom:require Sender's balance must be greater than or equals to the amount sent.
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, recipient, amount);

        return true;
    }

    /// @notice Return the amount of token an holder allow an entity to spend at his place.
    /// @param owner address which allow the spender address to spend some of its token
    /// @param spender address allowed to spend the token from the owner address
    /// @return uint256 amount allowed to be spend by the spender from the owner address
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @notice Approve an address to spend an amount of token from the caller address
    /// @param spender address allowed to spend the caller token
    /// @param amount amount allowed to be spend by the spender from the caller address
    /// @return bool true if allowance approved
    /// @custom:require Caller and/or spender can't be address(0): 0x0...0.
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(msg.sender, spender, amount);

        return true;
    }

    /// @notice Third party transfers an amount of tokens between two addresses.
    /// @param sender Address holding the tokens to send.
    /// @param recipient Address receiving the tokens.
    /// @param amount Amount transferred from sender to recipient.
    /// @return bool true if transfer success.
    /// @custom:require 1 The sender's third party allowance must be greater than or equal to the amount to be sent.
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");

        unchecked { 
            _approve(sender, msg.sender, currentAllowance - amount); 
        }

        return true;
    }

    /// @notice Transfer an amount of tokens from the sender to the receiver, subtracting fees during the process and adding them to the router balance.
    /// @param sender Address holding the tokens to send.
    /// @param recipient Address receiving the tokens.
    /// @param amount Amount transferred from sender to recipient.
    /// @custom:modifier lockVoteFromTo We restrict parts to change their vote during the transfer.
    /// @custom:require 1-2 Sender and/or recipient can't be address(0): 0x0...0.
    /// @custom:require 3 Sender balance need to be greater than or equals to the amount send.
    /// @custom:event Transfer(sender, recipient, amount) emited after balance updated before afterTransfer(...).
    /// @custom:event FeeRecipientBalance(feeRecipientBalance) amount transferred to the fee recipient, event declared in Fee Manager.
    function _transfer(address sender, address recipient, uint256 amount) 
    internal 
    virtual 
    lockVoteFromTo(sender, recipient) 
    {
        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        uint256 fee = _getFeeAmount(sender, recipient, amount);
        
        _transferVote(sender, recipient, amount, fee);

        unchecked {            
            _balances[sender] = senderBalance - amount;
            _balances[_feeRecipient] += fee;
            _balances[recipient] += amount - fee;
        }        

        emit Transfer(sender, recipient, amount);
        emit FeeRecipientBalance(_balances[_feeRecipient]);
    }

    /// @notice Set an allowance between to addresses.
    /// @param owner Address which own the tokens.
    /// @param spender Address allowed to spend the tokens.
    /// @param amount Amount authorized to be spent by the spender from the owner's address.
    /// @custom:require 1-2 Caller and/or spender can't be address(0): 0x0...0.
    /// @custom:event Approval(owner, spender, amount) new allowance approved. 
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve to the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }
}