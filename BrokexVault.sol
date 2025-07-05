// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BrokexVault is ERC20, ERC20Burnable, Ownable {
    IERC20 public immutable usdt;   // USDT (6 déc.)
    address public core;            // adresse autorisée à régler les trades

    mapping(address => uint256) public balances; // marge par trader
    uint256 public totalProfit;                // bénéfice cumulé du vault

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
        require(_usdt  != address(0), "Invalid USDT address");
        require(_core != address(0), "Invalid core address");
        usdt = IERC20(_usdt);
        core = _core;
    }

    // ----- OWNER-ONLY -----

    /// @notice Change l’adresse du module Core
    /// @param newCore Nouvelle adresse Core
    function setCore(address newCore) external onlyOwner {
        require(newCore != address(0), "Invalid core address");
        emit CoreUpdated(core, newCore);
        core = newCore;
    }

    // ----- MARGIN MANAGEMENT -----

    /// @notice Dépose de la marge pour un trade
    /// @param amount Montant en USDT (6 déc.)
    /// @notice Dépose de la marge pour un trader depuis son wallet
    /// @param trader Adresse du trader qui a fait l'approve
    /// @param amount Montant en USDT à transférer depuis `trader`
    function depositMargin(address trader, uint256 amount) external {
        require(trader != address(0), "Invalid trader");
        require(amount > 0, "Amount > 0");

        // Transfère les fonds depuis le trader (qui a approuvé le Vault)
        require(usdt.transferFrom(trader, address(this), amount), "Transfer failed");

        // Crédite la marge du trader
        balances[trader] += amount;
        emit DepositMargin(trader, amount);
    }


    /// @notice Règle la marge d'un trade (appelé par Core)
    /// @param trader      Adresse du trader
    /// @param openMargin  Marge initiale réservée
    /// @param closeMargin Montant restant après clôture
    function settleMargin(
        address trader,
        uint256 openMargin,
        uint256 closeMargin
    ) external onlyCore {
        require(trader != address(0), "Invalid trader");
        require(balances[trader] >= openMargin, "Insufficient margin");

        balances[trader] -= openMargin;

        uint256 profit;
        bool traderWon;
        if (openMargin > closeMargin) {
            // trader perd => profit pour le vault
            profit = openMargin - closeMargin;
            totalProfit += profit;
            traderWon = false;
        } else {
            // trader gagne ou égalité
            profit = 0;
            traderWon = (closeMargin > openMargin);
        }

        require(usdt.transfer(trader, closeMargin), "Payout failed");

        emit MarginSettled(trader, openMargin, closeMargin, profit, traderWon);
    }

    // ----- LIQUIDITY (LP TOKEN) -----

    /// @notice Dépose des USDT et reçoit des LP tokens (1 LP = 1 USDT)
    /// @param usdtAmount Montant USDT déposé (6 déc.)
    function depositLiquidity(uint256 usdtAmount) external {
        require(usdtAmount > 0, "Amount > 0");
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");
        uint256 lpToMint = usdtAmount * 1e12;  // ajustement 6 → 18 déc.
        _mint(msg.sender, lpToMint);
        emit DepositLiquidity(msg.sender, usdtAmount, lpToMint);
    }

    /// @notice Brûle des LP tokens et retourne des USDT (1 LP = 1 USDT)
    /// @param lpAmount Quantité de LP à brûler (18 déc.)
    function withdrawLiquidity(uint256 lpAmount) external {
        require(lpAmount > 0, "Amount > 0");
        uint256 usdtToReturn = lpAmount / 1e12;
        require(balanceOf(msg.sender) >= lpAmount,   "Not enough LP");
        require(usdt.balanceOf(address(this)) >= usdtToReturn, "Vault insufficient");

        _burn(msg.sender, lpAmount);
        require(usdt.transfer(msg.sender, usdtToReturn), "Transfer failed");
        emit WithdrawLiquidity(msg.sender, lpAmount, usdtToReturn);
    }

    /// @notice Prix courant du LP token en USDT (6 déc.)
    function getLpPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        require(supply > 0, "No LP supply");
        uint256 assets = usdt.balanceOf(address(this));
        return (assets * 1e18) / supply;
    }
}
