// SPDX-License-Identifier: GPL-3.0
// testnet pancakeswap router: 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3

/*

                MoonBag Token - a token to the BSC community, from the community
                An improved fork of SafeMoon with automatic marketing wallet and liquidity distribution
                2/2/2022 - asosfan69420@protonmail.com

*/
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./IRouter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFactory{
        function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract MoonBag is Context, IERC20, Ownable {
    using Address for address payable;
    
    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => mapping (address => uint256)) private _allowances;
    mapping (address => bool) private _isExcludedFromFee;

    address[] private _excluded;

    bool public tradingEnabled;
    bool public swapEnabled;
    bool private swapping;
    
    // Anti Dump
    mapping(address => uint256) private _lastSell;
    bool public coolDownEnabled = true;
    uint256 public coolDownTime = 30 seconds;

    IRouter public router;
    address public pair;

    uint8 private constant _decimals = 9;
    uint256 private constant MAX = ~uint256(0);

    uint256 private initialsupply = 1000000000; // 1 billion
	uint256 private _tTotal = initialsupply * 10 ** _decimals; 
    uint256 private _rTotal = (MAX - (MAX % _tTotal));

    uint256 public swapTokensAtAmount = 500000 * 10**9; // swaps tokens from tax at this amount
    uint256 public maxBuyLimit = 5000000 * 10**9;
    uint256 public maxSellLimit = 5000000 * 10**9; // max wallet size 0.5%
    uint256 public maxWalletLimit = 5000000 * 10**9;
    
    uint256 public genesis_block;
    
    address public marketingWallet;
    address public listingsWallet;
    address public airdropWallet;
    address public developmentWallet;

    string private constant _name = "MoonBag";
    string private constant _symbol = "MBAG";

    struct Taxes {
        uint256 marketing;
        uint256 liquidity; 
    }


    //@dev MAKE SURE TO UPDATE TAXES BEFORE ENABLING TRADING!!!!!!
    Taxes public taxes = Taxes(5, 5);
    Taxes public sellTaxes = Taxes(5, 5);
    uint256 public previousTax = 99;
    uint256 public previousSellTax = 99;

    struct TotFeesPaidStruct{
        uint256 marketing;
        uint256 liquidity; 
    }
    
    TotFeesPaidStruct public totFeesPaid;

    struct valuesFromGetValues{
      uint256 rAmount;
      uint256 rTransferAmount;
      uint256 rMarketing;
      uint256 rLiquidity;
      uint256 tTransferAmount;
      uint256 tMarketing;
      uint256 tLiquidity;
    }

    event FeesChanged(uint256 previousFee, uint256 currentFee, bytes32 _type);
    event UpdatedRouter(address oldRouter, address newRouter);

    // For authorizations
    // Allows other team members to execute certain functions in case the contract owner is not available
    // or when the contract is renounced

    mapping(address => bool) internal authorizations;

    modifier requiresAuth() {
        require(isAuthorized(msg.sender), "Not authorized");
        _;
    }

    modifier lockTheSwap {
        swapping = true;
        _;
        swapping = false;
    }

    constructor (address _routerAddress, address _marketingWallet, address _listingsWallet, address _airdropWallet, address _developmentWallet) {
        IRouter _router = IRouter(_routerAddress);
        address _pair = IFactory(_router.factory())
            .createPair(address(this), _router.WETH());

        marketingWallet = _marketingWallet;
        listingsWallet = _listingsWallet;
        airdropWallet = _airdropWallet;
        developmentWallet = _developmentWallet;
        tradingEnabled = false;
        router = _router;
        pair = _pair;

        authorizations[address(owner())] = true;

        _rOwned[owner()] = _rTotal;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[marketingWallet] = true;
        _isExcludedFromFee[listingsWallet] = true;
        _isExcludedFromFee[airdropWallet] = true;
        _isExcludedFromFee[developmentWallet] = true;

        emit Transfer(address(0), owner(), _tTotal);
    }


    /////////////////////////////
    // Public functions
    /////////////////////////////


    // sets an address' authorization status. cannot be changed after contract renouncement
    function authorize(address _addr) public onlyOwner() {
        authorizations[_addr] = true;
    }

    function unauthorize(address _addr) public onlyOwner() {
        authorizations[_addr] = false;
    }


    function isAuthorized(address _addr) public view returns(bool) {
        return authorizations[_addr];
    }

    // one time function to enable trading. once enabled, it CANNOT be stopped
    function enableTrading() external onlyOwner() {
        tradingEnabled = true;
        swapEnabled = true;
        genesis_block = block.number;
    }

    //keeping this to make the balanceOf function work
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount/currentRate;
    }

    // excludes an address from tx fees. cannot be called when contract is renounced
    function excludeFromFee(address account) public onlyOwner() {
        _isExcludedFromFee[account] = true;
    }

    // makes an address pay fees. cannot be called when contract is renounced
    function includeInFee(address account) public onlyOwner() {
        _isExcludedFromFee[account] = false;
    }

    // self explanatory
    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    //@dev in case what's below raises some eyebrows:
    /// any "authorized" addresses (i.e. the ones allowed to execute the functions below)
    /// DO NOT and can not have any special permissions that bypass anyone else
    /// if tax is set to 50%, authorized addresses also have to pay the 50% tax
    /// also, authorized addresses cannot bypass the max wallet limit
    /// check function _transfer for reference
    /// this is done to ensure certain changes in the contract can be made after it is renounced

    // updates the marketing wallet address
    function updateMarketingWallet(address _newWallet) external onlyOwner() {
        marketingWallet = _newWallet;
    }

    // updates the cooldown time between sells
    function updateCooldown(bool state, uint256 time) external requiresAuth() {
        coolDownTime = time * 1 seconds;
        coolDownEnabled = state;
    }

    // updates how many tokens in smart contract balance before swapping for liquidity
    function updateSwapTokensAtAmount(uint256 amount) external requiresAuth() {
        swapTokensAtAmount = amount * 10**_decimals;
    }
    
    // updates the maximum transaction limit
    function updateMaxTxLimit(uint256 maxBuy, uint256 maxSell) external requiresAuth() {
        maxBuyLimit = maxBuy * 10**decimals();
        maxSellLimit = maxSell * 10**decimals();
    }
    
    // updates the maximum wallet limit
    function updateMaxWalletlimit(uint256 amount) external requiresAuth() {
        maxWalletLimit = amount * 10**decimals();
    }

    // sets the tx fees
    // if contract is renounced, fee cannot be increased
    // self explanatory
    function setTaxes(uint256 _marketing, uint256 _liquidity) public requiresAuth() {
        if (msg.sender != owner()) {require(_marketing + _liquidity <= previousTax);}
        taxes = Taxes(_marketing,_liquidity);
        previousTax = _marketing + _liquidity;
        bytes32 _type = "BUY";
        emit FeesChanged(previousTax, _marketing + _liquidity, _type);
    }
    
    // self explanatory
    function setSellTaxes(uint256 _marketing, uint256 _liquidity) public requiresAuth() {
        if (msg.sender != owner()) {require(_marketing + _liquidity <= previousSellTax);}
        sellTaxes = Taxes(_marketing,_liquidity);
        previousSellTax = _marketing + _liquidity;
        bytes32 _type = "SELL";
        emit FeesChanged(previousSellTax, _marketing + _liquidity, _type);
    }

    // updates the PCv2 router address and pair address
    // shouldn't really be used
    function updateRouterAndPair(address newRouter, address newPair) external onlyOwner {
        router = IRouter(newRouter);
        pair = newPair;
    }
    
    // Use this in case BNB is sent to the contract by mistake
    function rescueBNB(uint256 weiAmount) external requiresAuth() {
        require(address(this).balance >= weiAmount, "insufficient BNB balance");
        payable(msg.sender).transfer(weiAmount);
    }
    
    // ditto, except for any tokens
    function rescueAnyBEP20Tokens(address _tokenAddr, address _to, uint _amount) public {
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

    // airdrops tokens to an array of addresses
    function airdropTokens(address[] memory accounts, uint256[] memory amounts) external {
        require(msg.sender == address(airdropWallet));
        require(accounts.length == amounts.length, "Arrays must have same size");
        for(uint256 i = 0; i < accounts.length; i++){
            _tokenTransfer(msg.sender, accounts[i], amounts[i], false, false);
        }
    }

    /////////////////////////////
    // Standard ERC20 functions
    /////////////////////////////


    function name() public pure returns (string memory) {
        return _name;
    }
    function symbol() public pure returns (string memory) {
        return _symbol;
    }
    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    //override ERC20:
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return tokenFromReflection(_rOwned[account]);
    }
    
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns(bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }
    
    function transfer(address recipient, uint256 amount) public override returns (bool)
    { 
      _transfer(msg.sender, recipient, amount);
      return true;
    }


    /////////////////////////////
    // Internal/private functions
    /////////////////////////////


    function _takeLiquidity(uint256 rLiquidity, uint256 tLiquidity) private {
        totFeesPaid.liquidity +=tLiquidity;

        _rOwned[address(this)] +=rLiquidity;
    }

    function _takeMarketing(uint256 rMarketing, uint256 tMarketing) private {
        totFeesPaid.marketing +=tMarketing;

        _rOwned[address(this)] +=rMarketing;
    }

    function _getValues(uint256 tAmount, bool takeFee, bool isSell) private view returns (valuesFromGetValues memory to_return) {
        to_return = _getTValues(tAmount, takeFee, isSell);
        (to_return.rAmount, to_return.rTransferAmount, to_return.rMarketing, to_return.rLiquidity) = _getRValues1(to_return, tAmount, takeFee, _getRate());
        // (to_return.rDonation) = _getRValues2(to_return, takeFee, _getRate());
        return to_return;
    }

    function _getTValues(uint256 tAmount, bool takeFee, bool isSell) private view returns (valuesFromGetValues memory s) {

        if(!takeFee) {
          s.tTransferAmount = tAmount;
          return s;
        }
        Taxes memory temp;
        if(isSell) temp = sellTaxes;
        else temp = taxes;
        
        s.tMarketing = tAmount*temp.marketing/100;
        s.tLiquidity = tAmount*temp.liquidity/100;
        s.tTransferAmount = tAmount-s.tMarketing-s.tLiquidity;
        return s;
    }

    function _getRValues1(valuesFromGetValues memory s, uint256 tAmount, bool takeFee, uint256 currentRate) private pure returns (uint256 rAmount, uint256 rTransferAmount,uint256 rMarketing, uint256 rLiquidity){
        rAmount = tAmount*currentRate;

        if(!takeFee) {
          return(rAmount, rAmount, 0,0);
        }

        rMarketing = s.tMarketing*currentRate;
        rLiquidity = s.tLiquidity*currentRate;
        rTransferAmount =  rAmount-rMarketing-rLiquidity;
        return (rAmount, rTransferAmount,rMarketing,rLiquidity);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply/tSupply;
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply-_rOwned[_excluded[i]];
            tSupply = tSupply-_tOwned[_excluded[i]];
        }
        if (rSupply < _rTotal/_tTotal) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(amount <= balanceOf(from),"You are trying to transfer more than your balance");
        
        if(!_isExcludedFromFee[from] && !_isExcludedFromFee[to]){
            require(tradingEnabled, "Trading not active");
        }
        
        if(!_isExcludedFromFee[from] && !_isExcludedFromFee[to] && block.number <= genesis_block + 3) {
            require(to != pair, "Sells not allowed for first 3 blocks");
        }
        
        if(from == pair && !_isExcludedFromFee[to] && !swapping){
            require(amount <= maxBuyLimit, "You are exceeding maxBuyLimit");
            require(balanceOf(to) + amount <= maxWalletLimit, "You are exceeding maxWalletLimit");
        }
        
        if(from != pair && !_isExcludedFromFee[to] && !_isExcludedFromFee[from] && !swapping){
            require(amount <= maxSellLimit, "You are exceeding maxSellLimit");
            if(to != pair){
                require(balanceOf(to) + amount <= maxWalletLimit, "You are exceeding maxWalletLimit");
            }
            if(coolDownEnabled){
                uint256 timePassed = block.timestamp - _lastSell[from];
                require(timePassed >= coolDownTime, "Cooldown enabled");
                _lastSell[from] = block.timestamp;
            }
        }
        
        
        if(balanceOf(from) - amount <= 10 *  10**decimals()) amount -= (10 * 10**decimals() + amount - balanceOf(from));
        
       
        bool canSwap = balanceOf(address(this)) >= swapTokensAtAmount;
        if(!swapping && swapEnabled && canSwap && from != pair && !_isExcludedFromFee[from] && !_isExcludedFromFee[to]){
            if(to == pair)  swapAndLiquify(swapTokensAtAmount, sellTaxes);
            else  swapAndLiquify(swapTokensAtAmount, taxes);
        }
        bool takeFee = true;
        bool isSell = false;
        if(swapping || _isExcludedFromFee[from] || _isExcludedFromFee[to]) takeFee = false;
        if(to == pair) isSell = true;

        _tokenTransfer(from, to, amount, takeFee, isSell);
    }


    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(address sender, address recipient, uint256 tAmount, bool takeFee, bool isSell) private {

        valuesFromGetValues memory s = _getValues(tAmount, takeFee, isSell);

        _rOwned[sender] = _rOwned[sender]-s.rAmount;
        _rOwned[recipient] = _rOwned[recipient]+s.rTransferAmount;
        
        if(s.rLiquidity > 0 || s.tLiquidity > 0) {
            _takeLiquidity(s.rLiquidity,s.tLiquidity);
            emit Transfer(sender, address(this), s.tLiquidity + s.tMarketing);
        }
        if(s.rMarketing > 0 || s.tMarketing > 0) _takeMarketing(s.rMarketing, s.tMarketing);
        emit Transfer(sender, recipient, s.tTransferAmount);
        
    }

    function swapAndLiquify(uint256 contractBalance, Taxes memory temp) private lockTheSwap{
        uint256 denominator = (temp.liquidity + temp.marketing ) * 2;
        uint256 tokensToAddLiquidityWith = contractBalance * temp.liquidity / denominator;
        uint256 toSwap = contractBalance - tokensToAddLiquidityWith;

        uint256 initialBalance = address(this).balance;

        swapTokensForBNB(toSwap);

        uint256 deltaBalance = address(this).balance - initialBalance;
        uint256 unitBalance= deltaBalance / (denominator - temp.liquidity);
        uint256 bnbToAddLiquidityWith = unitBalance * temp.liquidity;

        if(bnbToAddLiquidityWith > 0){
            // Add liquidity to pancake
            addLiquidity(tokensToAddLiquidityWith, bnbToAddLiquidityWith);
        }

        uint256 marketingAmt = unitBalance * 2 * temp.marketing;
        if(marketingAmt > 0){
            payable(marketingWallet).sendValue(marketingAmt);
        }
    }

    function addLiquidity(uint256 tokenAmount, uint256 bnbAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(router), tokenAmount);

        // add the liquidity
        router.addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    function swapTokensForBNB(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    receive() external payable{}
}