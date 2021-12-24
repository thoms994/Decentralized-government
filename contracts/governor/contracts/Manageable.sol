/// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../../token/interfaces/IERC20Metadata.sol";

/**
        Manageable manage the vote system.

        Keep in mind that we do not track user votes, we only keep track of user choices, the candidates chosen by the users (address(0) by default). 
        And when they transfer their tokens, the amount transferred is subtracted from the candidates vote pool to be added to the recipient candidates vote pool.

        Vote path: the sender transfers his tokens to the receiver, when the transfer starts we lock the votes of the sender and the receiver so that they don't change 
        their choices during the transfer, after what we check that the sender has enough funds in his balance and we start transferring the votes from the sender 
        to the receiver, then we transfer the tokens from the sender to the receiver. If all goes well, the vote is unlocked for both the sender and the receiver.

        During the vote transfer, we ignore operation on choices that point to the address(0).
        We do not transfer the fee-related vote to the tax recipient's choice, thus saving gas cost, and we restrict the fee's recipient (RouterController) so that 
        it cannot change its choice otherwise it would cause underflows and overflows.

        Restricted addresses are not locked during voting because they cannot use changeChoice and therefore cannot conflict with voting.

        A restricted address cannot be unrestricted, 10 addresses every 10 days can be restricted.
        The fact that the President can disturbe the vote by restricting the challenger's high-positioned vote is not considered as a problem because it is easy to bypass.
        We just need some addresses to be restricted. And other methods are no more effective when you look at all the use cases for this contract.
        Addresses are not unrestrictable due to the underflow from fee votes. The recipient of the fee (currently the router controller) should always be restricted because
        we increase its balance during the token transfer without transferring votes.

        When the contract is deployed a monarchy takes effect during a specific time, no one can claim the position of the president. And the President receives all the fees.
        This period of time is used to wait for the government to take place.

        Four positions are claimable : Executive, Legislative, Judicial, President.
        Anyone can candidate for one or multiple positions in order to claim the fees related to the position.

        The President has full rights over the fees distribution.

        Some tasks must be automated such as exchanging a token for eth in the router controller for every X tokens held by the router controller contract.
        Automated tasks are performed by web tools like "Defender": https://openzeppelin.com/defender/
        For this reason, each automated function must be limited to the Automaton address that can be modified by the current president.
        All presidents who take over position must handle the exchange of tokens for eth themselves.

        LEGISLATIVE: The legislative branch is responsible for enacting the laws.
        EXECUTIVE: The executive branch is responsible for implementing and administering the public policy enacted by the legislative branch.
        JUDICIAL: The judicial branch is responsible for interpreting the constitution and laws and applying their interpretations to controversies brought before it.
        PRESIDENT: Leads the branchs and appropriating the money necessary to operate the system.

        Law and lawChoice are used to vote on the law. When a proposal is made, it is sufficient to indicate the address of the law and the choice identified by a number.
        We use the addresses as a reference in candidates mapping for simplicity.

        -People can decide to swap the president and the legislature if they don't want the president to manage the fees.
        -They can also vote for a contract that would take the fees and redistribute them to the holders.
        -There's no limit...

 */
abstract contract Manageable {

    /// @notice LEGISLATIVE The legislative branch is responsible for enacting the laws.
    uint256 constant internal LEGISLATIVE = 0;

    /// @notice EXECUTIVE The executive branch is responsible for implementing and administering the public policy enacted by the legislative branch.
    uint256 constant internal EXECUTIVE = 1;

    /// @notice JUDICIAL The judicial branch is responsible for interpreting the constitution and laws and applying their interpretations to controversies brought before it.
    uint256 constant internal JUDICIAL = 2;

    /// @notice PRESIDENT Leads the branchs and appropriating the money necessary to operate the system.
    uint256 constant internal PRESIDENT = 3;

    /// @notice Power elected
    /// @custom:variable legislative The legislative branch is responsible for enacting the laws.
    /// @custom:variable executive The executive branch is responsible for implementing and administering the public policy enacted by the legislative branch.
    /// @custom:variable judicial The judicial branch is responsible for interpreting the constitution and laws and applying their interpretations to controversies brought before it.
    /// @custom:variable president Leads the branchs and appropriating the money necessary to operate the system.
    /// @custom:variable law Law's address.
    /// @custom:variable lawChoice's index.
    struct Choices { 
        address legislative;
        address executive;
        address judicial;

        address president;

        address law;
        uint256 lawChoice;
    }

    /// @notice Token address.
    IERC20Metadata internal TOKEN;

    /// @notice Memebers elected.
    Choices internal _electedMembers;

    /// @notice Number of restrictions given at each reset.
    uint256 constant private NUMBER_OF_RESTRICTION = 10;

    /// @notice Days before resetting the number of restrictions.
    uint256 constant private DAY_BEFORE_RESET_RESTRICTION_COUNT = 10 days;

    /// @notice Number of restrictions available.
    /// @dev Address restricted can't change their choices.
    uint256 private _restrictionCount;

    /// @notice Date when the position of President would be available to be claimed.
    uint256 internal _dateOfTheRevolution;

    /// @notice Date when the number of available restrictions can be reset to 10.
    uint256 private _dateRestrictionReset;

    /// @notice Address defined by the president, used to call function on router controller.
    address private _automate;

    /// @notice Mapping candidate with their votes. candidate => (position => votes).
    mapping(address => mapping(uint256 => uint256)) private _candidate;

    /// @notice Mapping electors with their choices.
    mapping(address => Choices) private _electorChoices;

    /// @notice Set to true if an electors is currently voting or transferring their tokens.
    mapping(address => bool) internal _isVoting;

    /// @notice Address that can't change their choices.
    mapping(address => bool) internal _isRestricted;

    /// @notice Notify the abolition of the monarchy.
    /// @param date Date of the abolition.
    event Abolition(uint256 date);

    /// @notice Notify the tapresident of position.
    /// @param position Position claimed.
    /// @param newElected Address of the newly elected.
    event PositionClaimed(uint256 position, address newElected);

    /// @notice Notify when an address is restricted.
    /// @param adr Address restriced.
    event AddressRestricted(address adr);

    /// @notice Lock the caller's vote during the voting process.
    /// @custom:require 1 The caller of the function must not be by changing their choices or transferring tokens (because it trigger lockVoteFromTo).
    modifier lockVote(address adr) {
        require(!_isVoting[adr], "Currently voting");
        
        _isVoting[adr] = true;
        _;
        _isVoting[adr] = false;
    }

    /// @notice Restrict the sender and receiver from transferring a token and changing their vote at the same time.
    /// @dev Restricted addresses cannot change their choice and therefore do not need to be locked.
    /// @custom:require 1 Sender of the transfer should not be in a voting process.
    /// @custom:require 2 Receiver of the transfer should not be in a voting process.
    modifier lockVoteFromTo(address from, address to) {
        require(!_isVoting[from], "ERC20: transfer from the zero address");
        require(!_isVoting[to], "ERC20: transfer to the zero address");

        if (!_isRestricted[from]) _isVoting[from] = true;
        if (!_isRestricted[to]) _isVoting[to] = true;
        _;
        _isVoting[from] = false;
        _isVoting[to] = false;
    }

    /// @notice Allow access only from the President's address.
    /// @custom:require 1 Restricted to the President.
    modifier onlyPresident(){
        require(_electedMembers.president == msg.sender, "Only President");
        _;
    }
    
    /// @notice Ending the monarchy by allowing anyone to run for the President's position.
    /// @custom:require 1 Require to be in monarchy periode.
    /// @custom:event Abolition Notify the end of the monarchy.
    function abolitionOfTheMonarchy() 
    external 
    onlyPresident
    {
        require(!isRepublic(), "Require monarchy");

        _dateOfTheRevolution = block.timestamp; 

        emit Abolition(_dateOfTheRevolution);
    }

    /// @notice Candidates must claim their position in order to withdraw fees and be recognized as such.
    /// @custom:require To claim the presidency, the monarchy must be abolished.
    /// @custom:event PositionClaimed Notifiy when a position has been taken.
    function claimPower() external {
        require(msg.sender != address(0));

        if (_candidate[msg.sender][LEGISLATIVE] > _candidate[_electedMembers.legislative][LEGISLATIVE]){
            _electedMembers.legislative = msg.sender;

            emit PositionClaimed(LEGISLATIVE, msg.sender);
        }

        if (_candidate[msg.sender][EXECUTIVE] > _candidate[_electedMembers.executive][EXECUTIVE]) {
            _electedMembers.executive = msg.sender;

            emit PositionClaimed(EXECUTIVE, msg.sender);
        }

        if (_candidate[msg.sender][JUDICIAL] > _candidate[_electedMembers.judicial][JUDICIAL]){
            _electedMembers.judicial = msg.sender;

            emit PositionClaimed(JUDICIAL, msg.sender);
        }

        if (isRepublic() && _candidate[msg.sender][PRESIDENT] > _candidate[_electedMembers.president][PRESIDENT]){
            _electedMembers.president = msg.sender;

            emit PositionClaimed(PRESIDENT, msg.sender);
        }
    }    

    /// @notice Get voter's choices.
    /// @param elector Elector address.
    /// @return legislative Legislataive's address choice.
    /// @return executive Executive's address choice.
    /// @return judicial Judicial's address choice.
    /// @return president President's address choice.
    /// @return law Law's address.
    /// @return lawChoice Law choice.
    function getChoices(address elector) external view returns (address, address, address, address, address, uint256){
        return (_electorChoices[elector].legislative, 
            _electorChoices[elector].executive, 
            _electorChoices[elector].judicial, 
            _electorChoices[elector].president, 
            _electorChoices[elector].law, 
            _electorChoices[elector].lawChoice
        );
    }

    /// @notice Change elector's choices.
    /// @dev We do not process votes on address(0), we simply ignore them.
    /// @param newLegislative New Legislative choice.
    /// @param newExecutive New Executive choice.
    /// @param newJudicial New Judicial choice.
    /// @param newPresident New President choice.
    /// @param newLaw New Law.
    /// @param newLawChoice New law choice.
    /// @custom:require Don't allow restricted address.
    /// @custom:event NewChoice Notify when an elector change his choices.
    function setChoices(
        address newLegislative, 
        address newExecutive, 
        address newJudicial, 
        address newPresident, 
        address newLaw,
        uint256 newLawChoice
        ) 
    external
    lockVote(msg.sender)
    returns (bool)
    {
        require(!_isRestricted[msg.sender], "Address restricted");

        Choices memory choice = _electorChoices[msg.sender];
        uint256 amount = TOKEN.balanceOf(msg.sender);

        unchecked {
            _candidate[choice.legislative][LEGISLATIVE] -= amount;
            _electorChoices[msg.sender].legislative = newLegislative;
            _candidate[newLegislative][LEGISLATIVE] += amount;

            _candidate[choice.executive][EXECUTIVE] -= amount;
            _electorChoices[msg.sender].executive = newExecutive;
            _candidate[newExecutive][EXECUTIVE] += amount;

            _candidate[choice.judicial][JUDICIAL] -= amount;
            _electorChoices[msg.sender].judicial = newJudicial;
            _candidate[newJudicial][JUDICIAL] += amount;

            _candidate[choice.president][PRESIDENT] -= amount;
            _electorChoices[msg.sender].president = newPresident;
            _candidate[newPresident][PRESIDENT] += amount;

            _candidate[choice.law][choice.lawChoice] -= amount;
            _electorChoices[msg.sender].law = newLaw;
            _electorChoices[msg.sender].lawChoice = newLawChoice;
            _candidate[newLaw][newLawChoice] += amount;
        }        

        return true;
    }
    
    /// @notice Restrict an address to prevent it from changing its choices.
    /// @param adr Address to restrict.
    /// @custom:modifier onlyPresident Only the president can restrict address.
    function setRestrict(address adr) 
    external 
    onlyPresident 
    { 
        _restrictAddress(adr); 
    }

    /// @notice Check is address is restricted.
    /// @param adr Address to check.
    /// @return bool True if the address passed in parameter is restricted.
    function isRestricted(address adr) external view returns (bool) { return _isRestricted[adr]; }

    /// @notice Change the Automate's address
    /// @param newAutomate New automate's address.
    /// @custom:modifier onlyPresident Only the President can change the Automate's address.
    /// @custom:event NewAutomate Notify of the new Automate's address.
    function setAutomate(address newAutomate) external onlyPresident { _automate = newAutomate; }

    /// @notice Get law's choice amount.
    /// @param adr Address make reference to a candidat or a law.
    /// @param index index make reference to a Power or a law choice.
    function getVotes(address adr, uint256 index) external view returns (uint256) {  return _candidate[adr][index]; }
    
    /// @notice Date of the revolution.
    /// @return uint256 Date of the revolution.
    function getRevolutionDate() external view returns (uint256){ return _dateOfTheRevolution; }

    /// @notice Current elected member.
    /// @notice return legislative.
    /// @notice return executive.
    /// @notice return judicial.
    /// @notice return president.
    function getElectedMembers() public view returns (address, address, address, address){
        return (_electedMembers.legislative, _electedMembers.executive, _electedMembers.judicial, _electedMembers.president);
    }

    /// @notice Current President's address.
    /// @return Address of the current President.
    function getPresident() public view returns (address){ return _electedMembers.president; }

    /// @notice Current Automate's address.
    /// @return Address of the current Automate.
    function getAutomate() public view returns (address){ return _automate; }
    
    /// @notice Return true if we'r no longer in the monarchy time.
    function isRepublic() public view returns (bool){ return _dateOfTheRevolution < block.timestamp; }

    /// @notice Transfer vote from the sender to the recipient of a token transfer.
    /// @dev We do not perform action on address(0).
    /// @param from Sender's address.
    /// @param to Recipient's address.
    /// @param fee Token substract from the transaction and added to the feeRecipient balance (RouterController).
    /// @custom:require lockVoteFromTo must be called on functions that call this function.
    /// @custom:detail If "from" and "to" have the same choice and choice is different from address(0) just remove votes related to fee from the choice.
    function _transferVote(address from, address to, uint256 amount, uint256 fee) internal {    

        Choices memory choiceFrom = _electorChoices[from];
        Choices memory choiceTo = _electorChoices[to];
        uint256 amountHF = amount - fee;

        unchecked {
            _candidate[choiceFrom.legislative][LEGISLATIVE] -= amount;
            _candidate[choiceTo.legislative][LEGISLATIVE] += amountHF;

            _candidate[choiceFrom.executive][EXECUTIVE] -= amount;
            _candidate[choiceTo.executive][EXECUTIVE] += amountHF;

            _candidate[choiceFrom.judicial][JUDICIAL] -= amount;
            _candidate[choiceTo.judicial][JUDICIAL] += amountHF;

            _candidate[choiceFrom.president][PRESIDENT] -= amount;
            _candidate[choiceTo.president][PRESIDENT] += amountHF;

            _candidate[choiceFrom.law][choiceFrom.lawChoice] -= amount;
            _candidate[choiceTo.law][choiceTo.lawChoice] += amountHF;
        }        
    }
    
    /// @notice Restrict an address to prevent it from changing its choices.
    /// @dev An address can't be unrestricted. _restrictionCount is initialized at the first call of this function.
    /// @param adr Address to restrict.
    /// @custom:modifier lockVote Used to avoid conflict with change choice.
    /// @custom:require 1 Require to have enough Restriction available or reached the reset delay.
    function _restrictAddress(address adr) 
    internal    
    lockVote(adr) 
    {
        if (_dateRestrictionReset <= block.timestamp){
            _dateRestrictionReset = block.timestamp + DAY_BEFORE_RESET_RESTRICTION_COUNT;
            _restrictionCount = NUMBER_OF_RESTRICTION;
        }

        require(_restrictionCount != 0, "No restriction credit");

        _restrictionCount -= 1;        

        _isRestricted[adr] = true;

        uint256 amount = TOKEN.balanceOf(adr);
        Choices memory choices = _electorChoices[adr];

        _candidate[choices.legislative][LEGISLATIVE] -= amount;
        _candidate[choices.executive][EXECUTIVE] -= amount;
        _candidate[choices.judicial][JUDICIAL] -= amount;
        _candidate[choices.president][PRESIDENT] -= amount;
        _candidate[choices.law][choices.lawChoice] -= amount;

        delete  _electorChoices[adr];

        emit AddressRestricted(adr);
    }
}