// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title BaseMemeToken
 * @notice BSC Launchpad 基础版代币（无税费、无反射）
 *         由 BondingCurveMarket 部署，部署后所有操作（transfer/approve 等）
 *         都是标准 ERC20，没有 transfer-tax、reflection、LP-dividend 等高级特性。
 *
 * 构造函数：
 *   - name:        代币名
 *   - symbol:      代币符号
 *   - totalSupply: 总供应量（最小 1B = 1e18 wei，按调用方需要）
 *   - creator:     接收初始供应的地址（一般为 BondingCurveMarket 自己）
 *
 * 设计原则：
 *   - 单一文件、单一合约，零 OZ 之外的依赖
 *   - 编译产物体积小，可被 Sourcify / BscScan 完整验证
 *   - 部署后立即可被 BscScan 识别为 standard ERC20
 */
contract BaseMemeToken is ERC20 {
    address public immutable creator;

    constructor(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address _creator
    ) ERC20(name, symbol) {
        require(_creator != address(0), "BaseMemeToken: zero creator");
        creator = _creator;
        _mint(_creator, totalSupply);
    }
}
