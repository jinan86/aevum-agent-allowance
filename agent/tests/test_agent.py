"""Tests for the Agent Allowance off-chain agent (agent/agent.py).

Hermetic: no network, no keys, no LLM calls. The chain reader and the
payer are injected into decide(); the LLM layer is replaced by fakes.
Run from the repo root:  python3 -m unittest discover -s agent/tests -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import agent as ag  # noqa: E402

NOW = 1_800_000_000
OWNER = "0x1111111111111111111111111111111111111111"
AGENT = "0x2222222222222222222222222222222222222222"
PAYEE = "0x3333333333333333333333333333333333333333"
STRANGER = "0x4444444444444444444444444444444444444444"


def allowance(**over):
    base = {
        "owner": OWNER, "agent": AGENT,
        "totalCap": 100_000_000, "perPaymentCap": 30_000_000,
        "expiry": NOW + 86_400, "spent": 0, "revoked": False,
        "remaining": 100_000_000, "now": NOW,
    }
    base.update(over)
    return base


def request(**over):
    base = {"allowanceId": 1, "task": "pay monthly API bill", "payee": PAYEE, "amount": 5_000_000}
    base.update(over)
    return base


def fake_judge_approve(req, allow, heuristic):
    return 10, True, "fake llm approves", {"layer": "llm", "provider": "fake"}


def fake_judge_reject(req, allow, heuristic):
    return 95, False, "fake llm: looks like a scam", {"layer": "llm", "provider": "fake"}


class TestPolicy(unittest.TestCase):
    def test_valid_request_passes(self):
        ok, reasons = ag.check_policy(allowance(), PAYEE, 5_000_000, True)
        self.assertTrue(ok)
        self.assertEqual(reasons, [])

    def test_over_per_payment_cap_rejected(self):
        ok, reasons = ag.check_policy(allowance(), PAYEE, 31_000_000, True)
        self.assertFalse(ok)
        self.assertTrue(any("per-payment cap" in r for r in reasons))

    def test_over_total_cap_rejected(self):
        ok, _ = ag.check_policy(allowance(spent=95_000_000), PAYEE, 10_000_000, True)
        self.assertFalse(ok)

    def test_expired_rejected(self):
        ok, reasons = ag.check_policy(allowance(now=NOW + 90_000), PAYEE, 5_000_000, True)
        self.assertFalse(ok)
        self.assertIn("allowance expired", reasons)

    def test_revoked_rejected(self):
        ok, reasons = ag.check_policy(allowance(revoked=True), PAYEE, 5_000_000, True)
        self.assertFalse(ok)
        self.assertIn("allowance revoked", reasons)

    def test_payee_outside_allowlist_rejected(self):
        ok, reasons = ag.check_policy(allowance(), STRANGER, 5_000_000, False)
        self.assertFalse(ok)
        self.assertTrue(any("not on the allowlist" in r for r in reasons))

    def test_zero_amount_rejected(self):
        ok, _ = ag.check_policy(allowance(), PAYEE, 0, True)
        self.assertFalse(ok)


class TestHeuristic(unittest.TestCase):
    def test_small_payment_approves(self):
        score, approve, _ = ag.heuristic_judge(request(amount=5_000_000), allowance())
        self.assertTrue(approve)
        self.assertLess(score, 70)

    def test_near_cap_payment_high_risk_but_under_threshold(self):
        score, approve, _ = ag.heuristic_judge(request(amount=29_000_000), allowance())
        self.assertEqual(score, 65)

    def test_empty_task_rejects(self):
        score, approve, _ = ag.heuristic_judge(request(task="   "), allowance())
        self.assertFalse(approve)
        self.assertGreaterEqual(score, 90)


class TestDecide(unittest.TestCase):
    def test_approve_when_policy_and_judge_agree(self):
        d = ag.decide(request(), allowance(), True, judge=fake_judge_approve)
        self.assertTrue(d["approved"])

    def test_policy_rejection_short_circuits_judge(self):
        called = []
        d = ag.decide(request(amount=50_000_000), allowance(), True,
                      judge=lambda *a: called.append(1) or (10, True, "x", {}))
        self.assertFalse(d["approved"])
        self.assertEqual(d["stage"], "policy")
        self.assertEqual(called, [])  # judge never consulted

    def test_llm_veto_blocks_payment(self):
        d = ag.decide(request(), allowance(), True, judge=fake_judge_reject)
        self.assertFalse(d["approved"])
        self.assertEqual(d["stage"], "judgment")

    def test_heuristic_veto_blocks_even_when_llm_approves(self):
        # Empty task: heuristic rejects (95) and llm_judge takes max risk,
        # so a fake "approve" judge must not override the heuristic.
        d = ag.decide(request(task=""), allowance(), True, judge=fake_judge_approve)
        self.assertFalse(d["approved"])


class TestFailClosed(unittest.TestCase):
    def test_all_providers_dead_and_heuristic_rejects(self):
        """LLM chain dead (no keys, no surrogate) + heuristic rejects
        (empty task) -> no payment. This is the fail-closed path."""
        for k in ("LLM_API_KEY", "LLM2_API_KEY", "LLM3_API_KEY"):
            os.environ.pop(k, None)
        os.environ["LLM2_ENABLED"] = "0"
        os.environ["LLM3_ENABLED"] = "0"
        ag.add_surrogate_to_request = None  # force "no surrogate"
        try:
            risk, approve, reasons, meta = ag.llm_judge(
                request(task=""), allowance(), ag.heuristic_judge(request(task=""), allowance()))
            self.assertFalse(approve)
            self.assertEqual(meta["layer"], "heuristic_only")
        finally:
            os.environ.pop("LLM2_ENABLED", None)
            os.environ.pop("LLM3_ENABLED", None)

    def test_all_providers_dead_and_heuristic_approves(self):
        """LLM chain dead + heuristic approves -> heuristic decides alone
        (documented behavior: the agent still pays small in-policy requests)."""
        for k in ("LLM_API_KEY", "LLM2_API_KEY", "LLM3_API_KEY"):
            os.environ.pop(k, None)
        os.environ["LLM2_ENABLED"] = "0"
        os.environ["LLM3_ENABLED"] = "0"
        ag.add_surrogate_to_request = None
        try:
            risk, approve, reasons, meta = ag.llm_judge(
                request(), allowance(), ag.heuristic_judge(request(), allowance()))
            self.assertTrue(approve)
            self.assertEqual(meta["layer"], "heuristic_only")
        finally:
            os.environ.pop("LLM2_ENABLED", None)
            os.environ.pop("LLM3_ENABLED", None)


class TestEncoding(unittest.TestCase):
    def test_pay_calldata(self):
        data = ag.build_pay_calldata(1, PAYEE, 5_000_000)
        self.assertEqual(data[:4].hex(), ag.SEL_PAY)
        self.assertEqual(len(data), 4 + 32 * 3)
        # allowanceId == 1 in the first word, amount in the third
        self.assertEqual(int.from_bytes(data[4:36], "big"), 1)
        self.assertEqual(int.from_bytes(data[68:100], "big"), 5_000_000)

    def test_parse_amount(self):
        self.assertEqual(ag.parse_amount("5"), 5_000_000)
        self.assertEqual(ag.parse_amount("5.25"), 5_250_000)
        self.assertEqual(ag.parse_amount(2), 2_000_000)


class TestDailyCap(unittest.TestCase):
    def test_cap_enforced(self):
        ag.STATE_FILE = "/tmp/agent-test-state.json"
        try:
            if os.path.exists(ag.STATE_FILE):
                os.remove(ag.STATE_FILE)
            ok, spent, cap = ag.daily_cap_ok(5_000_000, "100")
            self.assertTrue(ok)
            ag.record_spent(99_000_000)
            ok, _, _ = ag.daily_cap_ok(5_000_000, "100")
            self.assertFalse(ok)
            ok, _, _ = ag.daily_cap_ok(1_000_000, "100")
            self.assertTrue(ok)
        finally:
            if os.path.exists(ag.STATE_FILE):
                os.remove(ag.STATE_FILE)
            ag.STATE_FILE = os.path.join(ag.BASE_DIR, "state.json")


if __name__ == "__main__":
    unittest.main()
