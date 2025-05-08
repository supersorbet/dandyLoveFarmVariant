// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "../lib/solady/src/tokens/ERC20.sol";
import {Ownable} from "../lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "../lib/solady/src/utils/SafeTransferLib.sol";
import {LibBit} from "../lib/solady/src/utils/LibBit.sol";
import {FixedPointMathLib} from "../lib/solady/src/utils/FixedPointMathLib.sol";
import {IUniswapV2Router} from "./interfaces/IUniswapV2Router.sol";

/// @title DandyV2
/// @notice optimized ERC20 token with anti-bot protection and fee mechanism
contract DandyV2 is ERC20, Ownable {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    using LibBit for uint256;

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
    error TransferCooldown();

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MAX_SUPPLY = 250_000_000 ether;
    uint256 public constant MAX_TX_AMOUNT_MIN_LIMIT = 100 ether;
    uint256 public constant MAX_WALLET_AMOUNT_MIN_LIMIT = 1000 ether;
    uint16 public constant MAX_FEE = 1100; // 11% (in basis points)
    uint256 public constant BASIS_POINTS = 10000;

    string private _name;
    string private _symbol;

    mapping(address => bool) public isExcludedFromTxLimit;
    mapping(address => bool) public isExcludedFromHoldLimit;
    mapping(address => bool) public isExcludedFromCooldown;
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public lastTransferTimestamp;
    uint256 public txLimit = 50_000 ether;
    uint256 public holdLimit = 500_000 ether;
    uint32 public transferCooldown = 0; 

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
    
    address public marketingWallet;
    address public marketingToken;
    address public treasuryWallet;
    IUniswapV2Router public swapRouter;
    uint256 public thresholdAmount = 10_000 ether;
    bool public swapEnabled = true;
    bool private _inSwap;

    modifier lockSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    /// @notice Contract constructor
    /// @param tokenName Name of the token
    /// @param tokenSymbol Symbol of the token
    constructor(string memory tokenName, string memory tokenSymbol) {
        _name = tokenName;
        _symbol = tokenSymbol;
        _initializeOwner(msg.sender);

        isExcludedFromTxLimit[msg.sender] = true;
        isExcludedFromTxLimit[DEAD] = true;
        isExcludedFromTxLimit[address(0)] = true;
        isExcludedFromTxLimit[address(this)] = true;

        isExcludedFromHoldLimit[msg.sender] = true;
        isExcludedFromHoldLimit[DEAD] = true;
        isExcludedFromHoldLimit[address(0)] = true;
        isExcludedFromHoldLimit[address(this)] = true;
    }

    /// @notice Return the name of the token
    /// @return The token name
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Return the symbol of the token
    /// @return The token symbol
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Mint new tokens (only owner)
    /// @param to Address to mint tokens to
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) revert MaxSupplyExceeded();
        _mint(to, amount);
    }

    /// @notice Burn tokens from sender
    /// @param amount Amount to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Transfer tokens
    /// @param to Address to send tokens to
    /// @param amount Amount to send
    /// @return success True if successful
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFees(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer tokens from another address
    /// @param from Address to take tokens from
    /// @param to Address to send tokens to
    /// @param amount Amount to send
    /// @return success True if successful
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance(from, msg.sender);
        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - amount);
        }
        _transferWithFees(from, to, amount);
        return true;
    }

    /// @notice Internal function to handle transfers with fees
    /// @param from Address to take tokens from
    /// @param to Address to send tokens to
    /// @param amount Amount to send
    function _transferWithFees(address from, address to, uint256 amount) internal {
        if (amount == 0) revert ZeroTransfer();
        if (isBlacklisted[from] || isBlacklisted[to]) revert Blacklisted();
        if (transferCooldown > 0 && 
            !isExcludedFromCooldown[from] && 
            !isExcludedFromCooldown[to] && 
            lastTransferTimestamp[from] != 0) {
            if (block.timestamp - lastTransferTimestamp[from] < transferCooldown) {
                revert TransferCooldown();
            }
        }
        
        lastTransferTimestamp[from] = block.timestamp;
        
        if (!isExcludedFromTxLimit[from] && !isExcludedFromTxLimit[to] && amount > txLimit) {
            revert MaxTxLimitExceeded();
        }
        
        if (!isExcludedFromHoldLimit[to] && balanceOf(to) + amount > holdLimit) {
            revert MaxWalletLimitExceeded();
        }
        
        (bool shouldApplyFee, TxCase txCase) = _shouldApplyFee(from, to);
        
        uint256 contractBalance = balanceOf(address(this));
        if (!_inSwap && shouldApplyFee && swapEnabled && contractBalance >= thresholdAmount) {
            _swapToMarketingToken(thresholdAmount);
        }
        
        if (shouldApplyFee) {
            _transferWithFee(from, to, amount, txCase);
        } else {
            _transfer(from, to, amount);
        }
    }
    
    /// @notice Handle transfer with fee application
    /// @param from Address to take tokens from
    /// @param to Address to send tokens to
    /// @param amount Amount to send
    /// @param txCase Type of transaction (buy, sell, transfer)
    function _transferWithFee(address from, address to, uint256 amount, TxCase txCase) internal {
        TokenFees memory fees = tokenFees[txCase];
        
        unchecked {
            uint256 burnAmount = amount.mulDiv(fees.burnFee, BASIS_POINTS);
            uint256 treasuryAmount = amount.mulDiv(fees.treasuryFee, BASIS_POINTS);
            uint256 marketingAmount = amount.mulDiv(fees.marketingFee, BASIS_POINTS);
            uint256 transferAmount = amount - burnAmount - treasuryAmount - marketingAmount;
            
            if (burnAmount > 0) {
                _burn(from, burnAmount);
            }
            
            if (treasuryAmount > 0 && treasuryWallet != address(0)) {
                _transfer(from, treasuryWallet, treasuryAmount);
            }
            
            if (marketingAmount > 0) {
                _transfer(from, address(this), marketingAmount);
            }
            
            if (transferAmount > 0) {
                _transfer(from, to, transferAmount);
            }
        }
    }
    
    /// @notice Determine if fees should be applied
    /// @param from Address sending tokens
    /// @param to Address receiving tokens
    /// @return feeApplied Whether fee should be applied
    /// @return txCase Transaction type
    function _shouldApplyFee(address from, address to) internal view returns (bool, TxCase) {
        if (from == address(this) || to == address(this) || from == owner() || to == owner()) {
            return (false, TxCase.TRANSFER);
        }
        if (to == DEAD || to == address(0)) {
            return (false, TxCase.TRANSFER);
        }

        TxCase txCase;
        txCase = TxCase.TRANSFER;
        
        return (true, txCase);
    }

    /// @notice Swap tokens to marketing token
    /// @param amount Amount to swap
    function _swapToMarketingToken(uint256 amount) internal lockSwap {
        if (marketingToken == address(this)) {
            _transfer(address(this), marketingWallet, amount);
        } else if (_isETH(marketingToken)) {
            _swapToETH(amount, marketingWallet);
        } else {
            _swapToToken(marketingToken, amount, marketingWallet);
        }
    }
    
    /// @notice Swap tokens to another token
    /// @param token Token to swap to
    /// @param amount Amount to swap
    /// @param to Address to receive tokens
    function _swapToToken(address token, uint256 amount, address to) internal {
        if (address(swapRouter) == address(0)) {
            emit SwapToMarketingTokenFailed(token, to, amount);
            return;
        }

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = token;

        _approve(address(this), address(swapRouter), amount);

        uint256 balanceBefore = IERC20(token).balanceOf(to);
        
        try
            swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount,
                0,
                path,
                to,
                block.timestamp + 300
            )
        {
            uint256 amountOut = IERC20(token).balanceOf(to) - balanceBefore;
            emit SwapToMarketingTokenSucceeded(token, to, amount, amountOut);
        } catch {
            emit SwapToMarketingTokenFailed(token, to, amount);
        }
    }
    
    /// @notice Swap tokens to ETH
    /// @param amount Amount to swap
    /// @param to Address to receive ETH
    function _swapToETH(uint256 amount, address to) internal {
        if (address(swapRouter) == address(0)) {
            emit SwapToMarketingTokenFailed(ETH_ADDRESS, to, amount);
            return;
        }

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = swapRouter.WETH();

        _approve(address(this), address(swapRouter), amount);

        uint256 balanceBefore = to.balance;
        
        try
            swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                0,
                path,
                to,
                block.timestamp + 300
            )
        {
            uint256 amountOut = to.balance - balanceBefore;
            emit SwapToMarketingTokenSucceeded(ETH_ADDRESS, to, amount, amountOut);
        } catch {
            emit SwapToMarketingTokenFailed(ETH_ADDRESS, to, amount);
        }
    }
    
    /// @notice Check if token is ETH
    /// @param token Token address to check
    /// @return isEth True if token is ETH
    function _isETH(address token) internal pure returns (bool) {
        return (token == address(0) || token == ETH_ADDRESS);
    }

    /// @notice Helper function to set address exclusions
    /// @param account Address to set exclusions for
    /// @param excludeFromTxLimit Whether to exclude from tx limit
    /// @param excludeFromHoldLimit Whether to exclude from hold limit
    /// @param excludeFromCooldown Whether to exclude from cooldown
    function _setAddressExclusions(
        address account, 
        bool excludeFromTxLimit, 
        bool excludeFromHoldLimit,
        bool excludeFromCooldown
    ) internal {
        isExcludedFromTxLimit[account] = excludeFromTxLimit;
        isExcludedFromHoldLimit[account] = excludeFromHoldLimit;
        isExcludedFromCooldown[account] = excludeFromCooldown;
    }

    /// @notice Set fees for transaction type
    /// @param txCase Transaction type
    /// @param marketingFee Marketing fee in basis points
    /// @param treasuryFee Treasury fee in basis points
    /// @param burnFee Burn fee in basis points
    function setFees(TxCase txCase, uint16 marketingFee, uint16 treasuryFee, uint16 burnFee) external onlyOwner {
        uint16 totalFee = marketingFee + treasuryFee + burnFee;
        if (totalFee > MAX_FEE) revert FeeTooHigh();
        
        tokenFees[txCase] = TokenFees({
            marketingFee: marketingFee,
            treasuryFee: treasuryFee,
            burnFee: burnFee
        });
        
        emit FeeUpdated(txCase, marketingFee, treasuryFee, burnFee);
    }
    
    /// @notice Set transfer cooldown
    /// @param newCooldown Cooldown in seconds (0 to disable)
    function setTransferCooldown(uint32 newCooldown) external onlyOwner {
        uint32 oldCooldown = transferCooldown;
        transferCooldown = newCooldown;
        emit TransferCooldownSet(oldCooldown, newCooldown);
    }
    
    /// @notice Set swap router
    /// @param newSwapRouter Address of swap router
    function setSwapRouter(address newSwapRouter) external onlyOwner {
        if (newSwapRouter == address(0)) revert InvalidSwapRouter();
        swapRouter = IUniswapV2Router(newSwapRouter);
    }
    
    /// @notice Enable/disable swap
    /// @param enabled True to enable, false to disable
    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }
    
    /// @notice Set marketing wallet
    /// @param wallet Address of marketing wallet
    function setMarketingWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert InvalidFeeReceiver();
        marketingWallet = wallet;
    }
    
    /// @notice Set marketing token
    /// @param token Address of marketing token
    function setMarketingToken(address token) external onlyOwner {
        marketingToken = token;
    }
    
    /// @notice Set treasury wallet
    /// @param wallet Address of treasury wallet
    function setTreasuryWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert InvalidFeeReceiver();
        treasuryWallet = wallet;
    }
    
    /// @notice Set threshold amount
    /// @param amount Threshold amount
    function setThresholdAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidThreshold();
        thresholdAmount = amount;
    }
    
    /// @notice Set anti-whale configuration
    /// @param newTxLimit New transaction limit
    /// @param newHoldLimit New wallet hold limit
    function setAntiWhalesConfiguration(uint256 newTxLimit, uint256 newHoldLimit) external onlyOwner {
        if (newTxLimit < MAX_TX_AMOUNT_MIN_LIMIT) revert AmountTooLow();
        if (newHoldLimit < MAX_WALLET_AMOUNT_MIN_LIMIT) revert AmountTooLow();
        
        txLimit = newTxLimit;
        holdLimit = newHoldLimit;
    }
    
    /// @notice Blacklist or unblacklist an account
    /// @param account Address to blacklist
    /// @param flag True to blacklist, false to unblacklist
    function blacklistAccount(address account, bool flag) external onlyOwner {
        isBlacklisted[account] = flag;
        emit BlacklistUpdated(account, flag);
    }
    
    /// @notice Set address exclusions
    /// @param account Address to set exclusions for
    /// @param excludeFromTxLimit Whether to exclude from tx limit
    /// @param excludeFromHoldLimit Whether to exclude from hold limit
    /// @param excludeFromCooldown Whether to exclude from cooldown
    function setAddressExclusions(
        address account, 
        bool excludeFromTxLimit, 
        bool excludeFromHoldLimit,
        bool excludeFromCooldown
    ) external onlyOwner {
        _setAddressExclusions(account, excludeFromTxLimit, excludeFromHoldLimit, excludeFromCooldown);
        emit LimitExclusionUpdated(account, excludeFromTxLimit, excludeFromHoldLimit, excludeFromCooldown);
    }

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
    event FeeUpdated(TxCase indexed txCase, uint16 marketingFee, uint16 treasuryFee, uint16 burnFee);
    event TransferCooldownSet(uint32 oldCooldown, uint32 newCooldown);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event LimitExclusionUpdated(address indexed account, bool excludedFromTxLimit, bool excludedFromHoldLimit, bool excludedFromCooldown);

} 

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}
