// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ISupraOraclePull {
    struct PriceData {
        uint256[] pairs;
        uint256[] prices;
        uint256[] decimals;
    }
    function verifyOracleProof(bytes calldata proof) external returns (PriceData memory);
}

interface IBrokexVault {
    function depositMargin(address trader, uint256 amount) external;
    function settleMargin(address trader, uint256 openMargin, uint256 closeMargin) external;
}

interface IBrokexStorage {

    function updatePositionTarget(
        uint256 positionId,
        uint8 targetType,
        uint256 newBucketId,
        uint256 newTargetPrice
    ) external;


    struct Open {
        address trader;
        uint256 id;
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 openPrice;
        uint256 sizeUsd;
        uint256 timestamp;
        uint256 slBucketId;
        uint256 tpBucketId;
        uint256 liqBucketId;
        uint256 stopLossPrice;      // prix du stop-loss
        uint256 takeProfitPrice;    // prix du take-profit
        uint256 liquidationPrice;   // prix de liquidation
    }

    struct Order {
        address trader;
        uint256 id;
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 orderPrice;
        uint256 sizeUsd;
        uint256 timestamp;
        uint256 stopLoss;
        uint256 takeProfit;
        uint256 limitBucketId;
    }

    struct Closed {
        uint256 assetIndex;
        bool    isLong;
        uint256 leverage;
        uint256 openPrice;
        uint256 closePrice;
        uint256 sizeUsd;
        uint256 openTimestamp;
        uint256 closeTimestamp;
        int256  pnl;
    }

    struct BucketEntry {
        uint256 id;
        uint256 targetPrice;
    }

    function storeOpen(
        address trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 openPrice,
        uint256 sizeUsd,
        uint256 slBucketId,
        uint256 tpBucketId,
        uint256 liqBucketId,
        uint256 stopLossPrice,
        uint256 takeProfitPrice,
        uint256 liquidationPrice
    ) external returns (uint256 openId);

    function storeOrder(
        address trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 orderPrice,
        uint256 sizeUsd,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 limitBucketId
    ) external returns (uint256 orderId);

    function removeOrder(address trader, uint256 orderId) external;

    function removeOpen(address trader, uint256 openId) external;

    function removeFromBucket(
        uint8 bucketType,
        uint256 assetIndex,
        uint256 bucketId,
        uint256 id
    ) external;

    function addToBucket(
        uint8 bucketType,
        uint256 assetIndex,
        uint256 bucketId,
        uint256 id,
        uint256 targetPrice
    ) external;

    function storeClosed(
        address trader,
        uint256 assetIndex,
        bool isLong,
        uint256 leverage,
        uint256 openPrice,
        uint256 closePrice,
        uint256 sizeUsd,
        uint256 openTimestamp,
        uint256 closeTimestamp,
        int256 pnl
    ) external;

    function getOpenById(uint256 id) external view returns (IBrokexStorage.Open memory);

    function getOrderById(uint256 id) external view returns (Order memory);

    function getBucket(
        uint8 bucketType,
        uint256 assetIndex,
        uint256 bucketId
    ) external view returns (BucketEntry[] memory);
    function getUserOpenIds(address user) external view returns (uint256[] memory);
    function getUserOrderIds(address user) external view returns (uint256[] memory);
    function getUserCloseds(address user) external view returns (Closed[] memory);

    
}

contract BrokexCore is Ownable {
    IERC20 public usdt;
    ISupraOraclePull public supraOracle;
    IBrokexVault public brokexVault;
    IBrokexStorage public brokexStorage;

    address public executor;
    address public feeReceiver;

    uint256 public priceTolerance = 10; // 0.1% = 10 / 10000

    struct AssetInfo {
        uint256 bucketSize;
        uint8 assetType;
    }

    mapping(uint256 => AssetInfo) public _assets;
    mapping(uint256 => bool) public _isAssetListed;
    mapping(uint8 => bool) public marketOpen;
    mapping(uint256 => uint256) public fundingRatePerAsset;
    mapping(uint256 => uint256) public spreadPerAsset;

    modifier onlyExecutor() {
        require(msg.sender == executor, "Only executor");
        _;
    }

    constructor(
        address _usdt,
        address _supraOracle,
        address _vault,
        address _storage,
        address _executor,
        address _feeReceiver
    ) Ownable(msg.sender) {
        usdt = IERC20(_usdt);
        supraOracle = ISupraOraclePull(_supraOracle);
        brokexVault = IBrokexVault(_vault);
        brokexStorage = IBrokexStorage(_storage);
        executor = _executor;
        feeReceiver = _feeReceiver;
        for (uint8 i = 0; i < 4; i++) marketOpen[i] = true;
    }

    function setVault(address v) external onlyOwner { brokexVault = IBrokexVault(v); }
    function setStorage(address s) external onlyOwner { brokexStorage = IBrokexStorage(s); }
    function setOracle(address o) external onlyOwner { supraOracle = ISupraOraclePull(o); }
    function setExecutor(address e) external onlyOwner { executor = e; }
    function setTolerance(uint256 _tol) external onlyExecutor { require(_tol <= 100, "Max 1%"); priceTolerance = _tol; }

    function listAsset(uint256 idx, uint256 bsize, uint8 atype) external onlyExecutor {
        require(!_isAssetListed[idx], "Listed");
        require(atype <= 3, "Type");
        _isAssetListed[idx] = true;
        _assets[idx] = AssetInfo(bsize, atype);
    }

    function openPosition(
        uint256 idx,
        bytes calldata proof,
        bool isLong,
        uint256 lev,
        uint256 sizeUsd,
        uint256 slPrice,
        uint256 tpPrice
    ) external returns (uint256 openId) {
        require(_isAssetListed[idx], "Not listed");
        AssetInfo memory asset = _assets[idx];
        require(marketOpen[asset.assetType], "Market closed");
        require(lev >= 1 && lev <= 100, "Invalid leverage");
        require(sizeUsd >= 10e6, "Min size");

        brokexVault.depositMargin(msg.sender, sizeUsd);
        ISupraOraclePull.PriceData memory pd = supraOracle.verifyOracleProof(proof);

        uint256 price;
        for (uint i = 0; i < pd.pairs.length; i++) {
            if (pd.pairs[i] == idx) {
                price = pd.prices[i];
                break;
            }
        }
        require(price > 0, "Price not found");

        uint256 liqP = isLong ? (price * lev) / (lev + 1) : (price * (lev + 1)) / lev;

        if (slPrice > 0) {
            if (isLong) require(slPrice >= liqP && slPrice <= price, "Invalid SL");
            else require(slPrice <= liqP && slPrice >= price, "Invalid SL");
        }

        if (tpPrice > 0) {
            if (isLong) require(tpPrice > price, "Invalid TP");
            else require(tpPrice < price, "Invalid TP");
        }

        uint256 slId = slPrice > 0 ? slPrice / asset.bucketSize : 0;
        uint256 tpId = tpPrice > 0 ? tpPrice / asset.bucketSize : 0;
        uint256 liqId = liqP / asset.bucketSize;

        openId = brokexStorage.storeOpen(
            msg.sender,
            idx,
            isLong,
            lev,
            price,
            sizeUsd,
            slId,
            tpId,
            liqId,
            slPrice,
            tpPrice,
            liqP
        );

        if (slPrice > 0) brokexStorage.addToBucket(0, idx, slId, openId, slPrice);
        if (tpPrice > 0) brokexStorage.addToBucket(0, idx, tpId, openId, tpPrice);
        brokexStorage.addToBucket(2, idx, liqId, openId, liqP);
    }



    function closePosition(uint256 openId, bytes calldata proof) external {
        IBrokexStorage.Open memory op = brokexStorage.getOpenById(openId);
        require(op.id == openId, "Invalid");
        require(op.sizeUsd > 0, "Closed");
        require(op.trader == msg.sender, "Not position owner");

        ISupraOraclePull.PriceData memory pd = supraOracle.verifyOracleProof(proof);
        uint256 closePrice = 0;
        for (uint i = 0; i < pd.pairs.length; i++) {
            if (pd.pairs[i] == op.assetIndex) {
                closePrice = pd.prices[i];
                break;
            }
        }
        require(closePrice > 0, "PX");

        int256 priceDiff = int256(closePrice) - int256(op.openPrice);
        int256 pnl = priceDiff * int256(op.sizeUsd) * int256(op.leverage) / int256(op.openPrice);

        uint256 closeMargin = pnl >= 0
            ? op.sizeUsd + uint256(pnl)
            : op.sizeUsd - uint256(-pnl);

        brokexVault.settleMargin(msg.sender, op.sizeUsd, closeMargin);

        brokexStorage.removeOpen(msg.sender, openId);
        if (op.slBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.slBucketId, openId);
        if (op.tpBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.tpBucketId, openId);
        brokexStorage.removeFromBucket(2, op.assetIndex, op.liqBucketId, openId);

        brokexStorage.storeClosed(
            msg.sender,
            op.assetIndex,
            op.isLong,
            op.leverage,
            op.openPrice,
            closePrice,
            op.sizeUsd,
            op.timestamp,
            block.timestamp,
            pnl
        );
    }



    function placeOrder(
    uint256 idx,
    bool isLong,
    uint256 lev,
    uint256 orderPrice,
    uint256 sizeUsd,
    uint256 sl,
    uint256 tp
) external returns (uint256 orderId) {
    require(_isAssetListed[idx], "Not listed");
    AssetInfo memory asset = _assets[idx];
    require(lev >= 1 && lev <= 100, "Invalid leverage");
    require(sizeUsd >= 10e6, "Min size");

    if (sl > 0 && tp > 0) {
        if (isLong) {
            require(sl < orderPrice && tp > orderPrice, "SL/TP range invalid for long");
        } else {
            require(sl > orderPrice && tp < orderPrice, "SL/TP range invalid for short");
        }
    }

    brokexVault.depositMargin(msg.sender, sizeUsd);
    uint256 bucketId = orderPrice / asset.bucketSize;

    orderId = brokexStorage.storeOrder(
        msg.sender,
        idx,
        isLong,
        lev,
        orderPrice,
        sizeUsd,
        sl,
        tp,
        bucketId
    );

    brokexStorage.addToBucket(1, idx, bucketId, orderId, orderPrice);
}

    function cancelOrder(uint256 orderId) external {
        IBrokexStorage.Order memory o = brokexStorage.getOrderById(orderId);
        require(o.sizeUsd > 0, "Order doesn't exist");

        // Seul le créateur de l'ordre peut annuler
        require(msg.sender == tx.origin, "Not your order");

        // Rembourse la marge complète
        brokexVault.settleMargin(msg.sender, o.sizeUsd, o.sizeUsd);

        // Supprime du bucket
        brokexStorage.removeFromBucket(1, o.assetIndex, o.limitBucketId, orderId);

        // Supprime l'ordre
        brokexStorage.removeOrder(msg.sender, orderId);
    }
    function updatePositionTargetUser(
        uint256 positionId,
        uint8 targetType, // 0 = SL, 1 = TP
        uint256 newTargetPrice
    ) external {
        IBrokexStorage.Open memory pos = brokexStorage.getOpenById(positionId);
        require(pos.id == positionId, "Invalid position");
        require(tx.origin == msg.sender, "Only EOA");

        AssetInfo memory asset = _assets[pos.assetIndex];
        uint256 newBucketId = newTargetPrice / asset.bucketSize;

        if (targetType == 0) {
            // Stop Loss
            require(
                newTargetPrice < pos.openPrice,
                "SL must be below open price (long)"
            );
            if (pos.isLong) {
                require(
                    newBucketId > pos.liqBucketId,
                    "SL bucket must be above liquidation"
                );
            } else {
                // SHORT
                require(
                    newTargetPrice > pos.openPrice,
                    "SL must be above open price (short)"
                );
                require(
                    newBucketId < pos.liqBucketId,
                    "SL bucket must be below liquidation"
                );
            }
        } else if (targetType == 1) {
            // Take Profit
            if (pos.isLong) {
                require(
                    newTargetPrice > pos.openPrice,
                    "TP must be above open price (long)"
                );
            } else {
                require(
                    newTargetPrice < pos.openPrice,
                    "TP must be below open price (short)"
                );
            }
        } else {
            revert("Invalid target type");
        }

        brokexStorage.updatePositionTarget(positionId, targetType, newBucketId, newTargetPrice);
    }

    function closeAllOnTargets(bytes calldata proof) external onlyExecutor {
        ISupraOraclePull.PriceData memory pd = supraOracle.verifyOracleProof(proof);

        for (uint i = 0; i < pd.pairs.length; i++) {
            uint256 idx = pd.pairs[i];
            uint256 price = pd.prices[i];
            AssetInfo memory asset = _assets[idx];
            uint256 bId = price / asset.bucketSize;

            for (int j = -1; j <= 1; j++) {
                uint256 targetB = uint256(int256(bId) + j);
                IBrokexStorage.BucketEntry[] memory entries = brokexStorage.getBucket(0, idx, targetB);

                for (uint k = 0; k < entries.length; k++) {
                    IBrokexStorage.Open memory op = brokexStorage.getOpenById(entries[k].id);
                    uint256 diff = price > entries[k].targetPrice ? price - entries[k].targetPrice : entries[k].targetPrice - price;
                    if (diff * 10000 <= price * priceTolerance) {
                        _finalizePosition(op, price);
                    }
                }
            }
        }
    }
    function liquidatePositions(bytes calldata proof) external onlyExecutor {
        ISupraOraclePull.PriceData memory pd = supraOracle.verifyOracleProof(proof);

        for (uint i = 0; i < pd.pairs.length; i++) {
            uint256 idx = pd.pairs[i];
            uint256 price = pd.prices[i];
            AssetInfo memory asset = _assets[idx];
            uint256 bId = price / asset.bucketSize;

            for (int j = -1; j <= 1; j++) {
                uint256 targetB = uint256(int256(bId) + j);
                IBrokexStorage.BucketEntry[] memory entries = brokexStorage.getBucket(2, idx, targetB);

                for (uint k = 0; k < entries.length; k++) {
                    IBrokexStorage.Open memory op = brokexStorage.getOpenById(entries[k].id);
                    uint256 diff = price > entries[k].targetPrice ? price - entries[k].targetPrice : entries[k].targetPrice - price;
                    if (diff * 10000 <= price * priceTolerance) {
                        _finalizePositionLiquidation(op, price);
                    }
                }
            }
        }
    }
    function _finalizePosition(IBrokexStorage.Open memory op, uint256 closePrice) internal {
        int256 pnl = op.isLong
            ? int256((closePrice - op.openPrice) * op.sizeUsd * op.leverage / op.openPrice)
            : int256((op.openPrice - closePrice) * op.sizeUsd * op.leverage / op.openPrice);

        uint256 openM = op.sizeUsd;
        uint256 closeM = pnl >= 0 ? openM + uint256(pnl) : openM - uint256(-pnl);

        brokexVault.settleMargin(tx.origin, openM, closeM);
        brokexStorage.removeOpen(tx.origin, op.id);

        if (op.slBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.slBucketId, op.id);
        if (op.tpBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.tpBucketId, op.id);
        brokexStorage.removeFromBucket(2, op.assetIndex, op.liqBucketId, op.id);

        brokexStorage.storeClosed(
            tx.origin,
            op.assetIndex,
            op.isLong,
            op.leverage,
            op.openPrice,
            closePrice,
            op.sizeUsd,
            op.timestamp,
            block.timestamp,
            pnl
        );
    }

    function _finalizePositionLiquidation(IBrokexStorage.Open memory op, uint256 closePrice) internal {
        brokexVault.settleMargin(tx.origin, op.sizeUsd, 0);
        brokexStorage.removeOpen(tx.origin, op.id);

        if (op.slBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.slBucketId, op.id);
        if (op.tpBucketId > 0) brokexStorage.removeFromBucket(0, op.assetIndex, op.tpBucketId, op.id);
        brokexStorage.removeFromBucket(2, op.assetIndex, op.liqBucketId, op.id);

        brokexStorage.storeClosed(
            tx.origin,
            op.assetIndex,
            op.isLong,
            op.leverage,
            op.openPrice,
            closePrice,
            op.sizeUsd,
            op.timestamp,
            block.timestamp,
            -int256(op.sizeUsd)
        );
    }

    // Fonction pour définir le funding rate
    function setFundingRate(uint256 assetIndex, uint256 rate) external onlyExecutor {
        require(_isAssetListed[assetIndex], "Not listed");
        require(rate <= 1000, "Max 10%");
        fundingRatePerAsset[assetIndex] = rate;
    }

    // Fonction pour récupérer le funding rate
    function getFundingRate(uint256 assetIndex) external view returns (uint256) {
        return fundingRatePerAsset[assetIndex];
    }
    // Fonction pour définir le spread
function setSpread(uint256 assetIndex, uint256 spread) external onlyExecutor {
    require(_isAssetListed[assetIndex], "Not listed");
    require(spread <= 1000, "Too high"); // 10%
    spreadPerAsset[assetIndex] = spread;
}

// Fonction pour récupérer le spread d’un actif
function getSpread(uint256 assetIndex) external view returns (uint256) {
    return spreadPerAsset[assetIndex];
}

// Fonction pour récupérer tous les spreads en une fois
function getAllSpreads(uint256[] calldata assetIndexes) external view returns (uint256[] memory) {
    uint256[] memory spreads = new uint256[](assetIndexes.length);
    for (uint i = 0; i < assetIndexes.length; i++) {
        spreads[i] = spreadPerAsset[assetIndexes[i]];
    }
    return spreads;
}

function getOpenById(uint256 id) external view returns (IBrokexStorage.Open memory) {
    return brokexStorage.getOpenById(id);
}

function getOrderById(uint256 id) external view returns (IBrokexStorage.Order memory) {
    return brokexStorage.getOrderById(id);
}

function getUserOpenIds(address user) external view returns (uint256[] memory) {
    return brokexStorage.getUserOpenIds(user);
}

function getUserOrderIds(address user) external view returns (uint256[] memory) {
    return brokexStorage.getUserOrderIds(user);
}

function getUserCloseds(address user) external view returns (IBrokexStorage.Closed[] memory) {
    return brokexStorage.getUserCloseds(user);
}


function executeOrders(bytes calldata proof) external onlyExecutor {
    ISupraOraclePull.PriceData memory pd = supraOracle.verifyOracleProof(proof);

    for (uint i = 0; i < pd.pairs.length; i++) {
        uint256 idx = pd.pairs[i];
        uint256 price = pd.prices[i];
        AssetInfo memory asset = _assets[idx];
        uint256 bId = price / asset.bucketSize;

        for (int j = -1; j <= 1; j++) {
            uint256 targetB = uint256(int256(bId) + j);
            IBrokexStorage.BucketEntry[] memory ents = brokexStorage.getBucket(1, idx, targetB);

            for (uint k = 0; k < ents.length; k++) {
                IBrokexStorage.Order memory o = brokexStorage.getOrderById(ents[k].id);
                if (o.sizeUsd == 0) continue;

                uint256 diff = price > o.orderPrice ? price - o.orderPrice : o.orderPrice - price;
                if (diff * 10000 <= price * priceTolerance) {
                    uint256 liqP = o.isLong
                        ? (o.orderPrice * o.leverage) / (o.leverage + 1)
                        : (o.orderPrice * (o.leverage + 1)) / o.leverage;

                    uint256 slId = o.stopLoss > 0 ? o.stopLoss / asset.bucketSize : 0;
                    uint256 tpId = o.takeProfit > 0 ? o.takeProfit / asset.bucketSize : 0;
                    uint256 liqId = liqP / asset.bucketSize;

                    uint256 openId = brokexStorage.storeOpen(
                        o.trader,
                        o.assetIndex,
                        o.isLong,
                        o.leverage,
                        o.orderPrice,
                        o.sizeUsd,
                        slId,
                        tpId,
                        liqId,
                        o.stopLoss,
                        o.takeProfit,
                        liqP
                    );

                    if (o.stopLoss > 0)
                        brokexStorage.addToBucket(0, o.assetIndex, slId, openId, o.stopLoss);
                    if (o.takeProfit > 0)
                        brokexStorage.addToBucket(0, o.assetIndex, tpId, openId, o.takeProfit);
                    brokexStorage.addToBucket(2, o.assetIndex, liqId, openId, liqP);

                    brokexStorage.removeOrder(o.trader, o.id);
                    brokexStorage.removeFromBucket(1, o.assetIndex, o.limitBucketId, o.id);
                }
            }
        }
    }
}







}


