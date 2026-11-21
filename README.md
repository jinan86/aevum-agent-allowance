# Agent Allowance

A human sets an on-chain allowance for an AI agent in tUSD8 — total cap,
per-payment cap, expiry, and an allowlist of payees. The agent pays for
tasks and API calls only inside those limits; the owner can revoke instantly
and the unspent remainder comes straight back. Every payment and revocation
is an on-chain event, so the full spend history is an audit trail.

**Track:** Native AI Assistants — Aevum Builder Challenge #1 (QDay, DoraHacks).
**This is not an invoice app.** There are no invoices, no order ids, no
merchants here: the owner sets a spending policy, the agent spends inside it.
(Deliberately different from PayReceipt-style invoice payments.)

> **Status — Fase 1:** contract + tests on a local fork. The web UI, the
> off-chain agent, and the relayer come in later phases.
>
> **Alamat testnet:** menyusul (Fase 2: deploy testnet).

Built on the [Aevum Starter Kit](https://github.com/qday-io/aevum-starter-kit)
(MIT, © 2026 PQA Labs) — its chain config, `packages/aevum` helpers, fork
tooling, and `MockUSD8` are reused; `AllowanceVault.sol` is new work for
this entry. The kit's example `Checkout.sol` (pay-per-order) is kept as a
reference and is not used by Agent Allowance.

---

## Contents

- [How it works](#how-it-works)
- [Quickstart (5 minutes, no funds needed)](#quickstart-5-minutes-no-funds-needed)
- [Network details](#network-details)
- [Get test tokens](#get-test-tokens)
- [Deploy to Aevum testnet (Fase 2)](#deploy-to-aevum-testnet-fase-2)
- [Things that differ from Ethereum](#things-that-differ-from-ethereum)
- [Project layout](#project-layout)
- [Commands](#commands)
- [Submitting your project](#submitting-your-project)
- [FAQ](#faq)

---

## How it works

`AllowanceVault` (`contracts/src/AllowanceVault.sol`) takes one token
(tUSD8) at deploy time. One allowance, one agent:

```
owner ── approve(Vault, totalCap) ──▶ tUSD8
owner ── createAllowance(agent, totalCap, perPaymentCap, expiry, payees) ──▶ Vault
         Vault ── transferFrom ──▶ holds totalCap in escrow
agent ── pay(allowanceId, payee, amount) ──▶ Vault ── transfer ──▶ payee
         only if: caller is the allowance's agent, not revoked,
         block.timestamp <= expiry, amount > 0,
         amount <= perPaymentCap, spent + amount <= totalCap,
         payee is on the allowlist
owner ── revoke(allowanceId) ──▶ Vault ── transfer(totalCap - spent) ──▶ owner
         permanent: pay after revoke always reverts
```

Events (the audit trail): `AllowanceCreated(allowanceId, owner, agent,
totalCap, perPaymentCap, expiry)`, `AllowancePaid(allowanceId, payee,
amount, spentTotal)`, `AllowanceRevoked(allowanceId, refunded)`.

Views: `allowanceOf(id)` returns owner, agent, totalCap, perPaymentCap,
expiry, spent, revoked; `isPayee(id, payee)` checks the allowlist;
`remaining(id)` returns the unspent remainder (0 once revoked).

Design choices:

- The vault is funded **up front** at creation, so the agent can only ever
  spend money that is already escrowed — it can never overdraw the owner.
- One agent per allowance, one allowlist per allowance; different
  allowances are fully independent (separate caps, agents, payees).
- The contract never decides whether a payment is a good idea. The
  off-chain agent (later phase) judges each request — task, payee, amount —
  against the on-chain policy and an LLM verdict before calling `pay`.
  A dead LLM means no payment, never a wrong payment (fail closed).
- Shanghai-safe: compiled with `evm_version = "shanghai"`, no Cancun
  opcodes, no OpenZeppelin `*Transient` contracts. `make build` runs
  [`tools/check-shanghai.mjs`](tools/check-shanghai.mjs) to catch it.

Code to read, in order:

1. [`contracts/src/AllowanceVault.sol`](contracts/src/AllowanceVault.sol):
   the allowance contract
2. [`contracts/test/AllowanceVault.t.sol`](contracts/test/AllowanceVault.t.sol):
   unit tests — happy path, every revert path, revoke refund, independence
3. [`contracts/test/fork/AllowanceVaultFork.t.sol`](contracts/test/fork/AllowanceVaultFork.t.sol):
   the same flow end-to-end against the real tUSD8 on a local fork
4. [`contracts/src/Checkout.sol`](contracts/src/Checkout.sol): the kit's
   example contract (reference only, not used by Agent Allowance)

---

## Quickstart (5 minutes, no funds needed)

You need [Node 22+](https://nodejs.org), [pnpm](https://pnpm.io/installation) and [Foundry](https://book.getfoundry.sh/getting-started/installation) (`foundryup`).

```bash
git clone --recursive <this repo>
cd agent-allowance
make install          # Solidity libs + JS packages
make check            # build, Shanghai opcode check, unit tests, fork tests, typecheck
```

Run the whole app against a **local copy of Aevum**, with the real tUSD8 and free test balances:

```bash
# terminal 1: local copy of Aevum testnet on 127.0.0.1:8555 (chain 440050)
make fork

# terminal 2: deploy to the fork and give yourself test money
make deploy-fork                      # prints the Checkout address (kit example)
make deal TO=<your wallet address>    # 100 tUSD8 + 10 tQDAY, on the fork only

cp web/.env.example web/.env.local
#   NEXT_PUBLIC_NETWORKS=fork,aevum
make dev                              # http://localhost:3000
```

Use the **Local fork / Aevum testnet** switcher in the app's header. The first time you pick the fork, your wallet offers to add "Aevum fork (local)" as a new network; after that, switching is one click and your real testnet network stays untouched.

**Why the fork has its own chain ID (440050):** it copies Aevum's state (accounts, balances, tUSD8) but anything you sign there, such as an EIP-3009 authorization or a permit, can't be replayed on the real testnet, and wallets never mix the two up. `make deploy-fork` also deploys from a random address nobody has the key to, so its contract addresses can't be claimed on the real testnet.

Want an empty chain instead of a fork? `make anvil` + `make deploy-local` deploys a `MockUSD8` (same decimals, EIP-712 domain and EIP-3009 functions as tUSD8) that anyone can mint with `make mint`.

> **Fase 1 scope:** only the contract and its tests are Agent Allowance
> so far. `make deploy-fork` / `make deploy-local` still deploy the kit's
> `Checkout` (see [`contracts/script/Deploy.s.sol`](contracts/script/Deploy.s.sol));
> an `AllowanceVault` deploy script lands in Fase 2 with the testnet deploy.

---

## Network details

| | |
|---|---|
| Network | QDay Aevum Testnet |
| Chain ID | `44005` |
| RPC | `https://rpc-test.qday.info` (HTTPS only, no WebSocket) |
| Explorer | https://explorer-test.qday.info |
| Gas token | tQDAY (18 decimals) |
| Gas price | about 1 gwei. 1 tQDAY covers hundreds of contract calls. |
| EVM version | **Shanghai** |
| tUSD8 | [`0x456569838f1d43009A91ebA4263147Afd7233483`](https://explorer-test.qday.info/address/0x456569838f1d43009A91ebA4263147Afd7233483), 6 decimals, USDC-style (EIP-2612 `permit`, EIP-3009 signed transfers), EIP-712 domain `name: "tUSD8"`, `version: "2"` |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |

All of this is in [`packages/aevum/src/chain.ts`](packages/aevum/src/chain.ts) and [`contracts.ts`](packages/aevum/src/contracts.ts).

### Alamat testnet

Menyusul (Fase 2: deploy testnet). Fase 1 runs only on a local fork / anvil — no contract has been deployed to Aevum testnet yet.

---

## Get test tokens

- **Discord faucet (for Builder Challenge participants):** join the [QDay Discord](https://discord.gg/bYPhjmrSfK), react ✅ in `#verify`, then run `/faucet <your address>`. You get **1 tQDAY + 5 tUSD8**, once per Discord account and once per address. No Ethereum mainnet balance needed.
- **Web faucet:** https://faucet.qday.info. Check the page for its rules.
- **Local fork:** `make deal TO=<address>` for unlimited test balances. Nothing leaves your machine.

1 tQDAY is plenty for development: deploying `AllowanceVault` costs well under 0.01 tQDAY.

---

## Deploy to Aevum testnet (Fase 2)

> Not done yet — Fase 1 is local fork only. This section documents the
> intended flow; do not run it until the Fase 2 deploy script exists.

Keep your deployer key out of files and shell history. Foundry's encrypted keystore asks for the key once and a password each time:

```bash
cast wallet import aevum-deployer --interactive   # paste the key of a TEST wallet
cast wallet address --account aevum-deployer      # fund this address from the faucet

# Fase 2: deploy AllowanceVault (real tUSD8) — command to be added with the deploy script
```

Then set the vault address in `web/.env.local` and add `aevum` to `NEXT_PUBLIC_NETWORKS`.

**Contract verification:** the explorer's verifier isn't working yet, so `forge verify-contract` will fail for now. Put your contract addresses and a link to the source (the exact commit) in your README and submission instead. The command, for when it's back:

```bash
forge verify-contract <address> src/AllowanceVault.sol:AllowanceVault --chain-id 44005 \
  --verifier blockscout --verifier-url https://explorer-test.qday.info/api/
```

> Use a wallet made only for testing. Never paste a private key into chat, an issue, or a committed file.

---

## Things that differ from Ethereum

| | What happens | What to do |
|---|---|---|
| **Shanghai EVM** | Cancun opcodes (`MCOPY`, `TSTORE`/`TLOAD`, blob ops) don't exist. Code compiled for Cancun deploys fine, then reverts with `invalid opcode`. | Keep `evm_version = "shanghai"` in `foundry.toml` (already set). `make build` runs [`tools/check-shanghai.mjs`](tools/check-shanghai.mjs) to catch it. Don't use OpenZeppelin's `*Transient` contracts. |
| **anvil hides it** | A plain `anvil --fork-url` runs Cancun, so bad bytecode passes local tests. | Always add `--hardfork shanghai` (the Makefile does). |
| **1,000-block log limit** | `eth_getLogs` over more than 1,000 blocks fails. | Use `getLogsChunked` from `@aevum-kit/aevum`. Store your deploy block and start from there. |
| **No WebSocket RPC** | `watchContractEvent` over WS won't connect. | Poll over HTTPS (viem's default for `http()` transports). |
| **Explorer verification** | Not working yet. | See [Deploy](#deploy-to-aevum-testnet-fase-2). |
| **Legacy transactions** | The kit's scripts and relayer send legacy (type 0) transactions, the same as QDay's own faucet. | `--legacy` in `forge script`, `type: "legacy"` in viem. |

---

## Project layout

```
contracts/            Foundry project
  src/AllowanceVault.sol  the allowance contract (this entry)
  src/Checkout.sol        the kit's example contract (reference only)
  src/mocks/MockUSD8.sol  local tUSD8 stand-in (anyone can mint)
  test/                   unit tests + test/fork (real tUSD8 on a fork)
  script/Deploy.s.sol     deploys to anvil, a fork or Aevum (kit Checkout for now)
packages/aevum/       chain config, ABIs, EIP-3009 typed data, getLogsChunked
web/                  Next.js app (wagmi + RainbowKit) — kit checkout UI for now;
                      Agent Allowance UI lands in a later phase
  src/app/page.tsx        Setup check
  src/app/checkout/       standard + gasless checkout (kit example)
  src/app/receipts/       receipt read from the chain
  src/app/activity/       Paid events, read in 1,000-block chunks
  src/app/api/relay/      gasless relayer (server-side)
  src/app/globals.css     every color and font; edit to rebrand
examples/             runnable TypeScript scripts (kit)
tools/check-shanghai.mjs  fails the build on Cancun-only opcodes
LICENSE, NOTICE.md     MIT license and third-party licenses
```

---

## Commands

```
make install        Fetch Solidity libs and JS packages
make build          Compile contracts and check they are Shanghai-safe
make test           Unit tests (local, no network)
make test-fork      Tests against the real tUSD8 on a local fork of Aevum
make check          Build, tests and typecheck (CI also runs pnpm build)
make anvil          Empty local chain (31337) with Aevum's EVM rules
make fork           Local copy of Aevum testnet on 127.0.0.1:8555 (chain 440050)
make deploy-local   Deploy MockUSD8 + Checkout to `make anvil`
make deploy-fork    Deploy Checkout (real tUSD8) to `make fork`
make deploy-aevum   Deploy Checkout to Aevum testnet (ACCOUNT=<keystore>)
make mint           `make anvil` only: mint MockUSD8 (TO=, CHECKOUT=, AMOUNT=)
make deal           `make fork` only: give TO tUSD8 and tQDAY
make dev            Start the web app on http://localhost:3000
```

Examples (copy `examples/.env.example` to `examples/.env` first):

```bash
pnpm example check-setup      # chain, block, gas price and balances of ADDRESS
pnpm example pay-gasless      # BUYER_KEY signs, RELAYER_KEY submits
pnpm example read-payments    # every Paid event, 1,000 blocks at a time
```

---

## Submitting your project

Make it easy for judges to check your on-chain activity:

- Contract addresses on Aevum testnet (`44005`), with explorer links.
- A link to the exact commit you deployed.
- A few transaction hashes that show your app working (the receipt page and the activity page show them).
- A short demo video or a live URL.

Read the official rules on the DoraHacks challenge page. They win over anything here.

### Licenses and credit

The organizers confirmed that boilerplate, scaffolding and templates are allowed, as long as their license permits the use. This kit is MIT licensed, so you can build on it.

- Put a permissive open-source license on your repo, usually MIT or Apache 2.0.
- If you start from this kit, keep its `LICENSE` file (or its copyright notice) and say so in your README, for example: "Based on Aevum Starter Kit (MIT, PQA Labs)".
- Keep the original copyright and license headers in any file you copy from another project.
- Put a short comment above any code snippet you borrow, naming the source repo, author and license.
- List your third-party dependencies and their licenses in your README or a `NOTICE` file. [NOTICE.md](NOTICE.md) shows one way to do it.
- If you copy a whole directory or library, keep its original `LICENSE` file in that folder.

---

## FAQ

**Is this an invoice app?** No. Agent Allowance has no invoices, no order ids, no merchants. An owner funds a capped, expiring, allowlisted spending policy for one agent address; the agent pays inside it and the owner can revoke at any time.

**Do I have to use `Checkout`?** No. It's the kit's example. Agent Allowance replaces it with `AllowanceVault`; the kit's plumbing (`packages/aevum`, the chunked log reader, the setup checker) is kept.

**Can I use account abstraction?** It isn't required for this challenge, and there's no officially supported bundler or paymaster. A normal wallet plus tUSD8 payments is enough. For budgets, limits, expiry and revoke, write them into your own contract — that's what `AllowanceVault` does. You can deploy your own ERC-4337 setup if you want to, but the team won't support or debug it.

**Can I use Hardhat?** Yes. Set `evmVersion: "shanghai"` in the Solidity settings, and `hardfork: "shanghai"` for the Hardhat network.

**My transaction fails with `invalid opcode`.** You compiled for Cancun. See [Things that differ from Ethereum](#things-that-differ-from-ethereum).

**`eth_getLogs` errors on a big range.** Split it into 1,000-block chunks with `getLogsChunked`.

**Where do I ask for help?** In the [QDay Discord](https://discord.gg/bYPhjmrSfK)'s Builder Challenge channels (verify first to see them), Monday to Friday, 10:00 to 18:00 HKT.

**`pnpm audit` reports high advisories in `zod` and `decode-uri-component`.** Both come in through WalletConnect (`@reown/appkit-wallet` pins `zod` 3.22.4; `@walletconnect/utils` 2.21 uses `query-string`). They run only in the browser, are only reached when you set `NEXT_PUBLIC_WC_PROJECT_ID`, and at worst slow down the user's own tab. The relay route doesn't load them. The fix is upstream: RainbowKit moving to wagmi 3 brings WalletConnect 2.26, which drops `query-string`. Forcing newer versions with `pnpm.overrides` swaps in major versions WalletConnect wasn't tested with, so the kit doesn't.

---

MIT licensed, © 2026 PQA Labs (starter kit) — see [LICENSE](LICENSE). Third-party licenses are listed in [NOTICE.md](NOTICE.md). `AllowanceVault.sol` and its tests are new work for this entry, also MIT.
