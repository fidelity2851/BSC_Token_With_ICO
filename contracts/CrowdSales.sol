// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract CrowdSale is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token; // Token being sold
    address public wallet; // Address to receive funds
    IERC20 public usdtToken;
    AggregatorV3Interface internal bnbPriceFeed; // Chainlink Oracle

    uint256 public amountRaised; // Total amount of payment tokens raised
    uint256 public tokensSold; // Total number of tokens sold
    uint256 public startTime;
    uint256 public endTime;
    uint256 public totalCap; // Total token supply allocated for presale
    bool public isFinalized = false;

    struct SaleStage {
        uint256 rate; // Tokens per 1 payment token (e.g., 1 USDT = X tokens)
        uint256 cap; // Tokens to be sold in this stage
        uint256 sold; // Tokens sold in this stage
    }

    SaleStage[] public saleStages;
    uint256 public currentStage = 1;

    event TokensPurchased(
        address indexed buyer,
        uint256 amountPaid,
        uint256 tokensReceived
    );
    event SaleStageUpdated(uint256 stage, uint256 rate, uint256 cap);
    event CrowdsaleFinalized();
    event FundsWithdrawn(uint256 amount);
    event EndTimeUpdated(uint256 newEndTime);

    modifier onlyWhileOpen() {
        require(
            block.timestamp >= startTime && block.timestamp <= endTime,
            "Crowdsale is not open"
        );
        _;
    }

    modifier onlyBeforeFinalized() {
        require(!isFinalized, "Crowdsale has been finalized");
        _;
    }

    constructor(
        address _token,
        address _usdtToken,
        address _bnbPriceFeed,
        uint256 _startTime,
        uint256 _endTime
    ) Ownable(msg.sender) {
        require(_token != address(0), "Invalid token address");
        require(_usdtToken != address(0), "Invalid payment token address");
        require(_bnbPriceFeed != address(0), "Invalid wallet address");
        require(_startTime < _endTime, "Start time must be before end time");

        token = IERC20(_token);
        wallet = owner();
        usdtToken = IERC20(_usdtToken);
        bnbPriceFeed = AggregatorV3Interface(_bnbPriceFeed);
        startTime = _startTime;
        endTime = _endTime;
    }

    // Fallback function
    fallback() external payable {
        require(msg.value > 0, "Must send a positive amount");
        buyTokenWithNativeCoin();
    }

    receive() external payable {
        require(msg.value > 0, "Must send a positive amount");
        buyTokenWithNativeCoin();
    }

    // Buy Token with Native Coin
    function buyTokenWithNativeCoin()
        public
        payable
        onlyWhileOpen
        onlyBeforeFinalized
        whenNotPaused
        nonReentrant
    {
        require(msg.value > 0, "Must send a positive amount");
        uint256 bnbPrice = _getLatestBNBPrice(); // Get BNB/USD price
        uint256 amountInUSDT = (msg.value * bnbPrice) / 1e18; // Convert BNB to USDT equivalent
        uint256 tokenAmount = _calculateTokens(
            amountInUSDT,
            saleStages[currentStage].rate
        ); // Calculate tokens to send

        payable(wallet).transfer(msg.value); // Send BNB to wallet

        amountRaised += amountInUSDT;
        tokensSold += tokenAmount;
        saleStages[currentStage].sold += tokenAmount;

        _distributeTokens(msg.sender, tokenAmount);
        _checkAndAdvanceStage();
    }

    // Buy tokens using a BSC token (e.g., USDT)
    function buyTokenWithUsdt(
        uint256 _paymentAmount
    ) external onlyWhileOpen onlyBeforeFinalized whenNotPaused nonReentrant {
        require(_paymentAmount > 0, "Must send a positive amount");
        uint256 tokenAmount = _calculateTokens(
            _paymentAmount,
            saleStages[currentStage].rate
        ); // Calculate tokens to send

        // Send Usdt token to wallet
        _processUsdtPayment(msg.sender, _paymentAmount * 1e18);

        amountRaised += _paymentAmount;
        tokensSold += tokenAmount;
        saleStages[currentStage].sold += tokenAmount;

        _distributeTokens(msg.sender, tokenAmount);
        _checkAndAdvanceStage();
    }

    // Calculate the number of tokens a buyer will receive
    function _calculateTokens(
        uint256 _paymentAmount,
        uint256 _rate
    ) internal pure returns (uint256) {
        return _paymentAmount * _rate;
    }

    // Process the payment by transferring payment tokens to the wallet
    function _processUsdtPayment(address _buyer, uint256 _amount) internal {
        usdtToken.safeTransferFrom(_buyer, wallet, _amount);
    }

    // Transfer purchased tokens to the buyer
    function _distributeTokens(address _buyer, uint256 _tokenAmount) internal {
        token.safeTransfer(_buyer, _tokenAmount);
    }

    // Check if the current stage has reached its cap and move to the next stage if necessary
    function _checkAndAdvanceStage() internal {
        if (
            saleStages[currentStage].sold >= saleStages[currentStage].cap &&
            saleStages[currentStage + 1].rate != 0
        ) {
            currentStage++;
        }
    }

    // 🔹 Get the latest BNB price from Chainlink
    function _getLatestBNBPrice() public view returns (uint256) {
        (, int256 price, , , ) = bnbPriceFeed.latestRoundData();
        require(price > 0, "Invalid BNB price");
        return uint256(price) * 1e18; // Convert to 18 decimals
    }

    // Withdraw mistakenly sent BSC tokens
    function withdrawERC20(address _token, uint256 amount) external onlyOwner {
        IERC20(_token).transfer(owner(), amount);
        emit FundsWithdrawn(amount);
    }

    // Pause the sale
    function pause() external onlyOwner {
        _pause();
    }

    // Resume the sale
    function unpause() external onlyOwner {
        _unpause();
    }

    // Finalize the crowdsale
    function finalize() external onlyOwner onlyBeforeFinalized {
        isFinalized = true;
        emit CrowdsaleFinalized();
    }

    // Add a new sale stage
    function addSaleStage(
        uint256 _rate,
        uint256 _cap
    ) external onlyOwner onlyBeforeFinalized {
        require(_rate > 0, "Rate must be grateer than zero");

        saleStages.push(SaleStage(_rate, _cap, 0));
    }

    // Update end time (only if sale is not finalized)
    function updateEndTime(
        uint256 _newEndTime
    ) external onlyOwner onlyBeforeFinalized {
        require(
            _newEndTime > block.timestamp,
            "End time must be in the future"
        );
        require(_newEndTime > startTime, "End time must be after start time");
        endTime = _newEndTime;
        emit EndTimeUpdated(_newEndTime);
    }
}
