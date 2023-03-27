// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import "./lockedSAFEManager.sol";
import "./SortedlockedSAFEs.sol";

/*  Helper contract for grabbing lockedSAFE data for the front end. Not part of the core Liquity system. */
contract MultilockedSAFEGetter {
    struct CombinedlockedSAFEData {
        address owner;

        uint debt;
        uint coll;
        uint stake;

        uint snapshotUNLOCK;
        uint snapshotmyUSDDebt;
    }

    lockedSAFEManager public lockedSAFEManager; // XXX lockedSAFEs missing from IlockedSAFEManager?
    ISortedlockedSAFEs public sortedlockedSAFEs;

    constructor(lockedSAFEManager _lockedSAFEManager, ISortedlockedSAFEs _sortedlockedSAFEs) public {
        lockedSAFEManager = _lockedSAFEManager;
        sortedlockedSAFEs = _sortedlockedSAFEs;
    }

    function getMultipleSortedlockedSAFEs(int _startIdx, uint _count)
        external view returns (CombinedlockedSAFEData[] memory _lockedSAFEs)
    {
        uint startIdx;
        bool descend;

        if (_startIdx >= 0) {
            startIdx = uint(_startIdx);
            descend = true;
        } else {
            startIdx = uint(-(_startIdx + 1));
            descend = false;
        }

        uint sortedlockedSAFEsSize = sortedlockedSAFEs.getSize();

        if (startIdx >= sortedlockedSAFEsSize) {
            _lockedSAFEs = new CombinedlockedSAFEData[](0);
        } else {
            uint maxCount = sortedlockedSAFEsSize - startIdx;

            if (_count > maxCount) {
                _count = maxCount;
            }

            if (descend) {
                _lockedSAFEs = _getMultipleSortedlockedSAFEsFromHead(startIdx, _count);
            } else {
                _lockedSAFEs = _getMultipleSortedlockedSAFEsFromTail(startIdx, _count);
            }
        }
    }

    function _getMultipleSortedlockedSAFEsFromHead(uint _startIdx, uint _count)
        internal view returns (CombinedlockedSAFEData[] memory _lockedSAFEs)
    {
        address currentlockedSAFEowner = sortedlockedSAFEs.getFirst();

        for (uint idx = 0; idx < _startIdx; ++idx) {
            currentlockedSAFEowner = sortedlockedSAFEs.getNext(currentlockedSAFEowner);
        }

        _lockedSAFEs = new CombinedlockedSAFEData[](_count);

        for (uint idx = 0; idx < _count; ++idx) {
            _lockedSAFEs[idx].owner = currentlockedSAFEowner;
            (
                _lockedSAFEs[idx].debt,
                _lockedSAFEs[idx].coll,
                _lockedSAFEs[idx].stake,
                /* status */,
                /* arrayIndex */
            ) = lockedSAFEManager.lockedSAFEs(currentlockedSAFEowner);
            (
                _lockedSAFEs[idx].snapshotUNLOCK,
                _lockedSAFEs[idx].snapshotmyUSDDebt
            ) = lockedSAFEManager.rewardSnapshots(currentlockedSAFEowner);

            currentlockedSAFEowner = sortedlockedSAFEs.getNext(currentlockedSAFEowner);
        }
    }

    function _getMultipleSortedlockedSAFEsFromTail(uint _startIdx, uint _count)
        internal view returns (CombinedlockedSAFEData[] memory _lockedSAFEs)
    {
        address currentlockedSAFEowner = sortedlockedSAFEs.getLast();

        for (uint idx = 0; idx < _startIdx; ++idx) {
            currentlockedSAFEowner = sortedlockedSAFEs.getPrev(currentlockedSAFEowner);
        }

        _lockedSAFEs = new CombinedlockedSAFEData[](_count);

        for (uint idx = 0; idx < _count; ++idx) {
            _lockedSAFEs[idx].owner = currentlockedSAFEowner;
            (
                _lockedSAFEs[idx].debt,
                _lockedSAFEs[idx].coll,
                _lockedSAFEs[idx].stake,
                /* status */,
                /* arrayIndex */
            ) = lockedSAFEManager.lockedSAFEs(currentlockedSAFEowner);
            (
                _lockedSAFEs[idx].snapshotUNLOCK,
                _lockedSAFEs[idx].snapshotmyUSDDebt
            ) = lockedSAFEManager.rewardSnapshots(currentlockedSAFEowner);

            currentlockedSAFEowner = sortedlockedSAFEs.getPrev(currentlockedSAFEowner);
        }
    }
}
