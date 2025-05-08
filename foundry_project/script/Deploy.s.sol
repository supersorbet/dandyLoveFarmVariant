// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/DandyV2.sol";
import "../src/DandyFarmV2.sol";

contract DeployScript is Script {
    // Configuration
    string constant TOKEN_NAME = "Dandy Token";
    string constant TOKEN_SYMBOL = "DANDY";
    address constant FEE_ADDRESS = address(0x123); // Replace with actual fee address
    uint256 constant DANDY_PER_BLOCK = 1 ether; // 1 DANDY per block
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy DandyV2 token
        DandyV2 dandy = new DandyV2(TOKEN_NAME, TOKEN_SYMBOL);
        console.log("DandyV2 deployed at:", address(dandy));
        
        // Deploy DandyFarmV2 using the deployed token
        uint256 startBlock = block.number;
        DandyFarmV2 farm = new DandyFarmV2(
            dandy,
            FEE_ADDRESS,
            DANDY_PER_BLOCK,
            startBlock
        );
        console.log("DandyFarmV2 deployed at:", address(farm));
        
        // Set up initial configuration
        
        // Set fees for different transaction types
        dandy.setFees(DandyV2.TxCase.BUY, 300, 200, 100); // 3% marketing, 2% treasury, 1% burn
        dandy.setFees(DandyV2.TxCase.SELL, 500, 300, 200); // 5% marketing, 3% treasury, 2% burn
        dandy.setFees(DandyV2.TxCase.TRANSFER, 100, 50, 50); // 1% marketing, 0.5% treasury, 0.5% burn
        
        // Set wallets
        dandy.setMarketingWallet(FEE_ADDRESS);
        dandy.setTreasuryWallet(FEE_ADDRESS);
        
        // Grant operator role to farm
        dandy.setAddressExclusions(address(farm), true, true, true);
        
        vm.stopBroadcast();
    }
} 