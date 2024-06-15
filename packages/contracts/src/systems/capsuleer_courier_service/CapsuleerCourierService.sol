// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import { console } from "forge-std/console.sol";
import { ResourceId } from "@latticexyz/world/src/WorldResourceId.sol";
import { ResourceIds } from "@latticexyz/store/src/codegen/tables/ResourceIds.sol";
import { System } from "@latticexyz/world/src/System.sol";
import { IBaseWorld } from "@latticexyz/world/src/codegen/interfaces/IBaseWorld.sol";
import { WorldResourceIdLib } from "@latticexyz/world/src/WorldResourceId.sol";

import { IERC721 } from "@eveworld/world/src/modules/eve-erc721-puppet/IERC721.sol";
import { InventoryLib } from "@eveworld/world/src/modules/inventory/InventoryLib.sol";
import { InventoryItem } from "@eveworld/world/src/modules/inventory/types.sol";
import { IInventoryErrors } from "@eveworld/world/src/modules/inventory/IInventoryErrors.sol";

import { EntityRecordTable, EntityRecordTableData } from "@eveworld/world/src/codegen/tables/EntityRecordTable.sol";

import { DeployableTokenTable } from "@eveworld/world/src/codegen/tables/DeployableTokenTable.sol";

import { Utils as EntityRecordUtils } from "@eveworld/world/src/modules/entity-record/Utils.sol";
import { Utils as InventoryUtils } from "@eveworld/world/src/modules/inventory/Utils.sol";
import { Utils as SmartDeployableUtils } from "@eveworld/world/src/modules/smart-deployable/Utils.sol";
import "@eveworld/common-constants/src/constants.sol";

import { Deliveries, DeliveriesData } from "../../codegen/tables/Deliveries.sol";
import { ItemLikes } from "../../codegen/tables/ItemLikes.sol";
import { PlayerLikes } from "../../codegen/tables/PlayerLikes.sol";

import { AccessControlLib } from "@latticexyz/world-modules/src/utils/AccessControlLib.sol";
import { SystemRegistry } from "@latticexyz/world/src/codegen/tables/SystemRegistry.sol";

import "@openzeppelin/contracts/utils/Strings.sol";


contract CapsuleerCourierService is System {
  using InventoryLib for InventoryLib.World;
  using EntityRecordUtils for bytes14;
  using InventoryUtils for bytes14;
  using SmartDeployableUtils for bytes14;

  // TESTED
  function getItemId(uint256 typeId) public pure returns (uint256) {
    string memory packed = string(abi.encodePacked("item:devnet-", Strings.toString(typeId)));
    return uint256(keccak256(abi.encodePacked(packed)));
  }

  function setLikes(uint256 typeId, uint256 amount) public {
    _requireOwner();
    console.log("Setting likes for item:", typeId, " amount:", amount);
    uint256 itemId = getItemId(typeId);
    ItemLikes.set(itemId, amount);
  }

  // TESTED
  function addPlayerLikes(address playerAddress, uint256 amount) internal {
    console.log("Adding likes to player:", playerAddress, " amount:", amount);
    uint256 existingLikes = PlayerLikes.get(playerAddress);
    console.log("fetched existing likes");
    PlayerLikes.set(playerAddress, existingLikes + amount);
  }

  function createDeliveryRequest(
    uint256 smartObjectId,
    uint256 typeId,
    uint256 itemQuantity
  ) public {
    require(itemQuantity > 0, "quantity cannot be 0");
    require(itemQuantity <= 500, "quantity cannot be more than 500");

    uint256 itemId = getItemId(typeId);

    EntityRecordTableData memory itemEntity = EntityRecordTable.get(
      FRONTIER_WORLD_DEPLOYMENT_NAMESPACE.entityRecordTableId(),
      itemId
    );
    if (itemEntity.recordExists == false) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: item is not created on-chain",
        itemId
      );
    }

    uint256 likes = ItemLikes.get(itemId);
    if (likes == 0) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: item type does not have likes associated",
        itemId
      );
    }

    // I Considered incremental IDs, but the contract fields get reset every deployment.
    // I could store a counter in a MUD table, but that sounds annoying.
    // a random uint256 should be more than practical without needing any state tracking.
    uint256 deliveryId = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao)));
    // uint256 deliveryId = 1;

    Deliveries.set(
      deliveryId,
      smartObjectId,
      itemId,
      itemQuantity,
      address(0), // sender address is not known until delivery is fulfilled
      _msgSender(), // reciever of the package
      false
    );
  }

  function delivered(
    uint256 deliveryId
  ) public {

    // delivery validation
    DeliveriesData memory delivery = Deliveries.get(deliveryId);
    if (delivery.smartObjectId == 0) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: delivery does not exist",
        delivery.itemId
      );
    }
    if (delivery.smartObjectId == 0) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: item type does not match delivery",
        delivery.itemId
      );
    }

    EntityRecordTableData memory itemEntity = EntityRecordTable.get(
      FRONTIER_WORLD_DEPLOYMENT_NAMESPACE.entityRecordTableId(),
      delivery.itemId
    );
    // TODO assert user is not fulfilling their own delivery
    // I removed this for easier testing on hackathon account
    // if (_msgSender() == delivery.receiver) {
    //   revert IInventoryErrors.Inventory_InvalidItem(
    //     "CCS: cannot fulfill your own delivery you doofus",
    //     itemId
    //   );
    // }

    // move item from ephemeral storage to ssu inventory
    InventoryItem[] memory outItems = new InventoryItem[](1);
    outItems[0] = InventoryItem(
      delivery.itemId, // inventoryItemId
      _msgSender(), // sender
      itemEntity.itemId, // itemId
      itemEntity.typeId, // typeId
      itemEntity.volume, // volume
      delivery.itemQuantity // quantity
    );
    _inventoryLib().ephemeralToInventoryTransfer(delivery.smartObjectId, outItems);


    // Get the number of likes to reward the sender
    uint256 likes = ItemLikes.get(delivery.itemId);
    if (likes == 0) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: item type does not have likes associated",
        delivery.itemId
      );
    }

    addPlayerLikes(_msgSender(), likes * delivery.itemQuantity);

    Deliveries.setDelivered(deliveryId, true);
    Deliveries.setSender(deliveryId, _msgSender());
  }

  function pickup(
    uint256 deliveryId
  ) public {

    DeliveriesData memory delivery = Deliveries.get(deliveryId);
    if (_msgSender() != delivery.receiver) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: you may only pickup your own item",
        deliveryId
      );
    }
    EntityRecordTableData memory itemEntity = EntityRecordTable.get(
      FRONTIER_WORLD_DEPLOYMENT_NAMESPACE.entityRecordTableId(),
      delivery.itemId
    );
    if (itemEntity.recordExists == false) {
      revert IInventoryErrors.Inventory_InvalidItem(
        "CCS: item is not created on-chain",
        delivery.itemId
      );
    }

    address ssuOwner = IERC721(DeployableTokenTable.getErc721Address(FRONTIER_WORLD_DEPLOYMENT_NAMESPACE.deployableTokenTableId())).ownerOf(
      delivery.smartObjectId
    );
    
    // move the output to the requesting user's inventory
    InventoryItem[] memory outItems = new InventoryItem[](1);
    outItems[0] = InventoryItem(
      delivery.itemId, // inventoryItemId
      ssuOwner, // ssu inventory
      itemEntity.itemId, // itemId
      itemEntity.typeId, // typeId
      itemEntity.volume, // volume
      delivery.itemQuantity // quantity
    );
    _inventoryLib().inventoryToEphemeralTransfer(delivery.smartObjectId, outItems);

    Deliveries.deleteRecord(deliveryId);
  }

  function getLikes() public view returns (uint256) {
    return PlayerLikes.get(_msgSender());
  }

  function _inventoryLib() internal view returns (InventoryLib.World memory) {
    if (!ResourceIds.getExists(WorldResourceIdLib.encodeNamespace(FRONTIER_WORLD_DEPLOYMENT_NAMESPACE))) {
      return InventoryLib.World({ iface: IBaseWorld(_world()), namespace: FRONTIER_WORLD_DEPLOYMENT_NAMESPACE });
    } else return InventoryLib.World({ iface: IBaseWorld(_world()), namespace: FRONTIER_WORLD_DEPLOYMENT_NAMESPACE });
  }

  function getContractAddress() public view returns (address) {
    return address(this);
  }

  function _requireOwner() internal view {
    AccessControlLib.requireOwner(SystemRegistry.get(address(this)), _msgSender());
  }
}