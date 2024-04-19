// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPancakeRouter {
    function quote(
        uint amountA,
        uint reserveA,
        uint reserveB
    ) external pure returns (uint amountB);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

interface IPancakePair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

contract TokenVNDC is ERC20, ERC20Burnable, Pausable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Router address
    IPancakeRouter public router;
    // Pair address
    mapping(address => IPancakePair) public lpPairMap;
    // List of currency support
    mapping(address => bool) public currencyList;
    // Min amount to mint
    uint256 public minAmountMint;

    struct User {
        uint256 mintMax;
        bool mintable;
        bool redeemable;
        uint256 lastMintTimestamp;
        bool active;
    }

    // Track user address is currency whitelist
    mapping(address => address[]) public users;
    // Check user is whitelist in a currency, currency => user addres => user
    mapping(address => mapping(address => User)) public whitelistMap;
    // Check user is admin
    mapping(address => bool) public adminMap;
    // Total token per user
    mapping(address => mapping(address => uint256)) public totalVNDCPerUserMap; // totalVNDCPerUserMap[user][currency]
    mapping(address => mapping(address => uint256)) public totalTokenPerUserMap; // totalTokenPerUserMap[user][currency]
    mapping(address => mapping(address => uint256)) public lpPerUser;

    // Fee Withdraw
    uint256 public feeWithdraw; // 13 = 1.3%
    uint256 public bonus; // 10 = 1%
    uint256 public constant BASE_RATE = 1000;

    // Mint redeem setting
    struct MinMaxSetting {
        uint256 minPriceMint;
        uint256 maxPriceRedeem;
        uint256 minSeconds;
    }

    MinMaxSetting public minMaxSetting;

    constructor(address _router, uint256 _minAmountMint, uint256 _feeWithdraw, uint256 _bonus, uint256 _minPriceMint, uint256 _maxPriceRedeem)
        ERC20("VNDC", "VNDC") {
            router = IPancakeRouter(_router);
            minAmountMint = _minAmountMint;
            feeWithdraw = _feeWithdraw;
            bonus = _bonus;
            minMaxSetting  = MinMaxSetting({
                minPriceMint: _minPriceMint,
                maxPriceRedeem: _maxPriceRedeem,
                minSeconds: 1209600 // 14*86400
            });

            // Mint 26 billion VNDC to owner
            _mint(msg.sender, 26_000_000_000);
        }

    // Check admin or owner
    modifier isAdmin() {
        require(
            adminMap[msg.sender] || msg.sender == owner(),
            "Caller is not admin"
        );
        _;
    }

    // Event add whitelist
    event EventAddWhitelist(address[] _whitelist, bool _mintable, bool _redeemable, uint256 _mintMax, address _currency);

    // Event mint
    event EventMintWhitelist(
        address indexed to,
        uint256 amount,
        address indexed currency,
        uint256 amountsOut,
        uint256 liquidity
    );
    // Event withdraw token, burn VNDC whitelist
    event EventWithdrawWhitelist(
        address indexed to,
        uint256 amountLiquidty,
        address indexed currency,
        uint256 amountAWithdraw,
        uint256 amountBWithdraw,
        uint256 feeWithdraw
    );
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // Mint VNDC with whitelist
    function mintWhitelist(uint256 _amount, address _currency, uint256 slippage) public {
        // Check whitelist mintable
        require(whitelistMap[_currency][msg.sender].mintable, "Caller is not whitelist");
        // Check min amount
        require(_amount >= minAmountMint, "Amounts must be greater than min amount");
        // Check currency
        require(currencyList[_currency], "Currency is not support");
        // Check max amount
        require(_amount <= (whitelistMap[_currency][msg.sender].mintMax.sub(totalTokenPerUserMap[msg.sender][_currency])), "Amounts must be less than maximum minting");


        // get reserve
        (uint256 VNDCReserve, uint256 currencyReserve) = getReserve(_currency);
        // Get amount out
        uint256 amountsOut = router.quote(_amount, currencyReserve, VNDCReserve);
        require(getPriceInputToken(_amount, _currency) > minMaxSetting.minPriceMint, "The price must be more than minPriceMint");

        // Transfer from currency to this contract
        IERC20(_currency).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 amountAMin = amountsOut.sub(amountsOut.mul(slippage).div(BASE_RATE));
        uint256 amountBMin = _amount.sub(_amount.mul(slippage).div(BASE_RATE));
        // mint VNDC to contract
        _mint(address(this), amountsOut);
        // approve liquidity router
        IERC20(_currency).safeIncreaseAllowance(address(router), _amount);
        IERC20(address(this)).safeIncreaseAllowance(address(router), amountsOut);
        // add liquidity
        (, , uint256 liquidity) = router.addLiquidity(
            address(this), // VNDC
            _currency, // token
            amountsOut,
            _amount,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + 3600 // deadline 1 hour
        );
        // mint VNDC to user
        uint256 bonusVNDC = bonus.mul(amountsOut).div(BASE_RATE);
        _mint(msg.sender, amountsOut + bonusVNDC);
        // update total token per user
        totalVNDCPerUserMap[msg.sender][_currency] = totalVNDCPerUserMap[msg.sender][_currency].add(amountsOut);
        totalTokenPerUserMap[msg.sender][_currency] = totalTokenPerUserMap[msg.sender][_currency].add(_amount);
        lpPerUser[msg.sender][_currency] = lpPerUser[msg.sender][_currency].add(liquidity);
        whitelistMap[_currency][msg.sender].lastMintTimestamp = block.timestamp;
        // emit event
        emit EventMintWhitelist(
            msg.sender,
            _amount,
            _currency,
            amountsOut + bonusVNDC,
            liquidity
        );
    }
    // Withdraw token, burn VNDC whitelist (amountA is amount VNDC)
    function withdrawWhitelist(uint256 _amountVNDC, address _currency, uint256 _slippage) public {
        // Check whitelist redeemable
        require(whitelistMap[_currency][msg.sender].redeemable, "Caller is not whitelist");
        require(_amountVNDC <= totalVNDCPerUserMap[msg.sender][_currency], "Amounts must be less than total VNDC");
        require(isAfterMintTime(whitelistMap[_currency][msg.sender].lastMintTimestamp), "You must wait to redeem");
        // Check currency
        require(currencyList[_currency], "Currency is not support");
        require(getPriceInputVNDC(_amountVNDC, _currency) < minMaxSetting.maxPriceRedeem, "The price must be less than maxPriceRedeem");

        uint256 amountLiquidity = getAmountLiquidity(_amountVNDC, msg.sender, _currency);
        (uint256 VNDCAmount, uint256 currencyAmount) = estimateAmountByLp(_currency, amountLiquidity);
        uint256 amountAMin = VNDCAmount.sub(VNDCAmount.mul(_slippage).div(BASE_RATE)); // slippage
        uint256 amountBMin = currencyAmount.sub(currencyAmount.mul(_slippage).div(BASE_RATE)); // slippage
        // remove liquidity
        IERC20(address(lpPairMap[_currency])).safeIncreaseAllowance(address(router), amountLiquidity);
        (uint256 amountVNDCWithdraw, uint256 amountCurrencyWithdraw) = router.removeLiquidity(
            address(this), // VNDC
            _currency, // token
            amountLiquidity,
            amountAMin, // min amount VNDC
            amountBMin, // min amount token
            address(this),
            block.timestamp + 3600 // deadline 1 hour
        );
        // Burn VNDC
        _burn(address(this), amountVNDCWithdraw);
        _burn(msg.sender, _amountVNDC);

        uint256 feeWithdrawAmount = amountCurrencyWithdraw.mul(feeWithdraw).div(BASE_RATE);
        uint256 actualWithdrawAmount = amountCurrencyWithdraw.sub(feeWithdrawAmount);
        // Transfer fee to owner
        IERC20(_currency).safeTransfer(owner(), feeWithdrawAmount);
        // Transfer currency to user
        IERC20(_currency).safeTransfer(msg.sender, actualWithdrawAmount);
        // update total token per user
        totalVNDCPerUserMap[msg.sender][_currency] = totalVNDCPerUserMap[msg.sender][_currency].sub(_amountVNDC);
        lpPerUser[msg.sender][_currency] = lpPerUser[msg.sender][_currency].sub(amountLiquidity);
        // emit event
        emit EventWithdrawWhitelist(
            msg.sender,
            amountLiquidity,
            _currency,
            amountVNDCWithdraw,
            actualWithdrawAmount,
            feeWithdraw
        );
    }

    function estimateAmountByLp(address _currency, uint256 lpAmount) public view returns (uint256 VNDCAmount, uint256 currencyAmount) {
        uint256 totalSupply = IERC20(address(lpPairMap[_currency])).totalSupply();
        (uint256 VNDCReserve, uint256 currencyReserve) = getReserve(_currency);
        VNDCAmount = lpAmount.mul(VNDCReserve).div(totalSupply);
        currencyAmount = lpAmount.mul(currencyReserve).div(totalSupply);
    }

    function getReserve(address _currency) public view returns (uint256 VNDCReserve, uint256 currencyReserve) {
        require(address(lpPairMap[_currency]) != address(0), 'LP not found');
        (uint256 reserve0, uint256 reserve1, ) = lpPairMap[_currency].getReserves();
        if (lpPairMap[_currency].token0() == address(this)) {
            VNDCReserve = reserve0;
            currencyReserve = reserve1;
        } else {
            VNDCReserve = reserve1;
            currencyReserve = reserve0;
        }
    }

    function getAmountLiquidity(uint256 VNDCAmount, address user, address currency) public view returns (uint256 liquidityAmount) {
        return VNDCAmount.mul(lpPerUser[user][currency]).div(totalVNDCPerUserMap[user][currency]);
    }

    function addAdmin(address[] memory _admins, bool _isBool) public onlyOwner {
        for (uint256 i = 0; i < _admins.length; i++) {
            if (!adminMap[_admins[i]]) {
                adminMap[_admins[i]] = _isBool;
            }
        }
    }

    function addWhitelist(address[] memory _whitelist, bool _mintable, bool _redeemable, uint256 _mintMax, address _currency) public isAdmin {
        for (uint256 i = 0; i < _whitelist.length; i++) {
            if (!whitelistMap[_currency][_whitelist[i]].active) {
                users[_currency].push(_whitelist[i]);
            }
            whitelistMap[_currency][_whitelist[i]] = User({
                mintMax: _mintMax,
                mintable: _mintable,
                redeemable: _redeemable,
                lastMintTimestamp: whitelistMap[_currency][_whitelist[i]].lastMintTimestamp,
                active: true
            });
        }
        emit EventAddWhitelist(_whitelist, _mintable, _redeemable, _mintMax, _currency);
    }

    // Can use to pause mint/redeem
    function setCurrencyList(address[] memory _currencyList, bool _isBool) public onlyOwner {
        for (uint256 i = 0; i < _currencyList.length; i++) {
            currencyList[_currencyList[i]] = _isBool;
        }
    }

    function setMinAmountMint(uint256 _minAmountMint) public onlyOwner {
        minAmountMint = _minAmountMint;
    }

    function setFeeWithdraw(uint256 _feeWithdraw) public onlyOwner {
        feeWithdraw = _feeWithdraw;
    }

    function setBonus(uint256 _bonus) public onlyOwner {
        bonus = _bonus;
    }

    function setMinSeconds(uint256 _minSeconds) public onlyOwner {
        minMaxSetting.minSeconds = _minSeconds;
    }

    function setMinPriceMint(uint256 _minPriceMint) public onlyOwner {
        minMaxSetting.minPriceMint = _minPriceMint;
    }

    function setMaxPriceRedeem(uint256 _maxPriceRedeem) public onlyOwner {
        minMaxSetting.maxPriceRedeem = _maxPriceRedeem;
    }

    // Set router liquidity
    function setRouter(address _router) public onlyOwner {
        router = IPancakeRouter(_router);
    }

    // Set lp pair by currency address token
    function setLpPair(address _currency, address _lpPair) public onlyOwner {
        require(_lpPair != address(0), "_lpPair cannot be address(0)");
        require(_currency != address(0), "_currency cannot be address(0)");
        lpPairMap[_currency] = IPancakePair(_lpPair);
    }

    function withdrawEmergency(address _token, uint256 _amount) public onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 0;
    }

    function isAfterMintTime(uint256 timestamp) public view returns (bool) {
        // Get the current timestamp
        uint256 currentTime = block.timestamp;

        // Calculate the difference in seconds between the current time and the given timestamp
        uint256 difference = currentTime - timestamp;

        // Check if the difference is more than minSeconds seconds
        return difference >= minMaxSetting.minSeconds;
    }

    function getPriceInputVNDC(uint256 _amountVNDC, address _currency) public view returns (uint256) {
        // get reserve
        (uint256 VNDCReserve, uint256 currencyReserve) = getReserve(_currency);
        // Get amount out
        uint256 amountsOut = router.quote(_amountVNDC, VNDCReserve, currencyReserve);
        uint256 currencyDecimals = uint256(ERC20(_currency).decimals());
        uint256 price = _amountVNDC.mul(10**currencyDecimals).div(amountsOut);
        return price;
    }

    function getPriceInputToken(uint256 _amount, address _currency) public view returns (uint256) {
        // get reserve
        (uint256 VNDCReserve, uint256 currencyReserve) = getReserve(_currency);
        // Get amount out
        uint256 amountsOut = router.quote(_amount, currencyReserve, VNDCReserve);
        uint256 currencyDecimals = uint256(ERC20(_currency).decimals());
        uint256 price = amountsOut.mul(10**currencyDecimals).div(_amount);
        return price;
    }

    function getNumberOfUsers(address _currency) public view returns (uint256) {
        return users[_currency].length;
    }
}
