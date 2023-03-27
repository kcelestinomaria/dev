// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ICollSurplusPool.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";


contract CollSurplusPool is Ownable, CheckContract, ICollSurplusPool {
    using SafeMath for uint256;

    string constant public NAME = "CollSurplusPool";

    address public borrowerOperationsAddress;
    address public lockedSAFEManagerAddress;
    address public activePoolAddress;

    // deposited UNLOCKer tracker
    uint256 internal UNLOCK;
    // Collateral surplus claimable by lockedSAFE owners
    mapping (address => uint) internal balances;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event lockedSAFEManagerAddressChanged(address _newlockedSAFEManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);

    event CollBalanceUpdated(address indexed _account, uint _newBalance);
    event UNLOCKerSent(address _to, uint _amount);
    
    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _lockedSAFEManagerAddress,
        address _activePoolAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_lockedSAFEManagerAddress);
        checkContract(_activePoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        lockedSAFEManagerAddress = _lockedSAFEManagerAddress;
        activePoolAddress = _activePoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit lockedSAFEManagerAddressChanged(_lockedSAFEManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    /* Returns the UNLOCK state variable at ActivePool address.
       Not necessarily equal to the raw UNLOCKer balance - UNLOCKer can be forcibly sent to contracts. */
    function getUNLOCK() external view override returns (uint) {
        return UNLOCK;
    }

    function getCollateral(address _account) external view override returns (uint) {
        return balances[_account];
    }

    // --- Pool functionality ---

    function accountSurplus(address _account, uint _amount) external override {
        _requireCallerIslockedSAFEManager();

        uint newAmount = balances[_account].add(_amount);
        balances[_account] = newAmount;

        emit CollBalanceUpdated(_account, newAmount);
    }

    function claimColl(address _account) external override {
        _requireCallerIsBorrowerOperations();
        uint claimableColl = balances[_account];
        require(claimableColl > 0, "CollSurplusPool: No collateral available to claim");

        balances[_account] = 0;
        emit CollBalanceUpdated(_account, 0);

        UNLOCK = UNLOCK.sub(claimableColl);
        emit UNLOCKerSent(_account, claimableColl);

        (bool success, ) = _account.call{ value: claimableColl }("");
        require(success, "CollSurplusPool: sending UNLOCK failed");
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == borrowerOperationsAddress,
            "CollSurplusPool: Caller is not Borrower Operations");
    }

    function _requireCallerIslockedSAFEManager() internal view {
        require(
            msg.sender == lockedSAFEManagerAddress,
            "CollSurplusPool: Caller is not lockedSAFEManager");
    }

    function _requireCallerIsActivePool() internal view {
        require(
            msg.sender == activePoolAddress,
            "CollSurplusPool: Caller is not Active Pool");
    }

    // --- Fallback function ---

    receive() external payable {
        _requireCallerIsActivePool();
        UNLOCK = UNLOCK.add(msg.value);
    }
}
