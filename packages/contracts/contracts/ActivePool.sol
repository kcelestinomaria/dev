// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IActivePool.sol';
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
Formerly ETH -> UNLOCK , LUSD -> myUSD , trove -> lockedSAFE
 * The Active Pool holds the UNLOCK collateral and myUSD debt (but not myUSD tokens) for all active lockedSAFEs.
 *
 * When a lockedSAFE is liquidated, it's UNLOCK and myUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is Ownable, CheckContract, IActivePool {
    using SafeMath for uint256;

    string constant public NAME = "ActivePool";

    address public borrowerOperationsAddress;
    address public lockedSAFEManagerAddress;
    address public stabilityPoolAddress;
    address public defaultPoolAddress;
    uint256 internal UNLOCK;  // deposited UNLOCKer tracker
    uint256 internal myUSDDebt;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event lockedSAFEManagerAddressChanged(address _newlockedSAFEManagerAddress);
    event ActivePoolmyUSDDebtUpdated(uint _myUSDDebt);
    event ActivePoolUNLOCKBalanceUpdated(uint _UNLOCK);

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _lockedSAFEManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress
    )
        external
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_lockedSAFEManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        lockedSAFEManagerAddress = _lockedSAFEManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit lockedSAFEManagerAddressChanged(_lockedSAFEManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);

        _renounceOwnership();
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the UNLOCK state variable.
    *
    *Not necessarily equal to the the contract's raw UNLOCK balance - UNLOCKer can be forcibly sent to contracts.
    */
    function getUNLOCK() external view override returns (uint) {
        return UNLOCK;
    }

    function getmyUSDDebt() external view override returns (uint) {
        return myUSDDebt;
    }

    // --- Pool functionality ---

    function sendUNLOCK(address _account, uint _amount) external override {
        _requireCallerIsBOorlockedSAFEMorSP();
        UNLOCK = UNLOCK.sub(_amount);
        emit ActivePoolUNLOCKBalanceUpdated(UNLOCK);
        emit UNLOCKerSent(_account, _amount);

        (bool success, ) = _account.call{ value: _amount }("");
        require(success, "ActivePool: sending UNLOCK failed");
    }

    function increasemyUSDDebt(uint _amount) external override {
        _requireCallerIsBOorlockedSAFEM();
        myUSDDebt  = myUSDDebt.add(_amount);
        ActivePoolmyUSDDebtUpdated(myUSDDebt);
    }

    function decreasemyUSDDebt(uint _amount) external override {
        _requireCallerIsBOorlockedSAFEMorSP();
        myUSDDebt = myUSDDebt.sub(_amount);
        ActivePoolmyUSDDebtUpdated(myUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorlockedSAFEMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == lockedSAFEManagerAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor lockedSAFEManager nor StabilityPool");
    }

    function _requireCallerIsBOorlockedSAFEM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == lockedSAFEManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor lockedSAFEManager");
    }

    // --- Fallback function ---

    receive() external payable {
        _requireCallerIsBorrowerOperationsOrDefaultPool();
        UNLOCK = UNLOCK.add(msg.value);
        emit ActivePoolUNLOCKBalanceUpdated(UNLOCK);
    }
}
