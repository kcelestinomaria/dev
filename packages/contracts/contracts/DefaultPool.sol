// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IDefaultPool.sol';
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
 * The Default Pool holds the UNLOCK and myUSD debt (but not myUSD tokens) from liquidations that have been redistributed
 * to active lockedSAFEs but not yet "applied", i.e. not yet recorded on a recipient active lockedSAFE's struct.
 *
 * When a lockedSAFE makes an operation that applies its pending UNLOCK and myUSD debt, its pending UNLOCK and myUSD debt is moved
 * from the Default Pool to the Active Pool.
 */
contract DefaultPool is Ownable, CheckContract, IDefaultPool {
    using SafeMath for uint256;

    string constant public NAME = "DefaultPool";

    address public lockedSAFEManagerAddress;
    address public activePoolAddress;
    uint256 internal UNLOCK;  // deposited UNLOCK tracker
    uint256 internal myUSDDebt;  // debt

    event lockedSAFEManagerAddressChanged(address _newlockedSAFEManagerAddress);
    event DefaultPoolmyUSDDebtUpdated(uint _myUSDDebt);
    event DefaultPoolUNLOCKBalanceUpdated(uint _UNLOCK);

    // --- Dependency setters ---

    function setAddresses(
        address _lockedSAFEManagerAddress,
        address _activePoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_lockedSAFEManagerAddress);
        checkContract(_activePoolAddress);

        lockedSAFEManagerAddress = _lockedSAFEManagerAddress;
        activePoolAddress = _activePoolAddress;

        emit lockedSAFEManagerAddressChanged(_lockedSAFEManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the UNLOCK state variable.
    *
    * Not necessarily equal to the the contract's raw UNLOCK balance - UNLOCKer can be forcibly sent to contracts.
    */
    function getUNLOCK() external view override returns (uint) {
        return UNLOCK;
    }

    function getmyUSDDebt() external view override returns (uint) {
        return myUSDDebt;
    }

    // --- Pool functionality ---

    function sendUNLOCKToActivePool(uint _amount) external override {
        _requireCallerIslockedSAFEManager();
        address activePool = activePoolAddress; // cache to save an SLOAD
        UNLOCK = UNLOCK.sub(_amount);
        emit DefaultPoolUNLOCKBalanceUpdated(UNLOCK);
        emit UNLOCKerSent(activePool, _amount);

        (bool success, ) = activePool.call{ value: _amount }("");
        require(success, "DefaultPool: sending UNLOCK failed");
    }

    function increasemyUSDDebt(uint _amount) external override {
        _requireCallerIslockedSAFEManager();
        myUSDDebt = myUSDDebt.add(_amount);
        emit DefaultPoolmyUSDDebtUpdated(myUSDDebt);
    }

    function decreasemyUSDDebt(uint _amount) external override {
        _requireCallerIslockedSAFEManager();
        myUSDDebt = myUSDDebt.sub(_amount);
        emit DefaultPoolmyUSDDebtUpdated(myUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIslockedSAFEManager() internal view {
        require(msg.sender == lockedSAFEManagerAddress, "DefaultPool: Caller is not the lockedSAFEManager");
    }

    // --- Fallback function ---

    receive() external payable {
        _requireCallerIsActivePool();
        UNLOCK = UNLOCK.add(msg.value);
        emit DefaultPoolUNLOCKBalanceUpdated(UNLOCK);
    }
}
