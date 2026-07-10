// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./BaseMemeToken.sol";

interface IMemeTokenBase {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
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

/**
 * @title BondingCurveMarket
 * @dev 基础版：二次联合曲线定价，CREATE2 9999尾号，2.5%交易费，自动PancakeSwap流动性
 * 优化点：
 *   1. 毕业逻辑：isGraduated 在 Pancake 调用成功后才设置，失败不锁死
 *   2. 精度保护：buyCost 最小返回 1 wei，防止零成本漏洞
 *   3. 滑点保护：addLiquidityETH 使用 95% 最小金额
 *   4. 发行费可更新
 */
contract BondingCurveMarket is Ownable, ReentrancyGuard {
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
    // 用户要求 3 个核心约束同时严格满足:
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
    uint256 public constant VIRTUAL_POOL_TOKENS = 1066666667 * 10**18;  // ≈ 1066.67M, 让 A+B+C 严格满足

    // 单钱包累计持有上限：TOTAL_SUPPLY x 5% = 5000万 token
    // 仅在内盘（isGraduated = false）生效
    // 毕业去 Pancake 后不限制
    uint256 public constant MAX_WALLET_HOLD_BPS = 500; // 5%
    uint256 public constant MAX_WALLET_HOLD = 50_000_000 * 10**18; // 5% of TOTAL_SUPPLY

    // 2026-07-09: graduation trigger — 内盘已卖 token 数 ≥ 8亿 (留 2 亿给 Pancake LP).
    // 之前用 bnbRaised >= fundingGoal 作 trigger, 但 5% wallet cap + 0.5% fee + 多用户 buy/sell
    // 让 S=800M 时 bnbRaised 可能仍 < fundingGoal, _autoGraduate 永远不 fire, token 卡死.
    // 改用 tokensSold 作为主 trigger, bnbRaised 作 fallback (任一满足即可).
    uint256 public constant GRADUATION_TOKENS = 800_000_000 * 10**18; // 8亿 (留 2亿给 Pancake LP)

    uint256 public creationFee = 0.001 ether;  // 2026-07-08: 1e15 wei (跟 TokenLaunchpad 同价)
    address public constant FEE_WALLET = 0x4075C1Ba34Cc6fF7beA78ee855Ed0c656ACaDC30;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address public pancakeRouterAddress;
    address public pancakeFactoryAddress;

    address[] public allDeployedTokens;
    mapping(address => TokenInfo) public tokenRegistry;
    // 记录每个 token 的部署时间（block.timestamp，秒）。用来让前端按"最新创建"排序。
    // 旧合约（用硬编码字节码部署的 token）永远返回 0；前端会按 fallback 排序。
    mapping(address => uint256) public deployedAtOf;
    mapping(address => mapping(address => uint256)) public userInvestments;
    // 内盘阶段每个钱包对每个 token 的累计持有量（仅内盘追踪，毕业前有效）
    mapping(address => mapping(address => uint256)) public walletHoldings;
    // 每个 token 的用户总支付 BNB（含0.5%手续费，不含退款）。
    // 买入时用户实际花费 = cost(曲线成本) + fee(手续费)，退款部分不计入。
    // 用途：毕业条件考虑手续费——bnbRaised 只记净曲线资金，永远 < fundingGoal；
    //       totalBnbPaid 记含税总额，达到 fundingGoal 即可毕业。
    mapping(address => uint256) public totalBnbPaid;

    event TokenCreated(
        address indexed tokenAddress, string name, string symbol,
        string logoUrl, string twitter, string telegram,
        address indexed creator, uint256 fundingGoal
    );
    event TokenPurchased(
        address indexed tokenAddress, address indexed buyer,
        uint256 tokenAmount, uint256 bnbSpent, uint256 bnbFee,
        uint256 currentSupplySold
    );
    event TokenSold(
        address indexed tokenAddress, address indexed seller,
        uint256 tokenAmount, uint256 bnbReceived, uint256 bnbFee
    );
    event TokenGraduated(
        address indexed tokenAddress, address indexed pairAddress,
        uint256 bnbInjected, uint256 tokensInjected
    );
    /// @notice 当 bnbRaised >= fundingGoal 时 emit (但未自动毕业), 等待任何人触发 graduate()
    event ShouldGraduate(
        address indexed tokenAddress, uint256 bnbRaised, uint256 fundingGoal
    );

    constructor(address _pancakeRouter) Ownable() {
        _transferOwnership(msg.sender);
        pancakeRouterAddress = _pancakeRouter;
        address factory;
        bytes memory c = abi.encodeWithSelector(IPancakeRouter.factory.selector);
        (bool ok, bytes memory ret) = _pancakeRouter.staticcall(c);
        if (ok && ret.length >= 32) {
            assembly ("memory-safe") { factory := mload(add(ret, 32)) }
            pancakeFactoryAddress = factory;
        }
    }

    // ─── 定价：pump.fun 联合曲线 + 虚拟 V_T（用户硬约束）───────────────
    // 用户 3 个硬约束:
    //   A. 内盘毕业价 (S=800M) = Pancake 价 = fundingGoal/200M  (无跳变)
    //   B. 卖出 800M token 触发毕业
    //   C. bnRaised(800M) = fundingGoal  (严格, 不超募)
    //
    // 推导（pump.fun 风格 x*y=k）:
    //   price(S) = V_B / (V_T - S)    (wei-BNB per wei-token)
    //   A: V_B / (V_T - 800M) = fundingGoal/200M
    //      → V_B = fundingGoal × (V_T - 800M) / 200M
    //   C: bnRaised(800M) = V_B × ln(V_T/(V_T-800M)) = fundingGoal
    //      代入 V_B: fundingGoal × (V_T-800M)/200M × ln(V_T/(V_T-800M)) = fundingGoal
    //                (V_T-800M)/200M × ln(V_T/(V_T-800M)) = 1
    //      数值求解: V_T ≈ 885.8M token, K = V_T/(V_T-800M) ≈ 10.32x
    //   V_B = fundingGoal × 85.8M / 200M = fundingGoal × 0.429
    //
    // 关键: VIRTUAL_POOL_TOKENS 是 bonding curve 虚拟参数, 不等于 TOTAL_SUPPLY (= 1B)
    //   TOTAL_SUPPLY = 1B = 实际 mint 数量 (800M 内盘 + 200M Pancake)
    //   VIRTUAL_POOL_TOKENS = 886M = 价格公式里的虚拟 token 池
    //
    // 边际价曲线示例 (fundingGoal=1 BNB):
    //   S=0M,   price = 4.84e-10 BNB/token  (内盘初始价)
    //   S=400M, price = 8.83e-10 BNB/token
    //   S=800M, price = 5.00e-9 BNB/token   (内盘毕业价 = Pancake 价 ✓)
    //
    // 买 Δ 个 token：cost = k × Δ / ((V_T - S)(V_T - S - Δ))
    // 卖 Δ 个 token：payout = k × Δ / ((V_T - S)(V_T - S + Δ))
    //   其中 k = VIRTUAL_POOL_TOKENS × V_B

    /// @notice 虚拟 BNB 储备 V_B (让 A 严格满足)
    /// @dev 2026-07-08 redesign: V_B = fundingGoal / 3, 让 constant product 公式下
    ///     marginal(800M) = F/200M (Pancake 价) 严格成立
    function getVirtualBNBReserve(uint256 fundingGoal) public pure returns (uint256) {
        return fundingGoal / 3;
    }

    function getBuyCost(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo memory info = tokenRegistry[tokenAddress];
        require(info.tokenAddress != address(0), "Token not registered");
        require(info.tokensAvailable >= tokenAmount, "Insufficient tokens left");
        if (tokenAmount == 0) return 0;

        // cost = k × Δ / (vT × vTAfter)
        // k = V_T × V_B, vT = V_T - S, vTAfter = vT - Δ
        uint256 virtualToken = VIRTUAL_POOL_TOKENS;
        uint256 virtualBNB = getVirtualBNBReserve(info.fundingGoal);
        uint256 k = virtualToken * virtualBNB;

        uint256 vT = virtualToken - info.tokensSold;
        uint256 vTAfter = vT - tokenAmount;
        require(vTAfter > 0, "Exceeds virtual pool");

        uint256 cost = k * tokenAmount / (vT * vTAfter);
        return cost > 0 ? cost : 1;
    }

    function getSellPayout(address tokenAddress, uint256 tokenAmount) public view returns (uint256) {
        TokenInfo memory info = tokenRegistry[tokenAddress];
        require(info.tokenAddress != address(0), "Token not registered");
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

    // ─── 创建代币（CREATE2 9999 尾号?─────────────────────────────

    function createToken(
        string memory name, string memory symbol, string memory description,
        string memory logoUrl, string memory website, string memory twitter,
        string memory telegram, uint256 fundingGoal, uint256 salt
    ) external payable nonReentrant returns (address) {
        require(msg.value >= creationFee, "Fee required");
        require(fundingGoal >= MIN_FUNDING_GOAL && fundingGoal <= MAX_FUNDING_GOAL, "Range 1-10 BNB");

        address tokenAddr = _deploy(name, symbol, salt);
        _registerToken(tokenAddr, name, symbol, description, logoUrl, website, twitter, telegram, fundingGoal);

        // 先扣发行费给 FEE_WALLET
        if (creationFee > 0) payable(FEE_WALLET).transfer(creationFee);

        // 多余的 BNB = 创始人首次买入 (auto-buy)
        uint256 creatorBuyBNB = msg.value > creationFee ? msg.value - creationFee : 0;
        if (creatorBuyBNB > 0) {
            uint256 fee = creatorBuyBNB * TRADE_FEE_BPS / BPS_DENOMINATOR;
            uint256 net = creatorBuyBNB - fee;
            if (fee > 0) payable(FEE_WALLET).transfer(fee);

            // 单钱包 5% 上限检查
            uint256 currentHold = walletHoldings[tokenAddr][msg.sender];
            uint256 maxBuyThisTime = MAX_WALLET_HOLD > currentHold ? MAX_WALLET_HOLD - currentHold : 0;
            uint256 availableForWallet = info_tokensAvailable(tokenAddr) < maxBuyThisTime
                ? info_tokensAvailable(tokenAddr) : maxBuyThisTime;

            (uint256 tokens, uint256 cost) = _calcBuyTokens(tokenAddr, net, availableForWallet);
            if (tokens > 0) {
                _executeBuy(tokenAddr, tokens, cost, net, fee);
                // _executeBuy 已更新 totalBnbPaid 并检查毕业条件，此处无需重复触发
            }

            // 退还 net - cost (买 token 用不完的部分)
            uint256 unused = net > cost ? net - cost : 0;
            if (unused > 0) payable(msg.sender).transfer(unused);
        }

        emit TokenCreated(tokenAddr, name, symbol, logoUrl, twitter, telegram, msg.sender, fundingGoal);
        return tokenAddr;
    }

    /// @notice 辅助函数: 获取某 token 当前剩余可买数量
    function info_tokensAvailable(address tokenAddress) public view returns (uint256) {
        return tokenRegistry[tokenAddress].tokensAvailable;
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
        // 记录部署时间（秒）。前端 `fetchAllOnChainTokens` 用它按 createdAt 降序排序。
        // 对老 token（已用旧 factory 部署）会是 0，前端会用 index 倒推 fallback。
        deployedAtOf[tokenAddr] = block.timestamp;
        allDeployedTokens.push(tokenAddr);
    }

    // 2026-07-07: 用新 BaseMemeToken.sol (4-arg constructor, 无 OZ Ownable) 替代旧的内联字节码
    function _getCreate2Bytecode() public pure returns (bytes memory) {
        return type(BaseMemeToken).creationCode;
    }

    function _deploy(string memory name, string memory symbol, uint256 salt) internal returns (address) {
        // BUGFIX 2026-07-08: was abi.encode(name, symbol, TOTAL_SUPPLY, msg.sender) — mint 给了 creator 钱包,
        // 触发前端 5% 上限误判 (creator.balanceOf == 100% supply).
        // 修复: 第 4 参数改为 address(this) — BondingCurveMarket 自己持有全部 supply,
        // creator 钱包初始 0,前端 buy tab 正常工作.
        // 设计参照 TokenLaunchpad.sol line 386.
        bytes memory initCode = abi.encodePacked(
            _getCreate2Bytecode(),
            abi.encode(name, symbol, TOTAL_SUPPLY, address(this))
        );
        bytes32 codeHash = keccak256(initCode);

        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
        );
        require(uint256(uint160(predicted)) & 0xFFFF == SALT_TARGET_SUFFIX, "Bad salt");

        address tokenAddr;
        assembly ("memory-safe") {
            tokenAddr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(tokenAddr == predicted, "Mismatch");
        return tokenAddr;
    }

    function debugSalt(string memory name, string memory symbol, uint256 salt) external view returns (bytes32 codeHash, address predicted, uint256 lower16) {
        bytes memory initCode = abi.encodePacked(
            _getCreate2Bytecode(),
            abi.encode(name, symbol, TOTAL_SUPPLY, address(this))
        );
        codeHash = keccak256(initCode);
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))))
        );
        lower16 = uint256(uint160(predicted)) & 0xFFFF;
    }

    // ─── 内盘买入 ────────────────────────────────────────────────

    function buyTokens(address tokenAddress) external payable nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        require(info.tokenAddress != address(0), "Not registered");
        require(!info.isGraduated, "Graduated");
        require(msg.value > 0, "No BNB");

        // 兜底：token 已卖光但未毕业 → 尝试毕业，然后退款 revert
        // 场景：最后一笔买入触发 _autoGraduate 但 Pancake 临时失败，tokensAvailable=0 卡死
        if (info.tokensAvailable == 0) {
            address(this).call(abi.encodeWithSelector(this._autoGraduate.selector, tokenAddress));
            payable(msg.sender).transfer(msg.value);
            require(false, "Sold out, try PancakeSwap");
        }

        uint256 fee = (msg.value * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = msg.value - fee;
        if (fee > 0) payable(FEE_WALLET).transfer(fee);

        // 单钱包累计持有上限检查（仅内盘）
        uint256 currentHold = walletHoldings[tokenAddress][msg.sender];
        uint256 maxBuyThisTime = MAX_WALLET_HOLD > currentHold ? MAX_WALLET_HOLD - currentHold : 0;
        require(maxBuyThisTime > 0, "Wallet already at 5% cap");

        // 用 maxBuyThisTime 限制 available
        uint256 availableForWallet = info.tokensAvailable < maxBuyThisTime ? info.tokensAvailable : maxBuyThisTime;

        (uint256 tokens, uint256 cost) = _calcBuyTokens(tokenAddress, net, availableForWallet);
        require(tokens > 0, "Zero tokens");

        _executeBuy(tokenAddress, tokens, cost, net, fee);
    }

    function _calcBuyTokens(address tokenAddress, uint256 net, uint256 available) internal view returns (uint256 tokens, uint256 cost) {
        uint256 lo = 0;
        uint256 hi = available;
        uint256 t = 0;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            if (getBuyCost(tokenAddress, mid) <= net) { t = mid; lo = mid + 1; }
            else { if (mid == 0) break; hi = mid - 1; }
        }
        tokens = t;
        cost = getBuyCost(tokenAddress, t);
    }

    function _executeBuy(address tokenAddress, uint256 tokens, uint256 cost, uint256 net, uint256 fee) internal {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        info.tokensSold += tokens;
        info.tokensAvailable -= tokens;
        info.bnbRaised += cost;
        totalBnbPaid[tokenAddress] += (cost + fee);
        userInvestments[tokenAddress][msg.sender] += cost;
        walletHoldings[tokenAddress][msg.sender] += tokens;
        IMemeTokenBase(tokenAddress).transfer(msg.sender, tokens);
        if (net > cost) payable(msg.sender).transfer(net - cost);
        emit TokenPurchased(tokenAddress, msg.sender, tokens, cost, fee, info.tokensSold);
        // 毕业条件（任一满足即触发）：
        //   主条件: tokensSold >= 800M（内盘卖完）
        //   辅条件: totalBnbPaid >= fundingGoal（用户总支付含0.5%手续费达募集目标）
        // 失败不 revert 用户 tx，下次 buy/sell 会再试
        if (!info.isGraduated && (info.tokensSold >= GRADUATION_TOKENS || totalBnbPaid[tokenAddress] >= info.fundingGoal)) {
            emit ShouldGraduate(tokenAddress, info.bnbRaised, info.fundingGoal);
            address(this).call(abi.encodeWithSelector(this._autoGraduate.selector, tokenAddress));
        }
    }

    /// @notice 任何人可调用, 触发 token 毕业到 PancakeSwap
    /// @dev 2-tx 模式: 用户 buyTokens 已成功, 这里只把流动性加到 Pancake
    ///   - 失败只会 revert 本次 graduate() 调用, 不影响用户的买入
    ///   - 触发者可以是任何人 (用户、creator、链上机器人、运营钱包)
    /// @dev 2026-07-09: trigger 改用 tokensSold >= 800M (graduation point).
    ///   bnbRaised 仍作 fallback. 任一满足即可.
    function graduate(address tokenAddress) external nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        require(info.tokenAddress != address(0), "Not registered");
        require(!info.isGraduated, "Already graduated");
        require(
            info.tokensSold >= GRADUATION_TOKENS || totalBnbPaid[tokenAddress] >= info.fundingGoal,
            "Graduation threshold not reached (need 800M sold or fundingGoal BNB paid)"
        );
        _graduate(tokenAddress);
    }

    /// @notice 2026-07-08: 自动毕业入口,只在 buyTokens/createToken 触发毕业条件时由合约自己调用
    /// @dev 设计要点同 TokenLaunchpad._autoGraduate:
    ///   1. 不带 nonReentrant — 通过 low-level call 从 buyTokens (nonReentrant) 调用
    ///   2. require(msg.sender == address(this)) — 防外部触发
    ///   3. 失败不 revert 外层 tx (Pancake 临时不通也不影响用户 buy)
    ///   4. 保留 public graduate() 人工 fallback
    /// @dev 2026-07-09: 同 graduate() — 任一条件满足即可
    function _autoGraduate(address tokenAddress) external {
        require(msg.sender == address(this), "only self");
        TokenInfo storage info = tokenRegistry[tokenAddress];
        if (info.tokenAddress == address(0)) return;
        if (info.isGraduated) return;
        if (info.tokensSold < GRADUATION_TOKENS && totalBnbPaid[tokenAddress] < info.fundingGoal) return;
        _graduate(tokenAddress);
    }

    // ─── 内盘卖出 ────────────────────────────────────────────────

    function sellTokens(address tokenAddress, uint256 tokenAmount) external nonReentrant {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        require(info.tokenAddress != address(0), "Not registered");
        require(!info.isGraduated, "Graduated");
        // 2-tx 模式下, 达到阈值后禁止内盘卖出 (避免破坏"半毕业"状态)
        // 用户应在 Pancake 上 swap 卖出
        require(info.bnbRaised < info.fundingGoal, "Awaiting graduation, swap on Pancake");
        require(tokenAmount > 0, "Zero amount");
        uint256 cs = info.tokensSold;
        require(cs >= tokenAmount, "Underflow");

        // linear 价格曲线反向公式（卖 Δ token 回收 BNB）：
        // payout(Δ) = Δ·(a + b·S) - ½·b·Δ²
        uint256 out = getSellPayout(tokenAddress, tokenAmount);
        if (out == 0 && tokenAmount > 0) out = 1; // 精度保护
        require(info.bnbRaised >= out, "No reserves");

        uint256 fee = (out * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        info.tokensSold = cs - tokenAmount;
        info.tokensAvailable += tokenAmount;
        info.bnbRaised -= out;
        // 卖出时减少累计持有量
        walletHoldings[tokenAddress][msg.sender] -= tokenAmount;
        IMemeTokenBase(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);
        if (fee > 0) payable(FEE_WALLET).transfer(fee);
        payable(msg.sender).transfer(out - fee);
        emit TokenSold(tokenAddress, msg.sender, tokenAmount, out - fee, fee);
        // 卖出后也检查毕业条件（tokensSold 可能仍 >= 800M）
        if (!info.isGraduated && (info.tokensSold >= GRADUATION_TOKENS || totalBnbPaid[tokenAddress] >= info.fundingGoal)) {
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
    uint256 public constant LP_BNB_BPS = 9900;                       // (legacy) 实际现在 Pancake 加 fundingGoal BNB，不是 99% bnbRaised
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;  // LP token 黑洞销毁地址

    function _graduate(address tokenAddress) internal {
        TokenInfo storage info = tokenRegistry[tokenAddress];
        require(!info.isGraduated, "Already");

        uint256 bnbRaised = info.bnbRaised;
        require(bnbRaised > 0, "No BNB raised");
        require(address(this).balance >= bnbRaised, "Insufficient balance");

        // 设计：Pancake 池 = fundingGoal BNB + 200M token (用户原话"按设置募集到的资金金额加 200000000 创建 pancake")
        // Pancake 价 = fundingGoal / 200M
        // 用户硬约束:
        //   A. 内盘毕业价 (S=800M) = Pancake 价 = fundingGoal/200M
        //   B. 卖出 800M token 触发毕业
        //   C. bnRaised(800M) = fundingGoal 严格 (不超募)
        // 用 pump.fun 曲线 + VIRTUAL_POOL_TOKENS = 886M:
        //   V_B = fundingGoal × 85.8M / 200M = 0.429 × fundingGoal
        //   price(800M) = V_B / 85.8M = fundingGoal / 200M = Pancake 价 ✓
        //   bnRaised(800M) ≈ fundingGoal ✓ (数学严格, 见 getVirtualBNBReserve)
        // 触发: bnbRaised >= fundingGoal, 此时 tokensSold ≈ 800M
        // Pancake 加 fundingGoal BNB (= min(bnbRaised, fundingGoal)), 其余归 FEE_WALLET
        uint256 bnbForLP = bnbRaised > info.fundingGoal ? info.fundingGoal : bnbRaised;
        uint256 bnbForFee = bnbRaised - bnbForLP;

        // 加 LP 的 token 数：min(实际剩余, 2亿)
        // 极端情况：实际剩 < 2 亿（曲线没卖够），用实际剩余
        uint256 tokRemaining = TOTAL_SUPPLY - info.tokensSold;
        uint256 tokForLP = tokRemaining < LP_TOKEN_AMOUNT ? tokRemaining : LP_TOKEN_AMOUNT;

        // 授权 PancakeRouter 花费代币
        IMemeTokenBase(tokenAddress).approve(pancakeRouterAddress, tokForLP);

        // 滑点保护 95% 最小金额
        uint256 minToken = tokForLP - (tokForLP * SLIPPAGE_BPS / BPS_DENOMINATOR);
        uint256 minBnb = bnbForLP - (bnbForLP * SLIPPAGE_BPS / BPS_DENOMINATOR);

        bytes memory d = abi.encodeWithSelector(
            IPancakeRouter.addLiquidityETH.selector,
            tokenAddress, tokForLP, minToken, minBnb, address(this), block.timestamp + 3600
        );
        (bool ok,) = pancakeRouterAddress.call{value: bnbForLP}(d);
        require(ok, "Pancake addLiquidity failed");

        // 平台手续费（剩余 BNB）归 FEE_WALLET
        if (bnbForFee > 0) {
            payable(FEE_WALLET).transfer(bnbForFee);
        }

        // 仅在 Pancake addLiquidityETH 成功后才标记毕业
        info.isGraduated = true;

        address pair = address(0);
        if (pancakeFactoryAddress != address(0)) {
            pair = _getPair(tokenAddress);
        }
        info.pairAddress = pair;

        // 毕业后安全收尾：销毁 LP token，永久锁定流动性
        _renounceAndBurnLP(pair);

        emit TokenGraduated(tokenAddress, pair, bnbForLP, tokForLP);
    }

    /// @notice 销毁 LP token 到黑洞地址，永久锁定流动性
    /// @dev MemeToken 的 ownership 在 _deployToken 中已 renounce，无需在此重复。
    ///      Launchpad 自身的 ownership 不能在这里 renounce，否则第一个代币毕业后
    ///      所有 onlyOwner 管理函数全部失效。
    function _renounceAndBurnLP(address pair) internal {
        if (pair != address(0)) {
            uint256 lpBalance = IERC20(pair).balanceOf(address(this));
            if (lpBalance > 0) {
                IERC20(pair).transfer(DEAD_ADDRESS, lpBalance);
            }
        }
    }

    function _getPair(address tokenAddress) internal view returns (address) {
        if (pancakeFactoryAddress == address(0)) return address(0);
        (bool ok, bytes memory ret) = pancakeFactoryAddress.staticcall(
            abi.encodeWithSelector(IPancakeFactory.getPair.selector, tokenAddress, WBNB)
        );
        if (!ok || ret.length < 32) return address(0);
        address p;
        assembly ("memory-safe") { p := mload(add(ret, 32)) }
        return p;
    }

    // ─── 管理函数 ─────────────────────────────────────────────────

    function getTokenFundingGoal(address t) public view returns (uint256) { return tokenRegistry[t].fundingGoal; }
    function getTokenPair(address t) public view returns (address) { return tokenRegistry[t].pairAddress; }
    function getDeployedTokensCount() external view returns (uint256) { return allDeployedTokens.length; }

    function updateCreationFee(uint256 f) external onlyOwner { creationFee = f; }

    function setPancakeRouter(address r) external onlyOwner {
        pancakeRouterAddress = r;
        (bool ok, bytes memory ret) = r.staticcall(abi.encodeWithSelector(IPancakeRouter.factory.selector));
        if (ok && ret.length >= 32) {
            address f;
            assembly ("memory-safe") { f := mload(add(ret, 32)) }
            pancakeFactoryAddress = f;
        }
    }

    function withdrawProtocolFees() external onlyOwner {
        uint256 bal = address(this).balance;
        uint256 res = 0;
        for (uint i = 0; i < allDeployedTokens.length; i++) {
            if (!tokenRegistry[allDeployedTokens[i]].isGraduated) {
                res += tokenRegistry[allDeployedTokens[i]].bnbRaised;
            }
        }
        uint256 profit = bal > res ? bal - res : 0;
        require(profit > 0, "None");
        payable(owner()).transfer(profit);
    }

    receive() external payable {}
}
