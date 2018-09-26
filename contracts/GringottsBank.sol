pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "@evolutionland/common/contracts/interfaces/ISettingsRegistry.sol";
import "@evolutionland/common/contracts/interfaces/IBurnableERC20.sol";
import "@evolutionland/common/contracts/interfaces/IMintableERC20.sol";
import "./BankSettingIds.sol";

contract  GringottsBank is Ownable, BankSettingIds {
    /*
     *  Events
     */
    event ClaimedTokens(address indexed _token, address indexed _owner, uint _amount);

    event NewDeposit(address indexed _depositor, uint256 indexed _depositID);

    /*
     *  Constants
     */
    uint public constant MONTH = 30 * 1 days;

    /*
     *  Structs
     */
    struct Deposit {
        address depositor;
        uint128 value;  // amount of ring
        uint128 months; // Length of time from the deposit's beginning to end (in months), For now, months must >= 1 and <= 36
        uint256 startAt;   // when player deposit, timestamp in seconds
        uint256 unitInterest;
        bool claimed;
    }

    /*
     *  Storages
     */
    ERC20 public ring_; // token contract

    ERC20 public kryptonite_;   // bounty contract

    ISettingsRegistry registry_;

    mapping (uint256 => Deposit) public deposits_;

    uint public depositCount_;

    mapping (address => uint[]) playerDeposits_;

    // player => totalDepositRING, total number of ring that the player has deposited
    mapping (address => uint256) public playerTotalDeposit_;

    /*
     *  Modifiers
     */
    modifier canBeStoredWith128Bits(uint256 _value) {
        require(_value < 340282366920938463463374607431768211455);
        _;
    }

    /**
     * @dev Bank's constructor which set the token address and unitInterest_
     * @param _ring - address of ring
     * @param _kton - address of kton
     * @param _registry - address of SettingsRegistry
     */
    constructor (address _ring, address _kton, address _registry) public {
        ring_ = ERC20(_ring);
        kryptonite_ = ERC20(_kton);

        registry_ = ISettingsRegistry(_registry);
    }

    function getDeposit(uint id) public view returns (address, uint128, uint128, uint256, uint256, bool ) {
        return (deposits_[id].depositor, deposits_[id].value, deposits_[id].months, 
            deposits_[id].startAt, deposits_[id].unitInterest, deposits_[id].claimed);
    }

    /**
     * @dev ERC223 fallback function, make sure to check the msg.sender is from target token contracts
     * @param _from - person who transfer token in for deposits or claim deposit with penalty KTON.
     * @param _amount - amount of token.
     * @param _data - data which indicate the operations.
     */
    function tokenFallback(address _from, uint256 _amount, bytes _data) public {
        // deposit entrance
        if(address(ring_) == msg.sender) {
            uint months = bytesToUint256(_data);
            _deposit(_from, _amount, months);
        }
        //  Early Redemption entrance
        if (address(kryptonite_) == msg.sender) {
            uint depositID = bytesToUint256(_data);
            require(_amount >= computePenalty(depositID), "No enough amount of KTON penalty.");

            _claimDeposit(_from, depositID, true);

            // burn the KTON transferred in
            IBurnableERC20(kryptonite_).burn(address(this), _amount);
        }
    }

    /**
     * @dev Deposit for msg sender, require the token approvement ahead.
     * @param _amount - amount of token.
     * @param _months - the amount of months that the token will be locked in the deposit.
     */
    function deposit(uint256 _amount, uint256 _months) public {
        deposit(msg.sender, _amount, _months);
    }

    /**
     * @dev Deposit for benificiary, require the token approvement ahead.
     * @param _benificiary - benificiary of the deposit, which will get the KTON and RINGs after deposit being claimed.
     * @param _amount - amount of token.
     * @param _months - the amount of months that the token will be locked in the deposit.
     */
    function deposit(address _benificiary, uint256 _amount, uint256 _months) public {
        require(ring_.transferFrom(msg.sender, address(this), _amount), "RING token tranfer failed.");

        _deposit(_benificiary, _amount, _months);
    }

    function claimDeposit(uint _depositID) public {
        _claimDeposit(msg.sender, _depositID, false);
    }

    // normal Redemption, withdraw at maturity
    function _claimDeposit(address _depositor, uint _depositID, bool isPenalty) internal {
        require(deposits_[_depositID].claimed == false, "Already claimed");
        require(deposits_[_depositID].depositor == _depositor);

        if (!isPenalty) {
            uint months = deposits_[_depositID].months;
            uint startAt = deposits_[_depositID].startAt;
            uint duration = now - startAt;
        
            require (duration >= (months * MONTH));
        }

        deposits_[_depositID].claimed = true;
        playerTotalDeposit_[_depositor] -= deposits_[_depositID].value;

        require(ring_.transfer(_depositor, deposits_[_depositID].value));
    }

    /**
     * @dev deposit actions
     * @param _depositor - person who deposits
     * @param _value - depositor wants to deposit how many tokens
     * @param _month - Length of time from the deposit's beginning to end (in months).
     */
    function _deposit(address _depositor, uint _value, uint _month) 
        canBeStoredWith128Bits(_value) canBeStoredWith128Bits(_month) internal returns (uint depositId) {
        require( _value > 0 );
        require( _month <= 36 && _month >= 1 );

        depositId = depositCount_;

        uint _unitInterest = registry_.uintOf(BankSettingIds.UINT_BANK_UNIT_INTEREST);

        deposits_[depositId] = Deposit({
            depositor: _depositor,
            value: uint128(_value),
            months: uint128(_month),
            startAt: now,
            unitInterest: _unitInterest,
            claimed: false
        });
        
        depositCount_ += 1;

        playerDeposits_[_depositor].push(depositId);

        playerTotalDeposit_[_depositor] += _value;

        // give the player interest immediately
        uint interest = computeInterest(_value, _month, _unitInterest);
        IMintableERC20(kryptonite_).mint(_depositor, interest);
        
        emit NewDeposit(_depositor, depositId);
    }

    /**
     * @dev compute interst based on deposit amount and deposit time
     * @param _value - Amount of ring  (in deceimal units)
     * @param _month - Length of time from the deposit's beginning to end (in months).
     * @param _unitInterest - Parameter of basic interest for deposited RING.(default value is 1000, returns _unitInterest/ 10**7 for one year)
     */
    function computeInterest(uint _value, uint _month, uint _unitInterest) 
        public canBeStoredWith128Bits(_value) canBeStoredWith128Bits(_month) pure returns (uint) {
        // these two actually mean the multiplier is 1.015
        uint numerator = 67 ** _month;
        uint denominator = 66 ** _month;
        uint quotient;
        uint remainder;

        assembly {
            quotient := div(numerator, denominator)
            remainder := mod(numerator, denominator)
        }
        // depositing X RING for 12 months, interest is about (1 * _unitInterest * X / 10**7) KTON
        // and the multiplier is about 3
        // ((quotient - 1) * 1000 + remainder * 1000 / denominator) is 197 when _month is 12.
        return (_unitInterest * uint128(_value) / 197) * ((quotient - 1) * 1000 + remainder * 1000 / denominator) / (10**7);
    }


    function computePenalty(uint _depositID) public view returns (uint) {
        uint startAt = deposits_[_depositID].startAt;
        uint duration = now - startAt;
        uint depositMonth = duration / MONTH;

        uint penalty = registry_.uintOf(BankSettingIds.UINT_BANK_PENALTY_MULTIPLIER) * 
            (computeInterest(deposits_[_depositID].value, deposits_[_depositID].months, deposits_[_depositID].unitInterest) - computeInterest(deposits_[_depositID].value, depositMonth, deposits_[_depositID].unitInterest));


        return penalty;
    }

    function bytesToUint256(bytes _encodedParam) public pure returns (uint256 a) {
        /* solium-disable-next-line security/no-inline-assembly */
        assembly {
            a := mload(add(_encodedParam, /*BYTES_HEADER_SIZE*/32))
        }
    }

    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    ///  set to 0 in case you want to extract ether.
    function claimTokens(address _token) public onlyOwner {
        if (_token == 0x0) {
            owner.transfer(address(this).balance);
            return;
        }
        ERC20 token = ERC20(_token);
        uint balance = token.balanceOf(address(this));
        token.transfer(owner, balance);

        emit ClaimedTokens(_token, owner, balance);
    }
}
