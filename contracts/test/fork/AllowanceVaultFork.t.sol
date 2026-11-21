// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllowanceVault} from "../../src/AllowanceVault.sol";

interface ITUSD8 is IERC20 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Runs AllowanceVault against the REAL tUSD8 on a local fork of Aevum testnet.
///         No funds needed: `deal` writes a balance into the fork only.
///         Run with: make test-fork   (or: forge test --match-path 'test/fork/*' --fork-url aevum --evm-version shanghai)
contract AllowanceVaultForkTest is Test {
    ITUSD8 constant TUSD8 = ITUSD8(0x456569838f1d43009A91ebA4263147Afd7233483);

    AllowanceVault vault;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address payee1 = makeAddr("payee1");
    address payee2 = makeAddr("payee2");

    function setUp() public {
        vault = new AllowanceVault(IERC20(address(TUSD8)));
        deal(address(TUSD8), owner, 100e6); // 100 tUSD8, fork only
    }

    function test_realTusd8_createPayRevokeEndToEnd() public {
        assertEq(block.chainid, 44005, "run with --fork-url aevum");

        address[] memory payees = new address[](2);
        payees[0] = payee1;
        payees[1] = payee2;

        uint256 expiry = block.timestamp + 1 days;

        // Owner funds the allowance: 100 tUSD8 total, 30 max per payment.
        vm.startPrank(owner);
        TUSD8.approve(address(vault), 100e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AllowanceVault.AllowanceCreated(1, owner, agent, 100e6, 30e6, expiry);
        uint256 id = vault.createAllowance(agent, 100e6, 30e6, expiry, payees);
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(TUSD8.balanceOf(address(vault)), 100e6);
        assertEq(TUSD8.balanceOf(owner), 0);

        // Agent pays within policy, twice.
        vm.startPrank(agent);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee2, 20e6);
        vm.stopPrank();
        assertEq(TUSD8.balanceOf(payee1), 30e6);
        assertEq(TUSD8.balanceOf(payee2), 20e6);
        assertEq(vault.allowanceOf(id).spent, 50e6);
        assertEq(vault.remaining(id), 50e6);

        // Owner revokes: the unspent 50 tUSD8 comes straight back.
        vm.prank(owner);
        vault.revoke(id);
        assertEq(TUSD8.balanceOf(owner), 50e6);
        assertEq(TUSD8.balanceOf(address(vault)), 0);
        assertTrue(vault.allowanceOf(id).revoked);

        // Agent can no longer pay.
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AlreadyRevoked.selector);
        vault.pay(id, payee1, 1e6);
    }

    function test_realTusd8_policyEnforced() public {
        address[] memory payees = new address[](1);
        payees[0] = payee1;

        vm.startPrank(owner);
        TUSD8.approve(address(vault), 100e6);
        uint256 id = vault.createAllowance(agent, 100e6, 30e6, block.timestamp + 1 days, payees);
        vm.stopPrank();

        // Payee outside the allowlist is rejected even by the right agent.
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.PayeeNotAllowed.selector);
        vault.pay(id, payee2, 10e6);

        // Over the per-payment cap is rejected.
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AmountExceedsPerPaymentCap.selector);
        vault.pay(id, payee1, 31e6);

        // A non-agent cannot pay at all.
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.NotAgent.selector);
        vault.pay(id, payee1, 10e6);

        // A legal payment still works afterwards.
        vm.prank(agent);
        vault.pay(id, payee1, 30e6);
        assertEq(TUSD8.balanceOf(payee1), 30e6);
    }
}
