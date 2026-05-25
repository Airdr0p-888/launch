// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ModaMintToken
 * @notice BSC 链 Mint 代币 - 支持预售 Mint / 买卖税 / 税费分配 / 反机器人保护
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external;
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin,
        uint amountETHMin, address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) { return a + b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) { return a * b; }
    function div(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
}

contract Ownable {
    address internal _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function owner() public view virtual returns (address) { return _owner; }
    modifier onlyOwner() { require(owner() == msg.sender, "Ownable: caller is not owner"); _; }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

contract ModaMintToken is IERC20, Ownable {
    using SafeMath for uint256;

    string private _name;
    string private _symbol;
    uint8  private constant _decimals = 18;
    uint256 private _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Mint 预售
    uint256 public mintCostBNB;       // 单次 Mint 花费多少 BNB (wei)
    uint256 public tokensPerMint;     // 单次 Mint 获得多少代币
    uint256 public fillAmountBNB;     // 预售硬顶 (wei)
    uint256 public totalBNBCollected;
    bool    public presaleActive;
    bool    public tradingActive;

    // 税费 (基点, 100 = 1%, 最大 1000 = 10%)
    uint256 public buyTaxBps;
    uint256 public sellTaxBps;

    // 税费分配 (总和=10000 bps)
    uint256 public marketingBps;
    uint256 public burnBps;
    uint256 public dividendBps;
    uint256 public liquidityBps;

    address public marketingWallet;
    address public dividendToken;

    // 反机器人
    uint256 public protectionEndBlock;

    // DEX
    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    mapping(address => bool) public isExcludedFromTax;
    mapping(address => bool) public isExcludedFromProtection;
    mapping(address => uint256) private _lastTxBlock;

    uint256 private constant MAX_TAX = 1000;

    event Minted(address indexed user, uint256 bnbAmount, uint256 tokenAmount);
    event PresaleCompleted(uint256 totalBNB, uint256 totalTokens);
    event TradingEnabled();

    // 预售代币分配比例（构造函数参数）
    uint256 public presaleTokenPct;  // e.g. 50 = 50% 给预售，50% 留作 LP

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint256 mintCostBNB_,
        uint256 fillBNB_,
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 protectionBlocks_,
        uint256 marketingPct_,
        uint256 burnPct_,
        uint256 dividendPct_,
        uint256 liquidityPct_,
        address marketingWallet_,
        address dividendToken_,
        uint256 presaleTokenPct_,  // 预售分配比例 (1-100)
        address owner_
    ) {
        require(buyTax_ <= MAX_TAX, "Buy tax too high");
        require(sellTax_ <= MAX_TAX, "Sell tax too high");
        require(marketingPct_ + burnPct_ + dividendPct_ + liquidityPct_ == 10000, "Tax alloc != 10000");
        require(fillBNB_ > 0, "Fill must > 0");
        require(mintCostBNB_ > 0, "Mint cost > 0");
        require(fillBNB_ >= mintCostBNB_, "Fill < mint cost");
        require(marketingWallet_ != address(0), "Wallet zero");
        require(owner_ != address(0), "Owner zero");
        require(presaleTokenPct_ >= 1 && presaleTokenPct_ <= 99, "Presale pct 1-99");

        _name = name_;
        _symbol = symbol_;
        _totalSupply = totalSupply_.mul(10 ** uint256(_decimals));

        // 手动转移 ownership（CREATE2 工厂部署时 msg.sender 是工厂地址，不是用户）
        emit OwnershipTransferred(address(0), msg.sender); // Ownable constructor already set this
        emit OwnershipTransferred(msg.sender, owner_);      // transfer to actual user
        _owner = owner_;

        _balances[address(this)] = _totalSupply;
        mintCostBNB = mintCostBNB_;                                          // wei 精度存储
        fillAmountBNB = fillBNB_;
        presaleTokenPct = presaleTokenPct_;

        // tokensPerMint 基于 presaleTokenPct% 的代币量，而非全部 totalSupply
        // 剩余代币 (100 - presaleTokenPct)% 留在合约中用于自动添加底池
        uint256 presaleTokens = _totalSupply.mul(presaleTokenPct_).div(100);
        tokensPerMint = presaleTokens.mul(mintCostBNB_).div(fillBNB_);       // 单次 Mint 代币数

        buyTaxBps = buyTax_;
        sellTaxBps = sellTax_;
        protectionEndBlock = block.number.add(protectionBlocks_);
        marketingBps = marketingPct_;
        burnBps = burnPct_;
        dividendBps = dividendPct_;
        liquidityBps = liquidityPct_;
        marketingWallet = marketingWallet_;
        dividendToken = dividendToken_;
        presaleActive = true;
        tradingActive = false;

        IUniswapV2Router02 _router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        uniswapV2Router = _router;
        uniswapV2Pair = IUniswapV2Factory(_router.factory()).createPair(address(this), _router.WETH());

        isExcludedFromTax[address(this)] = true;
        isExcludedFromTax[owner_] = true;
        isExcludedFromTax[marketingWallet_] = true;
        isExcludedFromTax[address(_router)] = true;
        isExcludedFromProtection[address(_router)] = true;
        isExcludedFromProtection[address(this)] = true;
        isExcludedFromProtection[owner_] = true;

        emit Transfer(address(0), address(this), _totalSupply);
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address _owner, address spender) public view override returns (uint256) {
        return _allowances[_owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: exceed allowance");
        unchecked { _approve(from, msg.sender, currentAllowance - amount); }
        _transfer(from, to, amount);
        return true;
    }

    // ===== Mint 预售 =====
    function mint() external payable {
        _doMint(msg.sender, msg.value);
    }

    function _doMint(address user, uint256 bnbAmount) internal {
        require(presaleActive, "Presale ended");
        require(bnbAmount >= mintCostBNB, "Below min mint");
        require(totalBNBCollected.add(bnbAmount) <= fillAmountBNB, "Hardcap reached");

        uint256 mintCount = bnbAmount.div(mintCostBNB);
        uint256 tokens = mintCount.mul(tokensPerMint);
        require(_balances[address(this)] >= tokens, "No tokens left");

        // 直接操作 _balances，不走 _transfer，避免反机器人保护拦截普通用户
        _balances[address(this)] = _balances[address(this)].sub(tokens);
        _balances[user] = _balances[user].add(tokens);
        totalBNBCollected = totalBNBCollected.add(bnbAmount);

        emit Minted(user, bnbAmount, tokens);
        emit Transfer(address(this), user, tokens);

        if (totalBNBCollected >= fillAmountBNB) {
            _completePresale();
        }
    }

    // 接收直接转账：预售期间自动当作 mint 处理
    receive() external payable {
        if (presaleActive) {
            _doMint(msg.sender, msg.value);
        }
    }

    function completePresale() external onlyOwner {
        require(presaleActive, "Not active");
        _completePresale();
    }

    function _completePresale() internal {
        presaleActive = false;
        uint256 tokenBal = _balances[address(this)];
        uint256 bnbBal = address(this).balance;
        emit PresaleCompleted(bnbBal, tokenBal);

        if (tokenBal > 0 && bnbBal > 0) {
            _approve(address(this), address(uniswapV2Router), tokenBal);
            // LP Token 收款人：_owner（项目方钱包），而非 msg.sender（末位 mint 用户）
            // try-catch：防止 Router 调用异常导致整笔 mint tx 被 revert
            //   - 成功：tradingActive = true，交易自动开启
            //   - 失败：资产保留在合约，owner 可调用 addLiquidityManually() 手动补救
            try uniswapV2Router.addLiquidityETH{value: bnbBal}(
                address(this), tokenBal, 0, 0, _owner, block.timestamp
            ) returns (uint, uint, uint) {
                tradingActive = true;
                emit TradingEnabled();
            } catch {
                // 底池添加失败，tradingActive 保持 false，待 owner 手动处理
            }
        } else {
            tradingActive = true;
            emit TradingEnabled();
        }
    }

    function enableTrading() external onlyOwner {
        require(!tradingActive, "Already active");
        tradingActive = true;
        emit TradingEnabled();
    }

    // ===== 核心 _transfer =====
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0, "Amount zero");
        require(_balances[from] >= amount, "Insufficient balance");

        // ✅ Fix3: 交易未开启时，禁止通过 DEX（Pair）买卖；
        //         合约自身（addLiquidity/税费分配）、owner、router 豁免此限制
        bool isDexTransfer = (from == uniswapV2Pair || to == uniswapV2Pair);
        if (isDexTransfer && !tradingActive) {
            require(
                isExcludedFromTax[from] || isExcludedFromTax[to],
                "Trading not active"
            );
        }

        // 合约自身转出代币（税费分配、addLiquidity 等）跳过反机器人保护
        if (from != address(this)) {
            if (!isExcludedFromProtection[from] && !isExcludedFromProtection[to]) {
                require(block.number > protectionEndBlock, "Anti-bot active");
                require(_lastTxBlock[from] != block.number, "Same block");
            }
        }
        _lastTxBlock[from] = block.number;

        bool isBuy = (from == uniswapV2Pair && to != address(uniswapV2Router));
        bool isSell = (to == uniswapV2Pair && from != address(uniswapV2Router));
        uint256 taxAmount = 0;

        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            if (isBuy) taxAmount = amount.mul(buyTaxBps).div(10000);
            else if (isSell) taxAmount = amount.mul(sellTaxBps).div(10000);
        }

        uint256 sendAmt = amount.sub(taxAmount);
        _balances[from] = _balances[from].sub(amount);
        _balances[to] = _balances[to].add(sendAmt);

        if (taxAmount > 0) {
            _balances[address(this)] = _balances[address(this)].add(taxAmount);
            _distributeTax(taxAmount, isSell);
        }

        emit Transfer(from, to, sendAmt);
    }

    function _distributeTax(uint256 taxAmt, bool isSell) internal {
        // 营销钱包 — 直接操作 _balances，不走 _transfer，避免双重扣税和保护拦截
        uint256 mkt = taxAmt.mul(marketingBps).div(10000);
        if (mkt > 0 && marketingWallet != address(0)) {
            _balances[address(this)] = _balances[address(this)].sub(mkt);
            _balances[marketingWallet] = _balances[marketingWallet].add(mkt);
            emit Transfer(address(this), marketingWallet, mkt);
        }
        // 燃烧
        uint256 burn = taxAmt.mul(burnBps).div(10000);
        if (burn > 0) {
            _balances[address(this)] = _balances[address(this)].sub(burn);
            _totalSupply = _totalSupply.sub(burn);
            emit Transfer(address(this), address(0), burn);
        }
        // 流动性 (卖出时 swap)
        uint256 liq = taxAmt.mul(liquidityBps).div(10000);
        if (liq > 0 && isSell) {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = uniswapV2Router.WETH();
            _approve(address(this), address(uniswapV2Router), liq);
            uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                liq, 0, path, address(this), block.timestamp
            );
        }
    }

    // ===== Owner =====
    function setBuyTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); buyTaxBps = bps; }
    function setSellTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); sellTaxBps = bps; }
    function setMarketingWallet(address w) external onlyOwner { require(w != address(0)); marketingWallet = w; }
    function excludeFromTax(address a, bool ex) external onlyOwner { isExcludedFromTax[a] = ex; }
    function excludeFromProtection(address a, bool ex) external onlyOwner { isExcludedFromProtection[a] = ex; }
    function withdrawBNB() external onlyOwner { payable(owner()).transfer(address(this).balance); }

    /// @notice 立即关闭反机器人保护，或设置新的保护结束区块
    function setProtectionEndBlock(uint256 blockNumber) external onlyOwner {
        protectionEndBlock = blockNumber;
    }

    /// @notice 手动开关交易（比 enableTrading 更灵活，可开可关）
    function setTradingActive(bool active) external onlyOwner {
        tradingActive = active;
        if (active) emit TradingEnabled();
    }
    function addLiquidityManually() external onlyOwner {
        uint256 t = _balances[address(this)];
        uint256 b = address(this).balance;
        require(t > 0 && b > 0, "Nothing to add");
        _approve(address(this), address(uniswapV2Router), t);
        uniswapV2Router.addLiquidityETH{value: b}(
            address(this), t, 0, 0, owner(), block.timestamp
        );
        // ✅ 手动添加底池后，若交易仍未开启则打开
        if (!tradingActive) {
            tradingActive = true;
            emit TradingEnabled();
        }
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0) && spender != address(0));
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }
}
