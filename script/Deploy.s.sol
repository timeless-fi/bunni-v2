// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {LibString} from "solady/utils/LibString.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CREATE3Script} from "./base/CREATE3Script.sol";

import {BunniHub} from "../src/BunniHub.sol";
import {BunniHook} from "../src/BunniHook.sol";

contract DeployScript is CREATE3Script {
    using LibString for uint256;
    using SafeCastLib for uint256;

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (BunniHub hub, BunniHook hook, bytes32 hookSalt) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address deployer = vm.addr(deployerPrivateKey);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address weth = vm.envAddress(string.concat("WETH_", block.chainid.toString()));
        address permit2 = vm.envAddress("PERMIT2");
        address owner = vm.envAddress(string.concat("OWNER_", block.chainid.toString()));
        address hookFeesRecipient = vm.envAddress(string.concat("HOOK_FEES_RECIPIENT_", block.chainid.toString()));
        uint96 hookFeesModifier = vm.envUint("HOOK_FEES_MODIFIER").toUint96();

        vm.startBroadcast(deployerPrivateKey);

        hub = BunniHub(
            payable(
                create3.deploy(
                    getCreate3ContractSalt("BunniHub"),
                    bytes.concat(type(BunniHub).creationCode, abi.encode(poolManager, weth, permit2))
                )
            )
        );

        /*  unchecked {
            bytes32 hookBaseSalt = getCreate3ContractSalt("BunniHook");
            uint256 hookFlags = Hooks.AFTER_INITIALIZE_FLAG + Hooks.BEFORE_ADD_LIQUIDITY_FLAG + Hooks.BEFORE_SWAP_FLAG
                + Hooks.ACCESS_LOCK_FLAG + Hooks.NO_OP_FLAG;
            for (uint256 offset; offset < 10000; offset++) {
                hookSalt = bytes32(uint256(hookBaseSalt) + offset);
                address hookDeployed = create3.getDeployed(deployer, hookSalt);
                if (uint160((bytes20(hookDeployed) >> 148) << 148) == hookFlags) {
                    break;
                }
            }
        } */
        hookSalt = bytes32(0x94ec71366f7d23b6b928e8224c5c43811da127fc60e69550677a43d22ee9a601);
        hook = BunniHook(
            payable(
                create3.deploy(
                    hookSalt,
                    bytes.concat(
                        type(BunniHook).creationCode,
                        abi.encode(poolManager, hub, owner, hookFeesRecipient, hookFeesModifier)
                    )
                )
            )
        );

        vm.stopBroadcast();
    }
}
