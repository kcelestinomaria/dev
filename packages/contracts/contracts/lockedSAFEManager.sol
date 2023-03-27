// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IlockedSAFEManager.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/ImyUSDToken.sol";
import "./Interfaces/ISortedlockedSAFEs.sol";
import "./Interfaces/ImyJSRToken.sol";
import "./Interfaces/ImyJSRStaking.sol";
import "./Dependencies/JASIRIBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

contract lockedSAFEManager is JASIRIBase, Ownable, CheckContract, IlockedSAFEManager {
    string constant public NAME = "lockedSAFEManager";

    // --- Connected contract declarations ---

    address public borrowerOperationsAddress;

    IStabilityPool public override stabilityPool;

    address gasPoolAddress;

    ICollSurplusPool collSurplusPool;

    ImyUSDToken public override myUSDToken;

    ImyJSRToken public override myJSRToken;

    ImyJSRStaking public override myJSRStaking;

    // A doubly linked list of lockedSAFEs, sorted by their sorted by their collateral ratios
    ISortedlockedSAFEs public sortedlockedSAFEs;

    // --- Data structures ---

    uint constant public SECONDS_IN_ONE_MINUTE = 60;
    /*
     * Half-life of 12h. 12h = 720 min
     * (1/2) = d^720 => d = (1/2)^(1/720)
     */
    uint constant public MINUTE_DECAY_FACTOR = 999037758833783000;
    uint constant public REDEMPTION_FEE_FLOOR = DECIMAL_PRECISION / 1000 * 5; // 0.5%
    uint constant public MAX_BORROWING_FEE = DECIMAL_PRECISION / 100 * 5; // 5%

    // During bootsrap period redemptions are not allowed
    uint constant public BOOTSTRAP_PERIOD = 14 days;

    /*
    * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
    * Corresponds to (1 / ALPHA) in the white paper.
    */
    uint constant public BETA = 2;

    uint public baseRate;

    // The timestamp of the latest fee operation (redemption or new myUSD issuance)
    uint public lastFeeOperationTime;

    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    // Store the necessary data for a lockedSAFE
    struct lockedSAFE {
        uint debt;
        uint coll;
        uint stake;
        Status status;
        uint128 arrayIndex;
    }

    mapping (address => lockedSAFE) public lockedSAFEs;

    uint public totalStakes;

    // Snapshot of the value of totalStakes, taken immediately after the latest liquidation
    uint public totalStakesSnapshot;

    // Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
    uint public totalCollateralSnapshot;

    /*
    * L_UNLOCK and L_myUSDDebt track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
    *
    * An UNLOCK gain of ( stake * [L_UNLOCK - L_UNLOCK(0)] )
    * A myUSDDebt increase  of ( stake * [L_myUSDDebt - L_myUSDDebt(0)] )
    *
    * Where L_UNLOCK(0) and L_myUSDDebt(0) are snapshots of L_UNLOCK and L_myUSDDebt for the active lockedSAFE taken at the instant the stake was made
    */
    uint public L_UNLOCK;
    uint public L_myUSDDebt;

    // Map addresses with active lockedSAFEs to their RewardSnapshot
    mapping (address => RewardSnapshot) public rewardSnapshots;

    // Object containing the UNLOCK and myUSD snapshots for a given active lockedSAFE
    struct RewardSnapshot { uint UNLOCK; uint myUSDDebt;}

    // Array of all active lockedSAFE addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    address[] public lockedSAFEOwners;

    // Error trackers for the lockedSAFE redistribution calculation
    uint public lastUNLOCKError_Redistribution;
    uint public lastmyUSDDebtError_Redistribution;

    /*
    * --- Variable container structs for liquidations ---
    *
    * These structs are used to hold, return and assign variables inside the liquidation functions,
    * in order to avoid the error: "CompilerError: Stack too deep".
    **/

    struct LocalVariables_OuterLiquidationFunction {
        uint price;
        uint myUSDInStabPool;
        bool recoveryModeAtStart;
        uint liquidatedDebt;
        uint liquidatedColl;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint collToLiquidate;
        uint pendingDebtReward;
        uint pendingCollReward;
    }

    struct LocalVariables_LiquidationSequence {
        uint remainingmyUSDInStabPool;
        uint i;
        uint ICR;
        address user;
        bool backToNormalMode;
        uint entireSystemDebt;
        uint entireSystemColl;
    }

    struct LiquidationValues {
        uint entirelockedSAFEDebt;
        uint entirelockedSAFEColl;
        uint collGasCompensation;
        uint myUSDGasCompensation;
        uint debtToOffset;
        uint collToSendToSP;
        uint debtToRedistribute;
        uint collToRedistribute;
        uint collSurplus;
    }

    struct LiquidationTotals {
        uint totalCollInSequence;
        uint totalDebtInSequence;
        uint totalCollGasCompensation;
        uint totalmyUSDGasCompensation;
        uint totalDebtToOffset;
        uint totalCollToSendToSP;
        uint totalDebtToRedistribute;
        uint totalCollToRedistribute;
        uint totalCollSurplus;
    }

    struct ContractsCache {
        IActivePool activePool;
        IDefaultPool defaultPool;
        ImyUSDToken myUSDToken;
        ImyJSRStaking myJSRStaking;
        ISortedlockedSAFEs sortedlockedSAFEs;
        ICollSurplusPool collSurplusPool;
        address gasPoolAddress;
    }
    // --- Variable container structs for redemptions ---

    struct RedemptionTotals {
        uint remainingmyUSD;
        uint totalmyUSDToRedeem;
        uint totalUNLOCKDrawn;
        uint UNLOCKFee;
        uint UNLOCKToSendToRedeemer;
        uint decayedBaseRate;
        uint price;
        uint totalmyUSDSupplyAtStart;
    }

    struct SingleRedemptionValues {
        uint myUSDLot;
        uint UNLOCKLot;
        bool cancelledPartial;
    }

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event PriceFeedAddressChanged(address _newPriceFeedAddress);
    event myUSDTokenAddressChanged(address _newmyUSDTokenAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedlockedSAFEsAddressChanged(address _sortedlockedSAFEsAddress);
    event myJSRTokenAddressChanged(address _myJSRTokenAddress);
    event myJSRStakingAddressChanged(address _myJSRStakingAddress);

    event Liquidation(uint _liquidatedDebt, uint _liquidatedColl, uint _collGasCompensation, uint _myUSDGasCompensation);
    event Redemption(uint _attemptedmyUSDAmount, uint _actualmyUSDAmount, uint _UNLOCKSent, uint _UNLOCKFee);
    event lockedSAFEUpdated(address indexed _borrower, uint _debt, uint _coll, uint _stake, lockedSAFEManagerOperation _operation);
    event lockedSAFELiquidated(address indexed _borrower, uint _debt, uint _coll, lockedSAFEManagerOperation _operation);
    event BaseRateUpdated(uint _baseRate);
    event LastFeeOpTimeUpdated(uint _lastFeeOpTime);
    event TotalStakesUpdated(uint _newTotalStakes);
    event SystemSnapshotsUpdated(uint _totalStakesSnapshot, uint _totalCollateralSnapshot);
    event LTermsUpdated(uint _L_UNLOCK, uint _L_myUSDDebt);
    event lockedSAFESnapshotsUpdated(uint _L_UNLOCK, uint _L_myUSDDebt);
    event lockedSAFEIndexUpdated(address _borrower, uint _newIndex);

     enum lockedSAFEManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        redeemCollateral
    }


    // --- Dependency setter ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _myUSDTokenAddress,
        address _sortedlockedSAFEsAddress,
        address _myJSRTokenAddress,
        address _myJSRStakingAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_activePoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_gasPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_priceFeedAddress);
        checkContract(_myUSDTokenAddress);
        checkContract(_sortedlockedSAFEsAddress);
        checkContract(_myJSRTokenAddress);
        checkContract(_myJSRStakingAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePool = IActivePool(_activePoolAddress);
        defaultPool = IDefaultPool(_defaultPoolAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        gasPoolAddress = _gasPoolAddress;
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        priceFeed = IPriceFeed(_priceFeedAddress);
        myUSDToken = ImyUSDToken(_myUSDTokenAddress);
        sortedlockedSAFEs = ISortedlockedSAFEs(_sortedlockedSAFEsAddress);
        myJSRToken = ImyJSRToken(_myJSRTokenAddress);
        myJSRStaking = ImyJSRStaking(_myJSRStakingAddress);

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit GasPoolAddressChanged(_gasPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
        emit myUSDTokenAddressChanged(_myUSDTokenAddress);
        emit SortedlockedSAFEsAddressChanged(_sortedlockedSAFEsAddress);
        emit myJSRTokenAddressChanged(_myJSRTokenAddress);
        emit myJSRStakingAddressChanged(_myJSRStakingAddress);

        _renounceOwnership();
    }

    // --- Getters ---

    function getlockedSAFEOwnersCount() external view override returns (uint) {
        return lockedSAFEOwners.length;
    }

    function getlockedSAFEFromlockedSAFEOwnersArray(uint _index) external view override returns (address) {
        return lockedSAFEOwners[_index];
    }

    // --- lockedSAFE Liquidation functions ---

    // Single liquidation function. Closes the lockedSAFE if its ICR is lower than the minimum collateral ratio.
    function liquidate(address _borrower) external override {
        _requirelockedSAFEIsActive(_borrower);

        address[] memory borrowers = new address[](1);
        borrowers[0] = _borrower;
        batchLiquidatelockedSAFEs(borrowers);
    }

    // --- Inner single liquidation functions ---

    // Liquidate one lockedSAFE, in Normal Mode.
    function _liquidateNormalMode(
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        address _borrower,
        uint _myUSDInStabPool
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        LocalVariables_InnerSingleLiquidateFunction memory vars;

        (singleLiquidation.entirelockedSAFEDebt,
        singleLiquidation.entirelockedSAFEColl,
        vars.pendingDebtReward,
        vars.pendingCollReward) = getEntireDebtAndColl(_borrower);

        _movePendinglockedSAFERewardsToActivePool(_activePool, _defaultPool, vars.pendingDebtReward, vars.pendingCollReward);
        _removeStake(_borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entirelockedSAFEColl);
        singleLiquidation.myUSDGasCompensation = myUSD_GAS_COMPENSATION;
        uint collToLiquidate = singleLiquidation.entirelockedSAFEColl.sub(singleLiquidation.collGasCompensation);

        (singleLiquidation.debtToOffset,
        singleLiquidation.collToSendToSP,
        singleLiquidation.debtToRedistribute,
        singleLiquidation.collToRedistribute) = _getOffsetAndRedistributionVals(singleLiquidation.entirelockedSAFEDebt, collToLiquidate, _myUSDInStabPool);

        _closelockedSAFE(_borrower, Status.closedByLiquidation);
        emit lockedSAFELiquidated(_borrower, singleLiquidation.entirelockedSAFEDebt, singleLiquidation.entirelockedSAFEColl, lockedSAFEManagerOperation.liquidateInNormalMode);
        emit lockedSAFEUpdated(_borrower, 0, 0, 0, lockedSAFEManagerOperation.liquidateInNormalMode);
        return singleLiquidation;
    }

    // Liquidate one lockedSAFE, in Recovery Mode.
    function _liquidateRecoveryMode(
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        address _borrower,
        uint _ICR,
        uint _myUSDInStabPool,
        uint _TCR,
        uint _price
    )
        internal
        returns (LiquidationValues memory singleLiquidation)
    {
        LocalVariables_InnerSingleLiquidateFunction memory vars;
        if (lockedSAFEOwners.length <= 1) {return singleLiquidation;} // don't liquidate if last lockedSAFE
        (singleLiquidation.entirelockedSAFEDebt,
        singleLiquidation.entirelockedSAFEColl,
        vars.pendingDebtReward,
        vars.pendingCollReward) = getEntireDebtAndColl(_borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entirelockedSAFEColl);
        singleLiquidation.myUSDGasCompensation = myUSD_GAS_COMPENSATION;
        vars.collToLiquidate = singleLiquidation.entirelockedSAFEColl.sub(singleLiquidation.collGasCompensation);

        // If ICR <= 100%, purely redistribute the lockedSAFE across all active lockedSAFEs
        if (_ICR <= _100pct) {
            _movePendinglockedSAFERewardsToActivePool(_activePool, _defaultPool, vars.pendingDebtReward, vars.pendingCollReward);
            _removeStake(_borrower);
           
            singleLiquidation.debtToOffset = 0;
            singleLiquidation.collToSendToSP = 0;
            singleLiquidation.debtToRedistribute = singleLiquidation.entirelockedSAFEDebt;
            singleLiquidation.collToRedistribute = vars.collToLiquidate;

            _closelockedSAFE(_borrower, Status.closedByLiquidation);
            emit lockedSAFELiquidated(_borrower, singleLiquidation.entirelockedSAFEDebt, singleLiquidation.entirelockedSAFEColl, lockedSAFEManagerOperation.liquidateInRecoveryMode);
            emit lockedSAFEUpdated(_borrower, 0, 0, 0, lockedSAFEManagerOperation.liquidateInRecoveryMode);
            
        // If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
        } else if ((_ICR > _100pct) && (_ICR < MCR)) {
             _movePendinglockedSAFERewardsToActivePool(_activePool, _defaultPool, vars.pendingDebtReward, vars.pendingCollReward);
            _removeStake(_borrower);

            (singleLiquidation.debtToOffset,
            singleLiquidation.collToSendToSP,
            singleLiquidation.debtToRedistribute,
            singleLiquidation.collToRedistribute) = _getOffsetAndRedistributionVals(singleLiquidation.entirelockedSAFEDebt, vars.collToLiquidate, _myUSDInStabPool);

            _closelockedSAFE(_borrower, Status.closedByLiquidation);
            emit lockedSAFELiquidated(_borrower, singleLiquidation.entirelockedSAFEDebt, singleLiquidation.entirelockedSAFEColl, lockedSAFEManagerOperation.liquidateInRecoveryMode);
            emit lockedSAFEUpdated(_borrower, 0, 0, 0, lockedSAFEManagerOperation.liquidateInRecoveryMode);
        /*
        * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
        * and there is myUSD in the Stability Pool, only offset, with no redistribution,
        * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
        * The remainder due to the capped rate will be claimable as collateral surplus.
        */
        } else if ((_ICR >= MCR) && (_ICR < _TCR) && (singleLiquidation.entirelockedSAFEDebt <= _myUSDInStabPool)) {
            _movePendinglockedSAFERewardsToActivePool(_activePool, _defaultPool, vars.pendingDebtReward, vars.pendingCollReward);
            assert(_myUSDInStabPool != 0);

            _removeStake(_borrower);
            singleLiquidation = _getCappedOffsetVals(singleLiquidation.entirelockedSAFEDebt, singleLiquidation.entirelockedSAFEColl, _price);

            _closelockedSAFE(_borrower, Status.closedByLiquidation);
            if (singleLiquidation.collSurplus > 0) {
                collSurplusPool.accountSurplus(_borrower, singleLiquidation.collSurplus);
            }

            emit lockedSAFELiquidated(_borrower, singleLiquidation.entirelockedSAFEDebt, singleLiquidation.collToSendToSP, lockedSAFEManagerOperation.liquidateInRecoveryMode);
            emit lockedSAFEUpdated(_borrower, 0, 0, 0, lockedSAFEManagerOperation.liquidateInRecoveryMode);

        } else { // if (_ICR >= MCR && ( _ICR >= _TCR || singleLiquidation.entirelockedSAFEDebt > _myUSDInStabPool))
            LiquidationValues memory zeroVals;
            return zeroVals;
        }

        return singleLiquidation;
    }

    /* In a full liquidation, returns the values for a lockedSAFE's coll and debt to be offset, and coll and debt to be
    * redistributed to active lockedSAFEs.
    */
    function _getOffsetAndRedistributionVals
    (
        uint _debt,
        uint _coll,
        uint _myUSDInStabPool
    )
        internal
        pure
        returns (uint debtToOffset, uint collToSendToSP, uint debtToRedistribute, uint collToRedistribute)
    {
        if (_myUSDInStabPool > 0) {
        /*
        * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
        * between all active lockedSAFEs.
        *
        *  If the lockedSAFE's debt is larger than the deposited myUSD in the Stability Pool:
        *
        *  - Offset an amount of the lockedSAFE's debt equal to the myUSD in the Stability Pool
        *  - Send a fraction of the lockedSAFE's collateral to the Stability Pool, equal to the fraction of its offset debt
        *
        */
            debtToOffset = JASIRIMath._min(_debt, _myUSDInStabPool);
            collToSendToSP = _coll.mul(debtToOffset).div(_debt);
            debtToRedistribute = _debt.sub(debtToOffset);
            collToRedistribute = _coll.sub(collToSendToSP);
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    /*
    *  Get its offset coll/debt and UNLOCK gas comp, and close the lockedSAFE.
    */
    function _getCappedOffsetVals
    (
        uint _entirelockedSAFEDebt,
        uint _entirelockedSAFEColl,
        uint _price
    )
        internal
        pure
        returns (LiquidationValues memory singleLiquidation)
    {
        singleLiquidation.entirelockedSAFEDebt = _entirelockedSAFEDebt;
        singleLiquidation.entirelockedSAFEColl = _entirelockedSAFEColl;
        uint cappedCollPortion = _entirelockedSAFEDebt.mul(MCR).div(_price);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(cappedCollPortion);
        singleLiquidation.myUSDGasCompensation = myUSD_GAS_COMPENSATION;

        singleLiquidation.debtToOffset = _entirelockedSAFEDebt;
        singleLiquidation.collToSendToSP = cappedCollPortion.sub(singleLiquidation.collGasCompensation);
        singleLiquidation.collSurplus = _entirelockedSAFEColl.sub(cappedCollPortion);
        singleLiquidation.debtToRedistribute = 0;
        singleLiquidation.collToRedistribute = 0;
    }

    /*
    * Liquidate a sequence of lockedSAFEs. Closes a maximum number of n under-collateralized lockedSAFEs,
    * starting from the one with the lowest collateral ratio in the system, and moving upwards
    */
    function liquidatelockedSAFEs(uint _n) external override {
        ContractsCache memory contractsCache = ContractsCache(
            activePool,
            defaultPool,
            ImyUSDToken(address(0)),
            ImyJSRStaking(address(0)),
            sortedlockedSAFEs,
            ICollSurplusPool(address(0)),
            address(0)
        );
        IStabilityPool stabilityPoolCached = stabilityPool;

        LocalVariables_OuterLiquidationFunction memory vars;

        LiquidationTotals memory totals;

        vars.price = priceFeed.fetchPrice();
        vars.myUSDInStabPool = stabilityPoolCached.getTotalmyUSDDeposits();
        vars.recoveryModeAtStart = _checkRecoveryMode(vars.price);

        // Perform the appropriate liquidation sequence - tally the values, and obtain their totals
        if (vars.recoveryModeAtStart) {
            totals = _getTotalsFromLiquidatelockedSAFEsSequence_RecoveryMode(contractsCache, vars.price, vars.myUSDInStabPool, _n);
        } else { // if !vars.recoveryModeAtStart
            totals = _getTotalsFromLiquidatelockedSAFEsSequence_NormalMode(contractsCache.activePool, contractsCache.defaultPool, vars.price, vars.myUSDInStabPool, _n);
        }

        require(totals.totalDebtInSequence > 0, "lockedSAFEManager: nothing to liquidate");

        // Move liquidated UNLOCK and myUSD to the appropriate pools
        stabilityPoolCached.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
        _redistributeDebtAndColl(contractsCache.activePool, contractsCache.defaultPool, totals.totalDebtToRedistribute, totals.totalCollToRedistribute);
        if (totals.totalCollSurplus > 0) {
            contractsCache.activePool.sendUNLOCK(address(collSurplusPool), totals.totalCollSurplus);
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(contractsCache.activePool, totals.totalCollGasCompensation);

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(vars.liquidatedDebt, vars.liquidatedColl, totals.totalCollGasCompensation, totals.totalmyUSDGasCompensation);

        // Send gas compensation to caller
        _sendGasCompensation(contractsCache.activePool, msg.sender, totals.totalmyUSDGasCompensation, totals.totalCollGasCompensation);
    }

    /*
    * This function is used when the liquidatelockedSAFEs sequence starts during Recovery Mode. However, it
    * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
    */
    function _getTotalsFromLiquidatelockedSAFEsSequence_RecoveryMode
    (
        ContractsCache memory _contractsCache,
        uint _price,
        uint _myUSDInStabPool,
        uint _n
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingmyUSDInStabPool = _myUSDInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = getEntireSystemDebt();
        vars.entireSystemColl = getEntireSystemColl();

        vars.user = _contractsCache.sortedlockedSAFEs.getLast();
        address firstUser = _contractsCache.sortedlockedSAFEs.getFirst();
        for (vars.i = 0; vars.i < _n && vars.user != firstUser; vars.i++) {
            // we need to cache it, because current user is likely going to be deleted
            address nextUser = _contractsCache.sortedlockedSAFEs.getPrev(vars.user);

            vars.ICR = getCurrentICR(vars.user, _price);

            if (!vars.backToNormalMode) {
                // Break the loop if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingmyUSDInStabPool == 0) { break; }

                uint TCR = JASIRIMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(_contractsCache.activePool, _contractsCache.defaultPool, vars.user, vars.ICR, vars.remainingmyUSDInStabPool, TCR, _price);

                // Update aggregate trackers
                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);
                vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
                vars.entireSystemColl = vars.entireSystemColl.
                    sub(singleLiquidation.collToSendToSP).
                    sub(singleLiquidation.collGasCompensation).
                    sub(singleLiquidation.collSurplus);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(vars.entireSystemColl, vars.entireSystemDebt, _price);
            }
            else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(_contractsCache.activePool, _contractsCache.defaultPool, vars.user, vars.remainingmyUSDInStabPool);

                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            }  else break;  // break if the loop reaches a lockedSAFE with ICR >= MCR

            vars.user = nextUser;
        }
    }

    function _getTotalsFromLiquidatelockedSAFEsSequence_NormalMode
    (
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        uint _price,
        uint _myUSDInStabPool,
        uint _n
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;
        ISortedlockedSAFEs sortedlockedSAFEsCached = sortedlockedSAFEs;

        vars.remainingmyUSDInStabPool = _myUSDInStabPool;

        for (vars.i = 0; vars.i < _n; vars.i++) {
            vars.user = sortedlockedSAFEsCached.getLast();
            vars.ICR = getCurrentICR(vars.user, _price);

            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(_activePool, _defaultPool, vars.user, vars.remainingmyUSDInStabPool);

                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            } else break;  // break if the loop reaches a lockedSAFE with ICR >= MCR
        }
    }

    /*
    * Attempt to liquidate a custom list of lockedSAFEs provided by the caller.
    */
    function batchLiquidatelockedSAFEs(address[] memory _lockedSAFEArray) public override {
        require(_lockedSAFEArray.length != 0, "lockedSAFEManager: Calldata address array must not be empty");

        IActivePool activePoolCached = activePool;
        IDefaultPool defaultPoolCached = defaultPool;
        IStabilityPool stabilityPoolCached = stabilityPool;

        LocalVariables_OuterLiquidationFunction memory vars;
        LiquidationTotals memory totals;

        vars.price = priceFeed.fetchPrice();
        vars.myUSDInStabPool = stabilityPoolCached.getTotalmyUSDDeposits();
        vars.recoveryModeAtStart = _checkRecoveryMode(vars.price);

        // Perform the appropriate liquidation sequence - tally values and obtain their totals.
        if (vars.recoveryModeAtStart) {
            totals = _getTotalFromBatchLiquidate_RecoveryMode(activePoolCached, defaultPoolCached, vars.price, vars.myUSDInStabPool, _lockedSAFEArray);
        } else {  //  if !vars.recoveryModeAtStart
            totals = _getTotalsFromBatchLiquidate_NormalMode(activePoolCached, defaultPoolCached, vars.price, vars.myUSDInStabPool, _lockedSAFEArray);
        }

        require(totals.totalDebtInSequence > 0, "lockedSAFEManager: nothing to liquidate");

        // Move liquidated UNLOCK and myUSD to the appropriate pools
        stabilityPoolCached.offset(totals.totalDebtToOffset, totals.totalCollToSendToSP);
        _redistributeDebtAndColl(activePoolCached, defaultPoolCached, totals.totalDebtToRedistribute, totals.totalCollToRedistribute);
        if (totals.totalCollSurplus > 0) {
            activePoolCached.sendUNLOCK(address(collSurplusPool), totals.totalCollSurplus);
        }

        // Update system snapshots
        _updateSystemSnapshots_excludeCollRemainder(activePoolCached, totals.totalCollGasCompensation);

        vars.liquidatedDebt = totals.totalDebtInSequence;
        vars.liquidatedColl = totals.totalCollInSequence.sub(totals.totalCollGasCompensation).sub(totals.totalCollSurplus);
        emit Liquidation(vars.liquidatedDebt, vars.liquidatedColl, totals.totalCollGasCompensation, totals.totalmyUSDGasCompensation);

        // Send gas compensation to caller
        _sendGasCompensation(activePoolCached, msg.sender, totals.totalmyUSDGasCompensation, totals.totalCollGasCompensation);
    }

    /*
    * This function is used when the batch liquidation sequence starts during Recovery Mode. However, it
    * handle the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
    */
    function _getTotalFromBatchLiquidate_RecoveryMode
    (
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        uint _price,
        uint _myUSDInStabPool,
        address[] memory _lockedSAFEArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingmyUSDInStabPool = _myUSDInStabPool;
        vars.backToNormalMode = false;
        vars.entireSystemDebt = getEntireSystemDebt();
        vars.entireSystemColl = getEntireSystemColl();

        for (vars.i = 0; vars.i < _lockedSAFEArray.length; vars.i++) {
            vars.user = _lockedSAFEArray[vars.i];
            // Skip non-active lockedSAFEs
            if (lockedSAFEs[vars.user].status != Status.active) { continue; }
            vars.ICR = getCurrentICR(vars.user, _price);

            if (!vars.backToNormalMode) {

                // Skip this lockedSAFE if ICR is greater than MCR and Stability Pool is empty
                if (vars.ICR >= MCR && vars.remainingmyUSDInStabPool == 0) { continue; }

                uint TCR = JASIRIMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

                singleLiquidation = _liquidateRecoveryMode(_activePool, _defaultPool, vars.user, vars.ICR, vars.remainingmyUSDInStabPool, TCR, _price);

                // Update aggregate trackers
                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);
                vars.entireSystemDebt = vars.entireSystemDebt.sub(singleLiquidation.debtToOffset);
                vars.entireSystemColl = vars.entireSystemColl.
                    sub(singleLiquidation.collToSendToSP).
                    sub(singleLiquidation.collGasCompensation).
                    sub(singleLiquidation.collSurplus);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

                vars.backToNormalMode = !_checkPotentialRecoveryMode(vars.entireSystemColl, vars.entireSystemDebt, _price);
            }

            else if (vars.backToNormalMode && vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(_activePool, _defaultPool, vars.user, vars.remainingmyUSDInStabPool);
                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

            } else continue; // In Normal Mode skip lockedSAFEs with ICR >= MCR
        }
    }

    function _getTotalsFromBatchLiquidate_NormalMode
    (
        IActivePool _activePool,
        IDefaultPool _defaultPool,
        uint _price,
        uint _myUSDInStabPool,
        address[] memory _lockedSAFEArray
    )
        internal
        returns(LiquidationTotals memory totals)
    {
        LocalVariables_LiquidationSequence memory vars;
        LiquidationValues memory singleLiquidation;

        vars.remainingmyUSDInStabPool = _myUSDInStabPool;

        for (vars.i = 0; vars.i < _lockedSAFEArray.length; vars.i++) {
            vars.user = _lockedSAFEArray[vars.i];
            vars.ICR = getCurrentICR(vars.user, _price);

            if (vars.ICR < MCR) {
                singleLiquidation = _liquidateNormalMode(_activePool, _defaultPool, vars.user, vars.remainingmyUSDInStabPool);
                vars.remainingmyUSDInStabPool = vars.remainingmyUSDInStabPool.sub(singleLiquidation.debtToOffset);

                // Add liquidation values to their respective running totals
                totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
            }
        }
    }

    // --- Liquidation helper functions ---

    function _addLiquidationValuesToTotals(LiquidationTotals memory oldTotals, LiquidationValues memory singleLiquidation)
    internal pure returns(LiquidationTotals memory newTotals) {

        // Tally all the values with their respective running totals
        newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation.add(singleLiquidation.collGasCompensation);
        newTotals.totalmyUSDGasCompensation = oldTotals.totalmyUSDGasCompensation.add(singleLiquidation.myUSDGasCompensation);
        newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence.add(singleLiquidation.entirelockedSAFEDebt);
        newTotals.totalCollInSequence = oldTotals.totalCollInSequence.add(singleLiquidation.entirelockedSAFEColl);
        newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset.add(singleLiquidation.debtToOffset);
        newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP.add(singleLiquidation.collToSendToSP);
        newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute.add(singleLiquidation.debtToRedistribute);
        newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute.add(singleLiquidation.collToRedistribute);
        newTotals.totalCollSurplus = oldTotals.totalCollSurplus.add(singleLiquidation.collSurplus);

        return newTotals;
    }

    function _sendGasCompensation(IActivePool _activePool, address _liquidator, uint _myUSD, uint _UNLOCK) internal {
        if (_myUSD > 0) {
            myUSDToken.returnFromPool(gasPoolAddress, _liquidator, _myUSD);
        }

        if (_UNLOCK > 0) {
            _activePool.sendUNLOCK(_liquidator, _UNLOCK);
        }
    }

    // Move a lockedSAFE's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
    function _movePendinglockedSAFERewardsToActivePool(IActivePool _activePool, IDefaultPool _defaultPool, uint _myUSD, uint _UNLOCK) internal {
        _defaultPool.decreasemyUSDDebt(_myUSD);
        _activePool.increasemyUSDDebt(_myUSD);
        _defaultPool.sendUNLOCKToActivePool(_UNLOCK);
    }

    // --- Redemption functions ---

    // Redeem as much collateral as possible from _borrower's lockedSAFE in exchange for myUSD up to _maxmyUSDamount
    function _redeemCollateralFromlockedSAFE(
        ContractsCache memory _contractsCache,
        address _borrower,
        uint _maxmyUSDamount,
        uint _price,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint _partialRedemptionHintNICR
    )
        internal returns (SingleRedemptionValues memory singleRedemption)
    {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the lockedSAFE minus the liquidation reserve
        singleRedemption.myUSDLot = JASIRIMath._min(_maxmyUSDamount, lockedSAFEs[_borrower].debt.sub(myUSD_GAS_COMPENSATION));

        // Get the UNLOCKLot of equivalent value in USD
        singleRedemption.UNLOCKLot = singleRedemption.myUSDLot.mul(DECIMAL_PRECISION).div(_price);

        // Decrease the debt and collateral of the current lockedSAFE according to the myUSD lot and corresponding UNLOCK to send
        uint newDebt = (lockedSAFEs[_borrower].debt).sub(singleRedemption.myUSDLot);
        uint newColl = (lockedSAFEs[_borrower].coll).sub(singleRedemption.UNLOCKLot);

        if (newDebt == myUSD_GAS_COMPENSATION) {
            // No debt left in the lockedSAFE (except for the liquidation reserve), therefore the lockedSAFE gets closed
            _removeStake(_borrower);
            _closelockedSAFE(_borrower, Status.closedByRedemption);
            _redeemCloselockedSAFE(_contractsCache, _borrower, myUSD_GAS_COMPENSATION, newColl);
            emit lockedSAFEUpdated(_borrower, 0, 0, 0, lockedSAFEManagerOperation.redeemCollateral);

        } else {
            uint newNICR = JASIRIMath._computeNominalCR(newColl, newDebt);

            /*
            * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
            * certainly result in running out of gas. 
            *
            * If the resultant net debt of the partial is less than the minimum, net debt we bail.
            */
            if (newNICR != _partialRedemptionHintNICR || _getNetDebt(newDebt) < MIN_NET_DEBT) {
                singleRedemption.cancelledPartial = true;
                return singleRedemption;
            }

            _contractsCache.sortedlockedSAFEs.reInsert(_borrower, newNICR, _upperPartialRedemptionHint, _lowerPartialRedemptionHint);

            lockedSAFEs[_borrower].debt = newDebt;
            lockedSAFEs[_borrower].coll = newColl;
            _updateStakeAndTotalStakes(_borrower);

            emit lockedSAFEUpdated(
                _borrower,
                newDebt, newColl,
                lockedSAFEs[_borrower].stake,
                lockedSAFEManagerOperation.redeemCollateral
            );
        }

        return singleRedemption;
    }

    /*
    * Called when a full redemption occurs, and closes the lockedSAFE.
    * The redeemer swaps (debt - liquidation reserve) myUSD for (debt - liquidation reserve) worth of UNLOCK, so the myUSD liquidation reserve left corresponds to the remaining debt.
    * In order to close the lockedSAFE, the myUSD liquidation reserve is burned, and the corresponding debt is removed from the active pool.
    * The debt recorded on the lockedSAFE's struct is zero'd elswhere, in _closelockedSAFE.
    * Any surplus UNLOCK left in the lockedSAFE, is sent to the Coll surplus pool, and can be later claimed by the borrower.
    */
    function _redeemCloselockedSAFE(ContractsCache memory _contractsCache, address _borrower, uint _myUSD, uint _UNLOCK) internal {
        _contractsCache.myUSDToken.burn(gasPoolAddress, _myUSD);
        // Update Active Pool myUSD, and send UNLOCK to account
        _contractsCache.activePool.decreasemyUSDDebt(_myUSD);

        // send UNLOCK from Active Pool to CollSurplus Pool
        _contractsCache.collSurplusPool.accountSurplus(_borrower, _UNLOCK);
        _contractsCache.activePool.sendUNLOCK(address(_contractsCache.collSurplusPool), _UNLOCK);
    }

    function _isValidFirstRedemptionHint(ISortedlockedSAFEs _sortedlockedSAFEs, address _firstRedemptionHint, uint _price) internal view returns (bool) {
        if (_firstRedemptionHint == address(0) ||
            !_sortedlockedSAFEs.contains(_firstRedemptionHint) ||
            getCurrentICR(_firstRedemptionHint, _price) < MCR
        ) {
            return false;
        }

        address nextlockedSAFE = _sortedlockedSAFEs.getNext(_firstRedemptionHint);
        return nextlockedSAFE == address(0) || getCurrentICR(nextlockedSAFE, _price) < MCR;
    }

    /* Send _myUSDamount myUSD to the system and redeem the corresponding amount of collateral from as many lockedSAFEs as are needed to fill the redemption
    * request.  Applies pending rewards to a lockedSAFE before reducing its debt and coll.
    *
    * Note that if _amount is very large, this function can run out of gas, specially if traversed lockedSAFEs are small. This can be easily avoided by
    * splitting the total _amount in appropriate chunks and calling the function multiple times.
    *
    * Param `_maxIterations` can also be provided, so the loop through lockedSAFEs is capped (if it’s zero, it will be ignored).This makes it easier to
    * avoid OOG for the frontend, as only knowing approximately the average cost of an iteration is enough, without needing to know the “topology”
    * of the lockedSAFE list. It also avoids the need to set the cap in stone in the contract, nor doing gas calculations, as both gas price and opcode
    * costs can vary.
    *
    * All lockedSAFEs that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be closed.
    * If the last lockedSAFE does have some remaining debt, it has a finite ICR, and the reinsertion could be anywhere in the list, therefore it requires a hint.
    * A frontend should use getRedemptionHints() to calculate what the ICR of this lockedSAFE will be after redemption, and pass a hint for its position
    * in the sortedlockedSAFEs list along with the ICR value that the hint was found for.
    *
    * If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    * is very likely that the last (partially) redeemed lockedSAFE would end up with a different ICR than what the hint is for. In this case the
    * redemption will stop after the last completely redeemed lockedSAFE and the sender will keep the remaining myUSD amount, which they can attempt
    * to redeem later.
    */
    function redeemCollateral(
        uint _myUSDamount,
        address _firstRedemptionHint,
        address _upperPartialRedemptionHint,
        address _lowerPartialRedemptionHint,
        uint _partialRedemptionHintNICR,
        uint _maxIterations,
        uint _maxFeePercentage
    )
        external
        override
    {
        ContractsCache memory contractsCache = ContractsCache(
            activePool,
            defaultPool,
            myUSDToken,
            myJSRStaking,
            sortedlockedSAFEs,
            collSurplusPool,
            gasPoolAddress
        );
        RedemptionTotals memory totals;

        _requireValidMaxFeePercentage(_maxFeePercentage);
        _requireAfterBootstrapPeriod();
        totals.price = priceFeed.fetchPrice();
        _requireTCRoverMCR(totals.price);
        _requireAmountGreaterThanZero(_myUSDamount);
        _requiremyUSDBalanceCoversRedemption(contractsCache.myUSDToken, msg.sender, _myUSDamount);

        totals.totalmyUSDSupplyAtStart = getEntireSystemDebt();
        // Confirm redeemer's balance is less than total myUSD supply
        assert(contractsCache.myUSDToken.balanceOf(msg.sender) <= totals.totalmyUSDSupplyAtStart);

        totals.remainingmyUSD = _myUSDamount;
        address currentBorrower;

        if (_isValidFirstRedemptionHint(contractsCache.sortedlockedSAFEs, _firstRedemptionHint, totals.price)) {
            currentBorrower = _firstRedemptionHint;
        } else {
            currentBorrower = contractsCache.sortedlockedSAFEs.getLast();
            // Find the first lockedSAFE with ICR >= MCR
            while (currentBorrower != address(0) && getCurrentICR(currentBorrower, totals.price) < MCR) {
                currentBorrower = contractsCache.sortedlockedSAFEs.getPrev(currentBorrower);
            }
        }

        // Loop through the lockedSAFEs starting from the one with lowest collateral ratio until _amount of myUSD is exchanged for collateral
        if (_maxIterations == 0) { _maxIterations = uint(-1); }
        while (currentBorrower != address(0) && totals.remainingmyUSD > 0 && _maxIterations > 0) {
            _maxIterations--;
            // Save the address of the lockedSAFE preceding the current one, before potentially modifying the list
            address nextUserToCheck = contractsCache.sortedlockedSAFEs.getPrev(currentBorrower);

            _applyPendingRewards(contractsCache.activePool, contractsCache.defaultPool, currentBorrower);

            SingleRedemptionValues memory singleRedemption = _redeemCollateralFromlockedSAFE(
                contractsCache,
                currentBorrower,
                totals.remainingmyUSD,
                totals.price,
                _upperPartialRedemptionHint,
                _lowerPartialRedemptionHint,
                _partialRedemptionHintNICR
            );

            if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last lockedSAFE

            totals.totalmyUSDToRedeem  = totals.totalmyUSDToRedeem.add(singleRedemption.myUSDLot);
            totals.totalUNLOCKDrawn = totals.totalUNLOCKDrawn.add(singleRedemption.UNLOCKLot);

            totals.remainingmyUSD = totals.remainingmyUSD.sub(singleRedemption.myUSDLot);
            currentBorrower = nextUserToCheck;
        }
        require(totals.totalUNLOCKDrawn > 0, "lockedSAFEManager: Unable to redeem any amount");

        // Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
        // Use the saved total myUSD supply value, from before it was reduced by the redemption.
        _updateBaseRateFromRedemption(totals.totalUNLOCKDrawn, totals.price, totals.totalmyUSDSupplyAtStart);

        // Calculate the UNLOCK fee
        totals.UNLOCKFee = _getRedemptionFee(totals.totalUNLOCKDrawn);

        _requireUserAcceptsFee(totals.UNLOCKFee, totals.totalUNLOCKDrawn, _maxFeePercentage);

        // Send the UNLOCK fee to the myJSR staking contract
        contractsCache.activePool.sendUNLOCK(address(contractsCache.myJSRStaking), totals.UNLOCKFee);
        contractsCache.myJSRStaking.increaseF_UNLOCK(totals.UNLOCKFee);

        totals.UNLOCKToSendToRedeemer = totals.totalUNLOCKDrawn.sub(totals.UNLOCKFee);

        emit Redemption(_myUSDamount, totals.totalmyUSDToRedeem, totals.totalUNLOCKDrawn, totals.UNLOCKFee);

        // Burn the total myUSD that is cancelled with debt, and send the redeemed UNLOCK to msg.sender
        contractsCache.myUSDToken.burn(msg.sender, totals.totalmyUSDToRedeem);
        // Update Active Pool myUSD, and send UNLOCK to account
        contractsCache.activePool.decreasemyUSDDebt(totals.totalmyUSDToRedeem);
        contractsCache.activePool.sendUNLOCK(msg.sender, totals.UNLOCKToSendToRedeemer);
    }

    // --- Helper functions ---

    // Return the nominal collateral ratio (ICR) of a given lockedSAFE, without the price. Takes a lockedSAFE's pending coll and debt rewards from redistributions into account.
    function getNominalICR(address _borrower) public view override returns (uint) {
        (uint currentUNLOCK, uint currentmyUSDDebt) = _getCurrentlockedSAFEAmounts(_borrower);

        uint NICR = JASIRIMath._computeNominalCR(currentUNLOCK, currentmyUSDDebt);
        return NICR;
    }

    // Return the current collateral ratio (ICR) of a given lockedSAFE. Takes a lockedSAFE's pending coll and debt rewards from redistributions into account.
    function getCurrentICR(address _borrower, uint _price) public view override returns (uint) {
        (uint currentUNLOCK, uint currentmyUSDDebt) = _getCurrentlockedSAFEAmounts(_borrower);

        uint ICR = JASIRIMath._computeCR(currentUNLOCK, currentmyUSDDebt, _price);
        return ICR;
    }

    function _getCurrentlockedSAFEAmounts(address _borrower) internal view returns (uint, uint) {
        uint pendingUNLOCKReward = getPendingUNLOCKReward(_borrower);
        uint pendingmyUSDDebtReward = getPendingmyUSDDebtReward(_borrower);

        uint currentUNLOCK = lockedSAFEs[_borrower].coll.add(pendingUNLOCKReward);
        uint currentmyUSDDebt = lockedSAFEs[_borrower].debt.add(pendingmyUSDDebtReward);

        return (currentUNLOCK, currentmyUSDDebt);
    }

    function applyPendingRewards(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _applyPendingRewards(activePool, defaultPool, _borrower);
    }

    // Add the borrowers's coll and debt rewards earned from redistributions, to their lockedSAFE
    function _applyPendingRewards(IActivePool _activePool, IDefaultPool _defaultPool, address _borrower) internal {
        if (hasPendingRewards(_borrower)) {
            _requirelockedSAFEIsActive(_borrower);

            // Compute pending rewards
            uint pendingUNLOCKReward = getPendingUNLOCKReward(_borrower);
            uint pendingmyUSDDebtReward = getPendingmyUSDDebtReward(_borrower);

            // Apply pending rewards to lockedSAFE's state
            lockedSAFEs[_borrower].coll = lockedSAFEs[_borrower].coll.add(pendingUNLOCKReward);
            lockedSAFEs[_borrower].debt = lockedSAFEs[_borrower].debt.add(pendingmyUSDDebtReward);

            _updatelockedSAFERewardSnapshots(_borrower);

            // Transfer from DefaultPool to ActivePool
            _movePendinglockedSAFERewardsToActivePool(_activePool, _defaultPool, pendingmyUSDDebtReward, pendingUNLOCKReward);

            emit lockedSAFEUpdated(
                _borrower,
                lockedSAFEs[_borrower].debt,
                lockedSAFEs[_borrower].coll,
                lockedSAFEs[_borrower].stake,
                lockedSAFEManagerOperation.applyPendingRewards
            );
        }
    }

    // Update borrower's snapshots of L_UNLOCK and L_myUSDDebt to reflect the current values
    function updatelockedSAFERewardSnapshots(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
       return _updatelockedSAFERewardSnapshots(_borrower);
    }

    function _updatelockedSAFERewardSnapshots(address _borrower) internal {
        rewardSnapshots[_borrower].UNLOCK = L_UNLOCK;
        rewardSnapshots[_borrower].myUSDDebt = L_myUSDDebt;
        emit lockedSAFESnapshotsUpdated(L_UNLOCK, L_myUSDDebt);
    }

    // Get the borrower's pending accumulated UNLOCK reward, earned by their stake
    function getPendingUNLOCKReward(address _borrower) public view override returns (uint) {
        uint snapshotUNLOCK = rewardSnapshots[_borrower].UNLOCK;
        uint rewardPerUnitStaked = L_UNLOCK.sub(snapshotUNLOCK);

        if ( rewardPerUnitStaked == 0 || lockedSAFEs[_borrower].status != Status.active) { return 0; }

        uint stake = lockedSAFEs[_borrower].stake;

        uint pendingUNLOCKReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingUNLOCKReward;
    }
    
    // Get the borrower's pending accumulated myUSD reward, earned by their stake
    function getPendingmyUSDDebtReward(address _borrower) public view override returns (uint) {
        uint snapshotmyUSDDebt = rewardSnapshots[_borrower].myUSDDebt;
        uint rewardPerUnitStaked = L_myUSDDebt.sub(snapshotmyUSDDebt);

        if ( rewardPerUnitStaked == 0 || lockedSAFEs[_borrower].status != Status.active) { return 0; }

        uint stake =  lockedSAFEs[_borrower].stake;

        uint pendingmyUSDDebtReward = stake.mul(rewardPerUnitStaked).div(DECIMAL_PRECISION);

        return pendingmyUSDDebtReward;
    }

    function hasPendingRewards(address _borrower) public view override returns (bool) {
        /*
        * A lockedSAFE has pending rewards if its snapshot is less than the current rewards per-unit-staked sum:
        * this indicates that rewards have occured since the snapshot was made, and the user therefore has
        * pending rewards
        */
        if (lockedSAFEs[_borrower].status != Status.active) {return false;}
       
        return (rewardSnapshots[_borrower].UNLOCK < L_UNLOCK);
    }

    // Return the lockedSAFEs entire debt and coll, including pending rewards from redistributions.
    function getEntireDebtAndColl(
        address _borrower
    )
        public
        view
        override
        returns (uint debt, uint coll, uint pendingmyUSDDebtReward, uint pendingUNLOCKReward)
    {
        debt = lockedSAFEs[_borrower].debt;
        coll = lockedSAFEs[_borrower].coll;

        pendingmyUSDDebtReward = getPendingmyUSDDebtReward(_borrower);
        pendingUNLOCKReward = getPendingUNLOCKReward(_borrower);

        debt = debt.add(pendingmyUSDDebtReward);
        coll = coll.add(pendingUNLOCKReward);
    }

    function removeStake(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _removeStake(_borrower);
    }

    // Remove borrower's stake from the totalStakes sum, and set their stake to 0
    function _removeStake(address _borrower) internal {
        uint stake = lockedSAFEs[_borrower].stake;
        totalStakes = totalStakes.sub(stake);
        lockedSAFEs[_borrower].stake = 0;
    }

    function updateStakeAndTotalStakes(address _borrower) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        return _updateStakeAndTotalStakes(_borrower);
    }

    // Update borrower's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(address _borrower) internal returns (uint) {
        uint newStake = _computeNewStake(lockedSAFEs[_borrower].coll);
        uint oldStake = lockedSAFEs[_borrower].stake;
        lockedSAFEs[_borrower].stake = newStake;

        totalStakes = totalStakes.sub(oldStake).add(newStake);
        emit TotalStakesUpdated(totalStakes);

        return newStake;
    }

    // Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
    function _computeNewStake(uint _coll) internal view returns (uint) {
        uint stake;
        if (totalCollateralSnapshot == 0) {
            stake = _coll;
        } else {
            /*
            * The following assert() holds true because:
            * - The system always contains >= 1 lockedSAFE
            * - When we close or liquidate a lockedSAFE, we redistribute the pending rewards, so if all lockedSAFEs were closed/liquidated,
            * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
            */
            assert(totalStakesSnapshot > 0);
            stake = _coll.mul(totalStakesSnapshot).div(totalCollateralSnapshot);
        }
        return stake;
    }

    function _redistributeDebtAndColl(IActivePool _activePool, IDefaultPool _defaultPool, uint _debt, uint _coll) internal {
        if (_debt == 0) { return; }

        /*
        * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
        * error correction, to keep the cumulative error low in the running totals L_UNLOCK and L_myUSDDebt:
        *
        * 1) Form numerators which compensate for the floor division errors that occurred the last time this
        * function was called.
        * 2) Calculate "per-unit-staked" ratios.
        * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
        * 4) Store these errors for use in the next correction when this function is called.
        * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
        */
        uint UNLOCKNumerator = _coll.mul(DECIMAL_PRECISION).add(lastUNLOCKError_Redistribution);
        uint myUSDDebtNumerator = _debt.mul(DECIMAL_PRECISION).add(lastmyUSDDebtError_Redistribution);

        // Get the per-unit-staked terms
        uint UNLOCKRewardPerUnitStaked = UNLOCKNumerator.div(totalStakes);
        uint myUSDDebtRewardPerUnitStaked = myUSDDebtNumerator.div(totalStakes);

        lastUNLOCKError_Redistribution = UNLOCKNumerator.sub(UNLOCKRewardPerUnitStaked.mul(totalStakes));
        lastmyUSDDebtError_Redistribution = myUSDDebtNumerator.sub(myUSDDebtRewardPerUnitStaked.mul(totalStakes));

        // Add per-unit-staked terms to the running totals
        L_UNLOCK = L_UNLOCK.add(UNLOCKRewardPerUnitStaked);
        L_myUSDDebt = L_myUSDDebt.add(myUSDDebtRewardPerUnitStaked);

        emit LTermsUpdated(L_UNLOCK, L_myUSDDebt);

        // Transfer coll and debt from ActivePool to DefaultPool
        _activePool.decreasemyUSDDebt(_debt);
        _defaultPool.increasemyUSDDebt(_debt);
        _activePool.sendUNLOCK(address(_defaultPool), _coll);
    }

    function closelockedSAFE(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _closelockedSAFE(_borrower, Status.closedByOwner);
    }

    function _closelockedSAFE(address _borrower, Status closedStatus) internal {
        assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

        uint lockedSAFEOwnersArrayLength = lockedSAFEOwners.length;
        _requireMorUNLOCKanOnelockedSAFEInSystem(lockedSAFEOwnersArrayLength);

        lockedSAFEs[_borrower].status = closedStatus;
        lockedSAFEs[_borrower].coll = 0;
        lockedSAFEs[_borrower].debt = 0;

        rewardSnapshots[_borrower].UNLOCK = 0;
        rewardSnapshots[_borrower].myUSDDebt = 0;

        _removelockedSAFEOwner(_borrower, lockedSAFEOwnersArrayLength);
        sortedlockedSAFEs.remove(_borrower);
    }

    /*
    * Updates snapshots of system total stakes and total collateral, excluding a given collateral remainder from the calculation.
    * Used in a liquidation sequence.
    *
    * The calculation excludes a portion of collateral that is in the ActivePool:
    *
    * the total UNLOCK gas compensation from the liquidation sequence
    *
    * The UNLOCK as compensation must be excluded as it is always sent out at the very end of the liquidation sequence.
    */
    function _updateSystemSnapshots_excludeCollRemainder(IActivePool _activePool, uint _collRemainder) internal {
        totalStakesSnapshot = totalStakes;

        uint activeColl = _activePool.getUNLOCK();
        uint liquidatedColl = defaultPool.getUNLOCK();
        totalCollateralSnapshot = activeColl.sub(_collRemainder).add(liquidatedColl);

        emit SystemSnapshotsUpdated(totalStakesSnapshot, totalCollateralSnapshot);
    }

    // Push the owner's address to the lockedSAFE owners list, and record the corresponding array index on the lockedSAFE struct
    function addlockedSAFEOwnerToArray(address _borrower) external override returns (uint index) {
        _requireCallerIsBorrowerOperations();
        return _addlockedSAFEOwnerToArray(_borrower);
    }

    function _addlockedSAFEOwnerToArray(address _borrower) internal returns (uint128 index) {
        /* Max array size is 2**128 - 1, i.e. ~3e30 lockedSAFEs. No risk of overflow, since lockedSAFEs have minimum myUSD
        debt of liquidation reserve plus MIN_NET_DEBT. 3e30 myUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */

        // Push the lockedSAFEowner to the array
        lockedSAFEOwners.push(_borrower);

        // Record the index of the new lockedSAFEowner on their lockedSAFE struct
        index = uint128(lockedSAFEOwners.length.sub(1));
        lockedSAFEs[_borrower].arrayIndex = index;

        return index;
    }

    /*
    * Remove a lockedSAFE owner from the lockedSAFEOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's lockedSAFE struct to point to its new array index.
    */
    function _removelockedSAFEOwner(address _borrower, uint lockedSAFEOwnersArrayLength) internal {
        Status lockedSAFEStatus = lockedSAFEs[_borrower].status;
        // It’s set in caller function `_closelockedSAFE`
        assert(lockedSAFEStatus != Status.nonExistent && lockedSAFEStatus != Status.active);

        uint128 index = lockedSAFEs[_borrower].arrayIndex;
        uint length = lockedSAFEOwnersArrayLength;
        uint idxLast = length.sub(1);

        assert(index <= idxLast);

        address addressToMove = lockedSAFEOwners[idxLast];

        lockedSAFEOwners[index] = addressToMove;
        lockedSAFEs[addressToMove].arrayIndex = index;
        emit lockedSAFEIndexUpdated(addressToMove, index);

        lockedSAFEOwners.pop();
    }

    // --- Recovery Mode and TCR functions ---

    function getTCR(uint _price) external view override returns (uint) {
        return _getTCR(_price);
    }

    function checkRecoveryMode(uint _price) external view override returns (bool) {
        return _checkRecoveryMode(_price);
    }

    // Check whUNLOCKer or not the system *would be* in Recovery Mode, given an UNLOCK:USD price, and the entire system coll and debt.
    function _checkPotentialRecoveryMode(
        uint _entireSystemColl,
        uint _entireSystemDebt,
        uint _price
    )
        internal
        pure
    returns (bool)
    {
        uint TCR = JASIRIMath._computeCR(_entireSystemColl, _entireSystemDebt, _price);

        return TCR < CCR;
    }

    // --- Redemption fee functions ---

    /*
    * This function has two impacts on the baseRate state variable:
    * 1) decays the baseRate based on time passed since last redemption or myUSD borrowing operation.
    * then,
    * 2) increases the baseRate based on the amount redeemed, as a proportion of total supply
    */
    function _updateBaseRateFromRedemption(uint _UNLOCKDrawn,  uint _price, uint _totalmyUSDSupply) internal returns (uint) {
        uint decayedBaseRate = _calcDecayedBaseRate();

        /* Convert the drawn UNLOCK back to myUSD at face value rate (1 myUSD:1 USD), in order to get
        * the fraction of total supply that was redeemed at face value. */
        uint redeemedmyUSDFraction = _UNLOCKDrawn.mul(_price).div(_totalmyUSDSupply);

        uint newBaseRate = decayedBaseRate.add(redeemedmyUSDFraction.div(BETA));
        newBaseRate = JASIRIMath._min(newBaseRate, DECIMAL_PRECISION); // cap baseRate at a maximum of 100%
        //assert(newBaseRate <= DECIMAL_PRECISION); // This is already enforced in the line above
        assert(newBaseRate > 0); // Base rate is always non-zero after redemption

        // Update the baseRate state variable
        baseRate = newBaseRate;
        emit BaseRateUpdated(newBaseRate);
        
        _updateLastFeeOpTime();

        return newBaseRate;
    }

    function getRedemptionRate() public view override returns (uint) {
        return _calcRedemptionRate(baseRate);
    }

    function getRedemptionRateWithDecay() public view override returns (uint) {
        return _calcRedemptionRate(_calcDecayedBaseRate());
    }

    function _calcRedemptionRate(uint _baseRate) internal pure returns (uint) {
        return JASIRIMath._min(
            REDEMPTION_FEE_FLOOR.add(_baseRate),
            DECIMAL_PRECISION // cap at a maximum of 100%
        );
    }

    function _getRedemptionFee(uint _UNLOCKDrawn) internal view returns (uint) {
        return _calcRedemptionFee(getRedemptionRate(), _UNLOCKDrawn);
    }

    function getRedemptionFeeWithDecay(uint _UNLOCKDrawn) external view override returns (uint) {
        return _calcRedemptionFee(getRedemptionRateWithDecay(), _UNLOCKDrawn);
    }

    function _calcRedemptionFee(uint _redemptionRate, uint _UNLOCKDrawn) internal pure returns (uint) {
        uint redemptionFee = _redemptionRate.mul(_UNLOCKDrawn).div(DECIMAL_PRECISION);
        require(redemptionFee < _UNLOCKDrawn, "lockedSAFEManager: Fee would eat up all returned collateral");
        return redemptionFee;
    }

    // --- Borrowing fee functions ---

    function getBorrowingRate() public view override returns (uint) {
        return _calcBorrowingRate(baseRate);
    }

    function getBorrowingRateWithDecay() public view override returns (uint) {
        return _calcBorrowingRate(_calcDecayedBaseRate());
    }

    function _calcBorrowingRate(uint _baseRate) internal pure returns (uint) {
        return JASIRIMath._min(
            BORROWING_FEE_FLOOR.add(_baseRate),
            MAX_BORROWING_FEE
        );
    }

    function getBorrowingFee(uint _myUSDDebt) external view override returns (uint) {
        return _calcBorrowingFee(getBorrowingRate(), _myUSDDebt);
    }

    function getBorrowingFeeWithDecay(uint _myUSDDebt) external view override returns (uint) {
        return _calcBorrowingFee(getBorrowingRateWithDecay(), _myUSDDebt);
    }

    function _calcBorrowingFee(uint _borrowingRate, uint _myUSDDebt) internal pure returns (uint) {
        return _borrowingRate.mul(_myUSDDebt).div(DECIMAL_PRECISION);
    }


    // Updates the baseRate state variable based on time elapsed since the last redemption or myUSD borrowing operation.
    function decayBaseRateFromBorrowing() external override {
        _requireCallerIsBorrowerOperations();

        uint decayedBaseRate = _calcDecayedBaseRate();
        assert(decayedBaseRate <= DECIMAL_PRECISION);  // The baseRate can decay to 0

        baseRate = decayedBaseRate;
        emit BaseRateUpdated(decayedBaseRate);

        _updateLastFeeOpTime();
    }

    // --- Internal fee functions ---

    // Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
    function _updateLastFeeOpTime() internal {
        uint timePassed = block.timestamp.sub(lastFeeOperationTime);

        if (timePassed >= SECONDS_IN_ONE_MINUTE) {
            lastFeeOperationTime = block.timestamp;
            emit LastFeeOpTimeUpdated(block.timestamp);
        }
    }

    function _calcDecayedBaseRate() internal view returns (uint) {
        uint minutesPassed = _minutesPassedSinceLastFeeOp();
        uint decayFactor = JASIRIMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);

        return baseRate.mul(decayFactor).div(DECIMAL_PRECISION);
    }

    function _minutesPassedSinceLastFeeOp() internal view returns (uint) {
        return (block.timestamp.sub(lastFeeOperationTime)).div(SECONDS_IN_ONE_MINUTE);
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "lockedSAFEManager: Caller is not the BorrowerOperations contract");
    }

    function _requirelockedSAFEIsActive(address _borrower) internal view {
        require(lockedSAFEs[_borrower].status == Status.active, "lockedSAFEManager: lockedSAFE does not exist or is closed");
    }

    function _requiremyUSDBalanceCoversRedemption(ImyUSDToken _myUSDToken, address _redeemer, uint _amount) internal view {
        require(_myUSDToken.balanceOf(_redeemer) >= _amount, "lockedSAFEManager: Requested redemption amount must be <= user's myUSD token balance");
    }

    function _requireMorUNLOCKanOnelockedSAFEInSystem(uint lockedSAFEOwnersArrayLength) internal view {
        require (lockedSAFEOwnersArrayLength > 1 && sortedlockedSAFEs.getSize() > 1, "lockedSAFEManager: Only one lockedSAFE in the system");
    }

    function _requireAmountGreaterThanZero(uint _amount) internal pure {
        require(_amount > 0, "lockedSAFEManager: Amount must be greater than zero");
    }

    function _requireTCRoverMCR(uint _price) internal view {
        require(_getTCR(_price) >= MCR, "lockedSAFEManager: Cannot redeem when TCR < MCR");
    }

    function _requireAfterBootstrapPeriod() internal view {
        uint systemDeploymentTime = myJSRToken.getDeploymentStartTime();
        require(block.timestamp >= systemDeploymentTime.add(BOOTSTRAP_PERIOD), "lockedSAFEManager: Redemptions are not allowed during bootstrap phase");
    }

    function _requireValidMaxFeePercentage(uint _maxFeePercentage) internal pure {
        require(_maxFeePercentage >= REDEMPTION_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
            "Max fee percentage must be between 0.5% and 100%");
    }

    // --- lockedSAFE property getters ---

    function getlockedSAFEStatus(address _borrower) external view override returns (uint) {
        return uint(lockedSAFEs[_borrower].status);
    }

    function getlockedSAFEStake(address _borrower) external view override returns (uint) {
        return lockedSAFEs[_borrower].stake;
    }

    function getlockedSAFEDebt(address _borrower) external view override returns (uint) {
        return lockedSAFEs[_borrower].debt;
    }

    function getlockedSAFEColl(address _borrower) external view override returns (uint) {
        return lockedSAFEs[_borrower].coll;
    }

    // --- lockedSAFE property setters, called by BorrowerOperations ---

    function setlockedSAFEStatus(address _borrower, uint _num) external override {
        _requireCallerIsBorrowerOperations();
        lockedSAFEs[_borrower].status = Status(_num);
    }

    function increaselockedSAFEColl(address _borrower, uint _collIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = lockedSAFEs[_borrower].coll.add(_collIncrease);
        lockedSAFEs[_borrower].coll = newColl;
        return newColl;
    }

    function decreaselockedSAFEColl(address _borrower, uint _collDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = lockedSAFEs[_borrower].coll.sub(_collDecrease);
        lockedSAFEs[_borrower].coll = newColl;
        return newColl;
    }

    function increaselockedSAFEDebt(address _borrower, uint _debtIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = lockedSAFEs[_borrower].debt.add(_debtIncrease);
        lockedSAFEs[_borrower].debt = newDebt;
        return newDebt;
    }

    function decreaselockedSAFEDebt(address _borrower, uint _debtDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = lockedSAFEs[_borrower].debt.sub(_debtDecrease);
        lockedSAFEs[_borrower].debt = newDebt;
        return newDebt;
    }
}
