// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title ChasepotVRF
 * @notice VRF-only contract for generating provably fair winning numbers for Chasepot sweepstakes
 * @dev Deployed on Arbitrum for low gas costs. Does NOT handle payouts - that's done by backend from BSC community wallet.
 * @dev Uses VRFConsumerBaseV2Plus's built-in ownership (ConfirmedOwner pattern from Chainlink)
 *
 * Flow:
 * 1. Owner calls requestDraw(roundId) weekly
 * 2. Chainlink VRF returns random number
 * 3. Contract generates 6 unique numbers from 1-45
 * 4. Backend reads DrawFulfilled event, matches entries, pays winners from BSC
 */
contract ChasepotVRF is VRFConsumerBaseV2Plus {
    // ============ Game Configuration ============
    uint8 public pickCount = 6;      // Numbers to pick (6/45 format)
    uint8 public maxNumber = 45;     // Max number in range (1-45)

    // ============ VRF Configuration ============
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public callbackGasLimit = 300000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;  // We only need 1 random word to generate all numbers

    // ============ Pause State ============
    bool public paused;

    // ============ Draw Recovery ============
    uint256 public constant DRAW_TIMEOUT = 1 hours;

    // ============ Draw State ============
    struct Draw {
        uint256 roundId;
        uint256 requestId;
        uint8[] winningNumbers;
        bool fulfilled;
        uint256 timestamp;
        uint8 pickCount;     // Snapshotted at request time
        uint8 maxNumber;     // Snapshotted at request time
    }

    // roundId => Draw
    mapping(uint256 => Draw) public draws;

    // requestId => roundId (for VRF callback lookup)
    mapping(uint256 => uint256) public requestToRound;

    // Track active rounds to prevent duplicate draws
    mapping(uint256 => bool) public activeDraws;

    // ============ Events ============
    event DrawRequested(uint256 indexed roundId, uint256 indexed requestId);
    event DrawFulfilled(uint256 indexed roundId, uint256 indexed requestId, uint8[] winningNumbers);
    event GameFormatUpdated(uint8 pickCount, uint8 maxNumber);
    event VRFConfigUpdated(uint256 subscriptionId, bytes32 keyHash, uint32 callbackGasLimit);
    event DrawCancelled(uint256 indexed roundId, uint256 indexed requestId);

    // ============ Errors ============
    error DrawAlreadyInProgress(uint256 roundId);
    error DrawNotFound(uint256 roundId);
    error InvalidGameFormat();
    error RoundAlreadyDrawn(uint256 roundId);
    error DrawNotPending(uint256 roundId);
    error DrawNotTimedOut(uint256 roundId, uint256 requestTimestamp, uint256 timeoutAt);
    error ContractPaused();

    // ============ Modifiers ============
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @notice Constructor
     * @param vrfCoordinator Chainlink VRF Coordinator address
     * @param subscriptionId Chainlink VRF subscription ID
     * @param keyHash Gas lane key hash
     */
    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
    }

    // ============ Owner Functions ============

    /**
     * @notice Request a draw for a round
     * @param roundId Backend round ID to draw for
     * @return requestId The Chainlink VRF request ID
     */
    function requestDraw(uint256 roundId) external onlyOwner whenNotPaused returns (uint256 requestId) {
        // Check round hasn't already been drawn
        if (draws[roundId].fulfilled) {
            revert RoundAlreadyDrawn(roundId);
        }

        // Check no active draw for this round
        if (activeDraws[roundId]) {
            revert DrawAlreadyInProgress(roundId);
        }

        // Request random words from Chainlink VRF
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        // Store draw request (snapshot game format at request time)
        draws[roundId] = Draw({
            roundId: roundId,
            requestId: requestId,
            winningNumbers: new uint8[](0),
            fulfilled: false,
            timestamp: block.timestamp,
            pickCount: pickCount,
            maxNumber: maxNumber
        });

        requestToRound[requestId] = roundId;
        activeDraws[roundId] = true;

        emit DrawRequested(roundId, requestId);
    }

    /**
     * @notice Update game format (e.g., change from 6/45 to 6/49)
     * @param _pickCount Number of numbers to pick (1-9; limited by uint64 base-100 encoding in ChasepotEntries)
     * @param _maxNumber Maximum number in range (1 to N, max 99)
     */
    function setGameFormat(uint8 _pickCount, uint8 _maxNumber) external onlyOwner {
        if (_pickCount == 0 || _pickCount > 9) revert InvalidGameFormat();
        if (_maxNumber < _pickCount || _maxNumber > 99) revert InvalidGameFormat();

        pickCount = _pickCount;
        maxNumber = _maxNumber;

        emit GameFormatUpdated(_pickCount, _maxNumber);
    }

    /**
     * @notice Update VRF configuration
     * @param subscriptionId New subscription ID
     * @param keyHash New key hash
     * @param _callbackGasLimit New callback gas limit
     */
    function setVRFConfig(
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 _callbackGasLimit
    ) external onlyOwner {
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;
        callbackGasLimit = _callbackGasLimit;

        emit VRFConfigUpdated(subscriptionId, keyHash, _callbackGasLimit);
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        paused = true;
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        paused = false;
    }

    /**
     * @notice Cancel a stuck draw that has not been fulfilled within the timeout period
     * @dev Only callable after DRAW_TIMEOUT has passed since the draw request.
     *      No whenNotPaused — recovery should work even when paused.
     * @param roundId The round ID of the stuck draw
     */
    function cancelDraw(uint256 roundId) external onlyOwner {
        if (!activeDraws[roundId]) revert DrawNotPending(roundId);

        Draw storage draw = draws[roundId];
        require(!draw.fulfilled, "Already fulfilled");

        if (block.timestamp < draw.timestamp + DRAW_TIMEOUT) {
            revert DrawNotTimedOut(roundId, draw.timestamp, draw.timestamp + DRAW_TIMEOUT);
        }

        uint256 requestId = draw.requestId;

        activeDraws[roundId] = false;
        delete draws[roundId];
        delete requestToRound[requestId];

        emit DrawCancelled(roundId, requestId);
    }

    // ============ VRF Callback ============

    /**
     * @notice Chainlink VRF callback - generates winning numbers from randomness
     * @param requestId The VRF request ID
     * @param randomWords Array of random words (we use index 0)
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 roundId = requestToRound[requestId];
        Draw storage draw = draws[roundId];

        require(!draw.fulfilled, "Already fulfilled");
        require(draw.requestId == requestId, "Request ID mismatch");

        // Generate winning numbers from randomness (using snapshotted game format)
        uint8[] memory numbers = _generateNumbers(randomWords[0], draw.pickCount, draw.maxNumber);

        draw.winningNumbers = numbers;
        draw.fulfilled = true;
        activeDraws[roundId] = false;

        emit DrawFulfilled(roundId, requestId, numbers);
    }

    // ============ View Functions ============

    /**
     * @notice Get winning numbers for a round
     * @param roundId The round ID
     * @return numbers Array of winning numbers
     */
    function getWinningNumbers(uint256 roundId) external view returns (uint8[] memory) {
        Draw storage draw = draws[roundId];
        if (!draw.fulfilled) revert DrawNotFound(roundId);
        return draw.winningNumbers;
    }

    /**
     * @notice Get full draw details
     * @param roundId The round ID
     * @return roundId_ Round ID
     * @return requestId VRF request ID
     * @return winningNumbers Array of winning numbers
     * @return fulfilled Whether draw is complete
     * @return timestamp When draw was requested
     */
    function getDraw(uint256 roundId) external view returns (
        uint256 roundId_,
        uint256 requestId,
        uint8[] memory winningNumbers,
        bool fulfilled,
        uint256 timestamp,
        uint8 pickCount_,
        uint8 maxNumber_
    ) {
        Draw storage draw = draws[roundId];
        return (
            draw.roundId,
            draw.requestId,
            draw.winningNumbers,
            draw.fulfilled,
            draw.timestamp,
            draw.pickCount,
            draw.maxNumber
        );
    }

    /**
     * @notice Check if a draw is pending (requested but not fulfilled)
     * @param roundId The round ID
     * @return isPending Whether draw is pending
     */
    function isDrawPending(uint256 roundId) external view returns (bool) {
        return activeDraws[roundId];
    }

    // ============ Internal Functions ============

    /**
     * @notice Generate unique sorted random numbers from a seed
     * @param seed The random seed from VRF
     * @param _pickCount Number of numbers to pick (snapshotted from draw request)
     * @param _maxNumber Maximum number in range (snapshotted from draw request)
     * @return numbers Array of unique random numbers (sorted ascending)
     */
    function _generateNumbers(uint256 seed, uint8 _pickCount, uint8 _maxNumber) internal pure returns (uint8[] memory) {
        uint8[] memory numbers = new uint8[](_pickCount);
        bool[] memory used = new bool[](_maxNumber + 1);
        uint256 currentSeed = seed;
        uint8 count = 0;

        // Generate unique numbers
        while (count < _pickCount) {
            uint8 num = uint8((currentSeed % _maxNumber) + 1);
            if (!used[num]) {
                numbers[count] = num;
                used[num] = true;
                count++;
            }
            // Generate new seed for next iteration
            currentSeed = uint256(keccak256(abi.encodePacked(currentSeed)));
        }

        // Sort numbers ascending (bubble sort - efficient for small arrays)
        for (uint8 i = 0; i < _pickCount - 1; i++) {
            for (uint8 j = 0; j < _pickCount - i - 1; j++) {
                if (numbers[j] > numbers[j + 1]) {
                    (numbers[j], numbers[j + 1]) = (numbers[j + 1], numbers[j]);
                }
            }
        }

        return numbers;
    }
}
