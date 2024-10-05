// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

contract GameInstance is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address[] public participants;
    mapping(address => Participant) public participantData;
    uint256 public entryFeePool;
    uint256 public startTime;
    uint256 public endTime;
    bool public inProgress;
    uint256 public totalStakes;

    uint256 public immutable gameId;
    IERC20 public immutable gameToken;
    uint256 public immutable minParticipants;
    uint256 public immutable maxParticipants;
    uint256 public immutable entryFee;
    uint256 public immutable gameDuration;
    uint256 public immutable entryFeePoolPercentageDeduction;
    uint256 public immutable minStakeAmount;

    struct Participant {
        uint256 joinTimestamp;
        uint256 totalAmountStaked;
        Stake[] stakeDetails;
    }

    struct Stake {
        uint256 amount;
        uint256 timestamp;
    }

    event GameStarted(uint256 startTime);
    event GameEnded(address winner, uint256 reward);
    event GameCancelled();
    event ParticipantJoined(address participant);
    event ParticipantLeft(address participant, uint256 refund);
    event Staked(address participant, uint256 amount);
    event Unstaked(address participant, uint256 amount);
    event WinnerSelected(address winner);
    event RewardDistributed(address participant, uint256 amount);

    modifier gameInProgress() {
        require(inProgress, "Game has not started yet");
        _;
    }

    modifier gameNotInProgress() {
        require(!inProgress, "Game is still in progress");
        _;
    }

    modifier isParticipant() {
        require(
            participantData[msg.sender].joinTimestamp > 0,
            "Not a participant"
        );
        _;
    }

    modifier isNotParticipant() {
        require(
            participantData[msg.sender].joinTimestamp == 0,
            "Already a participant"
        );
        _;
    }

    /**
     * @notice Creates a new game instance with the specified parameters.
     * @param _gameTokenAddress The address of the game token (ERC20).
     * @param _minParticipants The minimum number of participants required to start the game.
     * @param _maxParticipants The maximum number of participants allowed in the game.
     * @param _entryFee The entry fee for the game in tokens.
     * @param _gameDuration The duration of the game in seconds.
     * @param _entryFeePoolPercentageDeduction The percentage of the entry fee to be deducted for the pool.
     * @param _minStakeAmount The minimum stake amount in tokens.
     */
    constructor(
        uint256 _gameId,
        address _gameTokenAddress,
        uint256 _minParticipants,
        uint256 _maxParticipants,
        uint256 _entryFee,
        uint256 _gameDuration,
        uint256 _entryFeePoolPercentageDeduction,
        uint256 _minStakeAmount
    ) Ownable(msg.sender) {
        require(
            _minParticipants > 1,
            "Minimum participants must be greater than one"
        );
        require(
            _maxParticipants > _minParticipants,
            "Maximum participants cannot be less than minimum participants"
        );
        require(_entryFee > 0, "Entry fee must be greater than zero");
        require(
            _gameDuration > 1 minutes,
            "Game duration must be greater than one minute"
        );
        require(
            _minStakeAmount > 0,
            "Minimum stake amount must be greater than zero"
        );

        gameId = _gameId;
        gameToken = IERC20(_gameTokenAddress);
        minParticipants = _minParticipants;
        maxParticipants = _maxParticipants;
        entryFee = _entryFee;
        gameDuration = _gameDuration;
        entryFeePoolPercentageDeduction = _entryFeePoolPercentageDeduction;
        minStakeAmount = _minStakeAmount;
        participants = new address[](0);
    }

    function withdraw() external nonReentrant onlyOwner gameNotInProgress {
        require(
            gameToken.balanceOf(address(this)) > 0,
            "No balance to withdraw"
        );
        gameToken.safeTransfer(owner(), gameToken.balanceOf(address(this)));
    }

    function join() external nonReentrant isNotParticipant gameNotInProgress {
        require(
            participants.length < maxParticipants,
            "Max participants reached"
        );
        require(
            gameToken.balanceOf(msg.sender) >= entryFee,
            "Insufficient token balance"
        );
        require(
            gameToken.allowance(msg.sender, address(this)) >= entryFee,
            "Allowance not set for entry fee"
        );

        participants.push(msg.sender);
        participantData[msg.sender].joinTimestamp = block.timestamp;
        participantData[msg.sender].totalAmountStaked = 0;

        uint256 entryFeePoolDeduction = (entryFee *
            entryFeePoolPercentageDeduction) / 100;
        entryFeePool += entryFeePoolDeduction;

        gameToken.safeTransferFrom(msg.sender, address(this), entryFee);

        emit ParticipantJoined(msg.sender);
    }

    function leave() external nonReentrant isParticipant gameNotInProgress {
        uint256 contractBalance = gameToken.balanceOf(address(this));

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == msg.sender) {
                participants[i] = participants[participants.length - 1];
                participants.pop();
                break;
            }
        }

        delete participantData[msg.sender];

        uint256 refund = ((block.timestamp - startTime) * entryFee) /
            gameDuration;

        if (contractBalance < refund) {
            refund = contractBalance;
        }

        gameToken.safeTransfer(msg.sender, refund);

        emit ParticipantLeft(msg.sender, refund);
    }

    function start() public onlyOwner {
        require(
            participants.length >= minParticipants,
            "Not enough participants"
        );
        require(!inProgress, "Game has already started");

        startTime = block.timestamp;
        inProgress = true;

        emit GameStarted(startTime);
    }

    function end() public nonReentrant onlyOwner gameInProgress {
        if (participants.length >= minParticipants) {
            require(
                block.timestamp >= startTime + gameDuration,
                "Game has not ended yet"
            );
        } else {
            emit GameCancelled();
        }

        endTime = block.timestamp;
        inProgress = false;

        address[] storage _participants = participants;
        uint256 numberOfParticipants = _participants.length;
        mapping(address => Participant)
            storage _participantData = participantData;
        uint256 _totalStakes = totalStakes;
        uint256 _entryFeePool = entryFeePool;

        delete totalStakes;
        delete entryFeePool;
        delete participants;
        for (uint256 i = 0; i < numberOfParticipants; i++) {
            delete participantData[_participants[i]];
        }

        address winner = selectWinner(_participants);
        uint256 winnerRewardAmount = getWinnerRewardAmount(
            _participantData[winner],
            _totalStakes,
            _entryFeePool
        );

        uint256[] memory rewards = calculateRewards(
            _participants,
            _participantData,
            _entryFeePool,
            _totalStakes
        );
        for (uint256 i = 0; i < _participants.length; i++) {
            if (_participants[i] == winner) {
                rewards[i] += winnerRewardAmount;
            }
            gameToken.safeTransfer(_participants[i], rewards[i]);
            emit RewardDistributed(_participants[i], rewards[i]);
        }

        emit GameEnded(winner, winnerRewardAmount);
    }

    function stake(uint256 amount) external nonReentrant isParticipant gameInProgress {
        require(
            gameToken.balanceOf(msg.sender) >= amount,
            "Insufficient token balance"
        );
        require(amount >= minStakeAmount, "Stake amount too low");

        participantData[msg.sender].stakeDetails.push(
            Stake(amount, block.timestamp)
        );
        participantData[msg.sender].totalAmountStaked += amount;
        totalStakes += amount;

        gameToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant isParticipant gameInProgress {
        require(
            gameToken.balanceOf(address(this)) >= amount,
            "Insufficient contract balance"
        );
        require(amount > 0, "Unstake amount must be greater than zero");
        require(
            participantData[msg.sender].totalAmountStaked >= amount,
            "Cannot unstake more than staked amount"
        );

        participantData[msg.sender].totalAmountStaked -= amount;
        totalStakes -= amount;

        Participant storage participant = participantData[msg.sender];
        uint256 unstakedAmount = 0;

        for (uint256 i = participant.stakeDetails.length; i > 0; i--) {
            if (unstakedAmount == amount) {
                break;
            }
            uint256 lastStakeAmount = participant.stakeDetails[i - 1].amount;
            if (lastStakeAmount <= amount - unstakedAmount) {
                unstakedAmount += lastStakeAmount;
                delete participant.stakeDetails[i - 1];
            } else {
                participant.stakeDetails[i - 1].amount -=
                    amount -
                    unstakedAmount;
                unstakedAmount = amount;
            }
        }

        gameToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function selectWinner(
        address[] memory _participants
    ) internal view gameNotInProgress returns (address) {
        require(_participants.length > 0, "No participants");

        bytes32 gameHash = keccak256(
            abi.encodePacked(blockhash(block.number - 1), _participants)
        );
        bytes32 finalHash = keccak256(
            abi.encodePacked(block.prevrandao, gameHash)
        );
        uint256 randomIndex = uint256(finalHash) % _participants.length;

        return _participants[randomIndex];
    }

    function getWinnerRewardAmount(
        Participant memory winnerData,
        uint256 _totalStakes,
        uint256 _entryFeePool
    ) internal view returns (uint256) {
        // reward winner depending on amount and duration of stakes

        uint256 rewardTotal = (_entryFeePool * winnerData.totalAmountStaked) /
            _totalStakes;

        for (uint256 i = 0; i < winnerData.stakeDetails.length; i++) {
            // multiply each stake by the duration it was staked for
            uint256 stakeDuration = block.timestamp -
                winnerData.stakeDetails[i].timestamp;
            rewardTotal += winnerData.stakeDetails[i].amount * stakeDuration;
        }

        return rewardTotal;
    }

    function calculateRewards(
        address[] memory _participants,
        mapping(address => Participant) storage _participantData,
        uint256 _entryFeePool,
        uint256 _totalStakes
    ) internal returns (uint256[] memory) {
        // distribute entry fee pool among all stakers, proportionate to their staked amounts
        uint256[] memory rewards = new uint256[](_participants.length);

        for (uint256 i = 0; i < _participants.length; i++) {
            if (participantData[participants[i]].totalAmountStaked == 0) {
                rewards[i] = 0;
                continue;
            }
            uint256 reward = (_entryFeePool *
                _participantData[participants[i]].totalAmountStaked) /
                _totalStakes;
            participantData[participants[i]].totalAmountStaked = 0;
            rewards[i] = reward;
        }

        return rewards;
    }
}
