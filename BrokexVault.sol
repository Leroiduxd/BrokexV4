// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BrokexVault is ERC20, ERC20Burnable, Ownable {
    IERC20 public immutable usdt;
    address public core;

    mapping(address => uint256) public balances; // marge trader
    mapping(address => int256) public traderTotalPnl;

    uint256 public totalMargins;               // somme des marges traders
    int256 public totalPnLRealized;            // profit net du pool (peut être négatif)

    event DepositMargin(address indexed user, uint256 amount);
    event MarginSettled(address indexed trader, uint256 openMargin, uint256 closeMargin, uint256 profit, bool traderWon);
    event DepositLiquidity(address indexed user, uint256 usdtAmount, uint256 lpMinted);
    event WithdrawLiquidity(address indexed user, uint256 lpBurned, uint256 usdtAmount);
    event CoreUpdated(address indexed oldCore, address indexed newCore);

    modifier onlyCore() {
        require(msg.sender == core, "BrokexVault: caller is not core");
        _;
    }

    constructor(address _usdt, address _core) ERC20("Brokex LP Token", "BXL") Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        require(_core != address(0), "Invalid core address");
        usdt = IERC20(_usdt);
        core = _core;
    }

    function setCore(address newCore) external onlyOwner {
        require(newCore != address(0), "Invalid core address");
        emit CoreUpdated(core, newCore);
        core = newCore;
    }

    // ----- MARGIN -----

    function depositMargin(address trader, uint256 amount) external {
        require(trader != address(0), "Invalid trader");
        require(amount > 0, "Amount > 0");
        require(usdt.transferFrom(trader, address(this), amount), "Transfer failed");
        balances[trader] += amount;
        totalMargins += amount;
        emit DepositMargin(trader, amount);
    }

    function depositMargin(uint256 amount) external {
        require(amount > 0, "Amount > 0");
        require(usdt.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        balances[msg.sender] += amount;
        totalMargins += amount;
        emit DepositMargin(msg.sender, amount);
    }

    function settleMargin(address trader, uint256 openMargin, uint256 closeMargin) external onlyCore {
        require(trader != address(0), "Invalid trader");
        require(balances[trader] >= openMargin, "Insufficient margin");

        balances[trader] -= openMargin;
        totalMargins -= openMargin;

        int256 pnl = int256(closeMargin) - int256(openMargin);
        traderTotalPnl[trader] += pnl;
        totalPnLRealized += pnl;

        require(usdt.transfer(trader, closeMargin), "Payout failed");

        emit MarginSettled(
            trader,
            openMargin,
            closeMargin,
            pnl < 0 ? uint256(-pnl) : 0,
            pnl >= 0
        );
    }

    // ----- LIQUIDITY -----

    function depositLiquidity(uint256 usdtAmount) external {
        require(usdtAmount > 0, "Amount > 0");
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");

        uint256 netAssets = getNetAssets();
        uint256 supply = totalSupply();
        uint256 lpToMint = (supply == 0 || netAssets == 0)
            ? usdtAmount * 1e12
            : (usdtAmount * supply) / netAssets;

        _mint(msg.sender, lpToMint);
        emit DepositLiquidity(msg.sender, usdtAmount, lpToMint);
    }

    function withdrawLiquidity(uint256 lpAmount) external {
        require(lpAmount > 0, "Amount > 0");
        uint256 supply = totalSupply();
        require(balanceOf(msg.sender) >= lpAmount, "Not enough LP");

        uint256 usdtToReturn = (lpAmount * getNetAssets()) / supply;
        require(usdt.balanceOf(address(this)) >= usdtToReturn, "Vault insufficient");

        _burn(msg.sender, lpAmount);
        require(usdt.transfer(msg.sender, usdtToReturn), "Transfer failed");

        emit WithdrawLiquidity(msg.sender, lpAmount, usdtToReturn);
    }

    // ----- VIEW -----

    function getLpPrice() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (getNetAssets() * 1e18) / supply;
    }

    function getTraderPnL(address trader) external view returns (int256) {
        return traderTotalPnl[trader];
    }

    function getTraderMargin(address trader) external view returns (uint256) {
        return balances[trader];
    }

    function getTotalMargins() external view returns (uint256) {
        return totalMargins;
    }

    function getPoolTotalProfit() external view returns (int256) {
        return totalPnLRealized;
    }

    function getNetAssets() public view returns (uint256) {
        return usdt.balanceOf(address(this)) - totalMargins;
    }

    function getInvestorValue() external view returns (uint256) {
        return getNetAssets();
    }
}
