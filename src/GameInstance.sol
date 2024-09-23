// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract GameInstance is Ownable {
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
    event GameEnded(address winner);
    event GameCancelled();
    event ParticipantJoined(address participant);
    event ParticipantLeft(address participant, uint256 refund);
    event Staked(address participant, uint256 amount);
    event Unstaked(address participant, uint256 amount);
    event WinnerSelected(address winner);
    event RewardDistributed(address participant, uint256 amount);

    modifier gameInProgress() {
        require(block.timestamp < startTime + gameDuration, "Game has ended");
        require(inProgress, "Game has not started yet");
        _;
    }

    modifier gameNotInProgress() {
        require(!inProgress, "Game is still in progress");
        require(block.timestamp >= startTime + gameDuration, "Game is still in progress");
        _;
    }

    modifier isParticipant() {
        require(participantData[msg.sender].joinTimestamp > 0, "Not a participant");
        _;
    }

    modifier isNotParticipant() {
        require(participantData[msg.sender].joinTimestamp == 0, "Already a participant");
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
        gameId = _gameId;
        gameToken = IERC20(_gameTokenAddress);
        minParticipants = _minParticipants;
        maxParticipants = _maxParticipants;
        entryFee = _entryFee;
        gameDuration = _gameDuration;
        entryFeePoolPercentageDeduction = _entryFeePoolPercentageDeduction;
        minStakeAmount = _minStakeAmount;

        require(_minParticipants > 0, "Minimum participants must be greater than zero");
        require(_maxParticipants > _minParticipants, "Max participants must be greater than minimum participants");
        require(_entryFee > 0, "Entry fee must be greater than zero");
        require(_gameDuration > 0, "Game duration must be greater than zero");
        require(_minStakeAmount > 0, "Minimum stake amount must be greater than zero");

        participants = new address[](0);

    }

    function withdraw() external onlyOwner gameNotInProgress {
        uint256 contractBalance = gameToken.balanceOf(address(this));
        require(contractBalance > 0, "No balance to withdraw");
        gameToken.safeTransfer(owner(), contractBalance);
    }

    function join() external isNotParticipant gameNotInProgress  {
        require(participants.length < maxParticipants, "Max participants reached");

        require(gameToken.balanceOf(msg.sender) >= entryFee, "Insufficient token balance");
        require(gameToken.allowance(msg.sender, address(this)) >= entryFee, "Allowance not set for entry fee");

        participants.push(msg.sender);
        participantData[msg.sender].joinTimestamp = block.timestamp;
        participantData[msg.sender].totalAmountStaked = 0;

        uint256 entryFeePoolDeduction = (entryFee * entryFeePoolPercentageDeduction) / 100;
        entryFeePool += entryFeePoolDeduction;

        gameToken.safeTransferFrom(msg.sender, address(this), entryFee);

        emit ParticipantJoined(msg.sender);
    }

    function leave() external isParticipant {
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == msg.sender) {
                participants[i] = participants[participants.length - 1];
                participants.pop();
                break;
            }
        }

        delete participantData[msg.sender];

        uint256 refund = (block.timestamp - startTime) * entryFee / gameDuration;
        require(gameToken.balanceOf(address(this)) >= refund, "Contract has insufficient game token balance to refund");
        require(gameToken.transfer(msg.sender, refund), "Refund transfer failed");

        emit ParticipantLeft(msg.sender, refund);

        if (participants.length < minParticipants) {
            cancel();
        }
    }

    function kick(address participant) public onlyOwner {
        require(participantData[participant].joinTimestamp > 0, "Participant not found");

        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] == participant) {
                participants[i] = participants[participants.length - 1];
                participants.pop();
                break;
            }
        }
        delete participantData[participant];

        uint256 refund = (block.timestamp - startTime) * entryFee / gameDuration;
        require(gameToken.balanceOf(address(this)) >= refund, "Contract has insufficient game token balance to refund");
        gameToken.safeTransfer(participant, refund);

        emit ParticipantLeft(participant, refund);

        if (participants.length < minParticipants) {
            cancel();
        }
    }

    function start() public onlyOwner {
        require(participants.length >= minParticipants, "Not enough participants");
        require(!inProgress, "Game has already started");

        startTime = block.timestamp;
        inProgress = true;

        emit GameStarted(startTime);
    }

    function end() public onlyOwner gameInProgress {

        require(block.timestamp >= startTime + gameDuration, "Game has not ended yet");
        endTime = block.timestamp;
        inProgress = false;

        address winner = selectWinner();
        require(winner != address(0), "Winner not selected");

        uint256 winnerRewardAmount = getWinnerRewardAmount(winner);
        distributeRewards();

        gameToken.safeTransfer(winner, winnerRewardAmount);
        emit GameEnded(winner);
    }

    function cancel() public onlyOwner {
        require(inProgress, "Game has not started yet");
        inProgress = false;
        reset();
        emit GameCancelled();
    }

    function reset() public onlyOwner gameNotInProgress {
        uint256 numberOfParticipants = participants.length;
        for (uint256 i = 0; i < numberOfParticipants; i++) {
            delete participantData[participants[i]];
        }

        participants = new address[](0);
        totalStakes = 0;
        entryFeePool = 0;
        startTime = 0;
        endTime = 0;

        inProgress = false;
    }

    function stake(uint256 amount) external isParticipant gameInProgress {
        require(amount >= minStakeAmount, "Stake amount too low");
        require(gameToken.balanceOf(msg.sender) >= amount, "Insufficient token balance");

        participantData[msg.sender].stakeDetails.push(Stake(amount, block.timestamp));
        participantData[msg.sender].totalAmountStaked += amount;
        totalStakes += amount;

        gameToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external isParticipant gameInProgress {
        require(amount > 0, "Unstake amount must be greater than zero");
        require(participantData[msg.sender].totalAmountStaked >= amount, "Cannot unstake more than staked amount");

        Participant storage participant = participantData[msg.sender];
        uint256 unstakedAmount = 0;

        for (uint256 i = participant.stakeDetails.length; i >= 0; i--) {
            if (unstakedAmount == amount) {
                break;
            }
            uint256 lastStakeAmount = participant.stakeDetails[i - 1].amount;
            if(lastStakeAmount <= amount - unstakedAmount) {
                unstakedAmount += lastStakeAmount;
                delete participant.stakeDetails[i - 1];
            } else {
                participant.stakeDetails[i - 1].amount -= amount - unstakedAmount;
                unstakedAmount = amount;
            }
        }

        require(unstakedAmount == amount, "Unstake amount does not match staked amount");

        participantData[msg.sender].totalAmountStaked -= amount;
        totalStakes -= amount;

        gameToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    function selectWinner() internal view returns (address) {
        require(participants.length > 0, "No participants");
        require(inProgress, "Game has not started yet");

        bytes32 gameHash = keccak256(abi.encodePacked(blockhash(block.number - 1), participants));
        bytes32 combinedHash = keccak256(abi.encodePacked(gameHash, blockhash(block.number - 1)));
        bytes32 finalHash = keccak256(abi.encodePacked(block.prevrandao, combinedHash, participants.length));
        uint256 scaledRandomIndex = uint256(finalHash) / (type(uint256).max / participants.length);

        return participants[scaledRandomIndex % participants.length];
    }

    function getWinnerRewardAmount(address winner) internal returns (uint256) {
        // reward winner depending on amount and duration of stakes
        Participant storage winnerData = participantData[winner];

        uint256 rewardTotal = (entryFeePool * winnerData.totalAmountStaked) / totalStakes;

        for (uint256 i = 0; i < winnerData.stakeDetails.length; i++) {
            // multiply each stake by the duration it was staked for
            uint256 stakeDuration = block.timestamp - winnerData.stakeDetails[i].timestamp;
            rewardTotal += winnerData.stakeDetails[i].amount * stakeDuration;
        }

        participantData[winner].totalAmountStaked = 0;
        delete participantData[winner].stakeDetails;

        return rewardTotal;
    }

    function distributeRewards() internal returns (bool) {
        // distribute entry fee pool among all stakers, proportionate to their staked amounts
        for (uint256 i = 0; i < participants.length; i++) {
            if (participantData[participants[i]].totalAmountStaked == 0) {
                continue;
            }
            uint256 reward = (entryFeePool * participantData[participants[i]].totalAmountStaked) / totalStakes;
            participantData[participants[i]].totalAmountStaked = 0;
            require(gameToken.balanceOf(address(this)) >= reward, "Insufficient contract balance");
            gameToken.safeTransfer(participants[i], reward);
        }
        return true;
    }

}