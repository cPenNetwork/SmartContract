// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title ChasepotEntries
 * @notice On-chain transparency layer for Chasepot sweepstakes entries
 * @dev Deployed on Arbitrum for low gas costs. Entry data is emitted in events
 *      (not stored in contract storage) for cost-efficient permanent auditability.
 *      The backend database is the source of truth; this contract provides
 *      a full event log for independent verification.
 *
 * Entry Format (uint64 per entry, decimal pairs with count prefix):
 * - Each entry is a uint64 encoded as: [count][n1][n2]...[nX] (base-100 encoding)
 * - Count prefix indicates number of picks (6 for 6/45, 7 for 7/49, etc.)
 * - Example 6/45: [5, 15, 25, 35, 42, 44] → 6051525354244 (read as 6-05-15-25-35-42-44)
 * - Example 7/49: [1, 2, 3, 4, 5, 6, 7] → 701020304050607 (read as 7-01-02-03-04-05-06-07)
 * - On Arbiscan: decimal value is directly readable!
 *
 * Architecture:
 * - Round-based: backend provides roundId for each operation
 * - Event-log storage: full entry data emitted in BatchCommitted events
 * - On-chain state: only counters (minimal storage)
 *
 * Trust Model:
 * - The backend (contract owner) is the trusted encoder and validator.
 * - On-chain validation is intentionally minimal (non-zero check only) to keep gas low.
 * - Full entry validation (count prefix, range, uniqueness, sort order) is the
 *   backend's responsibility and can be independently verified off-chain from events.
 * - The contract guarantees: batch size limits, round locking, idempotency, and non-zero entries.
 *
 * Verification Flow:
 * 1. Backend encodes entries (base-100) and calls commitBatch(roundId, expectedBatchIndex, entries)
 * 2. Contract emits BatchCommitted with uint64[] entries
 * 3. Anyone can read events via eth_getLogs to reconstruct all entries
 * 4. Users verify their entries on Arbiscan (decimal is readable!)
 */
contract ChasepotEntries is Ownable, Pausable {
    // ============ Constants ============
    uint256 public constant ENTRIES_PER_BATCH = 1000;

    // ============ Storage ============

    // roundId => number of batches
    mapping(uint256 => uint256) public batchCount;

    // roundId => total entry count
    mapping(uint256 => uint256) public entryCount;

    // roundId => entries locked (no more commits allowed)
    mapping(uint256 => bool) public entriesLocked;

    // ============ Events ============
    event BatchCommitted(
        uint256 indexed roundId,
        uint256 indexed batchIndex,
        uint256 entryCount,
        uint64[] entries
    );
    event EntriesLocked(uint256 indexed roundId, uint256 totalEntries);

    // ============ Errors ============
    error EntriesAlreadyLocked(uint256 roundId);
    error InvalidBatchSize();
    error InvalidEntry(uint256 index);
    error BatchIndexMismatch(uint256 roundId, uint256 expected, uint256 actual);

    /**
     * @notice Constructor
     */
    constructor() Ownable(msg.sender) {}

    // ============ Owner Functions ============

    /**
     * @notice Commit a batch of entries for a round
     * @param roundId The round ID (provided by backend)
     * @param expectedBatchIndex Expected batch index for idempotency (must match batchCount[roundId])
     * @param entries Array of base-100 encoded entries (uint64 each)
     * @return batchIndex The index of the committed batch
     */
    function commitBatch(
        uint256 roundId,
        uint256 expectedBatchIndex,
        uint64[] calldata entries
    ) external onlyOwner whenNotPaused returns (uint256 batchIndex) {
        if (entriesLocked[roundId]) revert EntriesAlreadyLocked(roundId);
        if (entries.length == 0 || entries.length > ENTRIES_PER_BATCH) revert InvalidBatchSize();

        // Minimal sanity check: zero is never a valid base-100 encoded entry
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i] == 0) revert InvalidEntry(i);
        }

        // Idempotency guard: prevents duplicate batch on RPC retry
        if (batchCount[roundId] != expectedBatchIndex) {
            revert BatchIndexMismatch(roundId, expectedBatchIndex, batchCount[roundId]);
        }

        batchIndex = batchCount[roundId];
        batchCount[roundId]++;
        entryCount[roundId] += entries.length;

        emit BatchCommitted(roundId, batchIndex, entries.length, entries);
    }

    /**
     * @notice Lock entries for a round (no more commits allowed)
     * @dev Call this before the draw to prevent last-minute entry manipulation
     * @param roundId The round ID (provided by backend)
     */
    function lockEntries(uint256 roundId) external onlyOwner {
        if (entriesLocked[roundId]) revert EntriesAlreadyLocked(roundId);

        entriesLocked[roundId] = true;

        emit EntriesLocked(roundId, entryCount[roundId]);
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Disabled — renouncing ownership would permanently brick this contract
     */
    function renounceOwnership() public view override onlyOwner {
        revert("Renounce disabled");
    }

    // ============ View Functions ============

    /**
     * @notice Get statistics for a round
     * @param roundId The round ID
     * @return totalEntries Total number of entries
     * @return totalBatches Number of batches
     * @return isLocked Whether entries are locked
     */
    function getRoundStats(uint256 roundId) external view returns (
        uint256 totalEntries,
        uint256 totalBatches,
        bool isLocked
    ) {
        return (
            entryCount[roundId],
            batchCount[roundId],
            entriesLocked[roundId]
        );
    }
}
