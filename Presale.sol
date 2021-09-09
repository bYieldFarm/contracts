// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract Presale is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Maps user to the number of tokens owned
    mapping (address => uint256) public tokensOwned;
    // Maps users number of unclaimed tokens
    mapping (address => uint256) public tokensUnclaimed;

    // Maps users participation in the Private Farming for Presale Holders
    mapping (address => bool) public whitelisting;
    // Maps users allowance for Private Farming if they are whitelisted
    // All Presale Holders are entitled to 0% of their presale commitments
    // For Private Farming
    mapping (address => uint256) public whitelistAllowance;

    // BYIELD token
    IBEP20 BYIELD;
    // BUSD token
    IBEP20 BUSD;
    
    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Governs whether presale is active/inactive
    bool isSaleActive;

    // Starting timestamp normal
    uint256 startingTimeStamp;

    // Global Variables to Track Presale Metrics
    uint256 totalTokensSold = 0;
    uint256 BUSDPerToken = 10;
    uint256 busdReceived = 0;


    address payable owner;

    modifier onlyOwner(){
        require(msg.sender == owner, "You're not the owner");
        _;
    }

    // Only the operator can edit the whitelisting allowance
    address private _operator;
    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    event TokenBuy(address user, uint256 tokens);
    event TokenClaim(address user, uint256 tokens);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    constructor (address _BYIELD, address _BUSD, uint256 _startingTimestamp) public {
        BYIELD = IBEP20(_BYIELD);
        BUSD = IBEP20(_BUSD);
        isSaleActive = true;
        owner = msg.sender;
        startingTimeStamp = _startingTimestamp;
        _operator = msg.sender;
    }

    function buy (uint256 _amount, address beneficiary) public nonReentrant {

        require(isSaleActive, "Presale has not started");

        address _buyer = beneficiary;

        // Number of Purchase Tokens = BUSD Received/BUSD per token
        uint256 tokens = _amount.div(BUSDPerToken);

        // What they have owned + purchase amount must not exceed 1,000 BYIELD
        require (tokensOwned[_buyer] + tokens <= 1000 ether, "Max limit of 10,000 BUSD reached");
        
        // Ensure 500,000 BUSD Hardcap is not exceeded
        require (busdReceived +  _amount <= 500000 ether, "Presale hardcap reached");

        // Ensure that Presale has began
        require(block.timestamp >= startingTimeStamp, "Presale has not started");

        BUSD.safeTransferFrom(beneficiary, address(this), _amount);
        
        // Records User Purchase 
        tokensOwned[_buyer] = tokensOwned[_buyer].add(tokens);
        tokensUnclaimed[_buyer] = tokensUnclaimed[_buyer].add(tokens);

        // Include Users into Whitelist and increase allowance. Allowance is 60% of Commitments
        whitelisting[_buyer] = true;
        whitelistAllowance[_buyer] = _amount.div(100).mul(60);

        // Records Global Purchase History
        totalTokensSold = totalTokensSold.add(tokens);
        busdReceived = busdReceived.add(_amount);

        emit TokenBuy(beneficiary, tokens);
    }

    function setSaleActive(bool _isSaleActive) external onlyOwner {
        isSaleActive = _isSaleActive;
    }

    function getTokensOwned () external view returns (uint256) {
        return tokensOwned[msg.sender];
    }

    function getTokensUnclaimed () external view returns (uint256) {
        return tokensUnclaimed[msg.sender];
    }

    function getBYIELDTokensLeft () external view returns (uint256) {
        return BYIELD.balanceOf(address(this));
    }
    
    function getUserWhitelistingAllowance (address _user) external view returns (uint256) {
        return whitelistAllowance[_user];
    }

    // Allow PrivateFarm MasterChef to edit allowance after Deposit
    // Must set operator to PrivateFarmMC to allow for change of Allowance
    function changeWhitelistingAllowance (address _user, uint256 _amount) external onlyOperator {

        uint256 newAmount = whitelistAllowance[_user].sub(_amount);
        whitelistAllowance[_user] = newAmount;
    }

    function getUserWhitelistingStatus (address _user) external view returns (bool) {
        return whitelisting[_user];
    }

    function claimTokens (address claimer) external {
        require (isSaleActive == false, "Sale is still active");
        require (tokensOwned[msg.sender] > 0, "User should own some BYIELD tokens");
        require (tokensUnclaimed[msg.sender] > 0, "User should have unclaimed BYIELD tokens");
        require (BYIELD.balanceOf(address(this)) >= tokensOwned[msg.sender], "There are not enough BYIELD tokens to transfer. Contract is broken");

        tokensUnclaimed[msg.sender] = tokensUnclaimed[msg.sender].sub(tokensOwned[msg.sender]);

        BYIELD.safeTransfer(msg.sender, tokensOwned[msg.sender]);
        emit TokenClaim(msg.sender, tokensOwned[msg.sender]);
    }

    // Transfer BUSD from Presale Commitments to Provide Liquidity
    function withdrawFunds () external onlyOwner {
        BUSD.safeTransfer(msg.sender, BUSD.balanceOf(address(this)));
    }

    // Unsold BYIELD will be burned 2 weeks after Presale has ended to provide everyone a reasonable chance to claim 
    function withdrawUnsoldBYIELD() external onlyOwner {
        BYIELD.safeTransfer(BURN_ADDRESS, BYIELD.balanceOf(address(this)));
    }
    
    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current owner.
     */
    function transferOperator(address newOperator) public onlyOwner {
        require(newOperator != address(0), "BYIELD::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }
}