# 发布到 GitHub — 步骤指南

本指南手把手教你创建一个公开的 GitHub 仓库，然后把 `bnbs-meme-token-template` 代码推上去。

## 1. 创建 GitHub 仓库

两种方式：

### 方式 A：网页操作（最简单）

1. 打开 https://github.com/new
2. 仓库名：`bnbs-meme-token-template`（或你想要的名字）
3. 描述：`Open-source smart contracts for BNBS Launchpad on BSC mainnet`（或中文：`BNBS Launchpad 发射台开源合约，BSC 主网`）
4. **Public（公开）** ← 重要！不要选 Private，开源就是要公开
5. **不要勾选** "Add a README"、"Add .gitignore" 或 "Choose a license"（我们本地已经有了）
6. 点 "Create repository"

### 方式 B：GitHub CLI

```bash
gh repo create bnbs-meme-token-template --public \
  --description "BNBS Launchpad 发射台开源合约，BSC 主网"
```

## 2. 推送代码

打开 PowerShell，执行：

```bash
cd "C:\Users\Administrator\Documents\bsc发射台\bnbs-meme-token-template"

# 初始化 git
git init
git add .
git commit -m "开源 BNBS Launchpad MemeToken 合约源码

- MemeToken.sol（带税版 ERC20，4 通道税费分配）
- TokenLaunchpad.sol（CREATE2 发射台工厂，税版）
- BaseMemeToken.sol（标准版，无税）
- BondingCurveMarket.sol（标准版发射台工厂）
- README.md（已部署代币索引 + 审计方法）
- docs/deployed-tokens.md（每个代币的链上详细数据）
- LICENSE（MIT）"

# 加 GitHub 远程（把 YOUR_USERNAME 换成你实际的 GitHub 用户名）
git remote add origin https://github.com/YOUR_USERNAME/bnbs-meme-token-template.git

# 推送到 main 分支
git branch -M main
git push -u origin main
```

## 3. 设置仓库描述和标签

推送完后，在 GitHub 仓库页：

1. 点 "About" 旁边的齿轮图标
2. Description（描述）：`BNBS Launchpad 发射台开源合约，BSC 主网（MemeToken 税版 + 反射 + 标准 ERC20 模板）`
3. Topics（标签）：`bsc`, `bnb-smart-chain`, `solidity`, `erc20`, `meme-token`, `launchpad`, `defi`, `smart-contracts`
4. Website（网站）：`https://bnbs.meme`

## 4. 钉到你的 GitHub 个人主页

打开你的 GitHub 主页（https://github.com/YOUR_USERNAME）：

1. 点 "Customize your pins"
2. 勾选 `bnbs-meme-token-template`
3. 保存

## 5.（可选）发个 Release

如果你想让用户看到具体的部署版本：

1. 进入仓库 → 右侧 "Releases" → "Create a new release"
2. Tag：`v1.0.0`（或你想要的版本号）
3. Title：`BNBS Launchpad 源码 — V6（含 6 个已部署代币）`
4. 描述：

```markdown
## 已部署代币（BSC 主网）

| 地址 | 符号 | 税率 | 部署时间 |
|---------|--------|-----|----------|
| 0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999 | CUT | 1%/3% | 2026-07-10 |
| 0x5E27cC825a284425249CE339E97d639E53B19999 | BNBSKING | 4%/4% | 2026-07-09 |
| 0x9b47D08Fa05247f82A3cE3606628cA3584359999 | CZ | 0%（标准版）| 2026-07-09 |
| 0x6218E27e03CfDCfE0E1B907EAc6e8641756e9999 | BAN | 3%/3% | 2026-07-09 |
| 0x573111E4FaAeC9384179609eA89Fb02605819999 | BAN | 3%/3% | 2026-07-09 |
| 0x980DA396dEe637c698545840FF30867F53119999 | SKY2 | 3%/3% | 2026-07-10 |
| 0x8FB1075d3063283c60101F4fF5A58996BfBd9999 | TEST | 0%（标准版）| 2026-07-09 |
| 0x0927895385C4Be2A5DfDd836EE93363732099999 | TEST | 0%（标准版）| 2026-07-09 |

完整列表见 README.md。
```

## 6.（推荐）在你的网页里加上 GitHub 链接

在你的 web app 底部 footer / 关于页面，加一个类似链接：

```html
<a href="https://github.com/YOUR_USERNAME/bnbs-meme-token-template"
   target="_blank" rel="noopener">
  开源合约源码 ↗
</a>
```

这样用户从 dapp 一键就能跳到 GitHub 看源码。

## 7.（可选）在 BscScan 加 GitHub 链接

对每个已部署合约地址（比如 `0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999`）：

1. 打开 https://bscscan.com/address/0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999
2. 找 "Update Contract Info" 或者联系 BscScan 加外链
3. 把 GitHub 仓库 URL 加为 "Official Source" 链接

（这个一般需要 BscScan 管理员审批，但对已验证项目是免费的。）

---

## 关于 verify 状态的说明

6 个已部署的税版代币（`0x02C0E0e06e4E29D156D226F80E5223Fe9dd99999` CUT 等）暂时无法在 BscScan 上做 source-verify，原因是 `viaIR: true` + BscScan solc server 不兼容（MemeToken 旧版 bytecode 的已知问题）。

这个仓库里的源码已经把 `viaIR` 依赖去掉了；**未来**新 deploy 的税版代币（用本仓库的 compile.mjs 编译）就能正常 BscScan verify。

对于已经部署的 6 个税版代币，本 GitHub 仓库的源码就是规范参考。审计员可以这样做：

1. 克隆这个仓库
2. 跑 `solc 0.8.20+commit.a1b79de6 --via-ir --optimize --optimize-runs 1 --evm-version shanghai --metadata --bin contracts/MemeToken.sol`
3. 把编译出的 bytecode 跟 `cast code <地址> --rpc-url https://bsc-rpc.publicnode.com` 拉到的链上 bytecode 对比
4. 两者字节完全一致（除去 constructor args 后缀）

---

## 常见问题

**Q: 推送时提示 "Permission denied"？**

A: 用 Personal Access Token 不用密码。GitHub 现在不支持密码 push 了。Settings → Developer settings → Personal access tokens → 生成一个，把 token 当密码用。

或者用 SSH：
```bash
# 1. 生成 SSH key
ssh-keygen -t ed25519 -C "your_email@example.com"

# 2. 把 ~/.ssh/id_ed25519.pub 内容加到 GitHub Settings → SSH and GPG keys

# 3. 改 remote 用 SSH
git remote set-url origin git@github.com:YOUR_USERNAME/bnbs-meme-token-template.git
git push -u origin main
```

**Q: 推送时报 "Updates were rejected"？**

A: GitHub 上如果已经勾了 "Add a README" 创建，会跟本地的 README 冲突。两种解决：
- 方法 1：删 GitHub 上那个 README，重新创建空白仓库
- 方法 2：本地先 `git pull origin main --rebase` 再 `git push`

**Q: 我不想用 "bnbs-meme-token-template" 这个名字？**

A: 随便改。GitHub 仓库名只是 URL 的一部分，唯一要求是全局唯一。建议名字包含 `meme` + `bsc` 关键字方便搜索。
