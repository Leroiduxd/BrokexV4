// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BrokexVault is ERC20, ERC20Burnable, Ownable {
    IERC20 public immutable usdt;   // USDT (6 déc.)
    address public core;            // adresse autorisée à régler les trades

    mapping(address => uint256) public balances;         // marge par trader
    mapping(address => int256) public traderTotalPnl;    // PnL total par trader
    uint256 public totalProfit;                          // bénéfice cumulé du vault
    uint256 public totalMargins;                         // somme des marges actives
    uint256 public totalInvestorDeposits;                // somme nette des dépôts investisseurs

    event DepositMargin(address indexed user, uint256 amount);
    event MarginSettled(
        address indexed trader,
        uint256 openMargin,
        uint256 closeMargin,
        uint256 profit,
        bool traderWon
    );
    event DepositLiquidity(address indexed user, uint256 usdtAmount, uint256 lpMinted);
    event WithdrawLiquidity(address indexed user, uint256 lpBurned, uint256 usdtAmount);
    event CoreUpdated(address indexed oldCore, address indexed newCore);

    modifier onlyCore() {
        require(msg.sender == core, "BrokexVault: caller is not core");
        _;
    }

    /// @param _usdt  Adresse du token USDT (6 déc.)
    /// @param _core  Module Core initial autorisé
    constructor(address _usdt, address _core)
        ERC20("Brokex LP Token", "BXL")
        Ownable(msg.sender)
    {
        require(_usdt != address(0), "Invalid USDT address");
        require(_core != address(0), "Invalid core address");
        usdt = IERC20(_usdt);
        core = _core;
    }

    // ----- OWNER-ONLY -----

    function setCore(address newCore) external onlyOwner {
        require(newCore != address(0), "Invalid core address");
        emit CoreUpdated(core, newCore);
        core = newCore;
    }

    // ----- MARGIN MANAGEMENT -----

    /// @notice Dépose de la marge pour un trade (appelé par Core)
    function depositMargin(address trader, uint256 amount) external {
        require(trader != address(0), "Invalid trader");
        require(amount > 0, "Amount > 0");

        require(usdt.transferFrom(trader, address(this), amount), "Transfer failed");

        balances[trader] += amount;
        totalMargins += amount;

        emit DepositMargin(trader, amount);
    }

    /// ✅ Ajout : version utilisée par ton ancien Core
    function depositMargin(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        require(usdt.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        balances[msg.sender] += amount;
        totalMargins += amount;

        emit DepositMargin(msg.sender, amount);
    }

    function settleMargin(
        address trader,
        uint256 openMargin,
        uint256 closeMargin
    ) external onlyCore {
        require(trader != address(0), "Invalid trader");
        require(balances[trader] >= openMargin, "Insufficient margin");

        balances[trader] -= openMargin;
        totalMargins -= openMargin;

        uint256 profit;
        bool traderWon;

        int256 pnl = int256(closeMargin) - int256(openMargin);
        traderTotalPnl[trader] += pnl;

        if (pnl < 0) {
            profit = uint256(-pnl);
            totalProfit += profit;
            traderWon = false;
        } else {
            profit = 0;
            traderWon = (pnl > 0);
        }

        require(usdt.transfer(trader, closeMargin), "Payout failed");

        emit MarginSettled(trader, openMargin, closeMargin, profit, traderWon);
    }

    // ----- LIQUIDITY (LP TOKEN) -----

    function depositLiquidity(uint256 usdtAmount) external {
        require(usdtAmount > 0, "Amount > 0");
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");

        uint256 lpToMint = usdtAmount * 1e12;
        _mint(msg.sender, lpToMint);

        totalInvestorDeposits += usdtAmount;

        emit DepositLiquidity(msg.sender, usdtAmount, lpToMint);
    }

    function withdrawLiquidity(uint256 lpAmount) external {
        require(lpAmount > 0, "Amount > 0");
        uint256 usdtToReturn = lpAmount / 1e12;

        require(balanceOf(msg.sender) >= lpAmount, "Not enough LP");
        require(usdt.balanceOf(address(this)) >= usdtToReturn, "Vault insufficient");

        _burn(msg.sender, lpAmount);
        require(usdt.transfer(msg.sender, usdtToReturn), "Transfer failed");

        totalInvestorDeposits -= usdtToReturn;

        emit WithdrawLiquidity(msg.sender, lpAmount, usdtToReturn);
    }

    // ----- VIEW FUNCTIONS -----

    function getLpPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        require(supply > 0, "No LP supply");

        uint256 assets = usdt.balanceOf(address(this));
        return (assets * 1e18) / supply;
    }

    function getTraderPnL(address trader) external view returns (int256) {
        return traderTotalPnl[trader];
    }

    function getTotalMargins() external view returns (uint256) {
        return totalMargins;
    }

    function getTotalInvestorDeposits() external view returns (uint256) {
        return totalInvestorDeposits;
    }
}

