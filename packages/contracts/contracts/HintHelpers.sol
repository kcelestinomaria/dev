// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/IlockedSAFEManager.sol";
import "./Interfaces/ISortedlockedSAFEs.sol";
import "./Dependencies/JASIRIBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";

contract HintHelpers is JASIRIBase, Ownable, CheckContract {
    string constant public NAME = "HintHelpers";

    ISortedlockedSAFEs public sortedlockedSAFEs;
    IlockedSAFEManager public lockedSAFEManager;

    // --- Events ---

    event SortedlockedSAFEsAddressChanged(address _sortedlockedSAFEsAddress);
    event lockedSAFEManagerAddressChanged(address _lockedSAFEManagerAddress);

    // --- Dependency setters ---

    function setAddresses(
        address _sortedlockedSAFEsAddress,
        address _lockedSAFEManagerAddress
    )
        external
        onlyOwner
    {
        checkContract(_sortedlockedSAFEsAddress);
        checkContract(_lockedSAFEManagerAddress);

        sortedlockedSAFEs = ISortedlockedSAFEs(_sortedlockedSAFEsAddress);
        lockedSAFEManager = IlockedSAFEManager(_lockedSAFEManagerAddress);

        emit SortedlockedSAFEsAddressChanged(_sortedlockedSAFEsAddress);
        emit lockedSAFEManagerAddressChanged(_lockedSAFEManagerAddress);

        _renounceOwnership();
    }

    // --- Functions ---

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_myUSDamount` to figure out where the redemption sequence will start and what state the final lockedSAFE
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first lockedSAFE with ICR >= MCR (i.e. the first lockedSAFE that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last lockedSAFE of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedmyUSDamount` is the maximum amount that can be redeemed out of the the provided `_myUSDamount`. This can be lower than
     *    `_myUSDamount` when redeeming the full amount would leave the last lockedSAFE of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. MIN_NET_DEBT).
     *
     * The number of lockedSAFEs to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(
        uint _myUSDamount, 
        uint _price,
        uint _maxIterations
    )
        external
        view
        returns (
            address firstRedemptionHint,
            uint partialRedemptionHintNICR,
            uint truncatedmyUSDamount
        )
    {
        ISortedlockedSAFEs sortedlockedSAFEsCached = sortedlockedSAFEs;

        uint remainingmyUSD = _myUSDamount;
        address currentlockedSAFEuser = sortedlockedSAFEsCached.getLast();

        while (currentlockedSAFEuser != address(0) && lockedSAFEManager.getCurrentICR(currentlockedSAFEuser, _price) < MCR) {
            currentlockedSAFEuser = sortedlockedSAFEsCached.getPrev(currentlockedSAFEuser);
        }

        firstRedemptionHint = currentlockedSAFEuser;

        if (_maxIterations == 0) {
            _maxIterations = uint(-1);
        }

        while (currentlockedSAFEuser != address(0) && remainingmyUSD > 0 && _maxIterations-- > 0) {
            uint netmyUSDDebt = _getNetDebt(lockedSAFEManager.getlockedSAFEDebt(currentlockedSAFEuser))
                .add(lockedSAFEManager.getPendingmyUSDDebtReward(currentlockedSAFEuser));

            if (netmyUSDDebt > remainingmyUSD) {
                if (netmyUSDDebt > MIN_NET_DEBT) {
                    uint maxRedeemablemyUSD = JASIRIMath._min(remainingmyUSD, netmyUSDDebt.sub(MIN_NET_DEBT));

                    uint ETH = lockedSAFEManager.getlockedSAFEColl(currentlockedSAFEuser)
                        .add(lockedSAFEManager.getPendingETHReward(currentlockedSAFEuser));

                    uint newColl = ETH.sub(maxRedeemablemyUSD.mul(DECIMAL_PRECISION).div(_price));
                    uint newDebt = netmyUSDDebt.sub(maxRedeemablemyUSD);

                    uint compositeDebt = _getCompositeDebt(newDebt);
                    partialRedemptionHintNICR = JASIRIMath._computeNominalCR(newColl, compositeDebt);

                    remainingmyUSD = remainingmyUSD.sub(maxRedeemablemyUSD);
                }
                break;
            } else {
                remainingmyUSD = remainingmyUSD.sub(netmyUSDDebt);
            }

            currentlockedSAFEuser = sortedlockedSAFEsCached.getPrev(currentlockedSAFEuser);
        }

        truncatedmyUSDamount = _myUSDamount.sub(remainingmyUSD);
    }

    /* getApproxHint() - return address of a lockedSAFE that is, on average, (length / numTrials) positions away in the 
    sortedlockedSAFEs list from the correct insert position of the lockedSAFE to be inserted. 
    
    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function 
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will 
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(uint _CR, uint _numTrials, uint _inputRandomSeed)
        external
        view
        returns (address hintAddress, uint diff, uint latestRandomSeed)
    {
        uint arrayLength = lockedSAFEManager.getlockedSAFEOwnersCount();

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = sortedlockedSAFEs.getLast();
        diff = JASIRIMath._getAbsoluteDifference(_CR, lockedSAFEManager.getNominalICR(hintAddress));
        latestRandomSeed = _inputRandomSeed;

        uint i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint(keccak256(abi.encodePacked(latestRandomSeed)));

            uint arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = lockedSAFEManager.getlockedSAFEFromlockedSAFEOwnersArray(arrayIndex);
            uint currentNICR = lockedSAFEManager.getNominalICR(currentAddress);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint currentDiff = JASIRIMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }

    function computeNominalCR(uint _coll, uint _debt) external pure returns (uint) {
        return JASIRIMath._computeNominalCR(_coll, _debt);
    }

    function computeCR(uint _coll, uint _debt, uint _price) external pure returns (uint) {
        return JASIRIMath._computeCR(_coll, _debt, _price);
    }
}
