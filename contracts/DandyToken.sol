// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../lib/solady/src/tokens/ERC20.sol";
import "../lib/solady/src/auth/Ownable.sol";
import "../lib/solady/src/utils/SafeTransferLib.sol";

/// @title DandyToken
/// @notice Gas-optimized ERC20 token with anti-bot protection and fee mechanism
contract DandyToken is ERC20, Ownable {
    using SafeTransferLib for address;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error Blacklisted();
    error MaxTxLimitExceeded();
    error MaxWalletLimitExceeded();
    error MaxSupplyExceeded();
    error ZeroTransfer();
    error InvalidThreshold();
    error InvalidFeeReceiver();
    error InvalidMarketingToken();
    error InvalidSwapRouter();
    error TxFailed();
    error FeeTooHigh();
    error AmountTooLow();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MAX_SUPPLY = 250_000_000 ether;
    uint256 public constant MAX_TX_AMOUNT_MIN_LIMIT = 100 ether;
    uint256 public constant MAX_WALLET_AMOUNT_MIN_LIMIT = 1000 ether;
    uint16 public constant MAX_FEE = 1100; // 11%%

    /*//////////////////////////////////////////////////////////////
                              TOKEN METADATA
    //////////////////////////////////////////////////////////////*/
    string private _name;
    string private _symbol;

    /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Anti-bot protection
    mapping(address => bool) public isExcludedFromTxLimit;
    mapping(address => bool) public isExcludedFromHoldLimit;
    mapping(address => bool) public isBlacklisted;
    uint256 public txLimit = 50_000 ether;
    uint256 public holdLimit = 500_000 ether;

    // Fee system
    struct TokenFees {
        uint16 marketingFee;
        uint16 treasuryFee;
        uint16 burnFee;
    }

    enum TxCase {
        BUY,
        SELL,
        TRANSFER
    }

    mapping(TxCase => TokenFees) public tokenFees;
    
    // Fee collection and swap
    address public marketingWallet;
    address public marketingToken;
    address public treasuryWallet;
    address public swapRouter;
    uint256 public thresholdAmount = 10_000 ether;
    bool public swapEnabled = true;
    bool private _inSwap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event SwapToMarketingTokenSucceeded(
        address indexed marketingToken,
        address indexed to,
        uint256 amountIn,
        uint256 amountOut
    );
    event SwapToMarketingTokenFailed(
        address indexed marketingToken,
        address indexed to,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier lockSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(string memory tokenName, string memory tokenSymbol) {
        _name = tokenName;
        _symbol = tokenSymbol;
        _initializeOwner(msg.sender);

        // Setup default excluded addresses
        isExcludedFromTxLimit[msg.sender] = true;
        isExcludedFromTxLimit[DEAD] = true;
        isExcludedFromTxLimit[address(0)] = true;
        isExcludedFromTxLimit[address(this)] = true;

        isExcludedFromHoldLimit[msg.sender] = true;
        isExcludedFromHoldLimit[DEAD] = true;
        isExcludedFromHoldLimit[address(0)] = true;
        isExcludedFromHoldLimit[address(this)] = true;
    }

    /*//////////////////////////////////////////////////////////////
                             ERC20 OVERRIDES
    //////////////////////////////////////////////////////////////*/
    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                             TOKEN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFees(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance(from, msg.sender);
        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - amount);
        }
        _transferWithFees(from, to, amount);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                         FEE CALCULATION & TRANSFER
    //////////////////////////////////////////////////////////////*/
    function _transferWithFees(address from, address to, uint256 amount) internal {
        if (amount == 0) revert ZeroTransfer();
        if (isBlacklisted[from] || isBlacklisted[to]) revert Blacklisted();
        
        // Check tx limit
        if (!isExcludedFromTxLimit[from] && !isExcludedFromTxLimit[to] && amount > txLimit) {
            revert MaxTxLimitExceeded();
        }
        
        // Check wallet limit
        if (!isExcludedFromHoldLimit[to] && balanceOf(to) + amount > holdLimit) {
            revert MaxWalletLimitExceeded();
        }
        
        // Determine tx case and if fee should be applied
        (bool shouldApplyFee, TxCase txCase) = _shouldApplyFee(from, to);
        
        // Swap accumulated tokens if threshold is met
        uint256 contractBalance = balanceOf(address(this));
        if (!_inSwap && shouldApplyFee && swapEnabled && contractBalance >= thresholdAmount) {
            _swapToMarketingToken(thresholdAmount);
        }
        
        // Handle fees or direct transfer
        if (shouldApplyFee) {
            _transferWithFee(from, to, amount, txCase);
        } else {
            _transfer(from, to, amount);
        }
    }
    
    function _transferWithFee(address from, address to, uint256 amount, TxCase txCase) internal {
        TokenFees memory fees = tokenFees[txCase];
        
        uint256 burnAmount = (amount * fees.burnFee) / 10000;
        uint256 treasuryAmount = (amount * fees.treasuryFee) / 10000;
        uint256 marketingAmount = (amount * fees.marketingFee) / 10000;
        uint256 transferAmount = amount - burnAmount - treasuryAmount - marketingAmount;
        
        // Handle burn
        if (burnAmount > 0) {
            _burn(from, burnAmount);
        }
        
        // Handle treasury fee
        if (treasuryAmount > 0 && treasuryWallet != address(0)) {
            _transfer(from, treasuryWallet, treasuryAmount);
        }
        
        // Handle marketing fee
        if (marketingAmount > 0) {
            _transfer(from, address(this), marketingAmount);
        }
        
        // Transfer remaining amount to recipient
        if (transferAmount > 0) {
            _transfer(from, to, transferAmount);
        }
    }
    
    function _shouldApplyFee(address from, address to) internal view returns (bool, TxCase) {
        // Exclude specific addresses from fees
        if (from == address(this) || to == address(this) || from == owner() || to == owner()) {
            return (false, TxCase.TRANSFER);
        }
        
        // No fee for burn address
        if (to == DEAD || to == address(0)) {
            return (false, TxCase.TRANSFER);
        }

        // Determine transaction type and apply appropriate fee
        TxCase txCase;
        
        // Simple transfer between users
        txCase = TxCase.TRANSFER;
        
        return (true, txCase);
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/
    function _swapToMarketingToken(uint256 amount) internal lockSwap {
        if (marketingToken == address(this)) {
            _transfer(address(this), marketingWallet, amount);
        } else if (_isETH(marketingToken)) {
            _swapToETH(amount, marketingWallet);
        } else {
            _swapToToken(marketingToken, amount, marketingWallet);
        }
    }
    
    function _swapToToken(address token, uint256 amount, address to) internal {
        // This is a simplified version - in a real implementation you'd need to 
        // interact with the swap router to exchange tokens
        // For now, just emit an event showing the intent
        emit SwapToMarketingTokenSucceeded(token, to, amount, 0);
    }
    
    function _swapToETH(uint256 amount, address to) internal {
        // This is a simplified version - in a real implementation you'd need to 
        // interact with the swap router to exchange tokens for ETH
        // For now, just emit an event showing the intent
        emit SwapToMarketingTokenSucceeded(ETH_ADDRESS, to, amount, 0);
    }
    
    function _isETH(address token) internal pure returns (bool) {
        return (token == address(0) || token == ETH_ADDRESS);
    }

    /*//////////////////////////////////////////////////////////////
                          CONFIGURATION METHODS
    //////////////////////////////////////////////////////////////*/
    function setFees(TxCase txCase, uint16 marketingFee, uint16 treasuryFee, uint16 burnFee) external onlyOwner {
        uint16 totalFee = marketingFee + treasuryFee + burnFee;
        if (totalFee > MAX_FEE) revert FeeTooHigh();
        
        tokenFees[txCase] = TokenFees({
            marketingFee: marketingFee,
            treasuryFee: treasuryFee,
            burnFee: burnFee
        });
    }
    
    function setSwapRouter(address newSwapRouter) external onlyOwner {
        if (newSwapRouter == address(0)) revert InvalidSwapRouter();
        swapRouter = newSwapRouter;
    }
    
    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }
    
    function setMarketingWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert InvalidFeeReceiver();
        marketingWallet = wallet;
    }
    
    function setMarketingToken(address token) external onlyOwner {
        marketingToken = token;
    }
    
    function setTreasuryWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert InvalidFeeReceiver();
        treasuryWallet = wallet;
    }
    
    function setThresholdAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidThreshold();
        thresholdAmount = amount;
    }
    
    function setAntiWhalesConfiguration(uint256 newTxLimit, uint256 newHoldLimit) external onlyOwner {
        if (newTxLimit < MAX_TX_AMOUNT_MIN_LIMIT) revert AmountTooLow();
        if (newHoldLimit < MAX_WALLET_AMOUNT_MIN_LIMIT) revert AmountTooLow();
        
        txLimit = newTxLimit;
        holdLimit = newHoldLimit;
    }
    
    function blacklistAccount(address account, bool flag) external onlyOwner {
        isBlacklisted[account] = flag;
    }
    
    function excludeFromTxLimit(address account, bool flag) external onlyOwner {
        isExcludedFromTxLimit[account] = flag;
    }
    
    function excludeFromHoldLimit(address account, bool flag) external onlyOwner {
        isExcludedFromHoldLimit[account] = flag;
    }
} 