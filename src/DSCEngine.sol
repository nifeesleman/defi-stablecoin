// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Nife Esleman
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    //     Errors    //
    ///////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    //   State Variables   //
    /////////////////////////

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    address[] private sCollateralTokens;

    DecentralizedStableCoin private immutable I_DSC;

    using OracleLib for AggregatorV3Interface;

    mapping(address token => address priceFeed) private sPriceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private sCollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private sDscMinted;
    ///////////////////
    //   Events      //
    ///////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeem(address indexed redeemFrom, address indexed redeemTo, uint256 amount, address indexed token);

    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    modifier isAllowedToken(address token) {
        _isAllowedToken(token);
        _;
    }

    ///////////////////
    //   Functions   //
    ///////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            sPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            sCollateralTokens.push(tokenAddresses[i]);
        }

        I_DSC = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    //   External Functions  //
    ///////////////////////////
    /**
     * @notice This function deposits collateral and mints DSC in one transaction.
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
        // _revertIgHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, amountCollateral, tokenCollateralAddress);
        _revertIgHealthFactorIsBroken(msg.sender);
    }
    /**
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, amountCollateral, tokenCollateralAddress);
        _revertIgHealthFactorIsBroken(msg.sender);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        sCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Redeems collateral in exchange for burning DSC.
     * @param tokenCollateralAddress The ERC20 token address of the collateral to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @dev This function allows users to redeem their collateral by burning DSC in a single transaction.
     */

    // In order to redeem collateral
    // 1. You must have minted DSC
    // 2. Health factor must be above 1 after redeeming collateral
    // CEI Check-Effects-Interactions

    /**
     * @notice follow CEI-20 standard
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        sDscMinted[msg.sender] += amountDscToMint;

        _revertIgHealthFactorIsBroken(msg.sender);
        bool minted = I_DSC.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIgHealthFactorIsBroken(msg.sender); // Revert if health factor is broken after burning, But i dont think it can be broken after burning
    }
    /**
     * Allows a user to liquidate another user's position by covering their debt and receiving their collateral.
     * @param collateral The address of the collateral token to be liquidated.
     * @param user The address of the user whose position is being liquidated.
     * @param debtToCover The amount of debt to cover for liquidation.
     *
     * @notice You can partially liquidate a user.
     * @notice You can get liqydation rewards by covering a user's debt.
     * @notice This function works assuming the protocol will be roughly 200% overcollateralized inorder for this to work.
     * Follow CEI - Check-Effects-Interactions
     */

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Check if the user is liquidatable
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, totalCollateralRedeemed, collateral);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIgHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////////
    //   Private & Internal View Functions   //
    ///////////////////////////////////////////
    /**
     * Burns DSC tokens on behalf of a user.
     * @param amountDscToBurn The amount of DSC to burn.
     * @param onBehalfOf The address on whose behalf the DSC is burned.
     * @param dscFrom The address from which DSC tokens are transferred.
     * @dev Low-level function to burn DSC tokens.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        sDscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = I_DSC.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, uint256 amountCollateral, address tokenCollateralAddress)
        private
    {
        sCollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeem(from, to, amountCollateral, tokenCollateralAddress);
        // _Calculate the health factor before transferring the collateral
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = sDscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /*
    * Returns how close to liquidation a user is
    * If a user goes below 1, then they can be liquidated.
    */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIgHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    function _moreThanZero(uint256 amount) internal pure {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
    }

    function _isAllowedToken(address token) internal view {
        if (sPriceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
    }

    //////////////////////////////////////////
    //   Public & External View Functions   //
    //////////////////////////////////////////
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return sCollateralDeposited[user][token];
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // casting to uint256 is safe because Chainlink price feeds are expected to be non-negative and fit in 256 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < sCollateralTokens.length; i++) {
            address token = sCollateralTokens[i];
            uint256 amount = sCollateralDeposited[user][token];
            totalCollateralValueInUsd += (getUsdValue(token, amount));
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // casting to uint256 is safe because Chainlink price feeds are expected to be non-negative and fit in 256 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(price)) * amount * ADDITIONAL_FEED_PRECISION / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return sCollateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(I_DSC);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return sPriceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
