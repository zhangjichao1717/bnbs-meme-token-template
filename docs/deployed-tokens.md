# Deployed Tokens — Detailed Index

This is the canonical on-chain index for tokens deployed via the BNBS Launchpad
on BSC mainnet. The data is queried via `/api/tokens-list` on the launchpad's
web server (which reads from a local chain index, refreshed on every new
event).

All addresses are checksummed EIP-55 format. Click any address to view on
BscScan.

---

## Standard Tokens (BaseMemeToken)

### `0x0927895385C4Be2A5DfDd836EE93363732099999` — TEST

- **Type**: Standard (no tax, no reflection)
- **Source**: `contracts/BaseMemeToken.sol`
- **Creator**: `0x1010f290AF962c26f1a744E010845E45A447962E`
- **Deployed**: V5 era, exact block timestamp not in current index
- **Funding goal**: 1.6 BNB
- **Initial price**: 4.9999999984375e-10 BNB
- **State**: Bonding (not yet graduated)
- **BscScan**: <https://bscscan.com/address/0x0927895385C4Be2A5DfDd836EE93363732099999>

### `0x8FB1075d3063283c60101F4fF5A58996BfBd9999` — TEST

- **Type**: Standard (V6 launchpad)
- **Source**: `contracts/BaseMemeToken.sol` (deployed via `BondingCurveMarket.sol`)
- **Launchpad**: `0x03de191d75bafd96124ff87a39e6e0d035964bbe` (V6 BCM, 2026-07-09)
- **Creator**: `0x4075C1Ba34Cc6fF7beA78ee855Ed0c656ACaDC30`
- **Deployed**: 2026-07-09 12:30:05 UTC
- **Funding goal**: 1.0 BNB
- **State**: Bonding, ~zero activity
- **BscScan**: <https://bscscan.com/address/0x8FB1075d3063283c60101F4fF5A58996BfBd9999>

### `0x9b47D08Fa05247f82A3cE3606628cA3584359999` — CZ ("赵长鹏是牛")

- **Type**: Standard (V6 launchpad)
- **Launchpad**: `0x03de191d75bafd96124ff87a39e6e0d035964bbe` (V6 BCM)
- **Creator**: `0xdb8b99c2c7e61cb7DB769AE48907Ceb86D7FB85E`
- **Deployed**: 2026-07-09 14:19:57 UTC
- **Funding goal**: 1.0 BNB
- **Progress**: 0.30% raised (0.002985 BNB)
- **Description**: "cz是牛" (CZ is awesome)
- **Twitter / Website**: `https://x.com/cz_binance`
- **State**: Bonding
- **BscScan**: <https://bscscan.com/address/0x9b47D08Fa05247f82A3cE3606628cA3584359999>

### `0x2158c3707a4eDdfb47e95f954c3749154ED29999` — SKY

- **Type**: Standard (V6 launchpad)
- **Launchpad**: `0x03de191d75bafd96124ff87a39e6e0d035964bbe` (V6 BCM)
- **Creator**: `0x1010f290AF962c26f1a744E010845E45A447962E`
- **Deployed**: 2026-07-10 12:41:58 UTC
- **Funding goal**: 1.0 BNB
- **State**: Bonding, no trades yet
- **BscScan**: <https://bscscan.com/address/0x2158c3707a4eDdfb47e95f954c3749154ED29999>

---

## Tax Tokens (MemeToken)

### `0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999` — CUT (Community Uprising Token)

- **Type**: Tax (V6 launchpad)
- **Launchpad**: `0xe6d7325f54a90d68d82b0a1bf94de90d2f230cc4` (V6 TokenLaunchpad, tax)
- **Creator**: `0x333A53815f1E049BbeDe05b671Bc3D16985A61b5`
- **Deployed**: 2026-07-10 14:25:57 UTC
- **Funding goal**: 1.0 BNB
- **Buy tax**: 1% (100 bps)
- **Sell tax**: 3% (300 bps)
- **Tax distribution**: 0% hold / 100% burn / 0% market / 0% liquidity
- **Reflection asset**: WBNB (`0xbb4CdB9Cbd36B01bD1cBaEBF2De08d9173bc095c`)
- **Progress**: 3.23% raised (0.0323 BNB), 94,264,942 tokens sold
- **State**: Bonding (not yet graduated)
- **Description**: "CUT\n释义：社区起义代币\n社群团结、普通人夺回币圈主权\n\n叙事:我们曾把真心捧给项目方，换来的是一次次的收割与嘲讽…"
- **Community**: Telegram `官方QQ1: 952473711`, Twitter `官方QQ2: 627534284`,
  Website `DeBox官方: https://m.debox.pro/group?id=thqx6scr&code=afsejomv`
- **BscScan**: <https://bscscan.com/address/0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999>

### `0x6218E27e03CfDCfE0E1B907EAc6e8641756e9999` — BAN

- **Type**: Tax (V6 launchpad)
- **Launchpad**: `0xe6d7325f54a90d68d82b0a1bf94de90d2f230cc4` (V6 TokenLaunchpad, tax)
- **Creator**: `0x1010f290AF962c26f1a744E010845E45A447962E`
- **Deployed**: 2026-07-09 01:14:42 UTC
- **Buy tax / Sell tax**: 3% / 3% (300/300 bps)
- **Tax distribution**: 0% hold / 50% burn / 0% market / 50% liquidity
- **Reflection asset**: WBNB
- **BscScan**: <https://bscscan.com/address/0x6218E27e03CfDCfE0E1B907EAc6e8641756e9999>

### `0x573111E4FaAeC9384179609eA89Fb02605819999` — BAN

- **Type**: Tax (V6 launchpad)
- **Launchpad**: `0xe6d7325f54a90d68d82b0a1bf94de90d2f230cc4` (V6 TokenLaunchpad, tax)
- **Creator**: `0x4075C1Ba34Cc6fF7beA78ee855Ed0c656ACaDC30`
- **Deployed**: 2026-07-09 12:34:57 UTC
- **Buy tax / Sell tax**: 3% / 3% (300/300 bps)
- **Tax distribution**: 0% hold / 50% burn / 0% market / 50% liquidity
- **Reflection asset**: WBNB
- **BscScan**: <https://bscscan.com/address/0x573111E4FaAeC9384179609eA89Fb02605819999>

### `0x5E27cC825a284425249CE339E97d639E53B19999` — BNBSKING

- **Type**: Tax (V6 launchpad)
- **Launchpad**: `0xe6d7325f54a90d68d82b0a1bf94de90d2f230cc4` (V6 TokenLaunchpad, tax)
- **Creator**: `0xD351cA099BEC984Baf0E53E57CA4263F312C76b2`
- **Deployed**: 2026-07-09 14:06:55 UTC
- **Buy tax / Sell tax**: 4% / 4% (400/400 bps)
- **Tax distribution**: 80% hold (reflection) / 20% burn / 0% market / 0% liquidity
- **Reflection asset**: USDT (`0x55d398326f99059ff775485246999027b3197955`)
- **Progress**: 0.19% raised
- **Description**: "bnbsking全力打造成为bnbs平台龙一，买5%卖10%持币100万分红bnbs，20%销毁，10%回流。群276714191"
- **BscScan**: <https://bscscan.com/address/0x5E27cC825a284425249CE339E97d639E53B19999>

### `0x980DA396dEe637c698545840FF30867F53119999` — SKY2

- **Type**: Tax (V6 launchpad)
- **Launchpad**: `0xe6d7325f54a90d68d82b0a1bf94de90d2f230cc4` (V6 TokenLaunchpad, tax)
- **Creator**: `0x1010f290AF962c26f1a744E010845E45A447962E`
- **Deployed**: 2026-07-10 12:44:09 UTC
- **Buy tax / Sell tax**: 3% / 3% (300/300 bps)
- **Tax distribution**: 0% hold / 50% burn / 0% market / 50% liquidity
- **Reflection asset**: WBNB
- **BscScan**: <https://bscscan.com/address/0x980DA396dEe637c698545840FF30867F53119999>

---

## How To Audit Any Token Above

Given the address, the canonical audit path is:

```bash
# 1. Pull the deployed bytecode from BSC
cast code 0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999 --rpc-url https://bsc-rpc.publicnode.com

# 2. Reproduce the deployment bytecode locally
solc 0.8.20+commit.a1b79de6 \
    --via-ir \
    --optimize --optimize-runs 1 \
    --evm-version shanghai \
    --metadata \
    --bin contracts/MemeToken.sol

# 3. Compare. They should be byte-identical (excluding the constructor args suffix).
```

If the comparison matches, the source code in this repo IS the deployed
contract's source code. BscScan's "Source Not Verified" label is purely a
BscScan-frontend UI bug caused by the `viaIR: true` + their compile server
mismatch — it does NOT indicate the source is unavailable.
