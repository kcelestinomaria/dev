// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/BaseMath.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Interfaces/ImyJSRToken.sol";
import "../Interfaces/ImyJSRStaking.sol";
import "../Dependencies/JASIRIMath.sol";
import "../Interfaces/ImyUSDToken.sol";

contract myJSRStaking is ImyJSRStaking, Ownable, CheckContract, BaseMath {
    using SafeMath for uint;

    // --- Data ---
    string constant public NAME = "myJSRStaking";

    mapping( address => uint) public stakes;
    uint public totalmyJSRStaked;

    uint public F_UNLOCK;  // Running sum of UNLOCK fees per-myJSR-staked
    uint public F_myUSD; // Running sum of myJSR fees per-myJSR-staked

    // User snapshots of F_UNLOCK and F_myUSD, taken at the point at which their latest deposit was made
    mapping (address => Snapshot) public snapshots; 

    struct Snapshot {
        uint F_UNLOCK_Snapshot;
        uint F_myUSD_Snapshot;
    }
    
    ImyJSRToken public myJSRToken;
    ImyUSDToken public myUSDToken;

    address public lockedSAFEManagerAddress;
    address public borrowerOperationsAddress;
    address public activePoolAddress;

    // --- Events ---

    event myJSRTokenAddressSet(address _myJSRTokenAddress);
    event myUSDTokenAddressSet(address _myUSDTokenAddress);
    event lockedSAFEManagerAddressSet(address _lockedSAFEManager);
    event BorrowerOperationsAddressSet(address _borrowerOperationsAddress);
    event ActivePoolAddressSet(address _activePoolAddress);

    event StakeChanged(address indexed staker, uint newStake);
    event StakingGainsWithdrawn(address indexed staker, uint myUSDGain, uint UNLOCKGain);
    event F_UNLOCKUpdated(uint _F_UNLOCK);
    event F_myUSDUpdated(uint _F_myUSD);
    event TotalmyJSRStakedUpdated(uint _totalmyJSRStaked);
    event UNLOCKerSent(address _account, uint _amount);
    event StakerSnapshotsUpdated(address _staker, uint _F_UNLOCK, uint _F_myUSD);

    // --- Functions ---

    function setAddresses
    (
        address _myJSRTokenAddress,
        address _myUSDTokenAddress,
        address _lockedSAFEManagerAddress, 
        address _borrowerOperationsAddress,
        address _activePoolAddress
    ) 
        external 
        onlyOwner 
        override 
    {
        checkContract(_myJSRTokenAddress);
        checkContract(_myUSDTokenAddress);
        checkContract(_lockedSAFEManagerAddress);
        checkContract(_borrowerOperationsAddress);
        checkContract(_activePoolAddress);

        myJSRToken = ImyJSRToken(_myJSRTokenAddress);
        myUSDToken = ImyUSDToken(_myUSDTokenAddress);
        lockedSAFEManagerAddress = _lockedSAFEManagerAddress;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePoolAddress = _activePoolAddress;

        emit myJSRTokenAddressSet(_myJSRTokenAddress);
        emit myJSRTokenAddressSet(_myUSDTokenAddress);
        emit lockedSAFEManagerAddressSet(_lockedSAFEManagerAddress);
        emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
        emit ActivePoolAddressSet(_activePoolAddress);

        _renounceOwnership();
    }

    // If caller has a pre-existing stake, send any accumulated UNLOCK and myUSD gains to them. 
    function stake(uint _myJSRamount) external override {
        _requireNonZeroAmount(_myJSRamount);

        uint currentStake = stakes[msg.sender];

        uint UNLOCKGain;
        uint myUSDGain;
        // Grab any accumulated UNLOCK and myUSD gains from the current stake
        if (currentStake != 0) {
            UNLOCKGain = _getPendingUNLOCKGain(msg.sender);
            myUSDGain = _getPendingmyUSDGain(msg.sender);
        }
    
       _updateUserSnapshots(msg.sender);

        uint newStake = currentStake.add(_myJSRamount);

        // Increase user’s stake and total myJSR staked
        stakes[msg.sender] = newStake;
        totalmyJSRStaked = totalmyJSRStaked.add(_myJSRamount);
        emit TotalmyJSRStakedUpdated(totalmyJSRStaked);

        // Transfer myJSR from caller to this contract
        myJSRToken.sendTomyJSRStaking(msg.sender, _myJSRamount);

        emit StakeChanged(msg.sender, newStake);
        emit StakingGainsWithdrawn(msg.sender, myUSDGain, UNLOCKGain);

         // Send accumulated myUSD and UNLOCK gains to the caller
        if (currentStake != 0) {
            myUSDToken.transfer(msg.sender, myUSDGain);
            _sendUNLOCKGainToUser(UNLOCKGain);
        }
    }

    // Unstake the myJSR and send the it back to the caller, along with their accumulated myUSD & UNLOCK gains. 
    // If requested amount > stake, send their entire stake.
    function unstake(uint _myJSRamount) external override {
        uint currentStake = stakes[msg.sender];
        _requireUserHasStake(currentStake);

        // Grab any accumulated UNLOCK and myUSD gains from the current stake
        uint UNLOCKGain = _getPendingUNLOCKGain(msg.sender);
        uint myUSDGain = _getPendingmyUSDGain(msg.sender);
        
        _updateUserSnapshots(msg.sender);

        if (_myJSRamount > 0) {
            uint myJSRToWithdraw = JASIRIMath._min(_myJSRamount, currentStake);

            uint newStake = currentStake.sub(myJSRToWithdraw);

            // Decrease user's stake and total myJSR staked
            stakes[msg.sender] = newStake;
            totalmyJSRStaked = totalmyJSRStaked.sub(myJSRToWithdraw);
            emit TotalmyJSRStakedUpdated(totalmyJSRStaked);

            // Transfer unstaked myJSR to user
            myJSRToken.transfer(msg.sender, myJSRToWithdraw);

            emit StakeChanged(msg.sender, newStake);
        }

        emit StakingGainsWithdrawn(msg.sender, myUSDGain, UNLOCKGain);

        // Send accumulated myUSD and UNLOCK gains to the caller
        myUSDToken.transfer(msg.sender, myUSDGain);
        _sendUNLOCKGainToUser(UNLOCKGain);
    }

    // --- Reward-per-unit-staked increase functions. Called by JASIRI core contracts ---

    function increaseF_UNLOCK(uint _UNLOCKFee) external override {
        _requireCallerIslockedSAFEManager();
        uint UNLOCKFeePermyJSRStaked;
     
        if (totalmyJSRStaked > 0) {UNLOCKFeePermyJSRStaked = _UNLOCKFee.mul(DECIMAL_PRECISION).div(totalmyJSRStaked);}

        F_UNLOCK = F_UNLOCK.add(UNLOCKFeePermyJSRStaked); 
        emit F_UNLOCKUpdated(F_UNLOCK);
    }

    function increaseF_myUSD(uint _myUSDFee) external override {
        _requireCallerIsBorrowerOperations();
        uint myUSDFeePermyJSRStaked;
        
        if (totalmyJSRStaked > 0) {myUSDFeePermyJSRStaked = _myUSDFee.mul(DECIMAL_PRECISION).div(totalmyJSRStaked);}
        
        F_myUSD = F_myUSD.add(myUSDFeePermyJSRStaked);
        emit F_myUSDUpdated(F_myUSD);
    }

    // --- Pending reward functions ---

    function getPendingUNLOCKGain(address _user) external view override returns (uint) {
        return _getPendingUNLOCKGain(_user);
    }

    function _getPendingUNLOCKGain(address _user) internal view returns (uint) {
        uint F_UNLOCK_Snapshot = snapshots[_user].F_UNLOCK_Snapshot;
        uint UNLOCKGain = stakes[_user].mul(F_UNLOCK.sub(F_UNLOCK_Snapshot)).div(DECIMAL_PRECISION);
        return UNLOCKGain;
    }

    function getPendingmyUSDGain(address _user) external view override returns (uint) {
        return _getPendingmyUSDGain(_user);
    }

    function _getPendingmyUSDGain(address _user) internal view returns (uint) {
        uint F_myUSD_Snapshot = snapshots[_user].F_myUSD_Snapshot;
        uint myUSDGain = stakes[_user].mul(F_myUSD.sub(F_myUSD_Snapshot)).div(DECIMAL_PRECISION);
        return myUSDGain;
    }

    // --- Internal helper functions ---

    function _updateUserSnapshots(address _user) internal {
        snapshots[_user].F_UNLOCK_Snapshot = F_UNLOCK;
        snapshots[_user].F_myUSD_Snapshot = F_myUSD;
        emit StakerSnapshotsUpdated(_user, F_UNLOCK, F_myUSD);
    }

    function _sendUNLOCKGainToUser(uint UNLOCKGain) internal {
        emit UNLOCKerSent(msg.sender, UNLOCKGain);
        (bool success, ) = msg.sender.call{value: UNLOCKGain}("");
        require(success, "myJSRStaking: Failed to send accumulated UNLOCKGain");
    }

    // --- 'require' functions ---

    function _requireCallerIslockedSAFEManager() internal view {
        require(msg.sender == lockedSAFEManagerAddress, "myJSRStaking: caller is not lockedSAFEM");
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "myJSRStaking: caller is not BorrowerOps");
    }

     function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "myJSRStaking: caller is not ActivePool");
    }

    function _requireUserHasStake(uint currentStake) internal pure {  
        require(currentStake > 0, 'myJSRStaking: User must have a non-zero stake');  
    }

    function _requireNonZeroAmount(uint _amount) internal pure {
        require(_amount > 0, 'myJSRStaking: Amount must be non-zero');
    }

    receive() external payable {
        _requireCallerIsActivePool();
    }
}
