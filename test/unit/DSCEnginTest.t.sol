// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "test/mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "test/mocks/MockFailedTransfer.sol";

contract DSCEngineTest is Test {
    error DSCEngine__NeedsMoreThanZero();

    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
    // redeemFrom != redeemedTo, then it was liquidated

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    // For deployment setup
    function setUp() public {
        deployer = new DeployDSC();

        // Ensure we're using the test runner's address
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public feedAddresses;

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);
        tokenAddresses.push(weth);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedTokenAmount = 0.05 ether;
        uint256 actualTokenAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualTokenAmount, expectedTokenAmount, "Token amount calculation is incorrect");
    }

    // to test the minting of DSC

    function testGetUsdValue() public view {
        uint256 ethAmount = 1e18;
        uint256 expectedUsd = 2000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd, "USD value calculation is incorrect");
    }

    ///////////////////////////////////////
    // depositCollateral Tests ////////////
    ///////////////////////////////////////
    function testRevertsIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        feedAddresses = [ethUsdPriceFeed];
        // DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral.
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        mockCollateralToken.mint(user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), amountCollateral);
        vm.stopPrank();
    }

    function testReverseCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        vm.expectRevert(DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", user, amountCollateral);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositeCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositeCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositeCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);

        // Assert the user hasn’t minted any DSC
        assertEq(totalDscMinted, 0);

        // Assert the USD value is correctly computed
        uint256 expectedUsdValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValueInUsd, expectedUsdValue);
    }

    function testGetAccountCollateralValue() public depositeCollateral {
        uint256 expectedUsdValue = dsce.getUsdValue(weth, amountCollateral);
        uint256 actualUsdValue = dsce.getAccountCollateralValue(user);
        assertEq(actualUsdValue, expectedUsdValue, "Collateral USD value mismatch");
    }
    //     ///////////////////////////////////////
    //     // depositCollateralAndMintDsc Tests //
    //     ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {}

    function testRevertsIfMintedDscIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        vm.expectRevert(DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, 0);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }
    ///////////////////////////////////////
    //MintDsc Tests ///////////////////////
    ///////////////////////////////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDscRevertsOnZeroCollateral() public {
        vm.expectRevert(); // Replace with specific error if available
        vm.prank(user);
        dsce.mintDsc(amountToMint);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositeCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // Chainlink prices are positive and fit in uint256 for these tests
        // forge-lint: disable-next-line(unsafe-typecast)
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositeCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }
    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }
    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    ////////////////////////
    // liquidate Tests //
    ////////////////////////

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint)
                * dsce.getLiquidationBonus()
                / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint)
                * dsce.getLiquidationBonus()
                / dsce.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testGetCollateralBalanceOfuser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValueFromInformation() public depositeCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetPrecisionReturnsCorrectValue() public view {
        // Expected constant
        uint256 expectedPrecision = 1e18;

        // Call the function
        uint256 actualPrecision = dsce.getPrecision();

        // Assert
        assertEq(actualPrecision, expectedPrecision, "getPrecision() did not return the correct value");
    }

    function testGetAdditionalFeedPrecision() public view {
        uint256 expected = 1e10; // Replace with actual constant in your contract
        assertEq(dsce.getAdditionalFeedPrecision(), expected, "Incorrect ADDITIONAL_FEED_PRECISION");
    }

    function testGetCollateralTokens() public view {
        address[] memory tokens = dsce.getCollateralTokens();
        assertEq(tokens.length, 2);
    }

    function testGetDscReturnsCorrectAddress() public view {
        assertEq(dsce.getDsc(), address(dsc));
    }

    function testHealthFactorReturnsMaxWhenNoDebt() public view {
        uint256 collateralUsd = 1000 ether;
        uint256 healthFactor = dsce.calculateHealthFactor(0, collateralUsd);
        assertEq(healthFactor, type(uint256).max);
    }

    function testGetLiquidationBonus() public view {
        uint256 expected = 10;
        uint256 actual = dsce.getLiquidationBonus();
        assertEq(actual, expected);
    }

    function testRevertsIfZeroDebtToCover() public {
        vm.expectRevert(); // or use custom error if applicable
        vm.prank(user);
        dsce.liquidate(weth, user, 0);
    }

    function testRevertsIfZeroToBurn() public {
        vm.expectRevert(); // or use custom error if applicable
        vm.prank(user);
        dsce.burnDsc(0);
    }

    function testRevertsIfZeroToRedeem() public {
        vm.expectRevert(); // or use custom error if applicable
        vm.prank(user);
        dsce.redeemCollateral(weth, 0);
    }

    function testRevertsIfZeroToRedeemForDsc() public {
        vm.expectRevert(); // or use custom error if applicable
        vm.prank(user);
        dsce.redeemCollateralForDsc(weth, 0, 0);
    }
}
