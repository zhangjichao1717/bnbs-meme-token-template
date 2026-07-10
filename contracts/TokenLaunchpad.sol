// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// 2026-07-07: 不再 import MemeToken.sol,改由 constructor 接收其 creationCode (避免 24KB 上限)
interface IMemeToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function initTaxConfig(
        uint256 _buyTaxRate,
        uint256 _sellTaxRate,
        uint256 _marketShare,
        uint256 _burnShare,
        uint256 _reflectShare,
        uint256 _liquidityShare,
        uint256 _minHoldForReward,
        address _marketWallet
    ) external;
    function initRouterApproval() external;
    function initWhitelist(address[] calldata accounts) external;
    function setPair(address _pair) external;
    function setLiquidityWallet(address _wallet) external;
    function setMarketWallet(address _wallet) external;
    function renounceOwnership() external;
    function launchpad() external view returns (address);
    function pair() external view returns (address);
    function reflectionAsset() external view returns (address);
    function cumulativeAsset() external view returns (uint256);
    function totalShares() external view returns (uint256);
}

interface IPancakeRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function factory() external pure returns (address);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IERC20LP {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title TokenLaunchpad
 * @dev 税费版：二次联合曲线定价，CREATE2 9999尾号，2.5%交易费，可配置税费，自动PancakeSwap流动性
 * 优化点：
 *   1. 毕业逻辑：isGraduated 在 Pancake 调用成功后才设置，失败不锁死
 *   2. 精度保护：buyCost 最小返回 1 wei，防止零成本漏洞
 *   3. 滑点保护：addLiquidityETH 使用 95% 最小金额
 *   4. 发行费可更新
 */

contract TokenLaunchpad is Ownable, ReentrancyGuard {
    error ErrZeroValue();
    error ErrFundingOutOfRange();
    error ErrBuyTaxTooHigh();
    error ErrSellTaxTooHigh();
    error ErrSharesNot100();
    error ErrSaltSuffix();
    error ErrCreate2Mismatch();
    error ErrZeroLaunchpad();
    error ErrZeroRouter();
    error ErrAlreadyInit();
    error ErrZeroAddress();
    error ErrBelowThreshold();
    error ErrNoPair();
    error ErrNotLaunchpad();
    error ErrTransferFailed();
    error ErrRange1To10();
    error ErrFeeRequired();
    error ErrTokenNotFound();
    error ErrAlreadyGraduated();
    error ErrNoBnb();
    error ErrFactoryFailed();
    error ErrInsufficientTokens();
    error ErrExceedsPool();
    error ErrNoLiquidity();
    error ErrUnknown();
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        string description;
        string logoUrl;
        string website;
        string twitter;
        string telegram;
        address creator;
        uint256 tokensAvailable;
        uint256 tokensSold;
        uint256 bnbRaised;
        uint256 fundingGoal;
        bool isGraduated;
        address pairAddress;
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;
    uint256 public constant INITIAL_POOL_SUPPLY = 800_000_000 * 10**18;
    uint256 public constant LP_TOKEN_AMOUNT = 200_000_000 * 10**18;
    uint256 public constant MIN_FUNDING_GOAL = 1 ether;
    uint256 public constant MAX_FUNDING_GOAL = 10 ether;
    // 设计：地址最后 4 个 hex 字符 == "9999"，即 address & 0xFFFF == 0x9999 == 39321
    uint256 public constant SALT_TARGET_SUFFIX = 0x9999;
    uint256 public constant TRADE_FEE_BPS = 50;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SLIPPAGE_BPS = 500; // 5% max slippage ?95% min

    // ═══ 联合曲线虚拟参数 (用户硬约束) ═══
    // 用户硬约束 3 个 (与 BondingCurveMarket 相同):
    //   A. 内盘毕业价 (S=800M) = Pancake 价 = fundingGoal/200M
    //   B. 卖出 800M token 触发毕业
    //   C. bnRaised(800M) = fundingGoal 严格 (不超募)
    //
    // 2026-07-08 redesign: 之前 V_T=885.8M, V_B=0.429F 是按注释的
    //   price(S) = V_B / (V_T - S) 公式推出来的,但代码实际用
    //   cost = K * Δ / (vT * vTAfter) = constant product 公式.
    //   两套公式数学不互通,导致 V5 实际卖到 S≈620M 就触发毕业,
    //   180M token 卡死在 launchpad.
    //
    // 修复: 反解 constant product 公式同时满足 A+B+C, 唯一解:
    //   V_T = 3200M / 3 ≈ 1066.67M
    //   V_B = F / 3
    //   (K = V_T × V_B, V_T - 800M = 266.67M)
    // 验证: cost(800M) = K × [1/266.67M - 1/1066.67M] = F 严格成立
    //       marginal(800M) = K / (266.67M)² = F/200M = Pancake 价
    uint256 public constant VIRTUAL_POOL_TOKENS = 1066666667 * 10**18;

    // 单钱包累计持有上限：TOTAL_SUPPLY x 5% = 5000万 token
    // 仅在内盘（isGraduated = false）生效
    // 毕业去 Pancake 后不限制
    uint256 public constant MAX_WALLET_HOLD_BPS = 500; // 5%
    uint256 public constant MAX_WALLET_HOLD = 50_000_000 * 10**18; // 5% of TOTAL_SUPPLY

    uint256 public creationFee = 0.001 ether;  // 2026-07-08: 1e15 wei
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant FEE_WALLET = 0x4075C1Ba34Cc6fF7beA78ee855Ed0c656ACaDC30;

    address public pancakeRouterAddress;
    address public pancakeFactoryAddress;

    address[] public allDeployedTokens;
    mapping(address => TokenInfo) public tokenRegistry;
    mapping(address => mapping(address => uint256)) public userInvestments;
    // 内盘阶段每个钱包对每个 token 的累计持有量
    mapping(address => mapping(address => uint256)) public walletHoldings;
    // 每个 token 的用户总支付 BNB（含0.5%手续费，不含退款）。
    // 毕业条件考虑手续费：bnbRaised 只记净曲线资金永远 < fundingGoal；
    // totalBnbPaid 记含税总额，达到 fundingGoal 即可毕业。
    mapping(address => uint256) public totalBnbPaid;

    event TokenCreated(
        address indexed tokenAddress,
        string name,
        string symbol,
        string logoUrl,
        string twitter,
        string telegram,
        address indexed creator,
        uint256 fundingGoal,
        uint256 buyTaxRate,
        uint256 sellTaxRate,
        uint256 marketShare,
        uint256 burnShare,
        uint256 reflectShare,
        uint256 liquidityShare,
        uint256 minHoldForReward,
        address reflectionAsset
    );
    event TokenPurchased(address indexed tokenAddress, address indexed buyer, uint256 tokenAmount, uint256 bnbSpent, uint256 bnbFee, uint256 currentSupplySold);
    event TokenSold(address indexed tokenAddress, address indexed seller, uint256 tokenAmount, uint256 bnbReceived, uint256 bnbFee);
    event TokenGraduated(address indexed tokenAddress, address indexed pairAddress, uint256 bnbInjected, uint256 tokensInjected);
    /// @notice 当 bnbRaised >= fundingGoal 时 emit (但未自动毕业), 等待任何人触发 graduate()
    event ShouldGraduate(address indexed tokenAddress, uint256 bnbRaised, uint256 fundingGoal);

    constructor(address _pancakeRouter, bytes memory creationCodeArg) Ownable() {
        _transferOwnership(msg.sender);
        require(creationCodeArg.length > 100, "Bad meme template");
        // BUGFIX 2026-07-08: was `_memeTokenCreationCode = _memeTokenCreationCode;` which
        // Silently mapped BOTH sides to the constructor PARAMETER (parameter name shadows
        // the state var of the same name in Solidity, no compile error). The state var
        // stayed empty, and `_getCreationCode()` returned length=0 bytes on every
        // `createToken` → CREATE2 always reverted with empty init code. Fixed by
        // renaming the parameter so the LHS unambiguously refers to state storage.
        _memeTokenCreationCode = creationCodeArg;
        pancakeRouterAddress = _pancakeRouter;
        address factory;
        bytes memory factoryCall = abi.encodeWithSelector(IPancakeRouter.factory.selector);
        (bool ok, bytes memory ret) = _pancakeRouter.staticcall(factoryCall);
        if (ok && ret.length >= 32) {
            assembly ("memory-safe") { factory := mload(add(ret, 32)) }
            pancakeFactoryAddress = factory;
        }
    }

    // ─── 定价：pump.fun 联合曲线 + 虚拟 V_T（用户硬约束）───────────────
    // 用户硬约束（与 BondingCurveMarket 同步）:
    //   A. 内盘毕业价 (S=800M) = Pancake 价 = fundingGoal/200M  (无跳变)
    //   B. 卖出 800M token 触发毕业
    //   C. bnRaised(800M) = fundingGoal 严格 (不超募)
    //
    // 推导（pump.fun 风格 x*y=k + 虚拟 V_T）:
    //   price(S) = V_B / (V_T - S)
    //   V_T = 885.8M token (虚拟, 不等于 TOTAL_SUPPLY=1B)
    //   V_B = fundingGoal × 85.8M / 200M = 0.429 × fundingGoal
    //   K = V_T / (V_T - 800M) ≈ 10.32x 跳变
    //   bnRaised(800M) = V_B × ln(V_T/(V_T-800M)) ≈ fundingGoal ✓
    //
    // 买 Δ 个 token：cost = k × Δ / ((V_T - S)(V_T - S - Δ))
    // 卖 Δ 个 token：payout = k × Δ / ((V_T - S)(V_T - S + Δ))

    function getVirtualBNBReserve(uint256 fundingGoal) public pure returns (uint256) {
        // 2026-07-08 redesign: V_B = fundingGoal / 3, 让 constant product 公式下
        //   marginal(800M) = F/200M (Pancake 价) 严格成立
        return fundingGoal / 3;
    }

    function getBuyCost(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo memory info = tokenRegistry[tokenAddress];
        if (!(info.tokenAddress != address(0))) revert ErrTokenNotFound();
        if (!(info.tokensAvailable >= tokenAmount)) revert ErrInsufficientTokens();
        if (tokenAmount == 0) return 0;

        uint256 virtualToken = VIRTUAL_POOL_TOKENS;
        uint256 virtualBNB = getVirtualBNBReserve(info.fundingGoal);
        uint256 k = virtualToken * virtualBNB;

        uint256 vT = virtualToken - info.tokensSold;
        uint256 vTAfter = vT - tokenAmount;
        if (!(vTAfter > 0)) revert ErrExceedsPool();

        // cost = k × Δ / (vT × vTAfter)
        uint256 cost = k * tokenAmount / (vT * vTAfter);
        return cost > 0 ? cost : 1; // 精度保护
    }

    function getSellPayout(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo memory info = tokenRegistry[tokenAddress];
        if (!(info.tokenAddress != address(0))) revert ErrTokenNotFound();
        if (tokenAmount == 0) return 0;

        uint256 virtualToken = VIRTUAL_POOL_TOKENS;
        uint256 virtualBNB = getVirtualBNBReserve(info.fundingGoal);
        uint256 k = virtualToken * virtualBNB;

        uint256 vT = virtualToken - info.tokensSold;
        uint256 vTAfter = vT + tokenAmount;

        // payout = k × Δ / (vT × vTAfter)
        uint256 payout = k * tokenAmount / (vT * vTAfter);
        return payout > 0 ? payout : 1;
    }

    function getTokenFundingGoal(address tokenAddress) public view returns (uint256) {
        return tokenRegistry[tokenAddress].fundingGoal;
    }

    function getTokenPair(address tokenAddress) public view returns (address) {
        return tokenRegistry[tokenAddress].pairAddress;
    }

    // ─── 创建代币（CREATE2 9999 尾号 + 税费初始化） ──────────────────

    function createToken(
        string memory name,
        string memory symbol,
        string memory description,
        string memory logoUrl,
        string memory website,
        string memory twitter,
        string memory telegram,
        uint256 fundingGoal,
        uint256 _buyTaxRate,
        uint256 _sellTaxRate,
        uint256 _marketShare,
        uint256 _burnShare,
        uint256 _reflectShare,
        uint256 _liquidityShare,
        uint256 _minHoldForReward,
        address _marketWallet,
        address _reflectionAsset,
        uint8 _dividendMode,   // 2026-07-07: 0=HOLDER 持币人 / 1=LP LP持有人
        uint256 salt,
        address[] calldata whitelist  // 白名单地址（免税），最多 50 个；空数组 = 无白名单
    ) external payable nonReentrant returns (address) {
        if (!(msg.value >= creationFee)) revert ErrFeeRequired();
        if (!(fundingGoal >= MIN_FUNDING_GOAL && fundingGoal <= MAX_FUNDING_GOAL)) revert ErrRange1To10();
        if (!(_buyTaxRate <= 1000)) revert ErrBuyTaxTooHigh();
        if (!(_sellTaxRate <= 1000)) revert ErrSellTaxTooHigh();
        // 4 类分配总和必须 = 100%
        if (!(_marketShare + _burnShare + _reflectShare + _liquidityShare == 100)) revert ErrSharesNot100();
        // 2026-07-07: 分红模式 (0=HOLDER 持币人 / 1=LP LP持有人)
        if (!(_dividendMode <= 1)) revert ErrUnknown();

        address tokenAddr = _deployToken(
            name, symbol,
            _buyTaxRate, _sellTaxRate,
            _marketShare, _burnShare, _reflectShare, _liquidityShare,
            _minHoldForReward, _marketWallet, _reflectionAsset,
            _dividendMode,
            salt,
            whitelist
        );
        _registerToken(tokenAddr, name, symbol, description, logoUrl, website, twitter, telegram, fundingGoal);

        payable(FEE_WALLET).transfer(creationFee);

        // 多余 BNB = 创始人首次买入 (auto-buy, ABI 不变)
        uint256 creatorBuyBNB = msg.value > creationFee ? msg.value - creationFee : 0;
        if (creatorBuyBNB > 0) {
            uint256 fee = creatorBuyBNB * TRADE_FEE_BPS / BPS_DENOMINATOR;
            uint256 net = creatorBuyBNB - fee;
            if (fee > 0) payable(FEE_WALLET).transfer(fee);

            uint256 currentHold = walletHoldings[tokenAddr][msg.sender];
            uint256 maxBuyThisTime = MAX_WALLET_HOLD > currentHold ? MAX_WALLET_HOLD - currentHold : 0;
            uint256 availableForWallet = tokenRegistry[tokenAddr].tokensAvailable < maxBuyThisTime
                ? tokenRegistry[tokenAddr].tokensAvailable : maxBuyThisTime;

            (uint256 tokens, uint256 cost) = _calcBuyTokens(tokenAddr, net, availableForWallet);
            if (tokens > 0) {
                _executeBuy(tokenAddr, tokens, cost, net, fee);
                // _executeBuy 已更新 totalBnbPaid 并检查毕业条件，此处无需重复触发
            }

            uint256 unused = net > cost ? net - cost : 0;
            if (unused > 0) payable(msg.sender).transfer(unused);
        }

        emit TokenCreated(tokenAddr, name, symbol, logoUrl, twitter, telegram, msg.sender, fundingGoal, _buyTaxRate, _sellTaxRate, _marketShare, _burnShare, _reflectShare, _liquidityShare, _minHoldForReward, _reflectionAsset);
        return tokenAddr;
    }

    function _registerToken(
        address tokenAddr, string memory name, string memory symbol,
        string memory description, string memory logoUrl, string memory website,
        string memory twitter, string memory telegram, uint256 fundingGoal
    ) internal {
        TokenInfo storage info = tokenRegistry[tokenAddr];
        info.tokenAddress = tokenAddr;
        info.name = name;
        info.symbol = symbol;
        info.description = description;
        info.logoUrl = logoUrl;
        info.website = website;
        info.twitter = twitter;
        info.telegram = telegram;
        info.creator = msg.sender;
        info.tokensAvailable = INITIAL_POOL_SUPPLY;
        info.tokensSold = 0;
        info.bnbRaised = 0;
        info.fundingGoal = fundingGoal;
        info.isGraduated = false;
        info.pairAddress = address(0);
        allDeployedTokens.push(tokenAddr);
    }

    // 2026-07-07: MemeToken creation code 由 constructor 注入,不再用 type(MemeToken).creationCode
    bytes private _memeTokenCreationCode;
    function _getCreationCode() public view returns (bytes memory) {
        return _memeTokenCreationCode;
    }

    function _deployToken(
        string memory name, string memory symbol,
        uint256 _buyTaxRate, uint256 _sellTaxRate,
        uint256 _marketShare, uint256 _burnShare, uint256 _reflectShare, uint256 _liquidityShare,
        uint256 _minHoldForReward, address _marketWallet, address _reflectionAsset,
        uint8 _dividendMode,
        uint256 salt,
        address[] calldata whitelist
    ) internal returns (address) {
        // 关键：构造函数第 4 个参数传 address(this)（launchpad 自己），
        // 这样 MemeToken.launchpad = launchpad 合约地址（immutable），gradute 时能调 setPair。
        // 2026-07-07: 多传一个 _dividendMode (0=HOLDER 持币人 / 1=LP LP持有人)
        bytes memory initCode = abi.encodePacked(
            _getCreationCode(),
            abi.encode(name, symbol, TOTAL_SUPPLY, address(this), _reflectionAsset, pancakeRouterAddress, _dividendMode)
        );
        bytes32 codeHash = keccak256(initCode);

        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
        );
        if (!((uint256(uint160(predicted)) & 0xFFFF) == SALT_TARGET_SUFFIX)) revert ErrSaltSuffix();

        address tokenAddr;
        assembly ("memory-safe") {
            tokenAddr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (!(tokenAddr == predicted)) revert ErrCreate2Mismatch();

        // 1. 写入创建者填的税参数（owner = launchpad，所以能调）
        //    marketWallet 也在这一步一次性写死 → 后面 renounce 后无法再改
        IMemeToken(tokenAddr).initTaxConfig(
            _buyTaxRate, _sellTaxRate,
            _marketShare, _burnShare, _reflectShare, _liquidityShare,
            _minHoldForReward,
            _marketWallet
        );

        // 2. 批量设置白名单（免税地址）—— 必须在 renounceOwnership 之前
        //    白名单地址在 Pancake 买入/卖出时均不收 buyTaxRate/sellTaxRate
        if (whitelist.length > 0) {
            IMemeToken(tokenAddr).initWhitelist(whitelist);
        }

        // 3. 立即 renounce → owner = 0x0
        //    之后 setTaxConfig / setTaxExclusion 等 onlyOwner 函数永久 revert
        //    创建者填的税参数和 marketWallet 永远固定，create 后没人能改
        IMemeToken(tokenAddr).renounceOwnership();

        // 3. 让 MemeToken 授权 Pancake router 无限授权 (reflection swap 用)
        //    这一步必须在 renounceOwnership 之后,owner=0x0,只有 onlyLaunchpad (我们) 能调
        //    之前是在 MemeToken 构造函数里做这个,但那是个 no-op bug (调用 address(this) 当时还没有 runtime code),
        //    移到外部调。initRouterApproval 内部会自己 approve router
        IMemeToken(tokenAddr).initRouterApproval();

        return tokenAddr;
    }

    // ─── 内盘买入 ────────────────────────────────────────────────

    function buyTokens(address tokenAddress) external payable nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (!(info.tokenAddress != address(0))) revert ErrTokenNotFound();
        if (!(!info.isGraduated)) revert ErrAlreadyGraduated();
        if (!(msg.value > 0)) revert ErrNoBnb();

        // 兜底：token 已卖光但未毕业 → 尝试毕业，然后退款 revert
        if (info.tokensAvailable == 0) {
            address(this).call(abi.encodeWithSelector(this._autoGraduate.selector, tokenAddress));
            payable(msg.sender).transfer(msg.value);
            revert ErrUnknown();
        }

        uint256 bnbAmount = msg.value;
        uint256 feeAmount = (bnbAmount * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 bnbForCurve = bnbAmount - feeAmount;
        if (feeAmount > 0) {
            payable(FEE_WALLET).transfer(feeAmount);
        }

        // 单钱包累计持有上限检查（仅内盘）
        uint256 currentHold = walletHoldings[tokenAddress][msg.sender];
        uint256 maxBuyThisTime = MAX_WALLET_HOLD > currentHold ? MAX_WALLET_HOLD - currentHold : 0;
        if (!(maxBuyThisTime > 0)) revert ErrUnknown();
        uint256 availableForWallet = info.tokensAvailable < maxBuyThisTime ? info.tokensAvailable : maxBuyThisTime;

        (uint256 tokensToBuy, uint256 exactCost) = _calcBuyTokens(tokenAddress, bnbForCurve, availableForWallet);
        if (!(tokensToBuy > 0)) revert ErrUnknown();

        _executeBuy(tokenAddress, tokensToBuy, exactCost, bnbForCurve, feeAmount);
    }

    function _calcBuyTokens(address tokenAddress, uint256 bnbForCurve, uint256 available) internal view returns (uint256 tokensToBuy, uint256 exactCost) {
        uint256 low = 0;
        uint256 high = available;
        uint256 t = 0;
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            uint256 estimatedCost = getBuyCost(tokenAddress, mid);
            if (estimatedCost <= bnbForCurve) {
                t = mid;
                low = mid + 1;
            } else {
                if (mid == 0) break;
                high = mid - 1;
            }
        }
        tokensToBuy = t;
        exactCost = getBuyCost(tokenAddress, t);
    }

    function _executeBuy(address tokenAddress, uint256 tokensToBuy, uint256 exactCost, uint256 bnbForCurve, uint256 feeAmount) internal {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        uint256 refundAmount = bnbForCurve - exactCost;

        info.tokensSold += tokensToBuy;
        info.tokensAvailable -= tokensToBuy;
        info.bnbRaised += exactCost;
        totalBnbPaid[tokenAddress] += (exactCost + feeAmount);
        userInvestments[tokenAddress][msg.sender] += exactCost;
        walletHoldings[tokenAddress][msg.sender] += tokensToBuy;
        IMemeToken(tokenAddress).transfer(msg.sender, tokensToBuy);

        if (refundAmount > 0) {
            payable(msg.sender).transfer(refundAmount);
        }

        emit TokenPurchased(tokenAddress, msg.sender, tokensToBuy, exactCost, feeAmount, info.tokensSold);

        // 毕业条件（任一满足即触发）：
        //   主条件: tokensSold >= 800M（内盘卖完）
        //   辅条件: totalBnbPaid >= fundingGoal（用户总支付含0.5%手续费达募集目标）
        if (!info.isGraduated && (info.tokensSold >= INITIAL_POOL_SUPPLY || totalBnbPaid[tokenAddress] >= info.fundingGoal)) {
            emit ShouldGraduate(tokenAddress, info.bnbRaised, info.fundingGoal);
            address(this).call(abi.encodeWithSelector(this._autoGraduate.selector, tokenAddress));
        }
    }

    /// @notice 任何人可调用, 触发 token 毕业到 PancakeSwap
    /// @dev 2-tx 模式: 用户 buyTokens 已成功, 这里只把流动性加到 Pancake
    ///   - 失败只会 revert 本次 graduate() 调用, 不影响用户的买入
    ///   - 触发者可以是任何人 (用户、creator、链上机器人、运营钱包)
    /// @dev 2026-07-09: trigger 改用 tokensSold >= INITIAL_POOL_SUPPLY (800M) 为主, bnbRaised 作 fallback
    function graduate(address tokenAddress) external nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (!(info.tokenAddress != address(0))) revert ErrUnknown();
        if (!(!info.isGraduated)) revert ErrUnknown();
        if (!(info.tokensSold >= INITIAL_POOL_SUPPLY || totalBnbPaid[tokenAddress] >= info.fundingGoal)) {
            revert ErrUnknown();
        }
        _graduateToken(tokenAddress);
    }

    /// @notice 2026-07-08: 自动毕业入口,只在 buyTokens/createToken 触发毕业条件时由合约自己调用
    /// @dev 设计要点:
    ///   1. 不带 nonReentrant — 通过 low-level call 从 buyTokens (nonReentrant) 调用,绕过重入锁
    ///   2. require(msg.sender == address(this)) — 只允许合约自身调用,防外部触发
    ///   3. 失败不 revert 外层 tx (low-level call 失败时 buyTokens 仍成功)
    ///   4. Pancake 临时不通 → 这次失败 → 下次 buy 自动再试,直到成功
    ///   5. 保留 public graduate() 作为人工 fallback (万一 Pancake 长时间不通)
    /// @dev 2026-07-09: trigger 同 graduate() — 任一条件满足即可
    function _autoGraduate(address tokenAddress) external {
        require(msg.sender == address(this), "only self");
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (info.tokenAddress == address(0)) return;
        if (info.isGraduated) return;
        if (info.tokensSold < INITIAL_POOL_SUPPLY && totalBnbPaid[tokenAddress] < info.fundingGoal) return;
        _graduateToken(tokenAddress);
    }

    // ─── 内盘卖出 ────────────────────────────────────────────────

    function sellTokens(address tokenAddress, uint256 tokenAmount) external nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (!(info.tokenAddress != address(0))) revert ErrTokenNotFound();
        if (!(!info.isGraduated)) revert ErrUnknown();
        // 2-tx 模式下, 达到阈值后禁止内盘卖出 (避免破坏"半毕业"状态)
        // 用户应在 Pancake 上 swap 卖出
        if (!(info.bnbRaised < info.fundingGoal)) revert ErrUnknown();
        if (!(tokenAmount > 0)) revert ErrUnknown();

        uint256 currentSold = info.tokensSold;
        if (!(currentSold >= tokenAmount)) revert ErrUnknown();

        // pump.fun 反向公式（卖 Δ token 回收 BNB，虚拟 V_T）：
        // payout = k × Δ / ((V_T - S) × (V_T - S + Δ))
        uint256 virtualToken = VIRTUAL_POOL_TOKENS;
        uint256 virtualBNB = getVirtualBNBReserve(info.fundingGoal);
        uint256 k = virtualToken * virtualBNB;

        uint256 vT = virtualToken - currentSold;
        uint256 vTAfter = vT + tokenAmount;
        uint256 bnbPayout = k * tokenAmount / (vT * vTAfter);
        if (bnbPayout == 0 && tokenAmount > 0) bnbPayout = 1; // 精度保护
        if (!(info.bnbRaised >= bnbPayout)) revert ErrUnknown();

        uint256 feeAmount = (bnbPayout * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 bnbToSeller = bnbPayout - feeAmount;

        info.tokensSold = currentSold - tokenAmount;
        info.tokensAvailable += tokenAmount;
        info.bnbRaised -= bnbPayout;
        walletHoldings[tokenAddress][msg.sender] -= tokenAmount;  // 卖出时减少累计持有
        IMemeToken(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);

        if (feeAmount > 0) {
            payable(FEE_WALLET).transfer(feeAmount);
        }
        payable(msg.sender).transfer(bnbToSeller);

        emit TokenSold(tokenAddress, msg.sender, tokenAmount, bnbToSeller, feeAmount);
        // 卖出后也检查毕业条件（tokensSold 可能仍 >= 800M）
        if (!info.isGraduated && (info.tokensSold >= INITIAL_POOL_SUPPLY || totalBnbPaid[tokenAddress] >= info.fundingGoal)) {
            emit ShouldGraduate(tokenAddress, info.bnbRaised, info.fundingGoal);
            address(this).call(abi.encodeWithSelector(this._autoGraduate.selector, tokenAddress));
        }
    }

    // ─── 毕业：自动添加 PancakeSwap 流动性（four.meme 风格） ─────────
    // isGraduated 在 Pancake 调用成功后才设置，失败不锁死
    //
    // 毕业时分配（参考 four.meme 设计）：
    //   - 加 Pancake:  2亿 token (TOTAL_SUPPLY x 20%) + 99% bnbRaised
    //   - 留合约:      1% bnbRaised（平台手续费归 FEE_WALLET）
    //   - 销毁:        0（曲线卖出 8亿 + 加 Pancake 2亿 = 10亿，恰好等于 TOTAL_SUPPLY）
    //
    // Pancake 起始价 = (99% x fundingGoal) / 2亿
    // 内盘终点价   = V_B / (V_T - INITIAL_POOL) = fundingGoal/4 / 2亿
    // Pancake/内盘 ~= 4x（向上小幅跳变，four.meme 也是这样设计）
    //
    // 毕业后安全操作：
    //   - 销毁 LP token（全部 transfer 到 DEAD_ADDRESS）→ 流动性永久锁定
    //   - renounce ownership → 所有 onlyOwner 函数失效，合约权限干净
    uint256 public constant LP_BNB_BPS = 9900;                       // (legacy) 实际现在 Pancake 加 fundingGoal BNB
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;  // LP token 黑洞销毁地址

    function _graduateToken(address tokenAddress) internal {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (!(!info.isGraduated)) revert ErrUnknown();

        uint256 bnbRaised = info.bnbRaised;
        if (!(bnbRaised > 0)) revert ErrUnknown();
        if (!(address(this).balance >= bnbRaised)) revert ErrUnknown();

        // 设计：Pancake 池 = fundingGoal BNB + 200M token (用户原话"按设置募集到的资金金额加 200000000 创建 pancake")
        // Pancake 价 = fundingGoal / 200M = 内盘毕业价 ✓ (用户硬约束 A)
        // 用 pump.fun 曲线 + VIRTUAL_POOL_TOKENS = 886M:
        //   bnRaised(800M) = fundingGoal 严格 (用户硬约束 C, 数学必然)
        // 触发: bnbRaised >= fundingGoal
        // Pancake 加 fundingGoal BNB (= min(bnbRaised, fundingGoal)), 其余归 FEE_WALLET
        uint256 bnbForLP = bnbRaised > info.fundingGoal ? info.fundingGoal : bnbRaised;
        uint256 bnbForFee = bnbRaised - bnbForLP;

        // 加 LP 的 token 数: min(实际剩余, 2亿)
        // 极端情况: 实际剩 < 2 亿 (曲线没卖够), 用实际剩余
        uint256 tokRemaining = TOTAL_SUPPLY - info.tokensSold;
        uint256 factoryHeldTokens = tokRemaining < LP_TOKEN_AMOUNT ? tokRemaining : LP_TOKEN_AMOUNT;

        // 授权 PancakeRouter 花费代币
        IMemeToken(tokenAddress).approve(pancakeRouterAddress, factoryHeldTokens);

        // 滑点保护 95% 最小金额
        uint256 minToken = factoryHeldTokens - (factoryHeldTokens * SLIPPAGE_BPS / BPS_DENOMINATOR);
        uint256 minBnb = bnbForLP - (bnbForLP * SLIPPAGE_BPS / BPS_DENOMINATOR);

        bytes memory addLiqData = abi.encodeWithSelector(
            IPancakeRouter.addLiquidityETH.selector,
            tokenAddress, factoryHeldTokens, minToken, minBnb, address(this), block.timestamp + 3600
        );
        (bool ok,) = pancakeRouterAddress.call{value: bnbForLP}(addLiqData);
        if (!(ok)) revert ErrUnknown();

        // 平台手续费（剩余 BNB）归 FEE_WALLET
        if (bnbForFee > 0) {
            payable(FEE_WALLET).transfer(bnbForFee);
        }

        // 仅在 Pancake addLiquidityETH 成功后才标记毕业
        info.isGraduated = true;

        address pairAddress = _getPair(tokenAddress);
        info.pairAddress = pairAddress;

        // 配置税费排除（设置 pair 地址，启用 Pancake 买卖税）
        _configureTaxExclusions(tokenAddress, pairAddress);

        // 毕业后安全收尾：销毁 LP token + 丢弃 owner 权限
        _renounceAndBurnLP(pairAddress);

        emit TokenGraduated(tokenAddress, pairAddress, bnbForLP, factoryHeldTokens);
    }

    /// @notice 销毁 LP token 到黑洞地址，永久锁定流动性
    /// @dev MemeToken 的 ownership 在 _deployToken 中已 renounce，无需在此重复。
    ///      Launchpad 自身的 ownership 不能在这里 renounce，否则第一个代币毕业后
    ///      所有 onlyOwner 管理函数（updateCreationFee/setPancakeRouter/withdrawProtocolFees 等）全部失效。
    function _renounceAndBurnLP(address pair) internal {
        if (pair != address(0)) {
            uint256 lpBalance = IERC20LP(pair).balanceOf(address(this));
            if (lpBalance > 0) {
                IERC20LP(pair).transfer(DEAD_ADDRESS, lpBalance);
            }
        }
    }

    function _getPair(address tokenAddress) internal view returns (address) {
        if (pancakeFactoryAddress == address(0)) return address(0);
        bytes memory data = abi.encodeWithSelector(IPancakeFactory.getPair.selector, tokenAddress, WBNB);
        (bool ok, bytes memory ret) = pancakeFactoryAddress.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        address pair;
        assembly ("memory-safe") { pair := mload(add(ret, 32)) }
        return pair;
    }

    function _configureTaxExclusions(address tokenAddress, address pair) internal {
        // 简化：MemeToken 现在只有 setPair 一个 launchpad-only 函数。
        // 因为 TAX_RATE = 0，setPair 实际只用于前端展示 / 事件记录。
        // 但保留它仍然有价值：
        //   1) 前端 / 区块浏览器可以正确显示 Pancake pair 地址
        //   2) 未来如果启用 transfer tax，逻辑可以无缝接入
        if (pair != address(0)) {
            _tryTokenCall(tokenAddress, abi.encodeWithSelector(IMemeToken.setPair.selector, pair));
        }
    }

    function _tryTokenCall(address token, bytes memory data) internal {
        (bool success,) = token.call(data);
        success; // 静默忽略失败
    }

    // ─── 管理函数 ─────────────────────────────────────────────────

    function updateCreationFee(uint256 _newFee) external onlyOwner { creationFee = _newFee; }

    function setPancakeRouter(address _router) external onlyOwner {
        pancakeRouterAddress = _router;
        bytes memory factoryCall = abi.encodeWithSelector(IPancakeRouter.factory.selector);
        (bool ok, bytes memory ret) = _router.staticcall(factoryCall);
        if (ok && ret.length >= 32) {
            address factory;
            assembly ("memory-safe") { factory := mload(add(ret, 32)) }
            pancakeFactoryAddress = factory;
        }
    }

    function fixTokenTaxExclusions(address tokenAddress) external onlyOwner {
        address pair = _getPair(tokenAddress);
        if (pair != address(0)) {
            tokenRegistry[tokenAddress].pairAddress = pair;
        }
        _configureTaxExclusions(tokenAddress, pair);
    }

    function fixAllTokenTaxExclusions() external onlyOwner {
        for (uint i = 0; i < allDeployedTokens.length; i++) {
            address tokenAddress = allDeployedTokens[i];
            address pair = _getPair(tokenAddress);
            if (pair != address(0)) {
                tokenRegistry[tokenAddress].pairAddress = pair;
            }
            _configureTaxExclusions(tokenAddress, pair);
        }
    }

    function withdrawProtocolFees() external onlyOwner {
        uint256 contractBalance = address(this).balance;
        uint256 totalReserves = 0;
        for (uint i = 0; i < allDeployedTokens.length; i++) {
            address tokAdd = allDeployedTokens[i];
            if (!tokenRegistry[tokAdd].isGraduated) {
                totalReserves += tokenRegistry[tokAdd].bnbRaised;
            }
        }
        uint256 feesCollected = contractBalance > totalReserves ? contractBalance - totalReserves : 0;
        if (!(feesCollected > 0)) revert ErrUnknown();
        payable(owner()).transfer(feesCollected);
    }

    function getDeployedTokensCount() external view returns (uint256) {
        return allDeployedTokens.length;
    }

    receive() external payable {}
}
