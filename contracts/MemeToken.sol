// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MemeToken
 * @notice BSC Launchpad 上一键创建的 meme 代币模板
 *
 * V2 改进（reflectionAsset 可调）：
 *   - 创建者填 reflectionAsset（address(0) = meme token 本身 / WBNB = BNB / 其他 = 该 ERC20）
 *   - 反射资产在 _transferWithTax 中通过 PancakeSwap 自动兑换累积
 *   - claimReflection() 收到的是 reflectionAsset（不再是 meme token）
 *   - reflectionAsset / marketWallet / pair 全部 immutable（创建后无法改）
 *
 * 反射模型（Synthetix-style 累积式）：
 *   - cumulativeAsset:    累积的反射资产总数（monotonic，只加不减）
 *   - totalShares:        累积的 meme token 份额总数（monotonic）
 *   - claimedAsset[holder]: 该 holder 已领取的反射资产数
 *   - pending(holder) = cumulativeAsset * balanceOf(holder) / eligibleSupply - claimedAsset[holder]
 *   - 优点：不会因为有人 claim 而拉低 perShare；分配公平
 *
 * 4 类 transfer tax 分配（总和必须 = 100%）：
 *   - marketShare  % → marketWallet（黄金钱包）
 *   - burnShare    % → _burn
 *   - reflectShare % → Pancake swap 到 reflectionAsset → 累积到合约
 *   - liquidityShare % → liquidityWallet
 */

interface IPancakeRouter02 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IERC20Ext {
    function approve(address spencer, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);  // 2026-07-07: LP 模式需要 pair.totalSupply()
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWBNB {
    function withdraw(uint256 amount) external;
    function deposit() external payable;
}

contract MemeToken is ERC20, Ownable {
    error ErrZeroLaunchpad();
    error ErrZeroRouter();
    error ErrAlreadyInit();
    error ErrBuyTaxTooHigh();
    error ErrSellTaxTooHigh();
    error ErrSharesNot100();
    error ErrNotLaunchpad();
    error ErrZeroAddress();
    error ErrBelowThreshold();
    error ErrTransferFailed();
    error ErrUnknown();

    /// @dev 2026-07-07: 分红模式。HOLDER = 持币人按 meme token 持仓分 (老逻辑);
    ///      LP = LP 持有人按 PancakePair 持仓分 WBNB (新模式)
    enum DividendMode { HOLDER, LP }

    /// @dev 2026-07-10: TaxDistributed 事件的 struct 形式.
    ///      Solidity 0.8 的 event 接受 struct 字段,emit 时整个 struct 在 memory (heap) 上,
    ///      只占 1 个 stack slot (指针),避开 8 个独立字段 emit 时的 Stack too deep.
    ///      这样 compile.mjs 可以不带 viaIR:true,生成的 bytecode 就能在 BscScan/Etherscan
    ///      verify (viaIR + BscScan solc server mismatch 是已知 bug,Sourcify V2 extra_file_input_bug 同源).
    struct TaxDistribution {
        uint256 totalAmount;
        uint256 toMarket;
        uint256 burned;
        uint256 toReflection;
        uint256 toLiquidity;
        uint256 assetReceived;
        bool isBuy;
        address asset;
    }

    /// @dev 部署该代币的 TokenLaunchpad 合约地址。immutable
    address public immutable launchpad;
    /// @dev 反射分红支付的资产。immutable
    ///      0 = meme token 本身 / WBNB (0xbb4CdB9...) = 原生 BNB / 其他 = 该 ERC20
    address public immutable reflectionAsset;
    /// @dev PancakeSwap router。immutable
    address public immutable pancakeRouter;
    /// @dev WBNB 地址。immutable
    address public immutable WBNB;
    /// @dev 分红模式。immutable,创建后无法改
    DividendMode public immutable dividendMode;

    uint256 public buyTaxRate;
    uint256 public sellTaxRate;
    uint256 public deployedAt;

    uint256 public marketShare;
    uint256 public burnShare;
    uint256 public reflectShare;
    uint256 public liquidityShare;

    address public marketWallet;
    address public liquidityWallet;
    address public pair;

    uint256 public minHoldForReward;

    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromReflection;

    // ─── 反射累积（Synthetix-style） ───
    uint256 public cumulativeAsset;                  // 累积反射资产（monotonic）
    uint256 public totalShares;                      // 累积 meme token 份额（monotonic）
    mapping(address => uint256) public claimedAsset; // holder 已领取的反射资产

    // ─── 2026-07-07: LP 分红模式专用 (DividendMode.LP) ───
    // 当 dividendMode == LP 时,reflectionAsset 的分红按 LP token 持仓分配给 LP 持有人
    // (PancakePair holder),而不是按 meme token 持仓分配
    uint256 public lpCumulativeAsset;                // LP 模式累积反射资产（monotonic）
    uint256 public lpTotalEligible;                  // LP 模式最近一次分配时的"合格 LP 持仓"总数（= lpTotalSupply - 合约自持 LP）
    mapping(address => uint256) public lpClaimedAsset; // LP 持有人已领取的反射资产

    /// @dev 2026-07-10: event signature 改成传 struct (tuple). ABI 变成
    ///      `TaxDistributed((uint256,uint256,uint256,uint256,uint256,uint256,bool,address))`.
    ///      所有 8 个字段都 non-indexed,在 data 里编码为 tuple.
    ///      Breaking change for listeners — 任何监控 TaxDistributed 的 indexer/前端
    ///      需要更新解码逻辑 (按 tuple 解,fields 顺序同 struct).
    event TaxDistributed(TaxDistribution tax);
    event PairSet(address indexed pair);
    event ReflectionClaim(address indexed holder, uint256 amount, address asset);
    event RelayerFeePaid(address indexed relayer, address indexed holder, uint256 amount, address asset);

    modifier onlyLaunchpad() {
        if (!(msg.sender == launchpad)) revert ErrNotLaunchpad();
        _;
    }

    /**
     * @param name             代币名
     * @param symbol           代币符号
     * @param initialSupply    总供应量（10 亿）
     * @param _launchpad       部署该代币的 TokenLaunchpad 合约地址
     * @param _reflectionAsset 反射分红资产：0=代币本身 / WBNB=BNB / 其他=该ERC20
     * @param _pancakeRouter   PancakeSwap V2 router 地址
     * @param _dividendMode    分红模式：0=HOLDER(持币人) / 1=LP(LP token 持有人)
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address _launchpad,
        address _reflectionAsset,
        address _pancakeRouter,
        DividendMode _dividendMode
    ) ERC20(name, symbol) {
        if (!(_launchpad != address(0))) revert ErrZeroLaunchpad();
        if (!(_pancakeRouter != address(0))) revert ErrZeroRouter();
        launchpad = _launchpad;
        reflectionAsset = _reflectionAsset;
        pancakeRouter = _pancakeRouter;
        WBNB = IPancakeRouter02(_pancakeRouter).WETH();
        dividendMode = _dividendMode;
        deployedAt = block.timestamp;
        _mint(_launchpad, initialSupply);
        isExcludedFromReflection[_launchpad] = true;
        // 2026-07-08: The launchpad itself MUST also be in isExcludedFromTax.
        // Why: `_graduate()` calls `router.addLiquidityETH(...)`, which inside
        // the router does `token.transferFrom(launchpad, pair, 200M)`. With
        // launchpad NOT exempted, that transfer routes through the normal
        // tax branch (from != pair, to == pair, isBuy=true) and `buyTaxRate`
        // gets charged, so the pair ends up with `200M × (10000-buyTaxRate)/10000`
        // tokens instead of a clean 200M. addLiquidityETH then either reverts
        // on its minToken slippage check, or silently seeds an LP with the
        // wrong ratio. The marketingWallet / liquidityWallet / pancakeRouter
        // paths are already exempted via setMarketWallet / setLiquidityWallet
        // / initRouterApproval; the launchpad was the missing exemption.
        isExcludedFromTax[_launchpad] = true;

        // NOTE: We deliberately do NOT pre-approve the Pancake router from the
        // constructor. Calling `address(this).approve(...)` from a constructor is
        // a no-op (no runtime code at `address(this)` yet), and the high-level
        // call ABI wrapper reverts because it expects a `bool` return value that
        // the no-op call cannot produce. The router approval is therefore
        // established by the launchpad contract *after* the MemeToken is
        // deployed, via `initRouterApproval()` below.
    }

    // 接收 BNB（从 WBNB.withdraw 来的）
    receive() external payable {}

    /**
     * @notice 初始化 transfer tax 配置（只能调一次，owner renounce 后永久 revert）
     */
    function initTaxConfig(
        uint256 _buyTaxRate,
        uint256 _sellTaxRate,
        uint256 _marketShare,
        uint256 _burnShare,
        uint256 _reflectShare,
        uint256 _liquidityShare,
        uint256 _minHoldForReward,
        address _marketWallet
    ) external onlyOwner {
        if (!(buyTaxRate == 0 && sellTaxRate == 0 && marketShare == 0 && marketWallet == address(0))) revert ErrAlreadyInit();
        if (!(_buyTaxRate <= 1000)) revert ErrBuyTaxTooHigh();
        if (!(_sellTaxRate <= 1000)) revert ErrSellTaxTooHigh();
        if (!(_marketShare + _burnShare + _reflectShare + _liquidityShare == 100)) revert ErrSharesNot100();
        buyTaxRate = _buyTaxRate;
        sellTaxRate = _sellTaxRate;
        marketShare = _marketShare;
        burnShare = _burnShare;
        reflectShare = _reflectShare;
        liquidityShare = _liquidityShare;
        minHoldForReward = _minHoldForReward;
        marketWallet = _marketWallet;
        if (_marketWallet != address(0)) {
            isExcludedFromTax[_marketWallet] = true;
            isExcludedFromReflection[_marketWallet] = true;
        }
    }

    function setPair(address _pair) external onlyLaunchpad {
        pair = _pair;
        // 2026-07-08: MemeToken business rule (corrected) — Pancake pair MUST
        // NOT be added to isExcludedFromTax. The two taxes are separate:
        //   - 0.5% bonding-curve fee  : collected by BondingCurveMarket.buy/sell
        //     on the router side. That path closes the moment bnbRaised
        //     reaches fundingGoal — adding the pair to isExcludedFromTax here
        //     was redundant *and* wrong: it stopped the token-level
        //     buyTaxRate/sellTaxRate from charging on Pancake, which is the
        //     whole point of the tax feature.
        //   - buyTaxRate/sellTaxRate : charged in `_transferWithTax` when
        //     (from == pair || to == pair) and the pair is NOT excluded.
        //   So: keep `isExcludedFromTax[_pair] = false` (do not write the
        //   mapping; the default zero value is what we want) so Pancake
        //   swaps route through the normal tax branch.
        //
        // 2026-07-07: LP 分红模式 — pair 的 reflection 处理按 dividendMode 区分
        //   HOLDER: pair exclude from reflection (锁仓 LP 不参与持币人分红)
        //   LP:     pair 不 exclude from reflection (pair 就是 LP token 本身,
        //           它的持有者 = LP 持有人 = 分红接收方)
        // （保持原 LP reflection 分叉逻辑不变。）
        isExcludedFromReflection[_pair] = (dividendMode == DividendMode.HOLDER);
        emit PairSet(_pair);
    }

    /**
     * @notice Approve the Pancake router to spend this meme token. Must be
     * called by the launchpad contract AFTER the MemeToken is fully deployed,
     * because the constructor cannot pre-approve (the call would be a no-op
     * and Solidity's high-level call wrapper would revert on the missing
     * `bool` return value).
     *
     * Only callable once.
     */
    bool private _routerApproved;
    function initRouterApproval() external onlyLaunchpad {
        require(!_routerApproved, 'already approved');
        _routerApproved = true;
        // Use a low-level call so we do not depend on the return value —
        // the router's `approve` may have side-effects we don't care about.
        (bool ok, ) = address(this).call(
            abi.encodeWithSelector(IERC20Ext.approve.selector, pancakeRouter, type(uint256).max)
        );
        require(ok, 'approve failed');
        // Also exclude the router from tax + reflection for cleanest accounting
        isExcludedFromTax[pancakeRouter] = true;
        isExcludedFromReflection[pancakeRouter] = true;
    }

    function setLiquidityWallet(address _wallet) external onlyLaunchpad {
        liquidityWallet = _wallet;
        if (_wallet != address(0)) {
            isExcludedFromTax[_wallet] = true;
            isExcludedFromReflection[_wallet] = true;
        }
    }

    function setMarketWallet(address _wallet) external onlyLaunchpad {
        marketWallet = _wallet;
        if (_wallet != address(0)) {
            isExcludedFromTax[_wallet] = true;
            isExcludedFromReflection[_wallet] = true;
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithTax(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transferWithTax(from, to, amount);
        return true;
    }

    function _transferWithTax(address from, address to, uint256 amount) internal {
        bool isSwap = (from == pair || to == pair);
        if (!isSwap) {
            super._transfer(from, to, amount);
            return;
        }

        // 2026-07-08: Pancake swap direction fix.
        //   buy  (user wants tokens):  pair → user   →  from == pair
        //   sell (user wants BNB):     user  → pair   →  to   == pair
        // The previous `isBuy = (to == pair)` inverted the two — Pancake
        // buys got charged sellTaxRate and sells got charged buyTaxRate.
        // For symmetric buyTax/sellTax settings this was invisible; the
        // asymmetry only surfaced when creators picked different rates.
        bool isBuy = (from == pair);
        uint256 currentTaxRate = isBuy ? buyTaxRate : sellTaxRate;

        if (currentTaxRate == 0 || isExcludedFromTax[from] || isExcludedFromTax[to]) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 taxAmount = (amount * currentTaxRate) / 10000;
        uint256 sendAmount = amount - taxAmount;
        super._transfer(from, to, sendAmount);

        if (taxAmount > 0) {
            _distributeTaxAndEmit(from, isBuy, taxAmount);
        }
    }

    /**
     * @dev 2026-07-10: 把 tax 计算+分发+emit 拆成独立函数,避开 _transferWithTax 的 Stack too deep.
     *      这样 compile.mjs 可以关闭 viaIR,新 deploy 的 tax token bytecode 跟 BscScan verify
     *      server 编译出的 bytecode 一致,verify 就能成功.
     */
    function _distributeTaxAndEmit(address from, bool isBuy, uint256 taxAmount) internal {
        (uint256 marketPart, uint256 burnPart, uint256 reflectPart, uint256 liqPart) =
            _splitTax(taxAmount);

        if (marketPart > 0 && marketWallet != address(0)) {
            _sendToMarket(from, marketPart);
        }
        if (burnPart > 0) {
            _burn(from, burnPart);
        }

        // 拆 reflection 处理到独立函数,避免本函数堆栈累积.
        (uint256 assetReceived, address actualAsset) = _processReflection(from, reflectPart);

        if (liqPart > 0 && liquidityWallet != address(0)) {
            _sendToLiquidity(from, liqPart);
        }

        // 2026-07-10: 用 memory struct 传 event,emit 时整个 struct 在 memory (heap) 上,
        // 只占 1 个 stack slot (指针),避开 8 个独立字段 emit 时的 Stack too deep.
        TaxDistribution memory _tax = TaxDistribution({
            totalAmount: taxAmount,
            toMarket: marketPart,
            burned: burnPart,
            toReflection: reflectPart,
            toLiquidity: liqPart,
            assetReceived: assetReceived,
            isBuy: isBuy,
            asset: actualAsset
        });
        emit TaxDistributed(_tax);
    }

    /**
     * @dev 2026-07-10: 把 tax 分成 market / burn / reflect / liq 四份.
     *      单独拆出来因为 _distributeTaxAndEmit 里同时有 4 个 uint256 + 2 个外部调用,
     *      stack 会爆. 拆出来后这个函数只有 1 个 stack slot (返回 tuple 走 memory).
     */
    function _splitTax(uint256 taxAmount) internal view returns (uint256 marketPart, uint256 burnPart, uint256 reflectPart, uint256 liqPart) {
        marketPart = (taxAmount * marketShare) / 100;
        burnPart = (taxAmount * burnShare) / 100;
        reflectPart = (taxAmount * reflectShare) / 100;
        liqPart = taxAmount - marketPart - burnPart - reflectPart;
    }

    /**
     * @dev 2026-07-10: super._transfer 每个调用点都包一层 helper,这样调用现场 0 stack.
     *      避免 _distributeTaxAndEmit 的 stack 太深导致 inline assembly 失败.
     */
    function _sendToMarket(address from, uint256 amount) internal {
        super._transfer(from, marketWallet, amount);
    }

    function _sendToLiquidity(address from, uint256 amount) internal {
        super._transfer(from, liquidityWallet, amount);
    }

    /**
     * @dev 2026-07-10: reflection 部分独立出来 (swap 到 reflectionAsset + 累积 + LP/holder 模式分流).
     *      返回 (assetReceived, actualAsset) 给 _distributeTaxAndEmit 拿去 emit.
     */
    function _processReflection(address from, uint256 reflectPart) internal returns (uint256, address) {
        if (reflectPart == 0) {
            return (0, address(this));
        }

        // 2026-07-10: super._transfer 包到独立 helper,这样调用现场 stack 占用 0 slot.
        // 原始函数里同时有 super._transfer + if/else + storage writes,stack 累积爆 16.
        _absorbReflection(from, reflectPart);
        return _creditReflection(reflectPart);
    }

    /**
     * @dev 2026-07-10: super._transfer 包独立 helper,让 caller 函数 stack 占用 0.
     */
    function _absorbReflection(address from, uint256 reflectPart) internal {
        super._transfer(from, address(this), reflectPart);
    }

    /**
     * @dev 2026-07-10: 处理 reflection 的 swap + 累积 + LP/holder 分流.
     *      单独拆出来因为里面有 if/else/swap/storage 写,stack 多.
     */
    function _creditReflection(uint256 reflectPart) internal returns (uint256 assetReceived, address actualAsset) {
        assetReceived = reflectPart;
        actualAsset = address(this);

        if (reflectionAsset != address(0) && pair != address(0)) {
            // Swap to reflectionAsset
            (bool ok, uint256 received) = _trySwapToReflectionAsset(reflectPart);
            if (ok && received > 0) {
                assetReceived = received;
                actualAsset = reflectionAsset;
                cumulativeAsset += received;
                // 2026-07-07: LP 模式同时累加 LP 持有人可分红的资产。
                // lpTotalEligible 在每次分配时更新,表示当前"合格 LP 持仓"= LP totalSupply - 合约自持 LP
                if (dividendMode == DividendMode.LP) {
                    lpCumulativeAsset += received;
                    lpTotalEligible = _lpEligibleSupply();
                }
            } else {
                // Swap failed → keep as meme token, credit as meme token
                cumulativeAsset += reflectPart;
                // 2026-07-07: LP 模式 swap 失败时,仍按 meme token 累积,按 LP 持仓分配
                if (dividendMode == DividendMode.LP) {
                    lpCumulativeAsset += reflectPart;
                    lpTotalEligible = _lpEligibleSupply();
                }
            }
        } else {
            // Default: hold meme token itself
            cumulativeAsset += reflectPart;
            if (dividendMode == DividendMode.LP) {
                lpCumulativeAsset += reflectPart;
                lpTotalEligible = _lpEligibleSupply();
            }
        }
        // HOLDER 模式:totalShares 累加 meme token 份额
        // LP 模式:totalShares 不增 (LP 分红不用 meme token 持仓)
        if (dividendMode == DividendMode.HOLDER) {
            totalShares += reflectPart;
        }
    }

    /**
     * @dev Try to swap `memeAmount` of this meme token to reflectionAsset via Pancake.
     *      Returns (ok, assetReceived). On failure, returns (false, 0) and caller falls back to meme token.
     */
    function _trySwapToReflectionAsset(uint256 memeAmount) internal returns (bool, uint256) {
        if (memeAmount == 0) return (true, 0);
        address[] memory path;
        if (reflectionAsset == WBNB) {
            path = new address[](2);
            path[0] = address(this);
            path[1] = WBNB;
        } else {
            path = new address[](3);
            path[0] = address(this);
            path[1] = WBNB;
            path[2] = reflectionAsset;
        }
        // Compute amountOutMin (5% slippage)
        uint256[] memory expected;
        try IPancakeRouter02(pancakeRouter).getAmountsOut(memeAmount, path) returns (uint256[] memory r) {
            expected = r;
        } catch {
            return (false, 0);
        }
        if (expected.length < path.length) return (false, 0);
        uint256 expectedOut = expected[expected.length - 1];
        if (expectedOut == 0) return (false, 0);
        uint256 amountOutMin = (expectedOut * 95) / 100;

        // Execute swap
        uint256 received = 0;
        try IPancakeRouter02(pancakeRouter).swapExactTokensForTokens(
            memeAmount, amountOutMin, path, address(this), block.timestamp + 300
        ) returns (uint256[] memory amounts) {
            received = amounts[amounts.length - 1];
        } catch {
            return (false, 0);
        }

        // If reflectionAsset is WBNB, unwrap to native BNB for cleaner UX
        if (reflectionAsset == WBNB && received > 0) {
            try IWBNB(WBNB).withdraw(received) {} catch {
                // WBNB withdraw failed (shouldn't happen); keep as WBNB
            }
        }
        return (true, received);
    }

    function _eligibleReflectionBalance() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 exclude = balanceOf(address(this)) + balanceOf(launchpad);
        if (pair != address(0)) exclude += balanceOf(pair);
        if (marketWallet != address(0)) exclude += balanceOf(marketWallet);
        if (liquidityWallet != address(0)) exclude += balanceOf(liquidityWallet);
        return supply > exclude ? supply - exclude : 0;
    }

    /// @dev 2026-07-07: LP 模式专用,合格 LP 持仓 = LP totalSupply - 合约自持 LP
    function _lpEligibleSupply() internal view returns (uint256) {
        if (pair == address(0)) return 0;
        uint256 lpTotal = IERC20Ext(pair).totalSupply();
        uint256 myLp = IERC20Ext(pair).balanceOf(address(this));
        return lpTotal > myLp ? lpTotal - myLp : 0;
    }

    /**
     * @notice 查询 holder 当前可领取的反射资产数量
     * @dev 2026-07-07: 根据 dividendMode 分两套计算逻辑
     *   HOLDER: 按 meme token 持仓分配
     *   LP:     按 LP token (PancakePair) 持仓分配
     */
    function pendingReflection(address holder) public view returns (uint256) {
        if (isExcludedFromReflection[holder]) return 0;
        if (cumulativeAsset == 0) return 0;
        if (dividendMode == DividendMode.LP) {
            // LP 模式:按 LP token 持仓分配
            if (pair == address(0)) return 0;
            if (lpCumulativeAsset == 0) return 0;
            uint256 eligibleLp = _lpEligibleSupply();
            if (eligibleLp == 0) return 0;
            uint256 lpBalance = IERC20Ext(pair).balanceOf(holder);
            if (lpBalance == 0) return 0;
            uint256 owed = (lpCumulativeAsset * lpBalance) / eligibleLp;
            uint256 paid = lpClaimedAsset[holder];
            return owed > paid ? owed - paid : 0;
        } else {
            // HOLDER 模式:按 meme token 持仓分配
            if (totalShares == 0) return 0;
            uint256 eligible = _eligibleReflectionBalance();
            if (eligible == 0) return 0;
            uint256 owed = (cumulativeAsset * balanceOf(holder)) / eligible;
            uint256 paid = claimedAsset[holder];
            return owed > paid ? owed - paid : 0;
        }
    }

    /**
     * @notice 领取反射分红（reflectionAsset）
     * @dev 必须持有 ≥ minHoldForReward 才能 claim
     *      HOLDER 模式要求持有 meme token ≥ minHoldForReward
     *      LP 模式要求持有 LP token ≥ minHoldForReward
     */
    function claimReflection() external {
        if (!(!isExcludedFromReflection[_msgSender()])) revert ErrZeroAddress();
        // 2026-07-07: LP 模式检查 LP token 持仓,其他模式检查 meme token 持仓
        if (dividendMode == DividendMode.LP) {
            if (pair == address(0)) revert ErrZeroAddress();
            if (!(IERC20Ext(pair).balanceOf(_msgSender()) >= minHoldForReward)) revert ErrBelowThreshold();
        } else {
            if (!(balanceOf(_msgSender()) >= minHoldForReward)) revert ErrBelowThreshold();
        }

        uint256 toClaim = pendingReflection(_msgSender());
        if (!(toClaim > 0)) revert ErrBelowThreshold();

        // Update snapshot
        if (dividendMode == DividendMode.LP) {
            uint256 eligibleLp = _lpEligibleSupply();
            if (eligibleLp > 0) {
                lpClaimedAsset[_msgSender()] = (lpCumulativeAsset * IERC20Ext(pair).balanceOf(_msgSender())) / eligibleLp;
            }
        } else {
            uint256 eligible = _eligibleReflectionBalance();
            if (eligible > 0) {
                claimedAsset[_msgSender()] = (cumulativeAsset * balanceOf(_msgSender())) / eligible;
            }
        }

        // Transfer reflectionAsset
        if (reflectionAsset == address(0)) {
            super._transfer(address(this), _msgSender(), toClaim);
        } else if (reflectionAsset == WBNB) {
            // native BNB
            (bool ok, ) = _msgSender().call{value: toClaim}("");
            if (!(ok)) revert ErrTransferFailed();
        } else {
            IERC20Ext(reflectionAsset).transfer(_msgSender(), toClaim);
        }

        address actualAsset = (reflectionAsset == address(0)) ? address(this) : reflectionAsset;
        emit ReflectionClaim(_msgSender(), toClaim, actualAsset);
    }

    /**
     * @notice Claim reflection on behalf of `holder`, paying a small relayer fee from the pending amount.
     * @dev V3 功能：让 bot / relayer 自给自足（用 holder 的待领扣手续费代替 bot 自掏 gas）
     * @param holder           The address whose reflection to claim
     * @param relayerFeeBps    Fee in bps paid to msg.sender (max 500 = 5%)
     */
    function claimReflectionFor(address holder, uint256 relayerFeeBps) external {
        if (!(relayerFeeBps <= 500)) revert ErrBuyTaxTooHigh();
        if (!(holder != address(0))) revert ErrZeroAddress();
        if (!(!isExcludedFromReflection[holder])) revert ErrUnknown();
        // 2026-07-07: LP 模式检查 LP token 持仓,其他模式检查 meme token 持仓
        if (dividendMode == DividendMode.LP) {
            if (pair == address(0)) revert ErrZeroAddress();
            if (!(IERC20Ext(pair).balanceOf(holder) >= minHoldForReward)) revert ErrBelowThreshold();
        } else {
            if (!(balanceOf(holder) >= minHoldForReward)) revert ErrBelowThreshold();
        }

        uint256 toClaim = pendingReflection(holder);
        if (!(toClaim > 0)) revert ErrBelowThreshold();

        // Update snapshot for the holder
        if (dividendMode == DividendMode.LP) {
            uint256 eligibleLp = _lpEligibleSupply();
            if (eligibleLp > 0) {
                lpClaimedAsset[holder] = (lpCumulativeAsset * IERC20Ext(pair).balanceOf(holder)) / eligibleLp;
            }
        } else {
            uint256 eligible = _eligibleReflectionBalance();
            if (eligible > 0) {
                claimedAsset[holder] = (cumulativeAsset * balanceOf(holder)) / eligible;
            }
        }

        // Split: relayer gets `relayerFeeBps%`, holder gets the rest
        uint256 relayerAmount = (toClaim * relayerFeeBps) / 10000;
        uint256 holderAmount = toClaim - relayerAmount;

        address actualAsset = (reflectionAsset == address(0)) ? address(this) : reflectionAsset;

        if (reflectionAsset == address(0)) {
            // meme token itself
            if (holderAmount > 0) super._transfer(address(this), holder, holderAmount);
            if (relayerAmount > 0 && msg.sender != holder) super._transfer(address(this), msg.sender, relayerAmount);
        } else if (reflectionAsset == WBNB) {
            // native BNB
            if (holderAmount > 0) {
                (bool ok1, ) = holder.call{value: holderAmount}("");
                if (!(ok1)) revert ErrTransferFailed();
            }
            if (relayerAmount > 0 && msg.sender != holder) {
                (bool ok2, ) = msg.sender.call{value: relayerAmount}("");
                if (!(ok2)) revert ErrUnknown();
            }
        } else {
            // ERC20 (USDT, custom, etc.)
            if (holderAmount > 0) IERC20Ext(reflectionAsset).transfer(holder, holderAmount);
            if (relayerAmount > 0 && msg.sender != holder) IERC20Ext(reflectionAsset).transfer(msg.sender, relayerAmount);
        }

        emit ReflectionClaim(holder, holderAmount, actualAsset);
        if (relayerAmount > 0) {
            emit RelayerFeePaid(msg.sender, holder, relayerAmount, actualAsset);
        }
    }

    // ─── onlyOwner functions: renounce 后永久 revert ───

    function setTaxConfig(
        uint256 _buyTaxRate,
        uint256 _sellTaxRate,
        uint256 _marketShare,
        uint256 _burnShare,
        uint256 _reflectShare,
        uint256 _liquidityShare,
        uint256 _minHoldForReward
    ) external onlyOwner {
        if (!(_buyTaxRate <= 1000)) revert ErrBuyTaxTooHigh();
        if (!(_sellTaxRate <= 1000)) revert ErrSellTaxTooHigh();
        if (!(_marketShare + _burnShare + _reflectShare + _liquidityShare == 100)) revert ErrSharesNot100();
        buyTaxRate = _buyTaxRate;
        sellTaxRate = _sellTaxRate;
        marketShare = _marketShare;
        burnShare = _burnShare;
        reflectShare = _reflectShare;
        liquidityShare = _liquidityShare;
        minHoldForReward = _minHoldForReward;
    }

    function setTaxExclusion(address account, bool excluded) external onlyOwner {
        isExcludedFromTax[account] = excluded;
    }

    function batchSetTaxExclusion(address[] calldata accounts, bool excluded) external onlyOwner {
        for (uint i = 0; i < accounts.length; i++) {
            isExcludedFromTax[accounts[i]] = excluded;
        }
    }

    /// @notice 创建时批量添加白名单（免税 + 不参与分红）。仅 owner 可调，renounce 后永久失效。
    /// @dev 在 _deployToken 中 renounceOwnership 之前调用。
    ///      白名单地址:
    ///        - 在 Pancake 买入/卖出时均不收 buyTaxRate/sellTaxRate
    ///        - 不参与反射分红（持币不获得分红，也不扣除分红份额）
    function initWhitelist(address[] calldata accounts) external onlyOwner {
        require(accounts.length <= 50, "Too many whitelist entries (max 50)");
        for (uint i = 0; i < accounts.length; i++) {
            if (accounts[i] != address(0)) {
                isExcludedFromTax[accounts[i]] = true;
                isExcludedFromReflection[accounts[i]] = true;
            }
        }
    }
}
