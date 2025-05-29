// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {LibString} from "solady/utils/LibString.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CREATE3Script} from "./base/CREATE3Script.sol";

import {BunniHub} from "../src/BunniHub.sol";
import {BunniZone} from "../src/BunniZone.sol";
import {BunniHook} from "../src/BunniHook.sol";
import {BunniToken} from "../src/BunniToken.sol";

contract DeployNewHookScript is CREATE3Script {
    using LibString for uint256;
    using SafeCastLib for uint256;

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (BunniHook hook, bytes32 hookSalt) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address deployer = vm.addr(deployerPrivateKey);

        address poolManager = vm.envAddress(string.concat("POOL_MANAGER_", block.chainid.toString()));
        address weth = vm.envAddress(string.concat("WETH_", block.chainid.toString()));
        address owner = vm.envAddress("OWNER");
        address hookFeeRecipient = vm.envAddress("HOOK_FEE_RECIPIENT");
        uint32 hookFeeModifier = vm.envUint("HOOK_FEE_MODIFIER").toUint32();
        address floodPlain = vm.envAddress("FLOOD_PLAIN");
        uint48 k = vm.envUint(string.concat("AMAMM_K_", block.chainid.toString())).toUint48();

        BunniHub hub = BunniHub(payable(getCreate3ContractFromEnvSalt("BunniHub")));
        BunniZone zone = BunniZone(payable(getCreate3ContractFromEnvSalt("BunniZone")));

        hookSalt = getCreate3SaltFromEnv("BunniHook");

        vm.startBroadcast(deployerPrivateKey);

        uint256 hookFlags = Hooks.AFTER_INITIALIZE_FLAG + Hooks.BEFORE_ADD_LIQUIDITY_FLAG + Hooks.BEFORE_SWAP_FLAG
            + Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        address hookDeployed = create3.getDeployed(deployer, hookSalt);
        require(
            uint160(bytes20(hookDeployed)) & Hooks.ALL_HOOK_MASK == hookFlags && hookDeployed.code.length == 0,
            "hook address invalid"
        );
        hook = BunniHook(
            payable(
                create3.deploy(
                    hookSalt,
                    bytes.concat(
                        type(BunniHook).creationCode,
                        abi.encode(
                            poolManager, hub, floodPlain, weth, zone, owner, hookFeeRecipient, hookFeeModifier, k
                        )
                    )
                )
            )
        );

        vm.stopBroadcast();
    }
}
