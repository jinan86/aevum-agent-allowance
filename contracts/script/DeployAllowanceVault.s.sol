// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllowanceVault} from "../src/AllowanceVault.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// @notice Deploys AllowanceVault (Agent Allowance, track "Native AI Assistants").
///   - Aevum testnet and `make fork`: uses the real tUSD8.
///   - `make anvil` (chain 31337) only: deploys MockUSD8 first and mints 1,000 to the deployer.
///   - Anywhere else it stops, rather than deploy a token anyone can mint.
///   The vault takes no merchant/owner at deploy time: anyone can create an
///   allowance on it afterwards (the allowance's owner is whoever calls
///   createAllowance). anvil's public accounts are refused as deployer
///   outside local chains.
///
///   make deploy-vault-fork                     # `make fork` on 127.0.0.1:8555
///   make deploy-vault-aevum ACCOUNT=deployer   # uses a keystore made with `cast wallet import`
contract DeployAllowanceVault is Script {
    address constant AEVUM_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    uint256 constant ANVIL_CHAIN = 31337;
    uint256 constant FORK_CHAIN = 440050;
    /// anvil's default accounts come from this public mnemonic.
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    function run() external returns (AllowanceVault vault, address token) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        bool local = block.chainid == ANVIL_CHAIN || block.chainid == FORK_CHAIN;
        require(local || !isAnvilAccount(deployer), "Deployer is a public anvil account. Use your own address.");

        if (AEVUM_TUSD8.code.length > 0) {
            token = AEVUM_TUSD8;
        } else {
            require(block.chainid == ANVIL_CHAIN, "tUSD8 not found on this chain. Check the RPC (Aevum testnet is 44005).");
            MockUSD8 mock = new MockUSD8();
            mock.mint(deployer, 1_000e6);
            token = address(mock);
        }
        vault = new AllowanceVault(IERC20(token));
        vm.stopBroadcast();

        console.log("chainId  ", block.chainid);
        console.log("token    ", token);
        console.log("deployer ", deployer);
        console.log("AllowanceVault ", address(vault));
    }

    function isAnvilAccount(address a) internal pure returns (bool) {
        for (uint32 i = 0; i < 10; i++) {
            if (vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)) == a) return true;
        }
        return false;
    }
}
