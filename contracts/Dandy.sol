//SPDX-License-Identifier: Frensware

import "./BotRepellant.sol";
import "./FeeHelper.sol";
import "./Operatable.sol";
import "./ERC20.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Router01.sol";
import "./IUniswapV2Router02.sol";
import "./IUniswapV2Factory.sol";


pragma solidity ^0.8.19;

contract Dandy is BotRepellant, FeeHelper, ERC20, Operatable {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 constant MAX_SUPPLY = 250000000 ether;

    address private _marketingWallet;
    address private _marketingToken;
    address private _treasuryWallet;

    bool private _inSwap;
    bool private _swapEnabled = true;
    uint256 private _thresholdAmount = 10000 ether; // threshold amount of piled up tax
    IUniswapV2Router02 private _swapRouter;

    event SwapToMarketingTokenSucceed(
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

    modifier lockTheSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {}

    function mint(uint256 amount) external onlyOperator {
        _mint(_msgSender(), amount);
    }

    function mint(address account, uint256 amount) external onlyOperator {
        _mint(account, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual override {
        super._mint(account, amount);
        _afterTokenTransfer(address(0), account, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual override {
        super._burn(account, amount);
        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(!_blacklist[from] && !_blacklist[to], "blacklisted account");

        // Check max tx limit
        require(
            _excludedFromTxLimit[from] ||
                _excludedFromTxLimit[to] ||
                amount <= _txLimit,
            "Tx amount limited"
        );

        // Check max wallet amount limit
        require(
            _excludedFromHoldLimit[to] || balanceOf(to) <= _holdLimit,
            "Receiver hold limited"
        );

        require(totalSupply() <= MAX_SUPPLY, "Exceeds MAX_SUPPLY");
    }

    function setSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");

        _swapRouter = IUniswapV2Router02(newSwapRouter);
    }

    function viewSwapRouter() external view returns (address) {
        return address(_swapRouter);
    }

    function enableSwap(bool flag) external onlyOwner {
        _swapEnabled = flag;
    }

    function swapEnabled() external view returns (bool) {
        return _swapEnabled;
    }

    function setMarketingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "Invalid marketing wallet");
        _marketingWallet = wallet;
    }

    function viewMarketingWallet() external view returns (address) {
        return _marketingWallet;
    }

    function setMarketingToken(address token) external onlyOwner {
        _marketingToken = token;
    }

    function viewMarketingToken() external view returns (address) {
        return _marketingToken;
    }

    function setTreasuryWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "Invalid treasury wallet");
        _treasuryWallet = wallet;
    }

    function viewTreasuryWallet() external view returns (address) {
        return _treasuryWallet;
    }

    /**
     * @dev Set threshold amount to be swapped to the marketing token
     * Too small value will cause sell tx happens in every tx
     */
    function setThresholdAmount(uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid threshold");
        _thresholdAmount = amount;
    }

    function viewThresholdAmount() external view returns (uint256) {
        return _thresholdAmount;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(amount > 0, "Zero transfer");

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is  pair.
        uint256 contractTokenBalance = balanceOf(address(this));

        // indicates if fee should be deducted from transfer
        (bool feeApplied, TX_CASE txCase) = shouldFeeApplied(from, to);

        // Swap and liquify also triggered when the tx needs to have fee
        if (
            !_inSwap &&
            feeApplied &&
            _swapEnabled &&
            contractTokenBalance >= _thresholdAmount
        ) {
            swapToMarketingToken(_thresholdAmount);
        }

        //transfer amount, it will take tax, burn fee
        _tokenTransfer(from, to, amount, feeApplied, txCase);
    }

    // this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool feeApplied,
        TX_CASE txCase
    ) private {
        if (feeApplied) {
            uint16 marketingFee = _tokenFees[txCase].marketingFee;
            uint16 treasuryFee = _tokenFees[txCase].treasuryFee;
            uint16 burnFee = _tokenFees[txCase].burnFee;

            uint256 burnFeeAmount = (amount * burnFee) / 10000;
            uint256 treasuryFeeAmount = (amount * treasuryFee) / 10000;
            uint256 marketingFeeAmount = (amount * marketingFee) / 10000;

            if (burnFeeAmount > 0) {
                _burn(sender, burnFeeAmount);
                amount -= burnFeeAmount;
            }
            if (treasuryFeeAmount > 0) {
                super._transfer(sender, _treasuryWallet, treasuryFeeAmount);
                amount -= treasuryFeeAmount;
            }
            if (marketingFeeAmount > 0) {
                super._transfer(sender, address(this), marketingFeeAmount);
                amount -= marketingFeeAmount;
            }
        }
        if (amount > 0) {
            super._transfer(sender, recipient, amount);
            _afterTokenTransfer(sender, recipient, amount);
        }
    }

    /**
     * @dev Swap token accumlated in this contract to the marketing token
     * 
     * According to the marketing token

     * - when marketing token is ETH, swapToETH function is called
     * - when marketing token is another token, swapToToken is called

     */
    function swapToMarketingToken(uint256 amount) private lockTheSwap {
        if (_marketingToken == address(this)) {
            super._transfer(address(this), _marketingWallet, amount);
            _afterTokenTransfer(address(this), _marketingWallet, amount);
        } else if (isETH(_marketingToken)) {
            swapToETH(amount, payable(_marketingWallet));
        } else {
            swapToToken(_marketingToken, amount, _marketingWallet);
        }
    }

    function swapToToken(
        address token,
        uint256 amount,
        address to
    ) private {
        // generate the  pair path of token ->
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = token;

        _approve(address(this), address(_swapRouter), amount);

        // capture the target address's current eth balance.
        uint256 balanceBefore = IERC20(_marketingToken).balanceOf(to);

        
        try
            _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount,
                0, // accept any amount of tokens
                path,
                to,
                block.number + 300
            )
        {
            uint256 amountOut = IERC20(_marketingToken).balanceOf(to) -
                balanceBefore;
            emit SwapToMarketingTokenSucceed(
                _marketingToken,
                to,
                amount,
                amountOut
            );
        } catch (
            bytes memory /* lowLevelData */
        ) {
            emit SwapToMarketingTokenFailed(_marketingToken, to, amount);
        }
    }

    function swapToETH(uint256 amount, address payable to) private {
        // generate the  pair path of token -> =
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _swapRouter.WETH();

        _approve(address(this), address(_swapRouter), amount);

        // capture the target address's current eth balance.
        uint256 balanceBefore = to.balance;

        try
            _swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amount,
                0, // accept any amount of eth
                path,
                to,
                block.number + 300
            )
        {
            // how much ETH did we just swap into?
            uint256 amountOut = to.balance - balanceBefore;
            emit SwapToMarketingTokenSucceed(
                _marketingToken,
                to,
                amount,
                amountOut
            );
        } catch (
            bytes memory /* lowLevelData */
        ) {
            // how much eth did we just swap into?
            emit SwapToMarketingTokenFailed(_marketingToken, to, amount);
        }
    }

    function isETH(address token) internal pure returns (bool) {
        return (token == address(0) || token == ETH_ADDRESS);
    }
}