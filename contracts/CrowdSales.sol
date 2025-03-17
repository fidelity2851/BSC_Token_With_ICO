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
    address public defaultTokenAddress;

    uint256 public totalAmountRaisedInUSD; // Total amount of payment tokens raised
    uint256 public tokensSold; // Total number of tokens sold
    uint256 public maxPurchaseLimit;

    uint256 public startTime;
    uint256 public endTime;
    bool public isFinalized = false;

    struct SaleStage {
        uint256 rate; // Tokens per 1 payment token (e.g, 1 USDT = X tokens)
        uint256 cap; // Tokens to be sold in this stage
        uint256 sold; // Tokens sold in this stage
    }
    SaleStage[] public saleStages;
    uint256 public currentStage = 0;

    struct PaymentToken {
        bool isActive; // Is the Payment Token allowed
        address priceFeedAddress; // Address of payment token price feed (ChainLink)
    }
    mapping(address => PaymentToken) public allowedPaymentToken;
    mapping(address => uint256) public tokensPurchasedByAddress;

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
        address _defaultTokenAddress,
        uint256 _maxPurchaseLimit,
        uint256 _startTime,
        uint256 _endTime
    ) Ownable(msg.sender) {
        require(_token != address(0), "Invalid token address");
        require(
            _defaultTokenAddress != address(0),
            "Invalid price feed address"
        );
        require(_startTime < _endTime, "Start time must be before end time");
        token = IERC20(_token);
        wallet = owner();
        defaultTokenAddress = _defaultTokenAddress;
        maxPurchaseLimit = _maxPurchaseLimit;
        startTime = _startTime;
        endTime = _endTime;
    }

    // Fallback function
    fallback() external payable onlyWhileOpen onlyBeforeFinalized {
        require(msg.value > 0, "Must send a positive amount");
        buyTokenWithNativeCoin();
    }

    receive() external payable onlyWhileOpen onlyBeforeFinalized {
        require(msg.value > 0, "Must send a positive amount");
        buyTokenWithNativeCoin();
    }

    // Update Allowed Payment Token
    function updateAllowedPaymentToken(
        address _paymentTokenAddress,
        address _priceFeedAddress
    ) external onlyOwner {
        require(
            _paymentTokenAddress != address(0),
            "You need to provide a valid payment token address"
        );
        require(
            _priceFeedAddress != address(0),
            "You need to provide a valid Price Feed Address"
        );
        allowedPaymentToken[_paymentTokenAddress] = PaymentToken(
            true,
            _priceFeedAddress
        );
    }

    // Enable Allowed Payment Token
    function enablePaymentToken(
        address _paymentTokenAddress
    ) external onlyOwner {
        require(
            _paymentTokenAddress != address(0),
            "You need to provide a valid payment token address"
        );
        require(
            allowedPaymentToken[_paymentTokenAddress].isActive == false &&
                allowedPaymentToken[_paymentTokenAddress].priceFeedAddress !=
                address(0),
            "You cannot enable a token that is already enabled"
        );
        allowedPaymentToken[_paymentTokenAddress].isActive = true;
    }

    // Disable Allowed Payment Token
    function disablePaymentToken(
        address _paymentTokenAddress
    ) external onlyOwner {
        require(
            _paymentTokenAddress != address(0),
            "You need to provide a valid payment token address"
        );
        require(
            allowedPaymentToken[_paymentTokenAddress].isActive == true &&
                allowedPaymentToken[_paymentTokenAddress].priceFeedAddress !=
                address(0),
            "You cannot enable a token that is already disabled"
        );
        allowedPaymentToken[_paymentTokenAddress].isActive = false;
    }

    // Get Payment Token Price Feed
    function getPaymentTokenPriceFeed(
        address _paymentTokenAddress
    ) public view returns (uint256) {
        require(
            _paymentTokenAddress != address(0),
            "You need to provide a valid payment token address"
        );
        require(
            allowedPaymentToken[_paymentTokenAddress].isActive == true &&
                allowedPaymentToken[_paymentTokenAddress].priceFeedAddress !=
                address(0),
            "Token not Allowed or Invalid Price Feed Address"
        );

        AggregatorV3Interface priceFeedProvider = AggregatorV3Interface(
            allowedPaymentToken[_paymentTokenAddress].priceFeedAddress
        );
        (, int256 price, , , ) = priceFeedProvider.latestRoundData();
        uint256 decimal = priceFeedProvider.decimals();
        require(price > 0, "Invalid Token price");
        return uint256(price) / 10**decimal;
    }

    event ValidAmount(
        uint256 value,
        uint256 raw_value,
        uint256 token,
        uint256 priceFeed
    );

    // Buy Token with Native Coin
    function buyTokenWithNativeCoin()
        public
        payable
        onlyWhileOpen
        onlyBeforeFinalized
        whenNotPaused
        nonReentrant
    {
        uint256 valueAmount = msg.value;
        require(valueAmount > 0, "Must send a positive amount");
        require(
            saleStages[currentStage].rate > 0,
            "We don't have a valid stage for purchase"
        );

        uint256 paymentAmountInUsd = (getPaymentTokenPriceFeed(
            defaultTokenAddress
        ) * valueAmount) / 1e18;
        uint256 tokenAmount = _calculateTokens(
            paymentAmountInUsd,
            saleStages[currentStage].rate
        );

        // Ensure the contract has enough tokens to distribute.
        require(
            hasEnoughTokens(tokenAmount),
            "We don't have enough token for your purchase"
        );
        require(
            tokensPurchasedByAddress[msg.sender] + tokenAmount <=
                maxPurchaseLimit,
            "You can't purchase more than max token allowed per address"
        );

        // Send payment token to wallet
        payable(wallet).transfer(valueAmount);

        emit ValidAmount(
            valueAmount,
            paymentAmountInUsd,
            tokenAmount,
            getPaymentTokenPriceFeed(defaultTokenAddress)
        );

        // Update the total amount raised in USD.
        totalAmountRaisedInUSD += paymentAmountInUsd;
        tokensSold += tokenAmount;
        saleStages[currentStage].sold += tokenAmount;
        tokensPurchasedByAddress[msg.sender] += tokenAmount;

        _distributeTokens(msg.sender, tokenAmount * 1e18);
        _checkAndAdvanceStage();

        emit TokensPurchased(
            msg.sender,
            paymentAmountInUsd,
            tokenAmount * 1e18
        );
    }

    // Buy tokens using a Payment Token
    function buyTokenWithPaymentToken(
        address _paymentTokenAddress,
        uint256 _paymentAmount
    ) external onlyWhileOpen onlyBeforeFinalized whenNotPaused nonReentrant {
        require(
            _paymentTokenAddress != address(0),
            "You need to provide a valid payment token address"
        );
        require(
            allowedPaymentToken[_paymentTokenAddress].isActive == true &&
                allowedPaymentToken[_paymentTokenAddress].priceFeedAddress !=
                address(0),
            "Token not Allowed or Invalid Price Feed Address"
        );
        require(_paymentAmount > 0, "Must send a positive amount");
        require(
            saleStages[currentStage].rate > 0,
            "We don't have a valid stage for purchase"
        );

        uint256 paymentAmountInUsd = getPaymentTokenPriceFeed(
            _paymentTokenAddress
        ) * _paymentAmount;
        uint256 tokenAmount = _calculateTokens(
            paymentAmountInUsd,
            saleStages[currentStage].rate
        );

        // Ensure the contract has enough tokens to distribute.
        require(
            hasEnoughTokens(tokenAmount),
            "We don't have enough token for your purchase"
        );
        require(
            tokensPurchasedByAddress[msg.sender] + tokenAmount <=
                maxPurchaseLimit,
            "You can't purchase more than max token allowed per address"
        );

        // Send payment token to wallet
        _processTokenPayment(
            msg.sender,
            _paymentTokenAddress,
            _paymentAmount * 1e18
        );

        // Update the total amount raised in USD.
        totalAmountRaisedInUSD += paymentAmountInUsd;
        tokensSold += tokenAmount;
        saleStages[currentStage].sold += tokenAmount;
        tokensPurchasedByAddress[msg.sender] += tokenAmount;

        _distributeTokens(msg.sender, tokenAmount * 1e18);
        _checkAndAdvanceStage();

        emit TokensPurchased(
            msg.sender,
            paymentAmountInUsd,
            tokenAmount * 1e18
        );
    }

    // Check if we have Enough Token
    function hasEnoughTokens(uint256 _tokenAmount) private view returns (bool) {
        return token.balanceOf(address(this)) >= _tokenAmount * 1e18;
    }

    // Calculate the number of tokens a buyer will receive
    function _calculateTokens(
        uint256 _paymentAmount,
        uint256 _rate
    ) internal pure returns (uint256) {
        return _paymentAmount * _rate;
    }

    // Process the payment by transferring payment tokens to the wallet
    function _processTokenPayment(
        address _buyer,
        address _paymentToken,
        uint256 _amount
    ) private {
        IERC20(_paymentToken).safeTransferFrom(_buyer, wallet, _amount);
    }

    // Transfer purchased tokens to the buyer
    function _distributeTokens(address _buyer, uint256 _tokenAmount) private {
        token.safeTransfer(_buyer, _tokenAmount);
    }

    // Check if the current stage has reached its cap and move to the next stage if necessary
    function _checkAndAdvanceStage() private {
        if (
            saleStages[currentStage].sold >= saleStages[currentStage].cap &&
            saleStages.length > currentStage + 1
        ) {
            currentStage++;
        } else if (
            saleStages[currentStage].sold >= saleStages[currentStage].cap &&
            saleStages.length <= currentStage + 1
        ) {
            isFinalized = true;
            emit CrowdsaleFinalized();
        }
    }

    // Withdraw funds
    function withdrawFunds() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        payable(wallet).transfer(balance);
    }

    // Withdraw mistakenly sent tokens
    function withdrawTokens(address _tokenAddress) external onlyOwner {
        IERC20 paymentToken = IERC20(_tokenAddress);
        uint256 balance = paymentToken.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        paymentToken.safeTransfer(wallet, balance);
        emit FundsWithdrawn(balance);
    }

    // Pause the sale
    function pauseSale() external onlyOwner {
        _pause();
    }

    // Resume the sale
    function unpauseSale() external onlyOwner {
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

    // Update max Purchase Limit per address
    function updateMaxPurchaseLimit(
        uint _limit
    ) external onlyOwner onlyBeforeFinalized {
        maxPurchaseLimit = _limit;
    }

    // Move to the Next Stage Manually
    function advanceToNextStage()
        external
        onlyOwner
        onlyWhileOpen
        onlyBeforeFinalized
    {
        require(
            saleStages.length > currentStage + 1,
            "You already in the final stage"
        );

        currentStage++;
    }
}
