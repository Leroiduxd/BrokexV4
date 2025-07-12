// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BrokexStorage {
    address public owner;
    address public core;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyCore() {
        require(msg.sender == core, "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setCore(address _core) external onlyOwner {
        require(core == address(0), "Core already set");
        core = _core;
    }

    function changeCore(address _newCore) external onlyOwner {
        core = _newCore;
    }

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

    uint256 private nextOpenId  = 1;
    uint256 private nextOrderId = 1;

    mapping(uint256 => Open)      private opens;
    mapping(uint256 => Order)     private orders;
    mapping(address => uint256[]) private userOpenIds;
    mapping(address => uint256[]) private userOrderIds;
    mapping(address => Closed[])  private userCloseds;

    mapping(uint256 => mapping(uint256 => BucketEntry[])) public sltpBuckets;
    mapping(uint256 => mapping(uint256 => BucketEntry[])) public limitBuckets;
    mapping(uint256 => mapping(uint256 => BucketEntry[])) public liquidationBuckets;

    event OpenStored(address indexed user, uint256 indexed openId);
    event OrderStored(address indexed user, uint256 indexed orderId);
    event ClosedStored(address indexed user, uint256 assetIndex, uint256 closeTimestamp, int256 pnl);
    event BucketUpdated(uint8 bucketType, uint256 indexed assetIndex, uint256 indexed bucketId, uint256 id, uint256 targetPrice);
    event OpenRemoved(address indexed user, uint256 indexed openId);
    event OrderRemoved(address indexed user, uint256 indexed orderId);

    function storeOpen(
        address trader,
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 openPrice,
        uint256 sizeUsd,
        uint256 slBucketId,
        uint256 tpBucketId,
        uint256 liqBucketId,
        uint256 stopLossPrice,
        uint256 takeProfitPrice,
        uint256 liquidationPrice
    ) external onlyCore returns (uint256 openId) {
        openId = nextOpenId++;
        opens[openId] = Open(
            trader,
            openId,
            assetIndex,
            isLong,
            leverage,
            openPrice,
            sizeUsd,
            block.timestamp,
            slBucketId,
            tpBucketId,
            liqBucketId,
            stopLossPrice,
            takeProfitPrice,
            liquidationPrice
        );
        userOpenIds[trader].push(openId);
        emit OpenStored(trader, openId);
    }

    function storeOrder(
        address trader,
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 orderPrice,
        uint256 sizeUsd,
        uint256 stopLoss,
        uint256 takeProfit,
        uint256 limitBucketId
    ) external onlyCore returns (uint256 orderId) {
        orderId = nextOrderId++;
        orders[orderId] = Order(
            trader,
            orderId,
            assetIndex,
            isLong,
            leverage,
            orderPrice,
            sizeUsd,
            block.timestamp,
            stopLoss,
            takeProfit,
            limitBucketId
        );
        userOrderIds[trader].push(orderId);
        emit OrderStored(trader, orderId);
    }

    function storeClosed(
        address trader,
        uint256 assetIndex,
        bool    isLong,
        uint256 leverage,
        uint256 openPrice,
        uint256 closePrice,
        uint256 sizeUsd,
        uint256 openTimestamp,
        uint256 closeTimestamp,
        int256  pnl
    ) external onlyCore {
        userCloseds[trader].push(
            Closed(
                assetIndex,
                isLong,
                leverage,
                openPrice,
                closePrice,
                sizeUsd,
                openTimestamp,
                closeTimestamp,
                pnl
            )
        );
        emit ClosedStored(trader, assetIndex, closeTimestamp, pnl);
    }

    function removeOpen(address trader, uint256 openId) external onlyCore {
        uint256[] storage arr = userOpenIds[trader];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == openId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
        delete opens[openId];
        emit OpenRemoved(trader, openId);
    }

    function removeOrder(address trader, uint256 orderId) external onlyCore {
        uint256[] storage arr = userOrderIds[trader];
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == orderId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
        delete orders[orderId];
        emit OrderRemoved(trader, orderId);
    }

    function addToBucket(
        uint8   bucketType,
        uint256 assetIndex,
        uint256 bucketId,
        uint256 id,
        uint256 targetPrice
    ) public onlyCore {
        BucketEntry memory entry = BucketEntry(id, targetPrice);
        if (bucketType == 0) {
            sltpBuckets[assetIndex][bucketId].push(entry);
        } else if (bucketType == 1) {
            limitBuckets[assetIndex][bucketId].push(entry);
        } else if (bucketType == 2) {
            liquidationBuckets[assetIndex][bucketId].push(entry);
        } else {
            revert("Invalid bucket type");
        }
        emit BucketUpdated(bucketType, assetIndex, bucketId, id, targetPrice);
    }

    function removeFromBucket(
        uint8   bucketType,
        uint256 assetIndex,
        uint256 bucketId,
        uint256 id
    ) public onlyCore {
        BucketEntry[] storage arr =
            bucketType == 0 ? sltpBuckets[assetIndex][bucketId] :
            bucketType == 1 ? limitBuckets[assetIndex][bucketId] :
                               liquidationBuckets[assetIndex][bucketId];
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i].id == id) {
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
        emit BucketUpdated(bucketType, assetIndex, bucketId, id, 0);
    }

    /// @notice Met à jour le SL ou TP d’une position ouverte
    /// @param positionId ID de la position à mettre à jour
    /// @param targetType 0 = SL, 1 = TP
    /// @param newBucketId nouveau bucketId
    /// @param newTargetPrice nouveau prix cible
    function updatePositionTarget(
        uint256 positionId,
        uint8   targetType,
        uint256 newBucketId,
        uint256 newTargetPrice
    ) external onlyCore {
        Open storage o = opens[positionId];
        uint256 assetIndex = o.assetIndex;
        uint256 oldBucketId = (targetType == 0) ? o.slBucketId : o.tpBucketId;
        removeFromBucket(0, assetIndex, oldBucketId, positionId);
        addToBucket(0, assetIndex, newBucketId, positionId, newTargetPrice);
        if (targetType == 0) {
            o.slBucketId = newBucketId;
        } else {
            o.tpBucketId = newBucketId;
        }
    }

    function getBucket(
        uint8   bucketType,
        uint256 assetIndex,
        uint256 bucketId
    ) external view returns (BucketEntry[] memory) {
        if (bucketType == 0) {
            return sltpBuckets[assetIndex][bucketId];
        } else if (bucketType == 1) {
            return limitBuckets[assetIndex][bucketId];
        } else if (bucketType == 2) {
            return liquidationBuckets[assetIndex][bucketId];
        }
        revert("Invalid bucket type");
    }

    function getOpenById(uint256 id) external view returns (Open memory) {
        return opens[id];
    }

    function getOrderById(uint256 id) external view returns (Order memory) {
        return orders[id];
    }

    function getUserOpenIds(address user) external view returns (uint256[] memory) {
        return userOpenIds[user];
    }

    function getUserOrderIds(address user) external view returns (uint256[] memory) {
        return userOrderIds[user];
    }

    function getUserCloseds(address user) external view returns (Closed[] memory) {
        return userCloseds[user];
    }
    function getUserClosedIds(address user) external view returns (uint256[] memory) {
        uint256 len = userCloseds[user].length;
        uint256[] memory ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = i;
        }
        return ids;
    }
    function getClosedById(address user, uint256 index) external view returns (Closed memory) {
        require(index < userCloseds[user].length, "Invalid index");
        return userCloseds[user][index];
    }


}
