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

contract DeployCoreScript is CREATE3Script {
    using LibString for uint256;
    using SafeCastLib for uint256;

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run()
        external
        returns (BunniHub hub, BunniZone zone, BunniHook hook, bytes32 hubSalt, bytes32 zoneSalt, bytes32 hookSalt)
    {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        address deployer = vm.addr(deployerPrivateKey);

        address poolManager = vm.envAddress(string.concat("POOL_MANAGER_", block.chainid.toString()));
        address weth = vm.envAddress(string.concat("WETH_", block.chainid.toString()));
        address owner = vm.envAddress("OWNER");
        address hookFeeRecipientController = vm.envAddress("HOOK_FEE_RECIPIENT_CONTROLLER");
        uint48 k = vm.envUint(string.concat("AMAMM_K_", block.chainid.toString())).toUint48();
        address[] memory initialZoneWhitelist =
            vm.envAddress(string.concat("FULFILLER_LIST_", block.chainid.toString()), ",");

        hubSalt = getCreate3SaltFromEnv("BunniHub");
        zoneSalt = getCreate3SaltFromEnv("BunniZone");
        hookSalt = getCreate3SaltFromEnv("BunniHook");

        address[] memory hookWhitelist = new address[](1);
        hookWhitelist[0] = getCreate3ContractFromEnvSalt("BunniHook");

        vm.startBroadcast(deployerPrivateKey);

        hub = BunniHub(
            payable(
                create3.deploy(
                    hubSalt,
                    bytes.concat(
                        type(BunniHub).creationCode,
                        abi.encode(
                            poolManager, weth, vm.envAddress("PERMIT2"), new BunniToken(), owner, owner, hookWhitelist
                        )
                    )
                )
            )
        );

        zone = BunniZone(
            payable(
                create3.deploy(
                    zoneSalt, bytes.concat(type(BunniZone).creationCode, abi.encode(owner, initialZoneWhitelist))
                )
            )
        );

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
                            poolManager,
                            hub,
                            vm.envAddress("FLOOD_PLAIN"),
                            weth,
                            zone,
                            owner,
                            hookFeeRecipientController,
                            k
                        )
                    )
                )
            )
        );

        vm.stopBroadcast();
    }
}
