"use client";

import { addressUrl, allowanceVaultAbi, erc20Abi, getLogsChunked, txUrl } from "@aevum-kit/aevum";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { formatUnits, getAbiItem, isAddress, parseUnits, type Address, type PublicClient } from "viem";
import { useAccount, useConfig, usePublicClient } from "wagmi";
import { readContract, simulateContract, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { useToken } from "@/components/useToken";
import { useNetwork } from "@/lib/network";
import { explain } from "@/lib/errors";
import { short } from "@/lib/order";

type Phase = "idle" | "working" | "done" | "error";

const WINDOWS = [
  { blocks: 1_000n, label: "Last 1k blocks" },
  { blocks: 5_000n, label: "Last 5k blocks" },
  { blocks: 20_000n, label: "Last 20k blocks" },
];

export default function AllowancePage() {
  const { net } = useNetwork();
  const appChain = net.chain;
  const vaultAddress = net.vault;
  const deployBlock = net.deployBlock;
  const hasExplorer = net.hasExplorer;
  const client = usePublicClient({ chainId: appChain.id }) as PublicClient | undefined;
  const config = useConfig();
  const { address } = useAccount();
  const token = useToken();

  // ---- create form ----
  const [agent, setAgent] = useState("");
  const [totalCap, setTotalCap] = useState("100");
  const [perPaymentCap, setPerPaymentCap] = useState("30");
  const [expiryDays, setExpiryDays] = useState("7");
  const [payees, setPayees] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [status, setStatus] = useState("");
  const [createdId, setCreatedId] = useState<bigint | null>(null);

  // ---- lookup / revoke ----
  const [lookupId, setLookupId] = useState("1");
  const [revokePhase, setRevokePhase] = useState<Phase>("idle");
  const [revokeStatus, setRevokeStatus] = useState("");

  const [windowSize, setWindowSize] = useState(5_000n);
  const [progress, setProgress] = useState(0);

  const allowance = useQuery({
    queryKey: ["allowance", appChain.id, vaultAddress, lookupId],
    enabled: Boolean(client && vaultAddress && /^\d+$/.test(lookupId)),
    queryFn: async () => {
      const id = BigInt(lookupId);
      const [a, remaining] = await Promise.all([
        client!.readContract({ address: vaultAddress!, abi: allowanceVaultAbi, functionName: "allowanceOf", args: [id] }),
        client!.readContract({ address: vaultAddress!, abi: allowanceVaultAbi, functionName: "remaining", args: [id] }),
      ]);
      return { id, ...a, remaining };
    },
  });

  const logs = useQuery({
    queryKey: ["allowance-paid-logs", appChain.id, vaultAddress, windowSize.toString()],
    enabled: Boolean(client && vaultAddress),
    queryFn: async () => {
      const head = await client!.getBlockNumber();
      let from = head > windowSize ? head - windowSize + 1n : 0n;
      if (deployBlock !== undefined && deployBlock > from) from = deployBlock;
      setProgress(0);
      const result = await getLogsChunked(client!, {
        address: vaultAddress!,
        event: getAbiItem({ abi: allowanceVaultAbi, name: "AllowancePaid" }),
        fromBlock: from,
        toBlock: head,
        onProgress: (done, total) => setProgress(total ? Number((done * 100n) / total) : 100),
      });
      return { from, head, items: [...result].reverse() };
    },
  });

  async function onCreate() {
    if (!address || !vaultAddress || !token.address) return;
    if (!isAddress(agent)) return setStatus("Agent address is not a valid 0x address."), setPhase("error");
    const payeeList = payees.split(/[\s,]+/).filter(Boolean);
    if (payeeList.some((p) => !isAddress(p))) return setStatus("One of the payees is not a valid 0x address."), setPhase("error");
    if (payeeList.length === 0) return setStatus("Add at least one payee."), setPhase("error");
    let total: bigint, per: bigint;
    try {
      total = parseUnits(totalCap, token.decimals);
      per = parseUnits(perPaymentCap, token.decimals);
    } catch {
      return setStatus("Caps must be numbers."), setPhase("error");
    }
    if (per > total) return setStatus("Per-payment cap cannot exceed the total cap."), setPhase("error");
    const expiry = BigInt(Math.floor(Date.now() / 1000) + Number(expiryDays) * 86_400);
    setPhase("working");
    try {
      setStatus("Step 1/2: approving the vault to pull the total cap…");
      const approveHash = await writeContract(config, {
        address: token.address, abi: erc20Abi, functionName: "approve",
        args: [vaultAddress, total], chainId: appChain.id,
      });
      await waitForTransactionReceipt(config, { hash: approveHash, chainId: appChain.id });
      setStatus("Step 2/2: creating the allowance…");
      const { request, result } = await simulateContract(config, {
        account: address, address: vaultAddress, abi: allowanceVaultAbi,
        functionName: "createAllowance",
        args: [agent as Address, total, per, expiry, payeeList as Address[]],
        chainId: appChain.id,
      });
      const hash = await writeContract(config, request);
      await waitForTransactionReceipt(config, { hash, chainId: appChain.id });
      setCreatedId(result);
      setPhase("done");
      setStatus(`Allowance #${result} created. The vault now holds ${totalCap} ${token.symbol} for this agent.`);
      void allowance.refetch();
      void logs.refetch();
    } catch (e) {
      setPhase("error");
      setStatus(explain(e));
    }
  }

  async function onRevoke() {
    if (!address || !vaultAddress || !/^\d+$/.test(lookupId)) return;
    setRevokePhase("working");
    try {
      const { request } = await simulateContract(config, {
        account: address, address: vaultAddress, abi: allowanceVaultAbi,
        functionName: "revoke", args: [BigInt(lookupId)], chainId: appChain.id,
      });
      const hash = await writeContract(config, request);
      await waitForTransactionReceipt(config, { hash, chainId: appChain.id });
      setRevokePhase("done");
      setRevokeStatus(`Allowance #${lookupId} revoked — the unspent remainder went back to the owner.`);
      void allowance.refetch();
    } catch (e) {
      setRevokePhase("error");
      setRevokeStatus(explain(e));
    }
  }

  const totalPaid = logs.data?.items.reduce((sum, l) => sum + (l.args.amount ?? 0n), 0n) ?? 0n;
  const a = allowance.data;
  const isOwner = a && address && a.owner.toLowerCase() === address.toLowerCase();

  return (
    <main className="shell">
      <div className="page-head">
        <div>
          <p className="eyebrow">Agent Allowance · Native AI Assistants</p>
          <h1>Agent allowance</h1>
          <p className="lede">
            Set an on-chain spending policy for an AI agent in {token.symbol}: a total cap, a per-payment cap,
            an expiry, and an allowlist of payees. The agent pays only inside those limits, and you can
            revoke instantly — the unspent remainder comes straight back. Every payment is an{" "}
            <code>AllowancePaid</code> event, so the history below is the audit trail.
          </p>
        </div>
        {logs.data && (
          <div className="score">
            <span className="score-num">{logs.data.items.length}</span>
            <span className="fine">
              payments · {formatUnits(totalPaid, token.decimals)} {token.symbol}
            </span>
          </div>
        )}
      </div>

      {!vaultAddress ? (
        <div className="card empty">
          No AllowanceVault configured for {net.label}. Set{" "}
          <code>NEXT_PUBLIC_VAULT_{net.key.toUpperCase()}</code> in <code>web/.env.local</code>.
        </div>
      ) : (
        <>
          <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "stretch" }}>
            <section className="card stack" aria-label="Create allowance" style={{ flex: "1 1 340px" }}>
              <h2>Create an allowance</h2>
              <p className="sub">You approve the vault for the total cap, then fund it in one transaction.</p>
              <label className="fine" htmlFor="agent">Agent address</label>
              <input id="agent" className="field" placeholder="0x…" value={agent} onChange={(e) => setAgent(e.target.value)} />
              <label className="fine" htmlFor="total">Total cap ({token.symbol})</label>
              <input id="total" className="field" inputMode="decimal" value={totalCap} onChange={(e) => setTotalCap(e.target.value)} />
              <label className="fine" htmlFor="per">Per-payment cap ({token.symbol})</label>
              <input id="per" className="field" inputMode="decimal" value={perPaymentCap} onChange={(e) => setPerPaymentCap(e.target.value)} />
              <label className="fine" htmlFor="expiry">Expires in (days)</label>
              <input id="expiry" className="field" inputMode="numeric" value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)} />
              <label className="fine" htmlFor="payees">Allowed payees (comma-separated addresses)</label>
              <input id="payees" className="field" placeholder="0x…, 0x…" value={payees} onChange={(e) => setPayees(e.target.value)} />
              <button type="button" className="btn big block" disabled={!address || phase === "working"} onClick={onCreate}>
                {phase === "working" ? "Creating…" : address ? "Approve + create allowance" : "Connect a wallet first"}
              </button>
              {status && <p className="fine" style={{ color: phase === "error" ? "var(--warn)" : undefined }}>{status}</p>}
              {createdId !== null && hasExplorer && (
                <p className="fine">Vault: <a href={addressUrl(vaultAddress)} target="_blank" rel="noreferrer">{short(vaultAddress)}</a></p>
              )}
            </section>

            <section className="card stack" aria-label="Allowance lookup" style={{ flex: "1 1 340px" }}>
              <h2>Look up &amp; revoke</h2>
              <p className="sub">Read any allowance by id. Only its owner can revoke it.</p>
              <label className="fine" htmlFor="lookup">Allowance id</label>
              <input id="lookup" className="field" inputMode="numeric" value={lookupId} onChange={(e) => setLookupId(e.target.value)} />
              {a && (
                <ul>
                  <li>Owner: {short(a.owner)}{isOwner ? " (you)" : ""}</li>
                  <li>Agent: {short(a.agent)}</li>
                  <li>Total cap: {formatUnits(a.totalCap, token.decimals)} {token.symbol}</li>
                  <li>Per-payment cap: {formatUnits(a.perPaymentCap, token.decimals)} {token.symbol}</li>
                  <li>Spent: {formatUnits(a.spent, token.decimals)} · Remaining: {formatUnits(a.remaining, token.decimals)} {token.symbol}</li>
                  <li>Expiry: {new Date(Number(a.expiry) * 1000).toLocaleString()}</li>
                  <li>Status: {a.revoked ? "revoked" : "active"}</li>
                </ul>
              )}
              {allowance.isError && <p className="fine">No allowance #{lookupId} on this vault (yet).</p>}
              <button type="button" className="btn warn block" disabled={!address || !isOwner || a?.revoked || revokePhase === "working"} onClick={onRevoke}>
                {revokePhase === "working" ? "Revoking…" : "Revoke allowance (refund remainder)"}
              </button>
              {revokeStatus && <p className="fine" style={{ color: revokePhase === "error" ? "var(--warn)" : undefined }}>{revokeStatus}</p>}
            </section>
          </div>

          <section className="card flush" style={{ marginTop: 16 }}>
            <div style={{ display: "flex", justifyContent: "space-between", padding: "18px 22px 0", flexWrap: "wrap", gap: 8 }}>
              <h2>Payments — live from AllowancePaid events</h2>
              <div style={{ display: "flex", gap: 8 }}>
                {WINDOWS.map((w) => (
                  <button key={w.label} type="button" className={`btn small ${windowSize === w.blocks ? "" : "ghost"}`} onClick={() => setWindowSize(w.blocks)}>
                    {w.label}
                  </button>
                ))}
              </div>
            </div>
            {logs.isPending ? (
              <p className="fine" style={{ padding: "18px 22px" }}>Reading events in ≤1,000-block chunks… {progress}%</p>
            ) : logs.isError ? (
              <p className="fine" style={{ padding: "18px 22px" }}>Could not read events: {explain(logs.error)}</p>
            ) : logs.data!.items.length === 0 ? (
              <p className="fine" style={{ padding: "18px 22px" }}>No payments in this window yet. Create an allowance and let the agent pay.</p>
            ) : (
              <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead>
                  <tr style={{ textAlign: "left" }}>
                    <th style={{ padding: "12px 22px" }}>Allowance</th>
                    <th>Payee</th>
                    <th>Amount</th>
                    <th>Spent total</th>
                    <th>Tx</th>
                  </tr>
                </thead>
                <tbody>
                  {logs.data!.items.map((l) => (
                    <tr key={`${l.transactionHash}-${l.logIndex}`} style={{ borderTop: "1px solid var(--line)" }}>
                      <td style={{ padding: "10px 22px" }}>#{l.args.allowanceId?.toString()}</td>
                      <td>{short(l.args.payee ?? "")}</td>
                      <td>{formatUnits(l.args.amount ?? 0n, token.decimals)} {token.symbol}</td>
                      <td>{formatUnits(l.args.spentTotal ?? 0n, token.decimals)} {token.symbol}</td>
                      <td>{hasExplorer ? <a href={txUrl(l.transactionHash)} target="_blank" rel="noreferrer">tx ↗</a> : <span className="fine">{short(l.transactionHash)}</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
        </>
      )}
    </main>
  );
}
