// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ILockedSAFEManager.sol";
import "./Interfaces/ImyUSDToken.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ISortedLockedSAFEs.sol";
import "./Interfaces/ImyJSRStaking.sol"; // LQTY -> myJSR
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

contract BorrowerOperations is LiquityBase, Ownable, CheckContract, IBorrowerOperations {
    string constant public NAME = "BorrowerOperations";

    // --- Connected contract declarations ---

    ILockedSAFEManager public LockedSAFEManager;

    address stabilityPoolAddress;

    address gasPoolAddress;

    ICollSurplusPool collSurplusPool;

    ImyJSRStaking public myJSRStaking;
    address public myJSRStakingAddress;

    ImyUSDToken public myUSDToken;

    // A doubly linked list of LockedSAFEs, sorted by their collateral ratios
    ISortedLockedSAFEs public sortedLockedSAFEs;

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

     struct LocalVariables_adjustLockedSAFE {
        uint price;
        uint collChange;
        uint netDebtChange;
        bool isCollIncrease;
        uint debt;
        uint coll;
        uint oldICR;
        uint newICR;
        uint newTCR;
        uint myUSDFee;
        uint newDebt;
        uint newColl;
        uint stake;
    }

    struct LocalVariables_openLockedSAFE {
        uint price;
        uint myUSDFee;
        uint netDebt;
        uint compositeDebt;
        uint ICR;
        uint NICR;
        uint stake;
        uint arrayIndex;
    }

    struct ContractsCache {
        ILockedSAFEManager LockedSAFEManager;
        IActivePool activePool;
        ImyUSDToken myUSDToken;
    }

    enum BorrowerOperation {
        openLockedSAFE,
        closeLockedSAFE,
        adjustLockedSAFE
    }

    event LockedSAFEManagerAddressChanged(address _newLockedSAFEManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event SortedLockedSAFEsAddressChanged(address _sortedLockedSAFEsAddress);
    event myUSDTokenAddressChanged(address _myUSDTokenAddress);
    event myJSRStakingAddressChanged(address _myJSRStakingAddress);

    event LockedSAFECreated(address indexed _borrower, uint arrayIndex);
    event LockedSAFEUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, BorrowerOperation operation);
    event myUSDBorrowingFeePaid(address indexed _borrower, uint _myUSDFee);
    
    // --- Dependency setters ---

    function setAddresses(
        address _LockedSAFEManagerAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _sortedLockedSAFEsAddress,
        address _myUSDTokenAddress,
        address _myJSRStakingAddress
    )
        external
        override
        onlyOwner
    {
        // This makes impossible to open a LockedSAFE with zero withdrawn myUSD
        assert(MIN_NET_DEBT > 0);

        checkContract(_LockedSAFEManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_gasPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_priceFeedAddress);
        checkContract(_sortedLockedSAFEsAddress);
        checkContract(_myUSDTokenAddress);
        checkContract(_myJSRStakingAddress);

        LockedSAFEManager = ILockedSAFEManager(_LockedSAFEManagerAddress);
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPoolAddress = _stabilityPoolAddress;
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        sortedLockedSAFEs = ISortedLockedSAFEs(_sortedLockedSAFEsAddress);
        myUSDToken = ImyUSDToken(_myUSDTokenAddress);
        myJSRStakingAddress = _myJSRStakingAddress;
        myJSRStaking = ImyJSRStaking(_myJSRStakingAddress);

        emit LockedSAFEManagerAddressChanged(_LockedSAFEManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit GasPoolAddressChanged(_gasPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit SortedLockedSAFEsAddressChanged(_sortedLockedSAFEsAddress);
        emit myUSDTokenAddressChanged(_myUSDTokenAddress);
        emit myJSRStakingAddressChanged(_myJSRStakingAddress);

        _renounceOwnership();
    }

    // --- Borrower LockedSAFE Operations ---

    function openLockedSAFE(uint _maxFeePercentage, uint _myUSDAmount, address _upperHint, address _lowerHint) external payable override {
        ContractsCache memory contractsCache = ContractsCache(LockedSAFEManager, activePool, myUSDToken);
        LocalVariables_openLockedSAFE memory vars;

        vars.price = priceFeed.fetchPrice();
        bool isRecoveryMode = _checkRecoveryMode(vars.price);

        _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
        _requireLockedSAFEisNotActive(contractsCache.LockedSAFEManager, msg.sender);

        vars.myUSDFee;
        vars.netDebt = _myUSDAmount;

        if (!isRecoveryMode) {
            vars.myUSDFee = _triggerBorrowingFee(contractsCache.LockedSAFEManager, contractsCache.myUSDToken, _myUSDAmount, _maxFeePercentage);
            vars.netDebt = vars.netDebt.add(vars.myUSDFee);
        }
        _requireAtLeastMinNetDebt(vars.netDebt);

        // ICR is based on the composite debt, i.e. the requested myUSD amount + myUSD borrowing fee + myUSD gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);
        assert(vars.compositeDebt > 0);
        
        vars.ICR = LiquityMath._computeCR(msg.value, vars.compositeDebt, vars.price);
        vars.NICR = LiquityMath._computeNominalCR(msg.value, vars.compositeDebt);

        if (isRecoveryMode) {
            _requireICRisAboveCCR(vars.ICR);
        } else {
            _requireICRisAboveMCR(vars.ICR);
            uint newTCR = _getNewTCRFromLockedSAFEChange(msg.value, true, vars.compositeDebt, true, vars.price);  // bools: coll increase, debt increase
            _requireNewTCRisAboveCCR(newTCR); 
        }

        // Set the LockedSAFE struct's properties
        contractsCache.LockedSAFEManager.setLockedSAFEStatus(msg.sender, 1);
        contractsCache.LockedSAFEManager.increaseLockedSAFEColl(msg.sender, msg.value);
        contractsCache.LockedSAFEManager.increaseLockedSAFEDebt(msg.sender, vars.compositeDebt);

        contractsCache.LockedSAFEManager.updateLockedSAFERewardSnapshots(msg.sender);
        vars.stake = contractsCache.LockedSAFEManager.updateStakeAndTotalStakes(msg.sender);

        sortedLockedSAFEs.insert(msg.sender, vars.NICR, _upperHint, _lowerHint);
        vars.arrayIndex = contractsCache.LockedSAFEManager.addLockedSAFEOwnerToArray(msg.sender);
        emit LockedSAFECreated(msg.sender, vars.arrayIndex);

        // Move the ether to the Active Pool, and mint the myUSDAmount to the borrower
        _activePoolAddColl(contractsCache.activePool, msg.value);
        _withdrawmyUSD(contractsCache.activePool, contractsCache.myUSDToken, msg.sender, _myUSDAmount, vars.netDebt);
        // Move the myUSD gas compensation to the Gas Pool
        _withdrawmyUSD(contractsCache.activePool, contractsCache.myUSDToken, gasPoolAddress, myUSD_GAS_COMPENSATION, myUSD_GAS_COMPENSATION);

        emit LockedSAFEUpdated(msg.sender, vars.compositeDebt, msg.value, vars.stake, BorrowerOperation.openLockedSAFE);
        emit myUSDBorrowingFeePaid(msg.sender, vars.myUSDFee);
    }

    // Send ETH as collateral to a LockedSAFE
    function addColl(address _upperHint, address _lowerHint) external payable override {
        _adjustLockedSAFE(msg.sender, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Send ETH as collateral to a LockedSAFE. Called by only the Stability Pool.
    function moveETHGainToLockedSAFE(address _borrower, address _upperHint, address _lowerHint) external payable override {
        _requireCallerIsStabilityPool();
        _adjustLockedSAFE(_borrower, 0, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw ETH collateral from a LockedSAFE
    function withdrawColl(uint _collWithdrawal, address _upperHint, address _lowerHint) external override {
        _adjustLockedSAFE(msg.sender, _collWithdrawal, 0, false, _upperHint, _lowerHint, 0);
    }

    // Withdraw myUSD tokens from a LockedSAFE: mint new myUSD tokens to the owner, and increase the LockedSAFE's debt accordingly
    function withdrawmyUSD(uint _maxFeePercentage, uint _myUSDAmount, address _upperHint, address _lowerHint) external override {
        _adjustLockedSAFE(msg.sender, 0, _myUSDAmount, true, _upperHint, _lowerHint, _maxFeePercentage);
    }

    // Repay myUSD tokens to a LockedSAFE: Burn the repaid myUSD tokens, and reduce the LockedSAFE's debt accordingly
    function repaymyUSD(uint _myUSDAmount, address _upperHint, address _lowerHint) external override {
        _adjustLockedSAFE(msg.sender, 0, _myUSDAmount, false, _upperHint, _lowerHint, 0);
    }

    function adjustLockedSAFE(uint _maxFeePercentage, uint _collWithdrawal, uint _myUSDChange, bool _isDebtIncrease, address _upperHint, address _lowerHint) external payable override {
        _adjustLockedSAFE(msg.sender, _collWithdrawal, _myUSDChange, _isDebtIncrease, _upperHint, _lowerHint, _maxFeePercentage);
    }

    /*
    * _adjustLockedSAFE(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal. 
    *
    * It therefore expects either a positive msg.value, or a positive _collWithdrawal argument.
    *
    * If both are positive, it will revert.
    */
    function _adjustLockedSAFE(address _borrower, uint _collWithdrawal, uint _myUSDChange, bool _isDebtIncrease, address _upperHint, address _lowerHint, uint _maxFeePercentage) internal {
        ContractsCache memory contractsCache = ContractsCache(LockedSAFEManager, activePool, myUSDToken);
        LocalVariables_adjustLockedSAFE memory vars;

        vars.price = priceFeed.fetchPrice();
        bool isRecoveryMode = _checkRecoveryMode(vars.price);

        if (_isDebtIncrease) {
            _requireValidMaxFeePercentage(_maxFeePercentage, isRecoveryMode);
            _requireNonZeroDebtChange(_myUSDChange);
        }
        _requireSingularCollChange(_collWithdrawal);
        _requireNonZeroAdjustment(_collWithdrawal, _myUSDChange);
        _requireLockedSAFEisActive(contractsCache.LockedSAFEManager, _borrower);

        // Confirm the operation is either a borrower adjusting their own LockedSAFE, or a pure ETH transfer from the Stability Pool to a LockedSAFE
        assert(msg.sender == _borrower || (msg.sender == stabilityPoolAddress && msg.value > 0 && _myUSDChange == 0));

        contractsCache.LockedSAFEManager.applyPendingRewards(_borrower);

        // Get the collChange based on whether or not ETH was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(msg.value, _collWithdrawal);

        vars.netDebtChange = _myUSDChange;

        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (_isDebtIncrease && !isRecoveryMode) { 
            vars.myUSDFee = _triggerBorrowingFee(contractsCache.LockedSAFEManager, contractsCache.myUSDToken, _myUSDChange, _maxFeePercentage);
            vars.netDebtChange = vars.netDebtChange.add(vars.myUSDFee); // The raw debt change includes the fee
        }

        vars.debt = contractsCache.LockedSAFEManager.getLockedSAFEDebt(_borrower);
        vars.coll = contractsCache.LockedSAFEManager.getLockedSAFEColl(_borrower);
        
        // Get the LockedSAFE's old ICR before the adjustment, and what its new ICR will be after the adjustment
        vars.oldICR = LiquityMath._computeCR(vars.coll, vars.debt, vars.price);
        vars.newICR = _getNewICRFromLockedSAFEChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, vars.price);
        assert(_collWithdrawal <= vars.coll); 

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(isRecoveryMode, _collWithdrawal, _isDebtIncrease, vars);
            
        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough myUSD
        if (!_isDebtIncrease && _myUSDChange > 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt).sub(vars.netDebtChange));
            _requireValidmyUSDRepayment(vars.debt, vars.netDebtChange);
            _requireSufficientmyUSDBalance(contractsCache.myUSDToken, _borrower, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateLockedSAFEFromAdjustment(contractsCache.LockedSAFEManager, _borrower, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        vars.stake = contractsCache.LockedSAFEManager.updateStakeAndTotalStakes(_borrower);

        // Re-insert LockedSAFE in to the sorted list
        uint newNICR = _getNewNominalICRFromLockedSAFEChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);
        sortedLockedSAFEs.reInsert(_borrower, newNICR, _upperHint, _lowerHint);

        emit LockedSAFEUpdated(_borrower, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustLockedSAFE);
        emit myUSDBorrowingFeePaid(msg.sender,  vars.myUSDFee);

        // Use the unmodified _myUSDChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            contractsCache.activePool,
            contractsCache.myUSDToken,
            msg.sender,
            vars.collChange,
            vars.isCollIncrease,
            _myUSDChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeLockedSAFE() external override {
        ILockedSAFEManager LockedSAFEManagerCached = LockedSAFEManager;
        IActivePool activePoolCached = activePool;
        ImyUSDToken myUSDTokenCached = myUSDToken;

        _requireLockedSAFEisActive(LockedSAFEManagerCached, msg.sender);
        uint price = priceFeed.fetchPrice();
        _requireNotInRecoveryMode(price);

        LockedSAFEManagerCached.applyPendingRewards(msg.sender);

        uint coll = LockedSAFEManagerCached.getLockedSAFEColl(msg.sender);
        uint debt = LockedSAFEManagerCached.getLockedSAFEDebt(msg.sender);

        _requireSufficientmyUSDBalance(myUSDTokenCached, msg.sender, debt.sub(myUSD_GAS_COMPENSATION));

        uint newTCR = _getNewTCRFromLockedSAFEChange(coll, false, debt, false, price);
        _requireNewTCRisAboveCCR(newTCR);

        LockedSAFEManagerCached.removeStake(msg.sender);
        LockedSAFEManagerCached.closeLockedSAFE(msg.sender);

        emit LockedSAFEUpdated(msg.sender, 0, 0, 0, BorrowerOperation.closeLockedSAFE);

        // Burn the repaid myUSD from the user's balance and the gas compensation from the Gas Pool
        _repaymyUSD(activePoolCached, myUSDTokenCached, msg.sender, debt.sub(myUSD_GAS_COMPENSATION));
        _repaymyUSD(activePoolCached, myUSDTokenCached, gasPoolAddress, myUSD_GAS_COMPENSATION);

        // Send the collateral back to the user
        activePoolCached.sendETH(msg.sender, coll);
    }

    /**
     * Claim remaining collateral from a redemption or from a liquidation with ICR > MCR in Recovery Mode
     */
    function claimCollateral() external override {
        // send ETH from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(ILockedSAFEManager _LockedSAFEManager, ImyUSDToken _myUSDToken, uint _myUSDAmount, uint _maxFeePercentage) internal returns (uint) {
        _LockedSAFEManager.decayBaseRateFromBorrowing(); // decay the baseRate state variable
        uint myUSDFee = _LockedSAFEManager.getBorrowingFee(_myUSDAmount);

        _requireUserAcceptsFee(myUSDFee, _myUSDAmount, _maxFeePercentage);
        
        // Send fee to myJSR staking contract
        myJSRStaking.increaseF_myUSD(myUSDFee);
        _myUSDToken.mint(myJSRStakingAddress, myUSDFee);

        return myUSDFee;
    }

    function _getUSDValue(uint _coll, uint _price) internal pure returns (uint) {
        uint usdValue = _price.mul(_coll).div(DECIMAL_PRECISION);

        return usdValue;
    }

    function _getCollChange(
        uint _collReceived,
        uint _requestedCollWithdrawal
    )
        internal
        pure
        returns(uint collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update LockedSAFE's coll and debt based on whether they increase or decrease
    function _updateLockedSAFEFromAdjustment
    (
        ILockedSAFEManager _LockedSAFEManager,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        returns (uint, uint)
    {
        uint newColl = (_isCollIncrease) ? _LockedSAFEManager.increaseLockedSAFEColl(_borrower, _collChange)
                                        : _LockedSAFEManager.decreaseLockedSAFEColl(_borrower, _collChange);
        uint newDebt = (_isDebtIncrease) ? _LockedSAFEManager.increaseLockedSAFEDebt(_borrower, _debtChange)
                                        : _LockedSAFEManager.decreaseLockedSAFEDebt(_borrower, _debtChange);

        return (newColl, newDebt);
    }

    function _moveTokensAndETHfromAdjustment
    (
        IActivePool _activePool,
        ImyUSDToken _myUSDToken,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _myUSDChange,
        bool _isDebtIncrease,
        uint _netDebtChange
    )
        internal
    {
        if (_isDebtIncrease) {
            _withdrawmyUSD(_activePool, _myUSDToken, _borrower, _myUSDChange, _netDebtChange);
        } else {
            _repaymyUSD(_activePool, _myUSDToken, _borrower, _myUSDChange);
        }

        if (_isCollIncrease) {
            _activePoolAddColl(_activePool, _collChange);
        } else {
            _activePool.sendETH(_borrower, _collChange);
        }
    }

    // Send ETH to Active Pool and increase its recorded ETH balance
    function _activePoolAddColl(IActivePool _activePool, uint _amount) internal {
        (bool success, ) = address(_activePool).call{value: _amount}("");
        require(success, "BorrowerOps: Sending ETH to ActivePool failed");
    }

    // Issue the specified amount of myUSD to _account and increases the total active debt (_netDebtIncrease potentially includes a myUSDFee)
    function _withdrawmyUSD(IActivePool _activePool, ImyUSDToken _myUSDToken, address _account, uint _myUSDAmount, uint _netDebtIncrease) internal {
        _activePool.increasemyUSDDebt(_netDebtIncrease);
        _myUSDToken.mint(_account, _myUSDAmount);
    }

    // Burn the specified amount of myUSD from _account and decreases the total active debt
    function _repaymyUSD(IActivePool _activePool, ImyUSDToken _myUSDToken, address _account, uint _myUSD) internal {
        _activePool.decreasemyUSDDebt(_myUSD);
        _myUSDToken.burn(_account, _myUSD);
    }

    // --- 'Require' wrapper functions ---

    function _requireSingularCollChange(uint _collWithdrawal) internal view {
        require(msg.value == 0 || _collWithdrawal == 0, "BorrowerOperations: Cannot withdraw and add coll");
    }

    function _requireCallerIsBorrower(address _borrower) internal view {
        require(msg.sender == _borrower, "BorrowerOps: Caller must be the borrower for a withdrawal");
    }

    function _requireNonZeroAdjustment(uint _collWithdrawal, uint _myUSDChange) internal view {
        require(msg.value != 0 || _collWithdrawal != 0 || _myUSDChange != 0, "BorrowerOps: There must be either a collateral change or a debt change");
    }

    function _requireLockedSAFEisActive(ILockedSAFEManager _LockedSAFEManager, address _borrower) internal view {
        uint status = _LockedSAFEManager.getLockedSAFEStatus(_borrower);
        require(status == 1, "BorrowerOps: LockedSAFE does not exist or is closed");
    }

    function _requireLockedSAFEisNotActive(ILockedSAFEManager _LockedSAFEManager, address _borrower) internal view {
        uint status = _LockedSAFEManager.getLockedSAFEStatus(_borrower);
        require(status != 1, "BorrowerOps: LockedSAFE is active");
    }

    function _requireNonZeroDebtChange(uint _myUSDChange) internal pure {
        require(_myUSDChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
    }
   
    function _requireNotInRecoveryMode(uint _price) internal view {
        require(!_checkRecoveryMode(_price), "BorrowerOps: Operation not permitted during Recovery Mode");
    }

    function _requireNoCollWithdrawal(uint _collWithdrawal) internal pure {
        require(_collWithdrawal == 0, "BorrowerOps: Collateral withdrawal not permitted Recovery Mode");
    }

    function _requireValidAdjustmentInCurrentMode 
    (
        bool _isRecoveryMode,
        uint _collWithdrawal,
        bool _isDebtIncrease, 
        LocalVariables_adjustLockedSAFE memory _vars
    ) 
        internal 
        view 
    {
        /* 
        *In Recovery Mode, only allow:
        *
        * - Pure collateral top-up
        * - Pure debt repayment
        * - Collateral top-up with debt repayment
        * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
        *
        * In Normal Mode, ensure:
        *
        * - The new ICR is above MCR
        * - The adjustment won't pull the TCR below CCR
        */
        if (_isRecoveryMode) {
            _requireNoCollWithdrawal(_collWithdrawal);
            if (_isDebtIncrease) {
                _requireICRisAboveCCR(_vars.newICR);
                _requireNewICRisAboveOldICR(_vars.newICR, _vars.oldICR);
            }       
        } else { // if Normal Mode
            _requireICRisAboveMCR(_vars.newICR);
            _vars.newTCR = _getNewTCRFromLockedSAFEChange(_vars.collChange, _vars.isCollIncrease, _vars.netDebtChange, _isDebtIncrease, _vars.price);
            _requireNewTCRisAboveCCR(_vars.newTCR);  
        }
    }

    function _requireICRisAboveMCR(uint _newICR) internal pure {
        require(_newICR >= MCR, "BorrowerOps: An operation that would result in ICR < MCR is not permitted");
    }

    function _requireICRisAboveCCR(uint _newICR) internal pure {
        require(_newICR >= CCR, "BorrowerOps: Operation must leave LockedSAFE with ICR >= CCR");
    }

    function _requireNewICRisAboveOldICR(uint _newICR, uint _oldICR) internal pure {
        require(_newICR >= _oldICR, "BorrowerOps: Cannot decrease your LockedSAFE's ICR in Recovery Mode");
    }

    function _requireNewTCRisAboveCCR(uint _newTCR) internal pure {
        require(_newTCR >= CCR, "BorrowerOps: An operation that would result in TCR < CCR is not permitted");
    }

    function _requireAtLeastMinNetDebt(uint _netDebt) internal pure {
        require (_netDebt >= MIN_NET_DEBT, "BorrowerOps: LockedSAFE's net debt must be greater than minimum");
    }

    function _requireValidmyUSDRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
        require(_debtRepayment <= _currentDebt.sub(myUSD_GAS_COMPENSATION), "BorrowerOps: Amount repaid must not be larger than the LockedSAFE's debt");
    }

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "BorrowerOps: Caller is not Stability Pool");
    }

     function _requireSufficientmyUSDBalance(ImyUSDToken _myUSDToken, address _borrower, uint _debtRepayment) internal view {
        require(_myUSDToken.balanceOf(_borrower) >= _debtRepayment, "BorrowerOps: Caller doesnt have enough myUSD to make repayment");
    }

    function _requireValidMaxFeePercentage(uint _maxFeePercentage, bool _isRecoveryMode) internal pure {
        if (_isRecoveryMode) {
            require(_maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must less than or equal to 100%");
        } else {
            require(_maxFeePercentage >= BORROWING_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must be between 0.5% and 100%");
        }
    }

    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewNominalICRFromLockedSAFEChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        pure
        internal
        returns (uint)
    {
        (uint newColl, uint newDebt) = _getNewLockedSAFEAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newNICR = LiquityMath._computeNominalCR(newColl, newDebt);
        return newNICR;
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromLockedSAFEChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        pure
        internal
        returns (uint)
    {
        (uint newColl, uint newDebt) = _getNewLockedSAFEAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newICR = LiquityMath._computeCR(newColl, newDebt, _price);
        return newICR;
    }

    function _getNewLockedSAFEAmounts(
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        pure
        returns (uint, uint)
    {
        uint newColl = _coll;
        uint newDebt = _debt;

        newColl = _isCollIncrease ? _coll.add(_collChange) :  _coll.sub(_collChange);
        newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

        return (newColl, newDebt);
    }

    function _getNewTCRFromLockedSAFEChange
    (
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        internal
        view
        returns (uint)
    {
        uint totalColl = getEntireSystemColl();
        uint totalDebt = getEntireSystemDebt();

        totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
        totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

        uint newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price);
        return newTCR;
    }

    function getCompositeDebt(uint _debt) external pure override returns (uint) {
        return _getCompositeDebt(_debt);
    }
}
