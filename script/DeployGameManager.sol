// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {GameManager} from "../src/GameManager.sol";

contract DeployGameManager is Script {

    function run() external returns (GameManager) {
        vm.startBroadcast();
        
        GameManager gameManager = new GameManager();
        console.log("GameManager deployed at: ", address(gameManager));

        vm.stopBroadcast();
        return gameManager;
    }
}
