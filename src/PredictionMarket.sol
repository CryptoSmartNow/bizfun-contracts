// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";

contract PredictionMarket {
    enum MarketState { OPEN, CLOSED, RESOLVED }

    // ---------------- EVENTS ----------------

    event SharesBought(address indexed user, bool indexed isYes, uint shares, uint cost);
    event SharesSold(address indexed user, bool indexed isYes, uint shares, uint refund);
    event MarketClosed();
    event MarketResolved(uint8 outcome);
    event Redeemed(address indexed user, uint payout);

    // ---------------- STATE ----------------

    IERC20 public immutable collateralToken; // USDC
    address public immutable oracle;
    address public immutable creator;
    uint public immutable tradingDeadline;
    uint public immutable resolveTime;
    uint public immutable b; // liquidity parameter (scaled)

    MarketState public marketState;
    uint8 public resolvedOutcome; // 1 = YES, 2 = NO

    uint public yesShares;
    uint public noShares;

    mapping(address => uint) public userYes;
    mapping(address => uint) public userNo;

    uint private constant ONE = 1e18; // fixed point scale

    constructor(
        address _collateral,
        address _oracle,
        address _creator,
        uint _tradingDeadline,
        uint _resolveTime,
        uint _b
    ) {
        collateralToken = IERC20(_collateral);
        oracle = _oracle;
        creator = _creator;
        tradingDeadline = _tradingDeadline;
        resolveTime = _resolveTime;
        b = _b;
        marketState = MarketState.OPEN;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    modifier onlyOpen() {
        require(marketState == MarketState.OPEN, "Market not open");
        require(block.timestamp < tradingDeadline, "Trading ended");
        _;
    }

    // ---------------- LMSR MATH ----------------

    function _exp(int x) internal pure returns (uint) {
        // Very rough approximation for demo purposes
        // Production systems use better libraries
        if (x < -41e18) return 0;
        uint sum = ONE;
        uint term = ONE;
        for (uint i = 1; i < 20; i++) {
            term = (term * uint(x < 0 ? -x : x)) / (ONE * i);
            sum += term;
        }
        return sum;
    }

    function _cost(uint qYes, uint qNo) internal view returns (uint) {
        uint expYes = _exp(int(qYes * ONE / b));
        uint expNo  = _exp(int(qNo * ONE / b));
        return (b * _ln(expYes + expNo)) / ONE;
    }

    function _ln(uint x) internal pure returns (uint) {
        // Simplified natural log approximation
        uint result = 0;
        while (x >= 2 * ONE) {
            x /= 2;
            result += 693147180559945309; // ln(2)
        }
        return result;
    }

    /// @notice Returns the current cost to buy `amountShares` of YES shares.
    function quoteBuyYes(uint amountShares) external view returns (uint) {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares + amountShares, noShares);
        return costAfter - costBefore;
    }

    /// @notice Returns the current cost to buy `amountShares` of NO shares.
    function quoteBuyNo(uint amountShares) external view returns (uint) {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares + amountShares);
        return costAfter - costBefore;
    }

    // ---------------- TRADING ----------------

    function buyYes(uint amountShares) external onlyOpen {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares + amountShares, noShares);
        uint payment = costAfter - costBefore;

        yesShares += amountShares;
        userYes[msg.sender] += amountShares;

        require(collateralToken.transferFrom(msg.sender, address(this), payment), "Transfer failed");

        emit SharesBought(msg.sender, true, amountShares, payment);
    }

    function buyNo(uint amountShares) external onlyOpen {
        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares + amountShares);
        uint payment = costAfter - costBefore;

        noShares += amountShares;
        userNo[msg.sender] += amountShares;

        require(collateralToken.transferFrom(msg.sender, address(this), payment), "Transfer failed");

        emit SharesBought(msg.sender, false, amountShares, payment);
    }

    function sellYes(uint amountShares) external onlyOpen {
        require(userYes[msg.sender] >= amountShares, "Not enough YES");

        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares - amountShares, noShares);
        uint refund = costBefore - costAfter;

        yesShares -= amountShares;
        userYes[msg.sender] -= amountShares;

        require(collateralToken.transfer(msg.sender, refund), "Refund failed");

        emit SharesSold(msg.sender, true, amountShares, refund);
    }

    function sellNo(uint amountShares) external onlyOpen {
        require(userNo[msg.sender] >= amountShares, "Not enough NO");

        uint costBefore = _cost(yesShares, noShares);
        uint costAfter  = _cost(yesShares, noShares - amountShares);
        uint refund = costBefore - costAfter;

        noShares -= amountShares;
        userNo[msg.sender] -= amountShares;

        require(collateralToken.transfer(msg.sender, refund), "Refund failed");

        emit SharesSold(msg.sender, false, amountShares, refund);
    }

    // ---------------- LIFECYCLE ----------------

    function closeMarket() external {
        require(block.timestamp >= tradingDeadline, "Too early");
        require(marketState == MarketState.OPEN, "Already closed");
        marketState = MarketState.CLOSED;

        emit MarketClosed();
    }

    function resolve(uint8 outcome) external onlyOracle {
        require(block.timestamp >= resolveTime, "Too early");
        require(marketState != MarketState.RESOLVED, "Already resolved");
        require(outcome == 1 || outcome == 2, "Invalid outcome");

        resolvedOutcome = outcome;
        marketState = MarketState.RESOLVED;

        emit MarketResolved(outcome);
    }

    // ---------------- REDEMPTION ----------------

    function redeem() external {
        require(marketState == MarketState.RESOLVED, "Not resolved");

        uint payout;
        if (resolvedOutcome == 1) {
            payout = userYes[msg.sender];
            userYes[msg.sender] = 0;
        } else {
            payout = userNo[msg.sender];
            userNo[msg.sender] = 0;
        }

        require(payout > 0, "Nothing to redeem");
        require(collateralToken.transfer(msg.sender, payout), "Transfer failed");

        emit Redeemed(msg.sender, payout);
    }
}
