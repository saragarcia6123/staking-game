// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {GameInstance} from "./GameInstance.sol";
 
contract GameManager is Ownable {
 
    mapping(uint256 => address) public games;
    uint256 private nextGameId;
 
    modifier gameExists(uint256 gameId) {
        require(games[gameId] != address(0), "Game does not exist");
        _;
    }
 
    constructor() Ownable(msg.sender) {
        nextGameId = 1;
    }

    function createGame() public onlyOwner {
        uint256 gameId = nextGameId++;
        GameInstance game = new GameInstance(
            {
                _gameId: gameId,
                _gameTokenAddress: 0x6B175474E89094C44Da98b954EedeAC495271d0F, // DAI
                _minParticipants: 3,
                _maxParticipants: 100,
                _entryFee: 10 * 10**18, // 10 DAI
                _gameDuration: 5 minutes,
                _entryFeePoolPercentageDeduction: 10, // 10%
                _minStakeAmount: 1e18 // 1 DAI
            }
        );
        games[gameId] = address(game);
    }
 
    function getGameAddress(uint256 gameId) external view gameExists(gameId) returns (address) {
        return games[gameId];
    }
    
}