#!/usr/bin/env python3
"""Agent Allowance — off-chain AI agent for the Aevum Builder Challenge #1.

The agent receives a payment request (task + payee + amount + allowanceId)
and decides whether to pay it from an on-chain AllowanceVault allowance:

  1. POLICY (on-chain, authoritative): reads the allowance via RPC
     (allowanceOf, isPayee, remaining, block.timestamp vs expiry) and
     rejects anything outside it — over per-payment cap, over total cap,
     expired, revoked, or a payee outside the allowlist.
  2. JUDGMENT (LLM chain): asks an LLM whether the request is legitimate
     and in scope. Providers are tried in order — 100milionseek first,
     then OpenRouter (free model), then Coarena — then a deterministic
     heuristic. Either layer can veto: the final risk is the max of the
     heuristic risk and the LLM risk, and a payment only goes ahead when
     the final risk is below the threshold.
  3. PAY (direct pay): calls AllowanceVault.pay() from the agent wallet.
     Direct, not gasless: pay() only accepts msg.sender == agent, so a
     relayer submitting the transaction would be rejected with NotAgent.
     The agent pays its own tQDAY gas (~1 gwei — cheap). Full gasless
     would need a meta-tx entrypoint in the contract; that is future work,
     not Fase 2 (see the repo README).

Fail closed: a policy rejection, an LLM+heuristic rejection, a failed
simulation, or a dead LLM chain with a rejecting heuristic all mean NO
payment — and the refusal is logged, like every decision, to
decisions.jsonl next to this script.

Rails (same spirit as the starter kit's relayer):
  * only OUR vault (VAULT_ADDRESS) — the agent never calls another contract;
  * only amounts the policy allows (checked on-chain AND off-chain);
  * simulate via eth_call before broadcast, so a revert costs nothing;
  * a daily cap (DAILY_CAP_TUSD8, default 100 tUSD8) across all payments;
  * no signatures are involved in direct pay(), so there is no signature
    window to enforce — the 1-hour window applies to EIP-3009 flows only.

LLM configuration (all optional — without a key the agent runs
heuristic-only and says so in every decision log). Auth follows the
Sentinel agent pattern exactly: a literal key wins, otherwise the
Secure Vault surrogate for the provider's host (dynamic_credentials +
add_surrogate_to_request). Keys are NEVER hardcoded or logged.
  LLM_API_URL   primary endpoint (default https://100milionseek.top/v1/chat/completions)
  LLM_MODEL     primary model (default deepseek-v4.1-flash-free)
  LLM_API_KEY   primary API key
  LLM2_API_URL  OpenRouter endpoint (default https://openrouter.ai/api/v1/chat/completions)
  LLM2_MODEL    OpenRouter model (default baidu/ernie-5.5-flash-preview:free)
  LLM2_API_KEY  OpenRouter API key
  LLM2_ENABLED=0  disable the OpenRouter fallback
  LLM3_API_URL  Coarena endpoint (default https://coarena.ai/api/v1/chat/completions)
  LLM3_MODEL    Coarena model (default deepseek-v4-1-flash-1017)
  LLM3_API_KEY  Coarena API key
  LLM3_ENABLED=0  disable the Coarena fallback
  LLM_USE_SURROGATE / LLM2_USE_SURROGATE / LLM3_USE_SURROGATE=1  force surrogate auth

Chain configuration (env, with local-fork defaults):
  AEVUM_RPC     default http://127.0.0.1:8555 (local fork); testnet: https://rpc-test.qday.info
  VAULT_ADDRESS AllowanceVault address (required)
  WALLET_FILE   project wallet keypair JSON (default ../../.wallet.json,
                i.e. the challenge dir, OUTSIDE the repo — never committed)
  DAILY_CAP_TUSD8  default 100
  RISK_THRESHOLD   default 70 (pay only when final risk < threshold)

Usage:
  python3 agent.py --request '{"allowanceId": 1, "task": "pay API bill", "payee": "0x...", "amount": "5"}'
  python3 agent.py --request-file request.json [--dry-run] [--vault 0x...] [--rpc-url ...]
  Amounts are tUSD8 in decimal units (6 decimals): "5" = 5 tUSD8 = 5000000 base units.

State (daily cap + audit trail) lives next to this script:
  state.json      per-day spent totals (resets daily)
  decisions.jsonl append-only decision log (one JSON object per request)
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

try:
    sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
    from dynamic_credentials import add_surrogate_to_request
except Exception:  # noqa: BLE001 - surrogate unavailable; literal key only
    add_surrogate_to_request = None

CAST = shutil.which("cast") or os.path.expanduser("~/.foundry/bin/cast")
TUSD8_DECIMALS = 6
RISK_THRESHOLD = int(os.environ.get("RISK_THRESHOLD", "70"))

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE_DIR, "state.json")
DECISIONS_FILE = os.path.join(BASE_DIR, "decisions.jsonl")

# Function selectors (cast sig). Hardcoded so the agent needs no keccak
# implementation in stdlib-only Python.
SEL_ALLOWANCE_OF = "516d2435"
SEL_IS_PAYEE = "80a7998c"
SEL_REMAINING = "0361bf14"
SEL_PAY = "0313766f"

# AllowancePaid(uint256,address,uint256,uint256) topic0 (for reference).
TOPIC_ALLOWANCE_PAID = "0xbc8a44c2bbdd8818d995dfad49a9c2ac1f07784076ee4bbd7546df2c9489316d"


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ------------------------------------------------------------------ RPC
def rpc(method, params, url, retries=3):
    """JSON-RPC call with retries. Sends a browser User-Agent because
    some endpoints 403 Python-urllib's default UA."""
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    last_err = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=body, headers={
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            })
            with urllib.request.urlopen(req, timeout=30) as resp:
                out = json.load(resp)
            if "error" in out:
                raise RuntimeError(f"RPC {method} failed: {out['error']}")
            return out["result"]
        except Exception as e:  # noqa: BLE001 - retry everything transient
            if isinstance(e, RuntimeError):
                raise
            last_err = e
            log(f"RPC {method} attempt {attempt + 1}/{retries} failed ({e}); retrying")
            time.sleep(2 ** attempt)
    raise RuntimeError(f"RPC {method} failed after {retries} attempts: {last_err}")


def _u256(word_bytes):
    return int.from_bytes(word_bytes, "big")


def _addr(word_bytes):
    return "0x" + word_bytes[-20:].hex()


def _encode_u256(value):
    return int(value).to_bytes(32, "big")


def _encode_address(address):
    return bytes(12) + bytes.fromhex(address[2:])


def eth_call(vault, data, rpc_url, from_addr=None):
    """Raw eth_call; returns the raw return-data bytes."""
    tx = {"to": vault, "data": "0x" + data.hex()}
    if from_addr:
        tx["from"] = from_addr
    raw = rpc("eth_call", [tx, "latest"], rpc_url)
    return bytes.fromhex(raw[2:])


def read_allowance(vault, allowance_id, rpc_url):
    """Read the allowance + isPayee is checked per payee by the caller.
    Returns dict with owner, agent, totalCap, perPaymentCap, expiry,
    spent, revoked, remaining, now (chain timestamp)."""
    data = bytes.fromhex(SEL_ALLOWANCE_OF) + _encode_u256(allowance_id)
    out = eth_call(vault, data, rpc_url)
    if len(out) < 7 * 32:
        raise RuntimeError(f"allowanceOf({allowance_id}) returned {len(out)} bytes (allowance may not exist)")
    words = [out[i:i + 32] for i in range(0, 7 * 32, 32)]
    data = bytes.fromhex(SEL_REMAINING) + _encode_u256(allowance_id)
    remaining = _u256(eth_call(vault, data, rpc_url)[:32])
    block = rpc("eth_getBlockByNumber", ["latest", False], rpc_url)
    now = int(block["timestamp"], 16)
    return {
        "owner": _addr(words[0]),
        "agent": _addr(words[1]),
        "totalCap": _u256(words[2]),
        "perPaymentCap": _u256(words[3]),
        "expiry": _u256(words[4]),
        "spent": _u256(words[5]),
        "revoked": bool(_u256(words[6])),
        "remaining": remaining,
        "now": now,
    }


def is_payee(vault, allowance_id, payee, rpc_url):
    data = bytes.fromhex(SEL_IS_PAYEE) + _encode_u256(allowance_id) + _encode_address(payee)
    out = eth_call(vault, data, rpc_url)
    return bool(_u256(out[:32]))


# ------------------------------------------------------------------ policy
def check_policy(allowance, payee, amount, payee_allowed):
    """Pure policy check against an allowance dict (see read_allowance).
    Returns (ok, [reasons]). amount is in base units (6 decimals)."""
    reasons = []
    if allowance["revoked"]:
        reasons.append("allowance revoked")
    if allowance["now"] > allowance["expiry"]:
        reasons.append("allowance expired")
    if amount <= 0:
        reasons.append("amount is zero")
    if amount > allowance["perPaymentCap"]:
        reasons.append(f"amount {amount} exceeds per-payment cap {allowance['perPaymentCap']}")
    if allowance["spent"] + amount > allowance["totalCap"]:
        reasons.append(f"amount would exceed total cap {allowance['totalCap']} (spent {allowance['spent']})")
    if not payee_allowed:
        reasons.append(f"payee {payee} is not on the allowlist")
    return (not reasons), reasons


# ------------------------------------------------------------------ heuristic
def heuristic_judge(request, allowance):
    """Deterministic risk score 0-100 + approve flag. Fully auditable.

    Risk grows with the share of the per-payment cap a single payment
    takes; an empty/meaningless task description is an automatic reject.
    """
    amount = request["amount"]
    cap = allowance["perPaymentCap"]
    task = (request.get("task") or "").strip()
    if not task:
        return 95, False, "empty task description"
    share = amount / cap if cap else 1.0
    if share <= 0.25:
        score, why = 10, f"small payment ({share:.0%} of per-payment cap)"
    elif share <= 0.5:
        score, why = 30, f"moderate payment ({share:.0%} of per-payment cap)"
    elif share <= 0.75:
        score, why = 50, f"large payment ({share:.0%} of per-payment cap)"
    else:
        score, why = 65, f"near-cap payment ({share:.0%} of per-payment cap)"
    return score, score < RISK_THRESHOLD, why


# ------------------------------------------------------------------ LLM layer
def _llm_providers():
    """Ordered LLM providers: 100milionseek first, OpenRouter second,
    Coarena third. Same shape as the Sentinel agent."""
    providers = []
    url1 = os.environ.get("LLM_API_URL", "https://100milionseek.top/v1/chat/completions")
    host1 = urllib.parse.urlparse(url1).hostname or ""
    providers.append({
        "name": "100milionseek" if host1 == "100milionseek.top" else host1 or "primary",
        "url": url1,
        "model": os.environ.get("LLM_MODEL", "deepseek-v4.1-flash-free"),
        "max_tokens": int(os.environ.get("LLM_MAX_TOKENS", "200")),
        "api_key": os.environ.get("LLM_API_KEY", ""),
        "connection": "custom.100milionseek",
        "allowed_hosts": ["100milionseek.top"],
        "use_surrogate": (
            add_surrogate_to_request is not None
            and (os.environ.get("LLM_USE_SURROGATE", "") == "1" or host1 == "100milionseek.top")
        ),
    })
    if os.environ.get("LLM2_ENABLED", "1") != "0":
        url2 = os.environ.get("LLM2_API_URL", "https://openrouter.ai/api/v1/chat/completions")
        host2 = urllib.parse.urlparse(url2).hostname or ""
        providers.append({
            "name": "openrouter",
            "url": url2,
            "model": os.environ.get("LLM2_MODEL", "baidu/ernie-5.5-flash-preview:free"),
            # Ernie reasons before answering (~1000 tokens of reasoning);
            # the JSON answer only completes with 4096 (verified live 22 Nov 2026).
            "max_tokens": int(os.environ.get("LLM2_MAX_TOKENS", "4096")),
            "api_key": os.environ.get("LLM2_API_KEY", ""),
            "connection": "custom.openrouter",
            "allowed_hosts": ["openrouter.ai"],
            "use_surrogate": (
                add_surrogate_to_request is not None
                and (os.environ.get("LLM2_USE_SURROGATE", "") == "1" or host2 == "openrouter.ai")
            ),
        })
    if os.environ.get("LLM3_ENABLED", "1") != "0":
        url3 = os.environ.get("LLM3_API_URL", "https://coarena.ai/api/v1/chat/completions")
        host3 = urllib.parse.urlparse(url3).hostname or ""
        providers.append({
            "name": "coarena",
            "url": url3,
            "model": os.environ.get("LLM3_MODEL", "deepseek-v4-1-flash-1017"),
            "max_tokens": int(os.environ.get("LLM3_MAX_TOKENS", "200")),
            "api_key": os.environ.get("LLM3_API_KEY", ""),
            "connection": "custom.coarena",
            "allowed_hosts": ["coarena.ai"],
            "use_surrogate": (
                add_surrogate_to_request is not None
                and (os.environ.get("LLM3_USE_SURROGATE", "") == "1" or host3 == "coarena.ai")
            ),
        })
    return providers


def _llm_call(provider, prompt, heuristic):
    """One provider, up to 3 attempts. Returns (risk_score, approve, reasons, meta).
    Raises the last error when the provider never answers."""
    payload = json.dumps({
        "model": provider["model"],
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "max_tokens": provider.get("max_tokens", 200),
    }).encode()
    last_err = None
    for attempt in range(3):
        req = urllib.request.Request(
            provider["url"], data=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                # Cloudflare blocks Python-urllib's default UA (error 1010).
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            },
        )
        if provider["use_surrogate"] and not provider["api_key"]:
            add_surrogate_to_request(req, provider["connection"], allowed_hosts=provider["allowed_hosts"])
        else:
            req.add_header("Authorization", f"Bearer {provider['api_key']}")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                out = json.load(resp)
            text = out["choices"][0]["message"]["content"].strip()
            parsed = json.loads(text[text.index("{"):text.rindex("}") + 1])
            score = int(parsed["risk_score"])
            reasons = str(parsed.get("reasons", ""))[:300]
            approve = bool(parsed.get("approve", score < RISK_THRESHOLD))
            if not (0 <= score <= 100):
                raise ValueError(f"out-of-range LLM score: {parsed}")
            if approve and score >= RISK_THRESHOLD:
                approve = False
            meta = {
                "layer": "llm",
                "provider": provider["name"],
                "llm": "ok",
                "model": provider["model"],
                "served_by": out.get("model"),
                "llm_text": text[:500],
            }
            return score, approve, reasons, meta
        except Exception as e:  # noqa: BLE001 - retry, then let the caller move on
            last_err = e
            log(f"LLM {provider['name']} attempt {attempt + 1}/3 failed ({type(e).__name__}: {str(e)[:120]}); retrying")
            time.sleep(2 ** attempt)
    raise last_err


def llm_judge(request, allowance, heuristic):
    """LLM reasoning pass, providers tried in order; falls back to the
    heuristic verdict. Returns (risk, approve, reasons, meta).

    Fail closed: the final risk is the MAX of the heuristic risk and the
    LLM risk — either layer can veto a payment. A dead LLM chain means
    the heuristic alone decides, so a heuristic rejection still blocks.
    """
    h_score, h_approve, h_reasons = heuristic
    prompt = (
        "You are a payment-approval judge for an AI agent with a capped on-chain allowance.\n"
        f"Task: {request.get('task')}\n"
        f"Payee: {request['payee']}\n"
        f"Amount: {request['amount']} base units ({request['amount'] / 10**TUSD8_DECIMALS} tUSD8, 6 decimals)\n"
        f"Allowance: total cap {allowance['totalCap']}, per-payment cap {allowance['perPaymentCap']}, "
        f"spent {allowance['spent']}, remaining {allowance['remaining']}, "
        f"expiry {allowance['expiry']} (now {allowance['now']})\n"
        f"Heuristic risk: {h_score}/100, reasons: {h_reasons}\n"
        "Rules: approve ONLY if the task is a plausible, in-scope payment to this payee for this "
        "amount (e.g. an API bill, a service fee, a task payout the owner would expect). "
        "Reject anything that looks like a scam, a self-payment, a duplicate charge, a "
        "mismatched payee/task, or an amount that does not fit the task. "
        f"risk_score is 0-100; approve is true only when risk_score < {RISK_THRESHOLD}.\n"
        "Reply with JSON only: {\"risk_score\": <int>, \"approve\": <bool>, \"reasons\": \"<one sentence>\"}."
    )
    tried = []
    last_err = None
    for provider in _llm_providers():
        if not provider["api_key"] and not provider["use_surrogate"]:
            log(f"LLM {provider['name']}: skipped (no key, no surrogate)")
            continue
        tried.append(provider["name"])
        try:
            l_score, l_approve, l_reasons, meta = _llm_call(provider, prompt, heuristic)
            final_score = max(h_score, l_score)
            final_approve = h_approve and l_approve and final_score < RISK_THRESHOLD
            meta["heuristic_score"] = h_score
            meta["llm_score"] = l_score
            return final_score, final_approve, f"heuristic: {h_reasons}; llm({meta['provider']}): {l_reasons}", meta
        except Exception as e:  # noqa: BLE001 - try the next provider
            last_err = e
            log(f"LLM {provider['name']} exhausted; trying next provider")
    if not tried:
        return h_score, h_approve, h_reasons, {"layer": "heuristic_only", "llm": "skipped_no_key"}
    return h_score, h_approve, h_reasons, {
        "layer": "heuristic_fallback",
        "llm": f"error: {type(last_err).__name__}" if last_err else "error",
        "providers_tried": tried,
    }


# ------------------------------------------------------------------ wallet / pay
def load_wallet_key(wallet_file):
    with open(wallet_file) as f:
        data = json.load(f)
    return data["data"][0]["private_key"], data["data"][0]["address"]


def build_pay_calldata(allowance_id, payee, amount):
    return (
        bytes.fromhex(SEL_PAY)
        + _encode_u256(allowance_id)
        + _encode_address(payee)
        + _encode_u256(amount)
    )


def simulate_pay(vault, allowance_id, payee, amount, agent_addr, rpc_url):
    """eth_call the pay() from the agent address. Raises on revert —
    a bad payment costs nothing here."""
    eth_call(vault, build_pay_calldata(allowance_id, payee, amount), rpc_url, from_addr=agent_addr)


def broadcast_pay(vault, allowance_id, payee, amount, pk, rpc_url):
    """Broadcast pay() via cast (legacy tx — Aevum's safest choice).
    Returns the tx hash."""
    cmd = [
        CAST, "send", vault,
        "pay(uint256,address,uint256)",
        str(allowance_id), payee, str(amount),
        "--private-key", pk, "--rpc-url", rpc_url, "--legacy", "--json",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(f"cast send failed: {out.stderr.strip()[-500:]}")
    return json.loads(out.stdout).get("transactionHash")


# ------------------------------------------------------------------ daily cap
def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {}


def save_state(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def daily_cap_ok(amount, cap_tusd8):
    """True when today's spent + amount stays within the daily cap.
    Updates state.json on success (callers save after a paid tx)."""
    state = load_state()
    today = time.strftime("%Y-%m-%d")
    spent = state.get("spent", {}).get(today, 0) if state.get("day") == today else 0
    cap = int(float(cap_tusd8) * 10 ** TUSD8_DECIMALS)
    return spent + amount <= cap, spent, cap


def record_spent(amount):
    state = load_state()
    today = time.strftime("%Y-%m-%d")
    if state.get("day") != today:
        state = {"day": today, "spent": {today: 0}}
    state["spent"][today] = state["spent"].get(today, 0) + amount
    save_state(state)


# ------------------------------------------------------------------ decide
def decide(request, allowance, payee_allowed, judge=None):
    """Full decision without touching the chain or paying.
    judge defaults to llm_judge; tests inject a fake.
    Returns a decision dict (approved True/False + layers)."""
    policy_ok, policy_reasons = check_policy(allowance, request["payee"], request["amount"], payee_allowed)
    if not policy_ok:
        return {
            "approved": False, "stage": "policy",
            "policy": {"ok": False, "reasons": policy_reasons},
            "judgment": None, "tx_hash": None,
        }
    heuristic = heuristic_judge(request, allowance)
    if judge is None:
        risk, approve, reasons, meta = llm_judge(request, allowance, heuristic)
        # llm_judge already applied the max-risk rule; keep its verdict.
        final_risk, final_approve = risk, approve
    else:
        risk, approve, reasons, meta = judge(request, allowance, heuristic)
        # Fail closed: either layer can veto. Final risk is the max of the
        # two, and approval needs both layers plus risk < threshold.
        final_risk = max(heuristic[0], risk)
        final_approve = bool(heuristic[1] and approve and final_risk < RISK_THRESHOLD)
    return {
        "approved": bool(final_approve),
        "stage": "judgment" if not final_approve else "approved",
        "policy": {"ok": True, "reasons": []},
        "judgment": {
            "risk": final_risk, "approve": bool(final_approve), "reasons": reasons,
            "heuristic": {"score": heuristic[0], "approve": heuristic[1], "reasons": heuristic[2]},
            "meta": meta,
        },
        "tx_hash": None,
    }


def parse_amount(raw):
    """'5' or '5.25' tUSD8 -> base units (int)."""
    if isinstance(raw, int):
        return raw * 10 ** TUSD8_DECIMALS
    s = str(raw).strip()
    if "." in s:
        whole, frac = s.split(".", 1)
        frac = (frac + "000000")[:6]
        return int(whole) * 10 ** TUSD8_DECIMALS + int(frac)
    return int(s) * 10 ** TUSD8_DECIMALS


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--request", default=None, help="payment request as JSON")
    ap.add_argument("--request-file", default=None, help="file with the payment request JSON")
    ap.add_argument("--vault", default=os.environ.get("VAULT_ADDRESS", ""), help="AllowanceVault address")
    ap.add_argument("--rpc-url", default=os.environ.get("AEVUM_RPC", "http://127.0.0.1:8555"))
    ap.add_argument("--wallet", default=os.environ.get("WALLET_FILE", os.path.join(BASE_DIR, "..", "..", ".wallet.json")))
    ap.add_argument("--dry-run", action="store_true", help="decide but do not pay")
    args = ap.parse_args()

    if args.request:
        request = json.loads(args.request)
    elif args.request_file:
        with open(args.request_file) as f:
            request = json.load(f)
    else:
        ap.error("give --request or --request-file")
    if not args.vault:
        ap.error("set VAULT_ADDRESS or --vault")
    request = {
        "allowanceId": int(request["allowanceId"]),
        "task": str(request.get("task", "")),
        "payee": str(request["payee"]),
        "amount": parse_amount(request["amount"]),
    }
    if not (request["payee"].startswith("0x") and len(request["payee"]) == 42):
        ap.error("payee must be a 0x address")

    pk, agent_addr = load_wallet_key(args.wallet)
    log(f"Agent Allowance — vault {args.vault} agent {agent_addr} rpc {args.rpc_url}")

    allowance = read_allowance(args.vault, request["allowanceId"], args.rpc_url)
    if allowance["agent"].lower() != agent_addr.lower():
        print(json.dumps({"approved": False, "stage": "policy",
                          "reason": f"wallet {agent_addr} is not the allowance agent {allowance['agent']}"}))
        sys.exit(1)
    payee_allowed = is_payee(args.vault, request["allowanceId"], request["payee"], args.rpc_url)
    decision = decide(request, allowance, payee_allowed)
    decision.update({
        "ts": int(time.time()),
        "allowanceId": request["allowanceId"],
        "task": request["task"],
        "payee": request["payee"],
        "amount": request["amount"],
        "vault": args.vault,
        "agent": agent_addr,
    })

    if decision["approved"]:
        cap_ok, spent_today, cap = daily_cap_ok(request["amount"], os.environ.get("DAILY_CAP_TUSD8", "100"))
        if not cap_ok:
            decision["approved"] = False
            decision["stage"] = "daily_cap"
            decision["daily_cap"] = {"spent_today": spent_today, "cap": cap}
            log(f"REFUSED: daily cap — spent today {spent_today}, cap {cap}")
        elif args.dry_run:
            decision["stage"] = "approved_dry_run"
            log("DRY RUN: approved, not paying")
        else:
            try:
                simulate_pay(args.vault, request["allowanceId"], request["payee"],
                             request["amount"], agent_addr, args.rpc_url)
            except Exception as e:
                decision["approved"] = False
                decision["stage"] = "simulation_failed"
                decision["error"] = str(e)
                log(f"REFUSED: simulation failed ({e})")
            else:
                tx_hash = broadcast_pay(args.vault, request["allowanceId"], request["payee"],
                                        request["amount"], pk, args.rpc_url)
                decision["tx_hash"] = tx_hash
                record_spent(request["amount"])
                log(f"PAID {request['amount'] / 10**TUSD8_DECIMALS} tUSD8 to {request['payee']} tx {tx_hash}")
    else:
        log(f"REFUSED at {decision['stage']}: "
            f"{decision.get('policy', {}).get('reasons') or decision.get('judgment', {}).get('reasons')}")

    with open(DECISIONS_FILE, "a") as f:
        f.write(json.dumps(decision) + "\n")
    print(json.dumps(decision, indent=2))
    sys.exit(0 if decision["approved"] or args.dry_run else 1)


if __name__ == "__main__":
    main()
