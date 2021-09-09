// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/BEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

// Fees Processor Contract helps processor deposit fees collected from farms
// Fees comes in both LP Tokens and Individual Tokens. Hence the need to processor into BUSD for Buyback Protocol
// Contract is community governance. Fees Processing can be called by anyone, to processor and transfer busd to Buyback Procotol


contract FeesProcessor is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    
    // Info of each LP or Token Contract Address (For Conversion to BUSD)
    struct LpInfo {
        IBEP20 lpToken;           // Address of LP Token Contract (Pancake LP or Token Mode).
        bool isLP;              // Whether it is a LP or Token. Gives True or False. Non-LP requires no break in Liquidity
        IBEP20 tokenA;            // Token A of LP
        IBEP20 tokenB;            // Token B of LP
    }
    
    // Info of each pool.
    LpInfo[] public lpInfo;

    // The SwapRouter. Will only be set to PancakeSwap Router 
    IUniswapV2Router02 public pancakeswapRouter;

    event FeesProcessed(uint256 transferAmount);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    // BUSD Token that all LP and Token will be converted to
    IBEP20 public BUSD;

    // Buyback Protocol Contract Address
    address public BUYBACK_ADDRESS;

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

    constructor (address _BUSD, address _BuybackContract) public {
        _operator =  msg.sender;
        emit OperatorTransferred(address(0), _operator);

        BUSD = BEP20(_BUSD);
        BUYBACK_ADDRESS = _BuybackContract;
        owner = msg.sender;
    }

    // Add a new lp. Can only be called by the owner.
    function add(IBEP20 _lpToken, bool _isLP, IBEP20 _tokenA, IBEP20 _tokenB) public onlyOwner {
        lpInfo.push(LpInfo({
            lpToken: _lpToken,
            isLP: _isLP,
            tokenA: _tokenA,
            tokenB: _tokenB
        }));
    }

    // Update the LpInfo
    function set(uint256 _pid, IBEP20 _lpToken, bool _isLP, IBEP20 _tokenA, IBEP20 _tokenB) public onlyOwner {
        lpInfo[_pid].lpToken = _lpToken;
        lpInfo[_pid].isLP = _isLP;
        lpInfo[_pid].tokenA = _tokenA;        
        lpInfo[_pid].tokenB = _tokenB;
    }

    // Process Tokens and Swap them Into BUSD
    // Can be Called by Anyone for Community Governance
    // !!!Becareful of Gas Usage!!!
    function feesProcessing() public {
        
        // Break LP and Convert them to BUSD
        breakLPAndProcessFees();

        // Amount of BUSD in contract
        uint256 transferAmount = BUSD.balanceOf(address(this));

        // Transfer all BUSD to Buyback Contract
        BUSD.safeTransfer(BUYBACK_ADDRESS, transferAmount);

        emit FeesProcessed(transferAmount);
       
    }

    /// @dev Swap Tokens to BUSD
    function convertToBUSD(IBEP20 entryToken, uint256 tokenAmount) private {

        // generate the busd pair path of tokens
        address[] memory path = new address[](2);
        path[0] = address(entryToken);
        path[1] = address(BUSD);

        // Give PancakeSwap Allowance to Spend Tokens
        entryToken.approve(address(pancakeswapRouter), tokenAmount);
        BUSD.approve(address(pancakeswapRouter), tokenAmount);

        // Make the swap from entryTokens to BUSD
        pancakeswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BUSD
            path,
            address(this),
            block.timestamp
        );
    }


    /// @dev BreakLP That Contract Received from Fees
    function breakLPAndProcessFees() private {

        uint256 length = lpInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {

            LpInfo storage lp = lpInfo[pid];
            IBEP20 LPToken = lp.lpToken;
            
            // Check if Token is LP to break LP
            if (lp.isLP == true && LPToken.balanceOf(address(this)) != 0) {

                // Approval must be given to Pancakeswap Router for allowance
                LPToken.approve(address(pancakeswapRouter), LPToken.balanceOf(address(this)));

                // Approval done. Remove Liquidity using Pancakeswap Router 
                pancakeswapRouter.removeLiquidity(
                    address(lp.tokenA),  // Token A of LP 
                    address(lp.tokenB), // Token B of LP
                    LPToken.balanceOf(address(this)), // Balance of LP Left. Similar to Approved Allowance
                    0, // Accepts any amount of Token A
                    0, // Accepts any amount of Token B
                    address(this), // Fees Processor as receipent of Tokens
                    block.timestamp 
                );

                // Swap Token A to BUSD. Cannot swap BUSD for BUSD. Cannot swap when amount = 0 
                if (address(lp.tokenA) != address(BUSD) && lp.tokenA.balanceOf(address(this)) != 0 ) {
                    convertToBUSD(lp.tokenA, lp.tokenA.balanceOf(address(this)));
                }

                // Swap Token B to BUSD. Cannot swap BUSD for BUSD. Cannot swap when amount = 0 
                if (address(lp.tokenB) != address(BUSD) && lp.tokenB.balanceOf(address(this)) != 0 ) {
                    convertToBUSD(lp.tokenB, lp.tokenB.balanceOf(address(this)));
                }
            }
            
            // Not LP. Will just swap for BUSD immediately on the condition that balance is not zero
            else {
                
                // Token Contract address will only be stored in the LpToken variable of LpInfo
                // Swap to BUSD. Cannot swap BUSD for BUSD. Cannot swap when amount = 0 
                if (address(LPToken) != address(BUSD) && LPToken.balanceOf(address(this)) != 0 ) {
                    convertToBUSD(LPToken, LPToken.balanceOf(address(this)));
                }               
            }
        }
    }

    // Only used in case contract fail for whatever reason 
    // Will be Timelocked to prevent tempering
    function withdrawFunds () external onlyOwner {
        uint256 length = lpInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {

            LpInfo storage lp = lpInfo[pid];
            IBEP20 LPToken = lp.lpToken;

            // Withdraw Tokens back to Owner (Dev)
            if (LPToken.balanceOf(address(this)) != 0) {
                LPToken.safeTransfer(owner, LPToken.balanceOf(address(this)));
            }
        }
    }

    function poolLength() external view returns (uint256) {
        return lpInfo.length;
    }
    
    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

 
    /**
     * @dev Update the swap router.
     * Important functionality because of rumours that PCS Router V3 is in the works
     * Can only be called by the current operator.
     */
    function updatePancakeSwapRouter(address _router) public onlyOperator {
        pancakeswapRouter = IUniswapV2Router02(_router);
    }


}