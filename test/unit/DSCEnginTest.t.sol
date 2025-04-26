// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address weth;
    // For deployment setup

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 1e18;
        uint256 expectedUsd = 2000e8;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd, "USD value calculation is incorrect");
    }
}
