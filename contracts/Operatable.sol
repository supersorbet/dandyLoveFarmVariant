// File contracts/access/Operatable.sol

import "./Context.sol";

pragma solidity ^0.8.0;
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an operator) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the operator account will be the one that deploys the contract. This
 * can later be changed with {transferOperator}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOperator`, which can be applied to your functions to restrict their use to
 * the operator.
  * 
  * It is recommended to use with Operator.sol to set permissions per specific functions
 */
abstract contract Operatable is Context {
    address private _operator;

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    /**
     * @dev Initializes the contract setting the deployer as the initial operator.
     */
    constructor() {
        _transferOperator(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the operator.
     */
    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view virtual returns (address) {
        return _operator;
    }

    /**
     * @dev Throws if the sender is not the operator.
     */
    function _checkOperator() internal view virtual {
        require(operator() == _msgSender(), "Operatable: caller is not the operator");
    }

    /**
     * @dev Leaves the contract without operator. It will not be possible to call
     * `onlyOperator` functions anymore. Can only be called by the current operator.
     *
     * NOTE: Renouncing operator will leave the contract without an operator,
     * thereby removing any functionality that is only available to the operator.
     */
    function renounceOperator() public virtual onlyOperator {
        _transferOperator(address(0));
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public virtual onlyOperator {
        require(newOperator != address(0), "Ownable: new operator is the zero address");
        _transferOperator(newOperator);
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Internal function without access restriction.
     */
    function _transferOperator(address newOperator) internal virtual {
        address oldOperator = _operator;
        _operator = newOperator;
        emit OperatorTransferred(oldOperator, newOperator);
    }
}
