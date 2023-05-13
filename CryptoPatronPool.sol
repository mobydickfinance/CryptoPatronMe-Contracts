// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./ReentrancyGuard.sol";
import "./AggregatorV3Interface.sol";
import "./TransferHelper.sol";


interface PoolAddressProvider {

    function getPool() external view returns (address);
    function getPoolDataProvider() external view returns (address);

}


interface YieldSource {

    function supply(
    	address asset,
    	uint256 amount,
    	address onBehalfOf,
    	uint16 referralCode) external;


    function withdraw(
    	address asset,
    	uint256 amount,
    	address to) external returns (uint256);

}


interface PoolDataProvider {

    function getReserveTokensAddresses(address asset) external view returns (
        address aTokenAddress,
        address stableDebtTokenAddress,
        address variableDebtTokenAddress);

}


contract CryptoPatronPool is ReentrancyGuard {

    address public constant EMPTY_ADDRESS = address(0);
    uint public immutable LOCK_LOTTERY;
    uint public immutable PERCENTAGE_LOTTERY;
    uint public immutable FEE_LOTTERY;
    uint public immutable FEE_WITHDRAW;

    PoolAddressProvider public immutable poolAddressProvider;
    IERC20 public underlying;
    IERC20 public aToken;
    
    AggregatorV3Interface internal priceFeed;
    
    uint public totalDevelopFee;
    uint public totalInterestPaid;
    uint public supporters;
    uint public lockDeposits;
    uint public jackpotValue;
    uint public interestValue;
    uint80 private nonce;
    uint private blockNumber;
    
    uint public generatorRNG;

    bool public spinning;
    bool public picking;

    uint public jackpotSettled;
    uint public timeJackpot;

    uint public jackpotsPaid;
    uint public developSettled;
    uint public balanceDonations;
    uint public totalDonations;
    uint public totalDonationsPaid;

    mapping(address => uint) public balanceDonators;
    mapping(address => uint) public balancePatrons;

    uint public balancePool;

    uint public decimalsToken;
    string public nameToken;

    address[] private players;
    
    mapping(address => uint) private indexPlayers;
    
    address public owner;
    address public developer;
    
    uint public lotteryCounter;
    
    struct Lottery {
        uint lotteryId;
        uint lotteryDate;
        uint lotteryResult;
        address lotteryWinner;
        uint lotteryAmount;
        uint dataBlock;
        uint80 dataNonce;
    }    
    
    Lottery[] public lotteryResults;
    
    event Deposit(address indexed from, uint amount);
    event Withdraw(address indexed to, uint amount);
    event DepositDonation(address indexed from, uint amount);
    event WithdrawDonation(address indexed to, uint amount);
    event CollectYield(address indexed to, uint amount);
    event PayWinner(address indexed to, uint amount);
    event PayDeveloper(address indexed to, uint amount);
    event ChangeOwner(address indexed oldowner, address indexed newowner);
    event ChangeDeveloper(address indexed olddeveloper, address indexed newdeveloper);
    event ChangeLockDeposits(address indexed ownerchanger, uint newlock);
    event LotteryAwarded(uint counter, uint date, address indexed thewinner, uint amount, uint result);
    event ChangeGeneratorRNG(address indexed ownerchanger, uint newRNG);

    
    constructor(
        address _owner,
        address _underlying,
        address _poolAddressProvider,
        address _developer,
        uint _cycleLottery,
        address _priceFeed,
        uint _generatorRNG,
        uint _feeLottery,
        uint _feeWithdraw,
        uint _percentageLottery) {
        
        require(_generatorRNG == 1 || _generatorRNG == 2);
        require(_feeLottery > 0 && _feeLottery < 100);
        require(_feeWithdraw > 0 && _feeWithdraw < 100);
        require(_percentageLottery > 0 && _percentageLottery < 100);
        require(_cycleLottery > 0);
        require(_priceFeed != EMPTY_ADDRESS);
        require(_developer != EMPTY_ADDRESS);
        require(_owner != EMPTY_ADDRESS);
        require(_underlying != EMPTY_ADDRESS);
        require(_poolAddressProvider != EMPTY_ADDRESS);

        underlying = IERC20(_underlying);
        poolAddressProvider = PoolAddressProvider(_poolAddressProvider);

        owner = _owner;
        developer = _developer;
        decimalsToken = underlying.decimals();
        nameToken = underlying.symbol();
        LOCK_LOTTERY = _cycleLottery;
        priceFeed = AggregatorV3Interface(_priceFeed);
        generatorRNG = _generatorRNG;
        FEE_LOTTERY = _feeLottery;
        FEE_WITHDRAW = _feeWithdraw;
        PERCENTAGE_LOTTERY = _percentageLottery;
        
        (address aTokenAddress,,) = (
            PoolDataProvider(poolAddressProvider.getPoolDataProvider())).getReserveTokensAddresses(_underlying);

        aToken = IERC20(aTokenAddress);

    }


    // Checks if msg.sender is the owner
    
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }


    // Returns historical price feed

    function _getHistoricalPrice(uint80 roundId) internal view returns (int, uint) {
        (,int price, uint startedAt,,) = priceFeed.getRoundData(roundId);
        
        return (price, startedAt);
    }


    // Returns latest price feed

    function _getLatestPrice() internal view returns (uint80) {
        (uint80 roundID,,,,) = priceFeed.latestRoundData();
        return roundID;
    }

    
    // Modifies the address of the owner
    
    function transferOwner(address _newOwner) external onlyOwner {
        require(_newOwner != EMPTY_ADDRESS);
        address oldOwner = owner;
        owner = _newOwner;
    
        emit ChangeOwner(oldOwner, owner);
    }


    // Modifies the address of the developer

    function transferDeveloper(address _newDeveloper) external {
        require(_newDeveloper != EMPTY_ADDRESS && msg.sender == developer);
        address oldDeveloper = developer;
        developer = _newDeveloper;
    
        emit ChangeDeveloper(oldDeveloper, developer);
    }
        

    // Changes RNG generator
    // 1 = PRICE FEED 
    // 2 = FUTURE BLOCKHASH
    
    function changeGenerator() external onlyOwner {
    
        if (generatorRNG == 1) {
            generatorRNG = 2;
        }
    
        if (generatorRNG == 2) {
            generatorRNG = 1;
        }
    
        spinning = false;
        picking = false;
        jackpotSettled = 0;
        developSettled = 0;
    
        emit ChangeGeneratorRNG(owner, generatorRNG);
    }


    // Locks or unlocks pool deposits
    // 0 = unlocked 
    // 1 = locked

    function changeLockDepositsPool() external onlyOwner {
                
        if (lockDeposits == 1) {
            lockDeposits = 0;
        }
        
        if (lockDeposits == 0) {
            lockDeposits = 1;
        }
        
        emit ChangeLockDeposits(owner, lockDeposits);
    }


    // Deposit underlying as lending and participate in lottery
        
    function deposit(uint _amount) external nonReentrant {
        
        require(!spinning && lockDeposits == 0);
        require(_amount > 0 && underlying.balanceOf(msg.sender) >= _amount);
        require(underlying.allowance(msg.sender, address(this)) >= _amount);
        
        TransferHelper.safeTransferFrom(address(underlying), msg.sender, address(this), _amount);

        if (balancePatrons[msg.sender] == 0) {
            supporters += 1;
            players.push(msg.sender);
            indexPlayers[msg.sender] = players.length - 1;
        }

        if (supporters > 0 && timeJackpot == 0 && !spinning) {
            timeJackpot = block.timestamp;
        }
        
        YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());

        TransferHelper.safeApprove(address(underlying), address(yieldSource), _amount);

        yieldSource.supply(address(underlying), _amount, address(this), 0);

        balancePatrons[msg.sender] += _amount;
        balancePool += _amount;
        
        emit Deposit(msg.sender, _amount);
    }
    
    
    // Deposit underlying as donation
  
    function depositDonation(uint _amount) external nonReentrant {
        
        require(lockDeposits == 0);
        require(_amount > 0 && underlying.balanceOf(msg.sender) >= _amount);
        require(underlying.allowance(msg.sender, address(this)) >= _amount);
        
        TransferHelper.safeTransferFrom(address(underlying), msg.sender, address(this), _amount);

        YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());

        TransferHelper.safeApprove(address(underlying), address(yieldSource), _amount);

        yieldSource.supply(address(underlying), _amount, address(this), 0);

        balanceDonators[msg.sender] += _amount;
        balanceDonations += _amount;
        totalDonations += _amount;
                
        emit DepositDonation(msg.sender, _amount);
    }
    
    
    // Withdraw underlying lended
        
    function withdraw(uint _amount) external nonReentrant {
        
        require(!spinning);
        require(_amount > 0 && balancePatrons[msg.sender] >= _amount);
                
        balancePatrons[msg.sender] -= _amount; 
        balancePool -= _amount;

        YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());
        
        require(yieldSource.withdraw(address(underlying), _amount, address(this)) == _amount);
        
        if (balancePatrons[msg.sender] == 0) {
            supporters -= 1;
                
            uint index = indexPlayers[msg.sender];
            uint indexMove = players.length - 1;
            address addressMove = players[indexMove];
                
            if (index == indexMove) {
                delete indexPlayers[msg.sender];
                players.pop();
                    
            } else {
                delete indexPlayers[msg.sender];
                players[index] = addressMove;
                indexPlayers[addressMove] = index;
                players.pop();
            }
        } 
        
        if (supporters == 0) {
            timeJackpot = 0;
            spinning = false;
            picking = false;
            jackpotSettled = 0;
            developSettled = 0;
        }    

        TransferHelper.safeTransfer(address(underlying), msg.sender, _amount);
    
        emit Withdraw(msg.sender, _amount);
    }


    // Accrues yield and splits into interests and jackpot
    
    function _splitYield() internal {
        
        uint interest = _interestAccrued();
        
        uint jackpotInterest = interest * (PERCENTAGE_LOTTERY * 10 ** decimalsToken / 100);
        jackpotInterest = jackpotInterest / 10 ** decimalsToken;
        jackpotValue += jackpotInterest;
        
        uint toTransferInterest = interest - jackpotInterest;
        interestValue += toTransferInterest;
    }


    // Calculates yield generated in yield source
    
    function _interestAccrued() internal view returns (uint) {
        
        uint interest = aToken.balanceOf(address(this)) - balancePool - balanceDonations - jackpotValue - interestValue; 
        return interest;
    }


    // Draw the Lottery
    
    function settleJackpot() external nonReentrant {
        
        require(!spinning && supporters > 0 && timeJackpot > 0);
        
        uint end = block.timestamp;
        uint totalTime = end - timeJackpot;
        require(totalTime >= LOCK_LOTTERY);

        spinning = true;
        timeJackpot = 0;
        
        _splitYield();
    
        require(jackpotValue > 0);
        
        jackpotSettled = jackpotValue;
        uint distJackpot = jackpotSettled;
        
        developSettled = distJackpot * (FEE_LOTTERY * 10 ** decimalsToken / 100);
        developSettled = developSettled / 10 ** decimalsToken;
        
        jackpotSettled = jackpotSettled - developSettled;
        
        if (generatorRNG == 1) {
            nonce = _getLatestPrice() + 10;
            blockNumber = block.number + 10;
        }

        if (generatorRNG == 2) {
            blockNumber = block.number + 10;
        }

        picking = true;
    }
    
    
    // RNG or PRNG (random or pseudo random number generator)
    
    function _generateRandomNumber() internal view returns (uint) {
        
        uint randNum;

        if (generatorRNG == 1) {
        (int thePrice, uint theStartRound) = _getHistoricalPrice(nonce);
        randNum = uint(keccak256(abi.encode(thePrice, theStartRound))) % players.length;
        }
        
        if (generatorRNG == 2) {
        randNum = uint(keccak256(abi.encode(blockhash(blockNumber)))) % players.length;
        }

        return randNum;  
    }


    // Award the Lottery Winner
        
    function pickWinner() external nonReentrant {
        
        if (generatorRNG == 1) {
        require(picking && _getLatestPrice() > nonce);
        }

        if (generatorRNG == 2) {
        require(picking && block.number > blockNumber);
        }

        uint toRedeem =  jackpotSettled + developSettled;
                
        uint toTransferBeneficiary = jackpotSettled;
        uint toTransferDevelop = developSettled;
        
        jackpotSettled = 0;
        developSettled = 0;
        
        lotteryCounter++;
        uint end = block.timestamp;
        
        if (block.number - blockNumber > 250) {
    
            lotteryResults.push(Lottery(lotteryCounter, end, 2, EMPTY_ADDRESS, 0, blockNumber, nonce));

            emit LotteryAwarded(lotteryCounter, end, EMPTY_ADDRESS, 0, 2);
        
        } else {
            
            uint randomNumber = _generateRandomNumber();
            address beneficiary = players[randomNumber];
            
            jackpotsPaid += toTransferBeneficiary;
            totalDevelopFee += toTransferDevelop;
            
            YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());
        
            require(yieldSource.withdraw(address(underlying), toRedeem, address(this)) == toRedeem);
            
            jackpotValue -= toRedeem;

            TransferHelper.safeTransfer(address(underlying), beneficiary, toTransferBeneficiary);
            TransferHelper.safeTransfer(address(underlying), developer, toTransferDevelop);

            lotteryResults.push(Lottery(lotteryCounter, end, 1, beneficiary, toTransferBeneficiary, blockNumber, nonce));
        
            emit PayWinner(beneficiary, toTransferBeneficiary);
            emit PayDeveloper(developer, toTransferDevelop);
                        
            emit LotteryAwarded(lotteryCounter, end, beneficiary, toTransferBeneficiary, 1);
        }
          
        timeJackpot = block.timestamp;
        spinning = false;
        picking = false;
    }
        
    
    // Returns the timeleft to draw lottery
    // 0 = no time left

    function calculateTimeLeft() public view returns (uint) {
        
        uint end = block.timestamp;
        uint totalTime = end - timeJackpot;
        
        if(totalTime < LOCK_LOTTERY) {
            uint timeLeft = LOCK_LOTTERY - totalTime;
            return timeLeft;
        } else {
            return 0;
        }
    }
    
    
    // Returns if conditions are met to draw lottery
    // 1 = met
    // 2 = not met 
    
    function checkJackpotReady() public view returns (uint) {
        
        uint end = block.timestamp;
        uint totalTime = end - timeJackpot;

        if (!spinning && supporters > 0 && timeJackpot > 0 && totalTime > LOCK_LOTTERY) {
            return 1;
    
        } else {
            return 2;
        }    
    }        
            
    
    // Returns if conditions are met to award a lottery winner
    // 1 = met
    // 2 = not met 
        
    function checkWinnerReady() public view returns (uint) {

        uint metWinner;
        
        if (generatorRNG == 1) {
            if (picking && _getLatestPrice() > nonce) {
                metWinner = 1;
            } else {
                metWinner = 2;
            }
        }

        if (generatorRNG == 2) {
            if (picking && block.number > blockNumber) {
                metWinner = 1;
            } else {
                metWinner = 2;
            }
        }
        
        return metWinner;
    }
    
    
    // Returns if account is the owner
    // 1 = is owner
    // 2 = is not owner
    
    function verifyOwner(address _account) public view returns (uint) {
        
        if (_account == owner) {
            return 1;
        } else {
            return 2;
        }
    }
    
  
    // Returns an array of struct of jackpots drawn results
  
    function getLotteryResults() external view returns (Lottery[] memory) {
    
        return lotteryResults;
    }
  
    
    // Withdraw interests by the owner
    
    function withdrawYield(uint _amount) external nonReentrant onlyOwner {
        
        _splitYield();

        require(_amount > 0);
        require(_amount <= interestValue);
        
        uint developFee;
        uint amountOwner;

        totalInterestPaid += _amount;
        interestValue -= _amount;
        
        developFee = _amount * (FEE_WITHDRAW * 10 ** decimalsToken / 100);
        developFee = developFee / 10 ** decimalsToken;
        amountOwner = _amount - developFee;
        totalDevelopFee += developFee;
        
        YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());
        
        require(yieldSource.withdraw(address(underlying), _amount, address(this)) == _amount);
        
        TransferHelper.safeTransfer(address(underlying), owner, amountOwner);
        TransferHelper.safeTransfer(address(underlying), developer, developFee);
        
        emit CollectYield(owner, amountOwner);
        emit PayDeveloper(developer, developFee);
    }
    
    
    // Withdraw donations by the owner     
    
    function withdrawDonations(uint _amount) external nonReentrant onlyOwner {
        
        require(_amount > 0);
        require(balanceDonations >= _amount);
        
        YieldSource yieldSource = YieldSource(poolAddressProvider.getPool());
        
        require(yieldSource.withdraw(address(underlying), _amount, address(this)) == _amount);
                
        balanceDonations -= _amount;
        totalDonationsPaid += _amount;
        
        uint developFee;
        uint amountOwner;

        developFee = _amount * (FEE_WITHDRAW * 10 ** decimalsToken / 100);
        developFee = developFee / 10 ** decimalsToken;
        amountOwner = _amount - developFee;
        totalDevelopFee += developFee;

        TransferHelper.safeTransfer(address(underlying), owner, amountOwner);
        TransferHelper.safeTransfer(address(underlying), developer, developFee);

        emit WithdrawDonation(owner, amountOwner);
        emit PayDeveloper(developer, developFee);
    }
    

    // Returns yield generated
    
    function calculateInterest() external view returns(uint, uint) {
        
        uint yield = _interestAccrued();
        
        uint jackpot = yield * (PERCENTAGE_LOTTERY * 10 ** decimalsToken / 100);
        jackpot = jackpot / 10 ** decimalsToken;

        uint interest = yield - jackpot;
        interest += interestValue;

        jackpot = jackpot + jackpotValue - jackpotSettled - developSettled;

        uint feeJackpot = jackpot * (FEE_LOTTERY * 10 ** decimalsToken / 100); 
        feeJackpot = feeJackpot / 10 ** decimalsToken;

        jackpot -= feeJackpot;

        return (interest, jackpot);
    }
    

    // Returns data to the front end

    function pullData() external view returns (uint [] memory) {
        
        uint[] memory dataFront = new uint[](17);
        
        dataFront[0] = balancePool + balanceDonations;
        dataFront[1] = lotteryCounter;
        dataFront[2] = calculateTimeLeft();
        dataFront[3] = checkJackpotReady();
        dataFront[4] = checkWinnerReady();
        dataFront[5] = totalInterestPaid;
        dataFront[6] = generatorRNG;
        dataFront[7] = totalDonationsPaid;
        dataFront[8] = balanceDonations;
        dataFront[9] = totalDonations;
        dataFront[10] = jackpotSettled;
        dataFront[11] = jackpotsPaid;
        dataFront[12] = lockDeposits;
        dataFront[13] = supporters;
        dataFront[14] = LOCK_LOTTERY;
        dataFront[15] = decimalsToken;
        dataFront[16] = balancePool;
        
        return (dataFront);
    }

   
   // Returns data to the front end
    
    function pullDataAccount(address _account) external view returns (uint [] memory) {
        
        uint[] memory dataFrontAccount = new uint[](5);
        
        dataFrontAccount[0] = balancePatrons[_account];
        dataFrontAccount[1] = underlying.balanceOf(_account);
        dataFrontAccount[2] = underlying.allowance(_account, address(this));
        dataFrontAccount[3] = verifyOwner(_account);
        dataFrontAccount[4] = balanceDonators[_account];
        
        return (dataFrontAccount);
    }


    // Checks conditions of transactions
    // flag 1 = deposits lending
    // flag 2 = deposits donations
    // flag 3 = withdraw lending
    // flag 4 = withdraw donations
    // flag 5 = withdraw yield

    function checkOperations(uint _amount, uint _amount1, address _account, uint _flag) external view returns (uint) {
                
        uint result = 0;
        
        if (lockDeposits == 1 && (_flag == 1 || _flag == 2)) {
            result = 1;
        } else {
            if (spinning && (_flag == 1 || _flag == 3)) {
                result = 2;
            } else {
                if (_amount > underlying.balanceOf(_account) && (_flag == 1 || _flag == 2)) {
                    result = 3;
                } else {
                    if (_amount > underlying.allowance(_account, address(this)) && (_flag == 1 || _flag == 2)) {
                        result = 4;
                    } else {
                        if (_amount > balancePatrons[_account] && _flag == 3) {
                            result = 5;            
                        } else {
                             if (verifyOwner(_account) == 2 && (_flag == 4 || _flag == 5)) {
                                result = 6;
                            } else {
                                if (_amount > balanceDonations && _flag == 4) {
                                    result = 7;
                                } else {
                                    if (_amount > _amount1 && _flag == 5) {
                                        result = 8;
                                    }
                                }
                            }     
                        }
                    }                        
                }
            }
        }
        
        return result;
    }


    function getPoolAddress() external view returns (address) {

        return poolAddressProvider.getPool();
    }

}