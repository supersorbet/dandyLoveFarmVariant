// File contracts/candy/FeeHelper.sol

import "./Ownable.sol";

pragma solidity ^0.8.0;
/**
 * @notice Tax Helper
 * Marketing fee
 * Burn fee
 * Fee in buy/sell/transfer separately
 */
contract FeeHelper is Ownable {
    enum TX_CASE {
        TRANSFER,
        BUY,
        SELL
    }

    struct TokenFee {
        uint16 marketingFee;
        uint16 treasuryFee;
        uint16 burnFee;
    }

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant ZERO = address(0);

    mapping(TX_CASE => TokenFee) internal _tokenFees;
    mapping(address => bool) internal _excludedFromTax;
    mapping(address => bool) internal _isSelfPair;

    constructor() {
        _excludedFromTax[_msgSender()] = true;
        _excludedFromTax[DEAD] = true;
        _excludedFromTax[ZERO] = true;
        _excludedFromTax[address(this)] = true;

        _tokenFees[TX_CASE.TRANSFER].marketingFee = 100;
        _tokenFees[TX_CASE.TRANSFER].treasuryFee = 0;
        _tokenFees[TX_CASE.TRANSFER].burnFee = 50;

        _tokenFees[TX_CASE.BUY].marketingFee = 400;
        _tokenFees[TX_CASE.TRANSFER].treasuryFee = 50;
        _tokenFees[TX_CASE.BUY].burnFee = 150;

        _tokenFees[TX_CASE.SELL].marketingFee = 500;
        _tokenFees[TX_CASE.TRANSFER].treasuryFee = 50;
        _tokenFees[TX_CASE.SELL].burnFee = 150;
    }

    /**
     * @notice Update fee in the token
     * @param feeCase: which case the fee is for: transfer / buy / sell
     * @param marketingFee: fee percent for marketing
     * @param treasuryFee: fee percent for treasury
     * @param burnFee: fee percent for burning
     */
    function setFee(
        TX_CASE feeCase,
        uint16 marketingFee,
        uint16 treasuryFee,
        uint16 burnFee
    ) external onlyOwner {
        require(marketingFee + treasuryFee + burnFee <= 10000, "Overflow");
        _tokenFees[feeCase].marketingFee = marketingFee;
        _tokenFees[feeCase].treasuryFee = treasuryFee;
        _tokenFees[feeCase].burnFee = burnFee;
    }

    /**
     * @notice Exclude / Include the account from fee
     * @dev Only callable by owner
     */
    function excludeFromTax(address account, bool flag) external onlyOwner {
        _excludedFromTax[account] = flag;
    }

    /**
     * @notice Check if the account is excluded from the fees
     * @param account: the account to be checked
     */
    function excludedFromTax(address account) external view returns (bool) {
        return _excludedFromTax[account];
    }

    function viewFees(TX_CASE feeCase) external view returns (TokenFee memory) {
        return _tokenFees[feeCase];
    }

    /**
     * @notice Check if fee should be applied
     */
    function shouldFeeApplied(address from, address to)
        internal
        view
        returns (bool feeApplied, TX_CASE txCase)
    {
        // Sender or receiver is excluded from fee
        if (_excludedFromTax[from] || _excludedFromTax[to]) {
            feeApplied = false;
        }
        // Buying tokens
        else if (_isSelfPair[from]) {
            TokenFee memory buyFee = _tokenFees[TX_CASE.BUY];
            feeApplied =
                (buyFee.marketingFee + buyFee.treasuryFee + buyFee.burnFee) > 0;
            txCase = TX_CASE.BUY;
        }
        // Selling tokens
        else if (_isSelfPair[to]) {
            TokenFee memory sellFee = _tokenFees[TX_CASE.SELL];
            feeApplied =
                (sellFee.marketingFee + sellFee.treasuryFee + sellFee.burnFee) >
                0;
            txCase = TX_CASE.SELL;
        }
        // Transferring tokens
        else {
            TokenFee memory transferFee = _tokenFees[TX_CASE.TRANSFER];
            feeApplied =
                (transferFee.marketingFee +
                    transferFee.treasuryFee +
                    transferFee.burnFee) >
                0;
            txCase = TX_CASE.TRANSFER;
        }
    }

    /**
     * @notice Include / Exclude lp address in self pairs
     */
    function includeInSelfPair(address lpAddress, bool flag)
        external
        onlyOwner
    {
        _isSelfPair[lpAddress] = flag;
    }

    /**
     * @notice Check if the lp address is self pair
     */
    function isSelfPair(address lpAddress) external view returns (bool) {
        return _isSelfPair[lpAddress];
    }
}
