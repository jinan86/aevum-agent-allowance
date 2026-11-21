// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllowanceVault} from "../src/AllowanceVault.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

contract AllowanceVaultTest is Test {
    MockUSD8 token;
    AllowanceVault vault;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address agent2 = makeAddr("agent2");
    address payee1 = makeAddr("payee1");
    address payee2 = makeAddr("payee2");
    address stranger = makeAddr("stranger");

    uint256 constant TOTAL_CAP = 100e6; // 100 tUSD8
    uint256 constant PER_PAYMENT_CAP = 30e6; // 30 tUSD8

    function _payees() internal view returns (address[] memory) {
        address[] memory p = new address[](2);
        p[0] = payee1;
        p[1] = payee2;
        return p;
    }

    function setUp() public {
        token = new MockUSD8();
        vault = new AllowanceVault(IERC20(address(token)));
        token.mint(owner, 1_000e6);
        vm.prank(owner);
        token.approve(address(vault), type(uint256).max);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days, _payees());
    }

    // ---------- createAllowance: happy path ----------

    function test_create_fundsVaultAndStoresPolicy() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit AllowanceVault.AllowanceCreated(1, owner, agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days);
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(vault.nextAllowanceId(), 2);

        AllowanceVault.Allowance memory a = vault.allowanceOf(1);
        assertEq(a.owner, owner);
        assertEq(a.agent, agent);
        assertEq(a.totalCap, TOTAL_CAP);
        assertEq(a.perPaymentCap, PER_PAYMENT_CAP);
        assertEq(a.expiry, block.timestamp + 1 days);
        assertEq(a.spent, 0);
        assertFalse(a.revoked);

        assertEq(token.balanceOf(address(vault)), TOTAL_CAP);
        assertEq(token.balanceOf(owner), 1_000e6 - TOTAL_CAP);
        assertTrue(vault.isPayee(1, payee1));
        assertTrue(vault.isPayee(1, payee2));
        assertFalse(vault.isPayee(1, stranger));
        assertEq(vault.remaining(1), TOTAL_CAP);
    }

    function test_create_idsIncrement() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(vault.nextAllowanceId(), 3);
        assertEq(token.balanceOf(address(vault)), 2 * TOTAL_CAP);
    }

    // ---------- createAllowance: reverts ----------

    function test_create_revertsZeroAgent() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ZeroAddress.selector);
        vault.createAllowance(address(0), TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days, _payees());
    }

    function test_create_revertsZeroTotalCap() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ZeroTotalCap.selector);
        vault.createAllowance(agent, 0, PER_PAYMENT_CAP, block.timestamp + 1 days, _payees());
    }

    function test_create_revertsZeroPerPaymentCap() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ZeroPerPaymentCap.selector);
        vault.createAllowance(agent, TOTAL_CAP, 0, block.timestamp + 1 days, _payees());
    }

    function test_create_revertsPerPaymentCapAboveTotalCap() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.PerPaymentCapExceedsTotalCap.selector);
        vault.createAllowance(agent, TOTAL_CAP, TOTAL_CAP + 1, block.timestamp + 1 days, _payees());
    }

    function test_create_revertsExpiryInPast() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ExpiryInPast.selector);
        vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp - 1, _payees());
    }

    function test_create_revertsExpiryNow() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ExpiryInPast.selector);
        vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp, _payees());
    }

    function test_create_revertsEmptyPayees() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.EmptyPayees.selector);
        vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days, new address[](0));
    }

    function test_create_revertsZeroPayee() public {
        address[] memory p = new address[](1);
        p[0] = address(0);
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.ZeroAddress.selector);
        vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days, p);
    }

    function test_create_revertsWithoutApproval() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        vault.createAllowance(agent, TOTAL_CAP, PER_PAYMENT_CAP, block.timestamp + 1 days, _payees());
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert(AllowanceVault.ZeroAddress.selector);
        new AllowanceVault(IERC20(address(0)));
    }

    // ---------- pay: happy path ----------

    function test_pay_movesFundsAndTracksSpent() public {
        uint256 id = _create();
        vm.expectEmit(true, true, false, true, address(vault));
        emit AllowanceVault.AllowancePaid(id, payee1, 10e6, 10e6);
        vm.prank(agent);
        vault.pay(id, payee1, 10e6);

        assertEq(token.balanceOf(payee1), 10e6);
        assertEq(vault.allowanceOf(id).spent, 10e6);
        assertEq(vault.remaining(id), 90e6);
    }

    function test_pay_repeatedUntilTotalCap() public {
        uint256 id = _create();
        vm.startPrank(agent);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee2, 30e6);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee2, 10e6); // exactly totalCap: 100
        vm.stopPrank();

        assertEq(vault.allowanceOf(id).spent, TOTAL_CAP);
        assertEq(vault.remaining(id), 0);
        assertEq(token.balanceOf(payee1), 60e6);
        assertEq(token.balanceOf(payee2), 40e6);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // ---------- pay: reverts ----------

    function test_pay_revertsNotAgent() public {
        uint256 id = _create();
        vm.prank(stranger);
        vm.expectRevert(AllowanceVault.NotAgent.selector);
        vault.pay(id, payee1, 10e6);
    }

    function test_pay_revertsOwnerCannotPay() public {
        uint256 id = _create();
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.NotAgent.selector);
        vault.pay(id, payee1, 10e6);
    }

    function test_pay_revertsZeroAmount() public {
        uint256 id = _create();
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.ZeroAmount.selector);
        vault.pay(id, payee1, 0);
    }

    function test_pay_revertsAbovePerPaymentCap() public {
        uint256 id = _create();
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AmountExceedsPerPaymentCap.selector);
        vault.pay(id, payee1, PER_PAYMENT_CAP + 1);
    }

    function test_pay_revertsSpentPlusAmountAboveTotalCap() public {
        uint256 id = _create();
        vm.startPrank(agent);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee1, 30e6); // spent 90, 10 left
        vm.expectRevert(AllowanceVault.AmountExceedsTotalCap.selector);
        vault.pay(id, payee1, 11e6); // within per-payment cap, over total cap
        vm.stopPrank();
    }

    function test_pay_revertsPayeeNotAllowlisted() public {
        uint256 id = _create();
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.PayeeNotAllowed.selector);
        vault.pay(id, stranger, 10e6);
    }

    function test_pay_revertsAfterExpiry() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AllowanceExpired.selector);
        vault.pay(id, payee1, 10e6);
    }

    function test_pay_succeedsAtExactExpiry() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 1 days);
        vm.prank(agent);
        vault.pay(id, payee1, 10e6);
        assertEq(token.balanceOf(payee1), 10e6);
    }

    function test_pay_revertsUnknownAllowance() public {
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AllowanceNotFound.selector);
        vault.pay(999, payee1, 10e6);
    }

    // ---------- revoke ----------

    function test_revoke_refundsRemainderExactlyAndKillsAllowance() public {
        uint256 id = _create();
        vm.prank(agent);
        vault.pay(id, payee1, 30e6); // spent 30, 70 left

        uint256 ownerBefore = token.balanceOf(owner);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AllowanceVault.AllowanceRevoked(id, 70e6);
        vm.prank(owner);
        vault.revoke(id);

        assertEq(token.balanceOf(owner), ownerBefore + 70e6);
        assertEq(token.balanceOf(address(vault)), 0);
        assertTrue(vault.allowanceOf(id).revoked);
        assertEq(vault.remaining(id), 0);
    }

    function test_revoke_refundsZeroWhenFullySpent() public {
        uint256 id = _create();
        vm.startPrank(agent);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee1, 30e6);
        vault.pay(id, payee1, 10e6);
        vm.stopPrank();

        vm.prank(owner);
        vault.revoke(id);
        assertTrue(vault.allowanceOf(id).revoked);
    }

    function test_pay_revertsAfterRevoke() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.revoke(id);
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.AlreadyRevoked.selector);
        vault.pay(id, payee1, 10e6);
    }

    function test_revoke_revertsSecondRevoke() public {
        uint256 id = _create();
        vm.prank(owner);
        vault.revoke(id);
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.AlreadyRevoked.selector);
        vault.revoke(id);
    }

    function test_revoke_revertsNotOwner() public {
        uint256 id = _create();
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.NotOwner.selector);
        vault.revoke(id);
        vm.prank(stranger);
        vm.expectRevert(AllowanceVault.NotOwner.selector);
        vault.revoke(id);
    }

    function test_revoke_revertsUnknownAllowance() public {
        vm.prank(owner);
        vm.expectRevert(AllowanceVault.AllowanceNotFound.selector);
        vault.revoke(999);
    }

    function test_allowanceOf_revertsUnknown() public {
        vm.expectRevert(AllowanceVault.AllowanceNotFound.selector);
        vault.allowanceOf(999);
    }

    // ---------- independence ----------

    function test_twoAllowancesAreIndependent() public {
        uint256 id1 = _create();
        address owner2 = makeAddr("owner2");
        token.mint(owner2, 500e6);
        vm.startPrank(owner2);
        token.approve(address(vault), type(uint256).max);
        uint256 id2 = vault.createAllowance(agent2, 50e6, 20e6, block.timestamp + 2 days, _payees());
        vm.stopPrank();
        assertEq(id2, 2);

        // agent2 cannot spend allowance 1, agent cannot spend allowance 2
        vm.prank(agent2);
        vm.expectRevert(AllowanceVault.NotAgent.selector);
        vault.pay(id1, payee1, 10e6);
        vm.prank(agent);
        vm.expectRevert(AllowanceVault.NotAgent.selector);
        vault.pay(id2, payee1, 10e6);

        // spend one, revoke the other: balances stay separate
        vm.prank(agent);
        vault.pay(id1, payee1, 30e6);
        vm.prank(owner2);
        vault.revoke(id2);

        assertEq(vault.allowanceOf(id1).spent, 30e6);
        assertFalse(vault.allowanceOf(id1).revoked);
        assertEq(vault.allowanceOf(id2).spent, 0);
        assertTrue(vault.allowanceOf(id2).revoked);
        assertEq(token.balanceOf(owner2), 500e6); // full 50 refunded
        assertEq(token.balanceOf(address(vault)), 70e6); // only allowance 1 remainder
        assertEq(token.balanceOf(payee1), 30e6);
    }

    // ---------- fuzz ----------

    function testFuzz_payWithinCaps(uint256 amount) public {
        amount = bound(amount, 1, PER_PAYMENT_CAP);
        uint256 id = _create();
        vm.prank(agent);
        vault.pay(id, payee2, amount);
        assertEq(token.balanceOf(payee2), amount);
        assertEq(vault.allowanceOf(id).spent, amount);
    }
}
