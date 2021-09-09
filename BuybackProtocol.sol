// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/BEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

// This is a testContract to ensure that the UI Works correctly, incase BSCScan flags out about similar contracts thereafter

contract BuybackProtocol is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // The SwapRouter. Will only be set to PancakeSwap Router 
    IUniswapV2Router02 public pancakeswapRouter;

    event BuybackAndBurn(uint256 singleBuybackAmount, uint256 totalBuybackAmount, uint256 totalTimesCalled);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    // bYield token
    IBEP20 public BYIELD;
    // BUSD Token that will be used as mean of transaction for Buyback by Contract
    IBEP20 public BUSD;

    // Block number where Buyback Protocol can be freely card by anyone
    uint256 public startBlock;

    // Global Variables
    uint256 busdBroughtBack = 0;
    uint256 busdReceived = 0;
    uint256 buybackCounter = 0;

    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Next Buyback Block
    uint256 public lastBuybackBlock = 0;
    // Buyback Interval in terms of block 
    // 100 Blocks is equalivant to about 5 Mins
    uint256 public constant BUYBACK_INTERVAL = 100;

    address payable owner;
    
    modifier onlyOwner(){
        require(msg.sender == owner, "You're not the owner");
        _;
    }

    address public _operator;

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    constructor (address _BYIELD, address _BUSD, uint256 _startingBlockNumber) public {
        _operator =  msg.sender;
        emit OperatorTransferred(address(0), _operator);

        BYIELD = BEP20(_BYIELD);
        BUSD = BEP20(_BUSD);
        owner = msg.sender;
        startBlock = _startingBlockNumber;
    }

    /// Buyback and Burn
    /// Can be Called by Anyone for Community Governance
    function buybackAndBurn() public {
        // Ensure that buyback only starts when farming starts
        require(block.number > startBlock, "buybackAndBurn: Buyback only available once farming starts");
        
        // Require that each buyback has an interval of 5 MINS (100 Block)
        // Ensure no abitrage pumping of price, but instead maintain long term price stability
        if( block.number < lastBuybackBlock && lastBuybackBlock != 0){
            return;
        } else {
            // Calculate total BUSD (From deposit fees) that is transferred to the FeesProcessor Contract
            uint256 contractBUSD = BUSD.balanceOf(address(this));

            // Each Buyback call can only be 3% of the Total BUSD available for Buyback
            uint256 buybackAmount = contractBUSD.div(100).mul(3);

            // Buyback bYield with BUSD
            buyback(buybackAmount);

            // Record buyback
            busdBroughtBack = busdBroughtBack.add(buybackAmount);
            buybackCounter = buybackCounter.add(1);

            // Automatically Burn all bYield that is bought back (Burn all bYield of Contract for Simplicity)
            BYIELD.safeTransfer(BURN_ADDRESS, BYIELD.balanceOf(address(this)));

            // Set lastBuybackBlock
            lastBuybackBlock = block.number.add(BUYBACK_INTERVAL);
            emit BuybackAndBurn(buybackAmount, busdBroughtBack, buybackCounter);
        }   
       
    }

    /// @dev Swap BUSD for bYield Tokens
    function buyback(uint256 tokenAmount) private {
        // generate the bYield pair path of token -> busd
        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(BYIELD);

        // Give PancakeSwap Allowance to Spend Tokens
        BUSD.approve(address(pancakeswapRouter), tokenAmount);
        BYIELD.approve(address(pancakeswapRouter), tokenAmount);

        // Make the swap for bYield with BUSD
        pancakeswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of bYield
            path,
            address(this),
            block.timestamp
        );
    }

    function getBUSDLeft () external view returns (uint256) {
        return BUSD.balanceOf(address(this));
    }

    function getBuybackAmount () external view returns (uint256) {
        return busdBroughtBack;
    }

    function getBuybackCounter () external view returns (uint256) {
        return buybackCounter;
    }

    function getLastBuybackIndex () external view returns (uint256) {
        return lastBuybackBlock;
    }

    // Only used in case contract fail for whatever reason 
    // Will be Timelocked to prevent tempering
    function withdrawFunds () external onlyOwner {
        BUSD.safeTransfer(owner, BUSD.balanceOf(address(this)));
    }

    /**
     * @dev Update the swap router. Can only be PancakeSwap Router
     * Can only be called by the current operator.
     */
    function updatePancakeSwapRouter(address _router) public onlyOperator {
        pancakeswapRouter = IUniswapV2Router02(_router);
    }


}