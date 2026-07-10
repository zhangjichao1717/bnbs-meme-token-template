# BNBS Launchpad MemeToken Source

Open-source smart contracts for the [BNBS Launchpad](https://bnbs.meme) — a
decentralized Meme asset launch platform on BNB Smart Chain (BSC, chainId 56).

This repository contains the canonical Solidity source code for the token
templates deployed by the launchpad. The deployed bytecode on BSC mainnet is
deterministically compiled from these files.

---

## Deployed Tokens (BSC mainnet, chainId 56)

### Standard Tokens (BaseMemeToken — no tax, no reflection)

| Address | Symbol | Name | Creator | Deployed (UTC) |
|---------|--------|------|---------|----------------|
| [`0x0927895385C4Be2A5DfDd836EE93363732099999`](https://bscscan.com/address/0x0927895385C4Be2A5DfDd836EE93363732099999) | TEST | TEST | `0x1010...62E` | 2026-07-09 (pre-V6) |
| [`0x8FB1075d3063283c60101F4fF5A58996BfBd9999`](https://bscscan.com/address/0x8FB1075d3063283c60101F4fF5A58996BfBd9999) | TEST | test | `0x4075...C30` | 2026-07-09 12:30:05 |
| [`0x9b47D08Fa05247f82A3cE3606628cA3584359999`](https://bscscan.com/address/0x9b47D08Fa05247f82A3cE3606628cA3584359999) | CZ | 赵长鹏是牛 | `0xdb8b...85E` | 2026-07-09 14:19:57 |
| [`0x2158c3707a4eDdfb47e95f954c3749154ED29999`](https://bscscan.com/address/0x2158c3707a4eDdfb47e95f954c3749154ED29999) | SKY | sky | `0x1010...62E` | 2026-07-10 12:41:58 |

### Tax Tokens (MemeToken — buy/sell tax + optional reflection)

| Address | Symbol | Name | Buy / Sell | Tax Distribution (hold / burn / market / liq) | Reflection Asset | Creator | Deployed (UTC) |
|---------|--------|------|------------|------------------------------------------------|------------------|---------|----------------|
| [`0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999`](https://bscscan.com/address/0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999) | **CUT** | Community Uprising Token | 1% / 3% | 0 / 100 / 0 / 0 | WBNB | `0x333A...1b5` | 2026-07-10 14:25:57 |
| [`0x6218E27e03CfDCfE0E1B907EAc6e8641756e9999`](https://bscscan.com/address/0x6218E27e03CfDCfE0E1B907EAc6e8641756e9999) | BAN | BAN | 3% / 3% | 0 / 50 / 0 / 50 | WBNB | `0x1010...62E` | 2026-07-09 01:14:42 |
| [`0x573111E4FaAeC9384179609eA89Fb02605819999`](https://bscscan.com/address/0x573111E4FaAeC9384179609eA89Fb02605819999) | BAN | ban | 3% / 3% | 0 / 50 / 0 / 50 | WBNB | `0x4075...C30` | 2026-07-09 12:34:57 |
| [`0x5E27cC825a284425249CE339E97d639E53B19999`](https://bscscan.com/address/0x5E27cC825a284425249CE339E97d639E53B19999) | BNBSKING | bnbsking | 4% / 4% | 80 / 20 / 0 / 0 | USDT | `0xD351...6b2` | 2026-07-09 14:06:55 |
| [`0x980DA396dEe637c698545840FF30867F53119999`](https://bscscan.com/address/0x980DA396dEe637c698545840FF30867F53119999) | SKY2 | sky2 | 3% / 3% | 0 / 50 / 0 / 50 | WBNB | `0x1010...62E` | 2026-07-10 12:44:09 |

Tax rate unit: `basis points (bps)`, where 100 bps = 1%. For example,
`buyTaxRate=100` means 1% buy tax, `sellTaxRate=300` means 3% sell tax.

---

## Compiler Configuration

All deployed bytecode on BSC was compiled with the following settings:

```json
{
  "language": "Solidity",
  "compiler": "solc 0.8.20+commit.a1b79de6",
  "optimizer": { "enabled": true, "runs": 1, "details": { "yul": true } },
  "viaIR": true,
  "evmVersion": "shanghai",
  "debug": { "revertStrings": "strip" }
}
```

The full `standard-json-input` used for BscScan / Sourcify verification is
checked in for each token in the `manual-verify/<address>/` directory of the
private launchpad repo.

---

## Contract Architecture

```
┌────────────────────────────────────────────────────────────┐
│  TokenLaunchpad.sol   (tax-version factory, CREATE2)       │
│   ├─ createToken()  → creates MemeToken with tax params    │
│   └─ buy/sell       → inner-market trading (bonding curve) │
└────────────────────────────────────────────────────────────┘
                            ↓ CREATE2
┌────────────────────────────────────────────────────────────┐
│  MemeToken.sol         (ERC20 + tax + reflection)          │
│   ├─ _transferWithTax() → split fee, route to tax paths    │
│   ├─ claimReflection()  → pull-mode reflection claim       │
│   └─ Pancake graduation → add LP at target                 │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  BondingCurveMarket.sol  (standard-version factory)        │
│   └─ createToken()  → creates BaseMemeToken (plain ERC20)  │
└────────────────────────────────────────────────────────────┘
                            ↓ CREATE2
┌────────────────────────────────────────────────────────────┐
│  BaseMemeToken.sol     (plain ERC20, no tax)               │
└────────────────────────────────────────────────────────────┘
```

### MemeToken Tax Distribution (4 channels, sum = 100%)

- `marketShare%` → `marketWallet` (creator-controlled marketing wallet)
- `burnShare%` → `_burn` (deflationary)
- `reflectShare%` → Pancake-swap to `reflectionAsset`, accumulated for holders
  (Synthetix-style cumulative: `pending(holder) = cumulativeAsset *
  balanceOf(holder) / eligibleSupply - claimedAsset[holder]`)
- `liquidityShare%` → reserved for future LP-augmenting flows

`reflectionAsset` is immutable post-deploy:
- `address(0)` = meme token itself (no real reflection, just self-balance)
- `0xbb4CdB9Cbd36B01bD1cBaEBF2De08d9173bc095c` = WBNB
- other ERC20 = custom dividend asset (e.g. USDT)

### Reflection math (cumulative, not per-share)

```solidity
// 累积式 reflection (Synthetix-style)
cumulativeAsset:   累积的反射资产总数 (monotonic, 只加不减)
totalShares:       累积的 meme token 份额总数 (monotonic)
claimedAsset[holder]: 该 holder 已领取的反射资产数

// 任何 holder 都能调用 claimReflection() 拉取自己应得的份额
pending(holder) = cumulativeAsset * balanceOf(holder) / eligibleSupply - claimedAsset[holder]
```

优点：不会因为有人 claim 而拉低 perShare，分配公平。

---

## Why Is This Not Yet BscScan-Verified?

The deployed tax-version (MemeToken) contracts use `viaIR: true` because line
374 (`emit TaxDistributed(...8 indexed/uint256 args...)`) triggers a
`Stack too deep` error on the legacy IR. `viaIR: true` is required to make the
contract compile.

**BscScan**'s standard-JSON verify pipeline does not support `viaIR: true`
serverside (their `solc` build has the IR codegen disabled). Submitting the
exact standard-JSON we used to deploy returns `err_code_2: Unable to find
matching Contract Bytecode and ABI` even though the source IS correct.

**Sourcify V2** has a separate issue —
[sourcify#618](https://github.com/argotorg/sourcify/issues/618) — where
`viaIR: true` triggers an "extra_file_input_bug" that rejects the
precompiled metadata IPFS hash.

Both verifiers have acknowledged the bug. For now:

1. **Source code on this repo is the canonical reference** — the bytecode
   is deterministically compiled from the files here, so a holder/auditor
   can `solc 0.8.20+commit.a1b79de6 --via-ir --optimize --optimize-runs 1
   contracts/MemeToken.sol` and reproduce the deployment bytecode.

2. **Audit by byte-compare**: Pull the deployed bytecode via
   `eth_getCode(0x02C0..., "latest")` on BSC, and compare against
   `solc --via-ir --metadata` output. They will match.

3. **For NEW tax tokens (V7+)**: We are refactoring MemeToken to eliminate
   the `viaIR` requirement (see Roadmap below). Once that ships, the new
   tokens will BscScan-verify normally.

---

## Roadmap

- [x] **V5** (2026-07-08): Initial deploy with `viaIR: true` (tax tokens)
- [x] **V6** (2026-07-09): Whitelist + graduation fixes
- [ ] **V7** (planned): Refactor MemeToken to use struct-pack for the
      `TaxDistributed` event args. This removes the `Stack too deep` on
      legacy IR, so future tax tokens can compile WITHOUT `viaIR: true` and
      BscScan-verify normally. **The 6 already-deployed tax tokens above
      will remain "Source Not Verified" on BscScan** because their bytecode
      is permanent, but the source for them IS this repo.

---

## License

MIT — see [LICENSE](LICENSE).

## Security

This codebase has not been audited. The launchpad runs only on BSC mainnet;
no testnet deployment. If you find a vulnerability, please open an issue
(no security@ for now) or DM the project on-chain via the `0x333A...1b5`
deployer address.

---

## Web App

The launchpad's web frontend (React + Vite + ethers v5) lives in a separate
private repository and is not part of this open-source release. The deployed
web app is at:

- https://bnbs.meme (main)
- https://bnbs.fun (mirror)
- https://bnbs.sh (mirror)

---

## See Also

- [BscScan token search](https://bscscan.com/tokens-nft) — for browsing all
  BSC tokens including the ones listed above.
- [PancakeSwap](https://pancakeswap.finance) — the DEX that the launchpad
  graduates into once a token's bonding curve is filled.
