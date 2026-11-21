// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AllowanceVault
/// @notice A human (owner) funds an on-chain allowance for ONE AI agent address.
///         The agent may pay only allowlisted payees, only up to a per-payment cap,
///         only up to a total cap, and only before the expiry. The owner can revoke
///         at any time; revocation is permanent and refunds the unspent remainder
///         immediately. Every payment and revocation is an on-chain event, so the
///         full spend history is an audit trail.
/// @dev Built for the Aevum Builder Challenge #1, track "Native AI Assistants".
///      This is NOT an invoice/payment-request contract: there is no invoice,
///      no order id, no merchant. The owner sets the policy; the agent spends
///      inside it. Shanghai-safe: no Cancun opcodes, no transient storage.
contract AllowanceVault {
    using SafeERC20 for IERC20;

    struct Allowance {
        address owner;
        address agent;
        uint256 totalCap;
        uint256 perPaymentCap;
        uint256 expiry;
        uint256 spent;
        bool revoked;
    }

    IERC20 public immutable token;

    uint256 public nextAllowanceId = 1;

    mapping(uint256 allowanceId => Allowance) private _allowances;
    // allowanceId => payee => allowed
    mapping(uint256 allowanceId => mapping(address payee => bool)) private _payees;

    event AllowanceCreated(
        uint256 indexed allowanceId,
        address indexed owner,
        address indexed agent,
        uint256 totalCap,
        uint256 perPaymentCap,
        uint256 expiry
    );
    event AllowancePaid(
        uint256 indexed allowanceId, address indexed payee, uint256 amount, uint256 spentTotal
    );
    event AllowanceRevoked(uint256 indexed allowanceId, uint256 refunded);

    error ZeroAddress();
    error ZeroTotalCap();
    error ZeroPerPaymentCap();
    error PerPaymentCapExceedsTotalCap();
    error ExpiryInPast();
    error EmptyPayees();
    error AllowanceNotFound();
    error NotAgent();
    error NotOwner();
    error AlreadyRevoked();
    error AllowanceExpired();
    error ZeroAmount();
    error AmountExceedsPerPaymentCap();
    error AmountExceedsTotalCap();
    error PayeeNotAllowed();

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @notice Create an allowance for `agent` and fund it with `totalCap` tUSD8
    ///         pulled from the caller (the caller must approve this contract first).
    /// @return allowanceId The id of the new allowance (starts at 1, increments).
    function createAllowance(
        address agent,
        uint256 totalCap,
        uint256 perPaymentCap,
        uint256 expiry,
        address[] calldata payees
    ) external returns (uint256 allowanceId) {
        if (agent == address(0)) revert ZeroAddress();
        if (totalCap == 0) revert ZeroTotalCap();
        if (perPaymentCap == 0) revert ZeroPerPaymentCap();
        if (perPaymentCap > totalCap) revert PerPaymentCapExceedsTotalCap();
        if (expiry <= block.timestamp) revert ExpiryInPast();
        if (payees.length == 0) revert EmptyPayees();

        allowanceId = nextAllowanceId;
        nextAllowanceId = allowanceId + 1;

        _allowances[allowanceId] = Allowance({
            owner: msg.sender,
            agent: agent,
            totalCap: totalCap,
            perPaymentCap: perPaymentCap,
            expiry: expiry,
            spent: 0,
            revoked: false
        });
        for (uint256 i = 0; i < payees.length; i++) {
            if (payees[i] == address(0)) revert ZeroAddress();
            _payees[allowanceId][payees[i]] = true;
        }

        // Fund the vault up front; the agent can only spend what is already here.
        token.safeTransferFrom(msg.sender, address(this), totalCap);

        emit AllowanceCreated(allowanceId, msg.sender, agent, totalCap, perPaymentCap, expiry);
    }

    /// @notice Pay `amount` to `payee` from allowance `allowanceId`.
    ///         Only the allowance's agent may call this, and only inside the policy.
    function pay(uint256 allowanceId, address payee, uint256 amount) external {
        Allowance storage a = _allowances[allowanceId];
        if (a.owner == address(0)) revert AllowanceNotFound();
        if (msg.sender != a.agent) revert NotAgent();
        if (a.revoked) revert AlreadyRevoked();
        if (block.timestamp > a.expiry) revert AllowanceExpired();
        if (amount == 0) revert ZeroAmount();
        if (amount > a.perPaymentCap) revert AmountExceedsPerPaymentCap();
        if (a.spent + amount > a.totalCap) revert AmountExceedsTotalCap();
        if (!_payees[allowanceId][payee]) revert PayeeNotAllowed();

        a.spent += amount;
        token.safeTransfer(payee, amount);

        emit AllowancePaid(allowanceId, payee, amount, a.spent);
    }

    /// @notice Permanently revoke `allowanceId` and refund the unspent remainder
    ///         (totalCap - spent) to the allowance owner. Only the owner may call.
    function revoke(uint256 allowanceId) external {
        Allowance storage a = _allowances[allowanceId];
        if (a.owner == address(0)) revert AllowanceNotFound();
        if (msg.sender != a.owner) revert NotOwner();
        if (a.revoked) revert AlreadyRevoked();

        a.revoked = true;
        uint256 refunded = a.totalCap - a.spent;
        if (refunded > 0) {
            token.safeTransfer(a.owner, refunded);
        }

        emit AllowanceRevoked(allowanceId, refunded);
    }

    /// @notice Full allowance record for `allowanceId`. Reverts if it does not exist.
    function allowanceOf(uint256 allowanceId) external view returns (Allowance memory) {
        Allowance memory a = _allowances[allowanceId];
        if (a.owner == address(0)) revert AllowanceNotFound();
        return a;
    }

    /// @notice True when `payee` is on the allowlist of `allowanceId`.
    function isPayee(uint256 allowanceId, address payee) external view returns (bool) {
        return _payees[allowanceId][payee];
    }

    /// @notice Unspent remainder of `allowanceId` (0 once revoked or fully spent).
    function remaining(uint256 allowanceId) external view returns (uint256) {
        Allowance memory a = _allowances[allowanceId];
        if (a.owner == address(0)) revert AllowanceNotFound();
        if (a.revoked) return 0;
        return a.totalCap - a.spent;
    }
}
