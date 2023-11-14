// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.0 <0.9.0;

// Escrow app using Chainlink or Uniswap oracles to settle contracts on chain
// Users (Maker) can open a bet and another user can take the bet (Taker); Taker can be specified by address

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

interface UniV3TwapOracleInterface {
    function convertToHumanReadable(
        address _factory,
        address _token1,
        address _token2,
        uint24 _fee,
        uint32 _twapInterval,
        uint8 _token0Decimals
    ) external view returns (uint256);

    function getToken0(
        address _factory,
        address _tokenA,
        address _tokenB,
        uint24 _fee
    ) external view returns (address);
}

contract Flex is AutomationCompatibleInterface, Context, Ownable {
    using SafeERC20 for IERC20;
    // Global variables
    uint8 private PROTOCOL_FEE;
    address OWNER;
    address UNIV3FACTORY;

    address private UNISWAP_TWAP_LIBRARY;
    UniV3TwapOracleInterface public twapGetter;

    enum Status {
        WAITING_FOR_TAKER,
        KILLED,
        IN_PROCESS,
        MAKER_WINS,
        TAKER_WINS,
        CANCELED
    }

    enum Comparison {
        GREATER_THAN,
        EQUALS,
        LESS_THAN
    }

    enum OracleType {
        CHAINLINK,
        UNISWAP_V3
    }

    // this struct exists to circumvent Stack too deep errors
    struct BetAddresses {
        address Maker; // stores address of bet creator via msg.sender
        address Taker; // stores address of taker, is either defined by the bet Maker or is blank so anyone can take the bet
        address CollateralToken; // address of the token used as medium of exchange in the bet
        address OracleAddressMain; // address of the Main price oracle that the bet will use (if Uniswap then this is token0)
        address OracleAddress2; // address of a secondary oracle if two are needed (if Uniswap then this is token1)
    }

    // struct to store each address's total deposited token balance and # tokens in a bet
    struct Ledger {
        uint depositedBalance;
        uint escrowedBalance;
    }

    // Mapping of mapping to track balances for each token by owner address
    mapping(address => mapping(address => Ledger)) public balances;

    // Mapping to track all of a user's bets;
    mapping(address => uint256[]) public UserBets;

    // Universal counter of every bet made
    uint256 public BetNumber;

    // this struct stores bets which will be assigned a BetNumber to be mapped to
    struct Bets {
        BetAddresses betAddresses; // struct to store all bet addresses
        uint BetAmount; // ammount of CollateralToken to be bet with
        uint EndTime; // unix time that bet ends, user defines number of seconds from time the bet creation Tx is approved
        Status BetStatus; // Status of bet as enum: WAITING_FOR_TAKER, KILLED, IN_PROCESS, SETTLED, CANCELED
        OracleType OracleName; // enum defining what type of oracle to use
        uint24 UniswapFeePool; // allows user defined fee pool to get price from ("3000" corresponds to 0.3%)
        uint256 PriceLine; // price level to determine winner based off of the price oracle
        Comparison Comparator; // enum defining direction taken by bet Maker enum: GREATER_THAN, EQUALS, LESS_THAN
        bool MakerCancel; // define if Maker has agreed to cancel bet
        bool TakerCancel; // defines if Taker has agreed to cancel bet
    }

    // Mapping of all opened bets
    mapping(uint256 => Bets) public AllBets;

    //Event triggered when a new bet is offered/created
    event betCreated(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );

    event betTaken(uint256 indexed betNumber); //Event for when a bet recieves a Taker
    event betKilled(uint256 indexed betNumber); //Event for when a bet is killed by the Maker after recieving no Taker
    event betCompleted(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    ); //Event for when a bet is closed/fulfilled
    //Event for when Maker requests that a bet with a Taker be cancelled
    event attemptBetCancelByMaker(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );
    //Event for when a Taker requests that a bet be cancelled
    event attemptBetCancelByTaker(
        address indexed maker,
        address indexed taker,
        uint256 indexed betNumber
    );
    //Event for when a bet is cancelled after a Maker and Taker agree
    event betCanceled(uint256 indexed betNumber);

    constructor(
        uint8 _protocolFee,
        address _UNISWAP_TWAP_LIBRARY,
        address _UNIV3FACTORY
    ) Ownable(msg.sender) {
        // Because Solidity can't perform decimal mult/div, multiply by PROTOCOL_FEE and divide by 10,000
        // PROTOCOL_FEE of 0001 equals 0.01% fee
        PROTOCOL_FEE = _protocolFee;
        UNISWAP_TWAP_LIBRARY = _UNISWAP_TWAP_LIBRARY;
        UNIV3FACTORY = _UNIV3FACTORY;
        OWNER = msg.sender;
    }

    function changeProtocolFee(uint8 _newProtocolFee) external onlyOwner {
        PROTOCOL_FEE = _newProtocolFee;
    }

    function getUserBets(
        address _userAddress
    ) external view returns (uint256[] memory) {
        return UserBets[_userAddress];
    }

    function setUniswapOracleLibrary(address _UniLibAddr) external onlyOwner {
        UNISWAP_TWAP_LIBRARY = _UniLibAddr;
        twapGetter = UniV3TwapOracleInterface(UNISWAP_TWAP_LIBRARY);
    }

    function transferERC20(
        address _tokenAddress,
        uint256 amount
    ) external onlyOwner {
        require(
            amount <= balances[address(this)][_tokenAddress].depositedBalance,
            "Insufficient Funds"
        );
        balances[OWNER][_tokenAddress].depositedBalance -= amount;
        IERC20(_tokenAddress).safeTransfer(OWNER, amount);
    }

    function withdrawEther(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient Funds");
        payable(OWNER).transfer(amount);
    }

    function depositTokens(address _tokenAddress, uint _amount) public {
        balances[msg.sender][_tokenAddress].depositedBalance += _amount;

        IERC20(_tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );
    }

    // Withdraws _amount of tokens if they are avaiable
    function userWithdrawTokens(address _tokenAddress, uint _amount) public {
        uint tokensAvailable = balances[msg.sender][_tokenAddress]
            .depositedBalance -
            balances[msg.sender][_tokenAddress].escrowedBalance;
        require(tokensAvailable >= _amount, "Insufficient Balance");
        balances[msg.sender][_tokenAddress].depositedBalance -= _amount;

        IERC20(_tokenAddress).safeTransfer(msg.sender, _amount);
    }

    function createNewBet(
        BetAddresses memory _betAddresses,
        uint _amount,
        uint32 _time,
        OracleType _oracleName,
        uint24 _uniFeePool,
        uint256 _priceLine,
        Comparison _comparator
    ) internal {
        AllBets[BetNumber].betAddresses.Maker = _betAddresses.Maker;
        AllBets[BetNumber].betAddresses.Taker = _betAddresses.Taker;
        AllBets[BetNumber].betAddresses.CollateralToken = _betAddresses
            .CollateralToken;
        AllBets[BetNumber].BetAmount = _amount;
        AllBets[BetNumber].EndTime = block.timestamp + _time;
        AllBets[BetNumber].BetStatus = Status.WAITING_FOR_TAKER;

        if (_oracleName == OracleType.UNISWAP_V3) {
            address _token0 = twapGetter.getToken0(
                UNIV3FACTORY,
                _betAddresses.OracleAddressMain,
                _betAddresses.OracleAddress2,
                3000
            );
            if (_betAddresses.OracleAddress2 == _token0) {
                _betAddresses.OracleAddress2 = _betAddresses.OracleAddressMain;
                _betAddresses.OracleAddressMain = _token0;
            }
        }
        AllBets[BetNumber].betAddresses.OracleAddressMain = _betAddresses
            .OracleAddressMain;
        AllBets[BetNumber].betAddresses.OracleAddress2 = _betAddresses
            .OracleAddress2;
        AllBets[BetNumber].OracleName = _oracleName;
        AllBets[BetNumber].PriceLine = _priceLine;
        AllBets[BetNumber].UniswapFeePool = _uniFeePool;
        AllBets[BetNumber].Comparator = _comparator;
        AllBets[BetNumber].MakerCancel = false;
        AllBets[BetNumber].TakerCancel = false;
    }

    function betWithUserBalance(
        address _takerAddress,
        address _collateralTokenAddress,
        uint _amount,
        uint32 _time,
        address _oracleAddressMain,
        address _oracleAddress2,
        OracleType _oracleName,
        uint24 _uniFeePool,
        uint256 _priceLine,
        Comparison _comparator
    ) public {
        require(_amount > 0, "amount !> 0");
        require(_takerAddress != msg.sender, "Maker = Taker");
        //Check that Maker has required amount of tokens for bet
        require(
            balances[msg.sender][_collateralTokenAddress].depositedBalance -
                balances[msg.sender][_collateralTokenAddress].escrowedBalance >=
                _amount,
            "Insufficient Funds"
        );
        require(_time > 15, "Time !>15 s");
        BetNumber++;

        BetAddresses memory _betAddresses;
        _betAddresses.Maker = msg.sender;
        _betAddresses.Taker = _takerAddress; // can be 0x0000000000000000000000000000000000000000
        _betAddresses.CollateralToken = _collateralTokenAddress;
        _betAddresses.OracleAddressMain = _oracleAddressMain;
        _betAddresses.OracleAddress2 = _oracleAddress2;
        createNewBet(
            _betAddresses,
            _amount,
            _time,
            _oracleName,
            _uniFeePool,
            _priceLine,
            _comparator
        );

        UserBets[msg.sender].push(BetNumber);
        emit betCreated(_betAddresses.Maker, _betAddresses.Taker, BetNumber);
        balances[msg.sender][_collateralTokenAddress]
            .escrowedBalance += _amount;
    }

    function cancelBet(uint _betNumber) public {
        address _tokenAddress = AllBets[_betNumber]
            .betAddresses
            .CollateralToken;

        // Check that request was sent by bet Maker
        require(msg.sender == AllBets[_betNumber].betAddresses.Maker, "!Maker");
        // check that bet is not taken
        require(
            AllBets[_betNumber].BetStatus == Status.WAITING_FOR_TAKER,
            "Status"
        );
        // Change status to "KILLED"
        AllBets[_betNumber].BetStatus = Status.KILLED;
        // subtract the bet amount from escrowedBalance
        emit betKilled(_betNumber);
        balances[msg.sender][_tokenAddress].escrowedBalance -= AllBets[
            _betNumber
        ].BetAmount;
    }

    function acceptBetWithUserBalance(uint _betNumber) public {
        //check if msg.sender can be taker
        require(
            msg.sender == AllBets[_betNumber].betAddresses.Taker ||
                AllBets[_betNumber].betAddresses.Taker == address(0),
            "!Taker"
        );
        // require that the bet is not taken, killed, cancelled, or completed
        require(
            AllBets[_betNumber].BetStatus == Status.WAITING_FOR_TAKER,
            "Status"
        );
        // require bet time not passed
        require(
            AllBets[_betNumber].EndTime > block.timestamp,
            "Action expired"
        );
        // check that Taker has required amount of tokens
        require(
            balances[msg.sender][
                AllBets[_betNumber].betAddresses.CollateralToken
            ].depositedBalance -
                balances[msg.sender][
                    AllBets[_betNumber].betAddresses.CollateralToken
                ].escrowedBalance >=
                AllBets[_betNumber].BetAmount,
            "Insufficient Funds"
        );

        // Assign msg.sender to Taker if Taker is unassigned
        if (AllBets[_betNumber].betAddresses.Taker == address(0)) {
            AllBets[_betNumber].betAddresses.Taker = msg.sender;
        }

        AllBets[_betNumber].BetStatus = Status.IN_PROCESS;
        UserBets[msg.sender].push(_betNumber);
        emit betTaken(_betNumber);
        balances[msg.sender][AllBets[_betNumber].betAddresses.CollateralToken]
            .escrowedBalance += AllBets[_betNumber].BetAmount;
    }

    // need to somehow check if oracle has gone dead or not updated in a long time
    function closeBet(uint _betNumber) public {
        // check _betNumber exists
        require(_betNumber <= BetNumber, "This bet does not exist");
        // check bet status
        require(AllBets[_betNumber].BetStatus == Status.IN_PROCESS, "Status");
        // check correct time has passed
        require(block.timestamp >= AllBets[_betNumber].EndTime, "!EndTime");

        // check winner
        bool makerWins;
        uint256 currentPrice = getOraclePriceByBet(_betNumber);
        uint256 priceLine = AllBets[_betNumber].PriceLine;

        if (currentPrice > priceLine) {
            if (AllBets[_betNumber].Comparator == Comparison.GREATER_THAN) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        } else if (currentPrice < priceLine) {
            if (AllBets[_betNumber].Comparator == Comparison.LESS_THAN) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        } else {
            if (AllBets[_betNumber].Comparator == Comparison.EQUALS) {
                makerWins = true;
            } else {
                makerWins = false;
            }
        }

        emit betCompleted(
            AllBets[_betNumber].betAddresses.Maker,
            AllBets[_betNumber].betAddresses.Taker,
            _betNumber
        );

        if (makerWins) {
            AllBets[_betNumber].BetStatus = Status.MAKER_WINS;
            settleBalances(
                AllBets[_betNumber].betAddresses.Maker,
                AllBets[_betNumber].betAddresses.Taker,
                AllBets[_betNumber].betAddresses.CollateralToken,
                AllBets[_betNumber].BetAmount
            );
        } else {
            AllBets[_betNumber].BetStatus = Status.TAKER_WINS;
            settleBalances(
                AllBets[_betNumber].betAddresses.Taker,
                AllBets[_betNumber].betAddresses.Maker,
                AllBets[_betNumber].betAddresses.CollateralToken,
                AllBets[_betNumber].BetAmount
            );
        }
    }

    function settleBalances(
        address _winningAddress,
        address _losingAddress,
        address _collateralToken,
        uint amount
    ) internal {
        // This should use SafeMath!!!!!!!!!!!!!!
        balances[_losingAddress][_collateralToken].depositedBalance -= amount;
        balances[_losingAddress][_collateralToken].escrowedBalance -= amount;
        balances[_winningAddress][_collateralToken].depositedBalance +=
            (amount * (10000 - PROTOCOL_FEE)) /
            10000;
        balances[_winningAddress][_collateralToken].escrowedBalance -= amount;
        balances[address(this)][_collateralToken].depositedBalance +=
            (amount * PROTOCOL_FEE) /
            10000;
    }

    function requestBetCancel(uint _betNumber) public {
        // Require that request was sent by Maker or Taker
        require(
            msg.sender == AllBets[_betNumber].betAddresses.Maker ||
                msg.sender == AllBets[_betNumber].betAddresses.Taker,
            "!Maker/Taker"
        );
        // Require that bet is in a cancellable state ("IN_PROCESS")
        require(AllBets[_betNumber].BetStatus == Status.IN_PROCESS, "Status");

        if (msg.sender == AllBets[_betNumber].betAddresses.Maker) {
            AllBets[_betNumber].MakerCancel = true;
            emit attemptBetCancelByMaker(
                AllBets[_betNumber].betAddresses.Maker,
                AllBets[_betNumber].betAddresses.Taker,
                _betNumber
            );
        } else if (msg.sender == AllBets[_betNumber].betAddresses.Taker) {
            AllBets[_betNumber].TakerCancel = true;
            emit attemptBetCancelByTaker(
                AllBets[_betNumber].betAddresses.Maker,
                AllBets[_betNumber].betAddresses.Taker,
                _betNumber
            );
        }

        //If Maker and Taker agree to cancel then refund each their tokens
        if (
            AllBets[_betNumber].MakerCancel == true &&
            AllBets[_betNumber].TakerCancel == true
        ) {
            emit betCanceled(_betNumber);
            AllBets[_betNumber].BetStatus = Status.CANCELED;
            balances[AllBets[_betNumber].betAddresses.Maker][
                AllBets[_betNumber].betAddresses.CollateralToken
            ].escrowedBalance -= AllBets[_betNumber].BetAmount;
            balances[AllBets[_betNumber].betAddresses.Taker][
                AllBets[_betNumber].betAddresses.CollateralToken
            ].escrowedBalance -= AllBets[_betNumber].BetAmount;
        }
    }

    function checkClosable(uint _betNumber) public view returns (bool) {
        if (
            block.timestamp >= AllBets[_betNumber].EndTime &&
            AllBets[_betNumber].BetStatus == Status.IN_PROCESS
        ) {
            return true;
        } else {
            return false;
        }
    }

    function getDecimals(address _oracleAddress) public view returns (uint8) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_oracleAddress);
        return priceFeed.decimals();
    }

    function getChainlinkPrice(
        address _oracleAddress
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_oracleAddress);
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        return uint256(answer / int256(10 ** getDecimals(_oracleAddress)));
    }

    function getOraclePriceByBet(
        uint256 _betNumber
    ) public view returns (uint256) {
        uint256 CurrentPrice;
        if (AllBets[_betNumber].OracleName == OracleType.CHAINLINK) {
            if (AllBets[_betNumber].betAddresses.OracleAddress2 == address(0)) {
                CurrentPrice = getChainlinkPrice(
                    AllBets[_betNumber].betAddresses.OracleAddressMain
                );
            } else {
                CurrentPrice =
                    getChainlinkPrice(
                        AllBets[_betNumber].betAddresses.OracleAddressMain
                    ) /
                    getChainlinkPrice(
                        AllBets[_betNumber].betAddresses.OracleAddress2
                    );
            }
        } else if (AllBets[_betNumber].OracleName == OracleType.UNISWAP_V3) {
            uint8 _token0Decimals = ERC20(
                AllBets[_betNumber].betAddresses.OracleAddressMain
            ).decimals();
            // address _factory, address _token1, address _token2, uint24 _fee, uint32 _twapInterval, uint8 _decimals
            CurrentPrice = twapGetter.convertToHumanReadable(
                UNIV3FACTORY,
                AllBets[_betNumber].betAddresses.OracleAddressMain,
                AllBets[_betNumber].betAddresses.OracleAddress2,
                AllBets[_betNumber].UniswapFeePool,
                uint32(60),
                _token0Decimals
            );
        }
        return CurrentPrice;
    }

    function checkUpkeep(
        bytes calldata /* checkData*/
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        //go through AllBets and if any are closable then trigger true
        uint _betNumber = 1;
        while (_betNumber <= BetNumber && upkeepNeeded == false) {
            if (checkClosable(_betNumber)) upkeepNeeded = true;
            _betNumber++;
        }
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        uint _betNumber = 1;
        while (_betNumber <= BetNumber) {
            if (checkClosable(_betNumber)) closeBet(_betNumber);
            _betNumber++;
        }
    }
}
