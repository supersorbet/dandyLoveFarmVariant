// SPDX-License-Identifier: GPL-3.0-or-later

import "./Ownable.sol";

pragma solidity ^0.8.0;

contract BotRepellant is Ownable {
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant ZERO = address(0);

    uint256 public constant MAX_TX_AMOUNT_MIN_LIMIT = 100 ether;
    uint256 public constant MAX_WALLET_AMOUNT_MIN_LIMIT = 1000 ether;

    mapping(address => bool) internal _excludedFromTxLimit;
    mapping(address => bool) internal _excludedFromHoldLimit;
    mapping(address => bool) internal _blacklist;

    uint256 internal _txLimit = 50000 ether;
    uint256 internal _holdLimit = 500000 ether;

    constructor() {
        _excludedFromTxLimit[_msgSender()] = true;
        _excludedFromTxLimit[DEAD] = true;
        _excludedFromTxLimit[ZERO] = true;
        _excludedFromTxLimit[address(this)] = true;

        _excludedFromHoldLimit[_msgSender()] = true;
        _excludedFromHoldLimit[DEAD] = true;
        _excludedFromHoldLimit[ZERO] = true;
        _excludedFromHoldLimit[address(this)] = true;
    }

    /**
     * @notice Blacklist the account
     * @dev Only callable by owner
     */
    function blacklistAccount(address account, bool flag) external onlyOwner {
        _blacklist[account] = flag;
    }

    /**
     * @notice Check if the account is included in black list
     * @param account: the account to be checked
     */
    function blacklisted(address account) external view returns (bool) {
        return _blacklist[account];
    }

    /**
     * @notice Exclude / Include the account from max tx limit
     * @dev Only callable by owner
     */
    function excludeFromTxLimit(address account, bool flag) external onlyOwner {
        _excludedFromTxLimit[account] = flag;
    }

    /**
     * @notice Check if the account is excluded from max tx limit
     * @param account: the account to be checked
     */
    function excludedFromTxLimit(address account) external view returns (bool) {
        return _excludedFromTxLimit[account];
    }

    /**
     * @notice Exclude / Include the account from max wallet limit
     * @dev Only callable by owner
     */
    function excludeFromHoldLimit(address account, bool flag)
        external
        onlyOwner
    {
        _excludedFromHoldLimit[account] = flag;
    }

    /**
     * @notice Check if the account is excluded from max wallet limit
     * @param account: the account to be checked
     */
    function excludedFromHoldLimit(address account)
        external
        view
        returns (bool)
    {
        return _excludedFromHoldLimit[account];
    }

    /**
     * @notice Set anti whales limit configuration
     * @param txLimit: max amount of token in a transaction
     * @param holdLimit: max amount of token can be kept in a wallet
     * @dev Only callable by owner
     */
    function setAntiWhalesConfiguration(uint256 txLimit, uint256 holdLimit)
        external
        onlyOwner
    {
        require(txLimit >= MAX_TX_AMOUNT_MIN_LIMIT, "Max tx amount too small");
        require(
            holdLimit >= MAX_WALLET_AMOUNT_MIN_LIMIT,
            "Max wallet amount too small"
        );
        _txLimit = txLimit;
        _holdLimit = holdLimit;
    }

    function viewHoldLimit() external view returns (uint256) {
        return _holdLimit;
    }

    function viewTxLimit() external view returns (uint256) {
        return _txLimit;
    }
}