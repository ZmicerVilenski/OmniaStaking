// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./ABDKMath64x64.sol";

/**
 * @title Omnia staking contract
 * This is a test task.
 * The set of events is not optimized; getters and setters are not optimized; detailed comments are not made; there are no full unit tests.
 * Algorithms works for a stake for a maximum of a year.
 */
contract OmniaStaking is AccessControl, ReentrancyGuard {
    uint256 public constant DAY = 1 days;
    uint256 public constant MONTH = 30 days;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public penRate; // Daily penality rate. There is no need to reduce the bit depth for a single value that is often read (used in calculations), but written few times (in proj life).

    // Staker contains info related to each staker.
    struct Staker {
        uint256 amount; // amount of tokens currently staked to the contract
        uint128 distributed; //
        uint32 unstakeTime; // time when tokens are available to withdraw
        uint16 stakingPeriod; // in days
        uint16 rps;
        uint8 slaID;
        uint8 networkID;
        uint8 penalityDays;
    } // storage optimization by using only 2 mem slots
    address public stakingToken;
    address public rewardToken;
    mapping(address => Staker) private stakers;
    mapping(uint256 => mapping(uint256 => uint256)) private interstRates; // storage optimization. for a live project, it is possible to use a structure. Depends on project details

    event tokensStaked(
        address indexed sender,
        uint256 amount,
        uint32 unstakeTime,
        uint16 stakingPeiodDays,
        uint16 rps,
        uint8 slaID,
        uint8 networkID
    );
    event rewardClaimed(uint256 amount, uint256 time, address indexed sender);
    event tokensUnstaked(uint256 amount, uint256 time, address indexed sender);
    event intrestRatesChanged(uint256 time, address indexed sender);

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        penRate = 137; // daily penalty rate. Multiplied by 10**5 (0.0137 % = 137)
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        // Transfer selector `bytes4(keccak256(bytes('transfer(address,uint256)')))` should be equal to 0xa9059cbb
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TRANSFER_FAILED"
        );
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // transferFrom selector `bytes4(keccak256(bytes('transferFrom(address,address,uint256)')))` should be equal to 0x23b872dd
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TRANSFER_FROM_FAILED"
        );
    }

    /**
     * @notice Multiplied by 10**5 (0.0137 % = 137)
     */
    function setPenRate(uint256 _penRate) external onlyAdmin {
        penRate = _penRate;
    }

    /**
     * @notice Rates multiplied by 10**2 (14.27% = 1427)
     */
    function setIntrestRates(uint256[][] calldata _irArray) external onlyAdmin {
        for (uint256 slaID = 0; slaID < _irArray.length; slaID++) {
            uint256[] memory networksArray = _irArray[slaID];
            for (uint256 netID = 0; netID < networksArray.length; netID++) {
                interstRates[slaID][netID] = networksArray[netID];
            }
        }
        emit intrestRatesChanged(block.timestamp, msg.sender);
    }

    function changeSLAparams(
        address _staker,
        uint16 _rps,
        uint8 _slaID,
        uint8 _networkID
    ) external onlyAdmin {
        stakers[_staker].rps = _rps;
        stakers[_staker].slaID = _slaID;
        stakers[_staker].networkID = _networkID;
    }

    function setPenalityDays(address _staker, uint8 _penalityDays)
        external
        onlyAdmin
    {
        stakers[_staker].penalityDays = _penalityDays;
    }

    /**
     * @notice Rates multiplied by 10**2 (14.27% = 1427)
     */
    function getIntrestRates(uint256 _slaID, uint256 _networkID)
        external
        view
        returns (uint256)
    {
        return interstRates[_slaID][_networkID];
    }

    /**
     * @dev stake
     *
     * Parameters:
     *
     * - `_amount` - stake amount
     */
    function stake(
        uint256 _amount,
        uint16 _stakingPeiodDays,
        uint8 _slaID,
        uint8 _networkID,
        uint16 _rps
    ) public {
        require(_amount > 0, "Incorrect amount");
        require(_stakingPeiodDays >= 30, "Min staking period is 30 days"); // 30 days to simplify

        Staker storage staker = stakers[msg.sender];
        if (staker.amount == 0) {
            staker.amount = _amount;
            staker.stakingPeriod = _stakingPeiodDays;
            staker.unstakeTime =
                SafeCast.toUint32(block.timestamp) +
                (SafeCast.toUint32(_stakingPeiodDays) * 86400);
            staker.slaID = _slaID;
            staker.networkID = _networkID;
            staker.rps = _rps;
        } else {
            staker.amount = staker.amount + _amount; // if user add staking amount than changing only amount not other parameters
        }

        _safeTransferFrom(stakingToken, msg.sender, address(this), _amount);
        emit tokensStaked(
            msg.sender,
            _amount,
            staker.unstakeTime,
            _stakingPeiodDays,
            _rps,
            _slaID,
            _networkID
        );
    }

    function unstake() public nonReentrant {
        Staker memory staker = stakers[msg.sender];
        require(block.timestamp > staker.unstakeTime, "Unstake is locked");
        // rewards
        uint256 reward = calcReward(msg.sender, staker.amount);
        reward -= staker.distributed;
        if (reward > 0) {
            _safeTransfer(rewardToken, msg.sender, reward); // To simplify, transfer of the reward token from the balance of the contract.The contract must have these tokens on the balance.
        }
        //
        _safeTransfer(stakingToken, msg.sender, staker.amount);
        staker.amount = 0;
        emit tokensUnstaked(staker.amount, block.timestamp, msg.sender);
    }

    event test(uint256 reward, uint256 monthLeft, uint256 distributed);

    /**
     * @dev claim available rewards
     */
    function claimReward() public nonReentrant returns (bool) {
        Staker storage staker = stakers[msg.sender];
        require(staker.amount > 0, "Caller not a staker");
        require(
            block.timestamp >
                (staker.unstakeTime - (staker.stakingPeriod * DAY)),
            "Incorrect staking period"
        );
        uint256 monthLeft;
        if (block.timestamp > staker.unstakeTime) {
            monthLeft = 12;
        } else {
            monthLeft =
                (block.timestamp -
                    (staker.unstakeTime - (staker.stakingPeriod * DAY))) /
                MONTH;
        }
        uint256 reward = calcReward(msg.sender, staker.amount);
        reward = (reward / (staker.stakingPeriod / 30)) * monthLeft;
        require(reward > uint256(staker.distributed), "Nothing to claim");
        reward -= uint256(staker.distributed);
        staker.distributed += SafeCast.toUint128(reward);

        emit test(reward, monthLeft, staker.distributed);

        _safeTransfer(rewardToken, msg.sender, reward); // To simplify, transfer of the reward token from the balance of the contract.The contract must have these tokens on the balance.
        emit rewardClaimed(reward, block.timestamp, msg.sender);
        return true;
    }

    function checkReward() public view returns (uint256) {
        return calcReward(msg.sender, stakers[msg.sender].amount);
    }

    /**
     * @dev calcReward - calculates available reward
     */
    function calcReward(address _staker, uint256 _amount)
        private
        view
        returns (uint256 reward)
    {
        Staker memory staker = stakers[_staker];
        uint256 apr = interstRates[staker.slaID][staker.networkID];
        uint256 daysNum = staker.stakingPeriod;
        uint256 penDays = staker.penalityDays;
        uint256 rps = staker.rps;
        reward = compound(_amount, apr, daysNum, penDays, rps, 4);
    }

    function compound(
        uint256 _amount, // Initial staked amount
        uint256 _apr, // intrest rate (APR)
        uint256 _term, // days
        uint256 _penDays, // Num of penality days
        uint256 _rps, // RPS is a measurement of the node's performance.
        uint256 _pf // percent fraction
    ) public view returns (uint256) {
        // rpsFactor = 0.5 * log10( RPS * 0.1)
        int128 rpsFactor = ABDKMath64x64.div(
            ABDKMath64x64.ln(ABDKMath64x64.divu(_rps, 100)),
            ABDKMath64x64.fromUInt(2)
        );
        rpsFactor = ABDKMath64x64.fromUInt(1); // tempr = 1 cos current formula has problem !!! APY = SLA_MAX_APY * 0.5 * log10(RPS * 0.1)
        return
            ABDKMath64x64.mulu(
                ABDKMath64x64.sub(
                    ABDKMath64x64.mul(calcAPY(_apr, _term, _pf), rpsFactor),
                    ABDKMath64x64.divu(_penDays * penRate, 10**(_pf + 2))
                ),
                _amount
            );
    } // ( APY * rpsFactor - penalty ) * _amount

    function calcAPY(
        uint256 _apr,
        uint256 _term,
        uint256 _pf
    ) internal pure returns (int128) {
        return
            ABDKMath64x64.sub(
                ABDKMath64x64.pow(
                    ABDKMath64x64.add(
                        ABDKMath64x64.fromUInt(1),
                        ABDKMath64x64.divu(_apr, 365 * 10**_pf)
                    ),
                    _term
                ),
                ABDKMath64x64.fromUInt(1)
            );
    } // ( ( 1+( _intrestRate/365 ) )^_term ) - 1

    // function compoundWithoutPenalties(
    //     uint256 _amount, // Initial staked amount
    //     uint256 _apr, // intrest rate (not APY, but APR)
    //     uint256 _term, // days
    //     uint256 _penDays, // Num of penality days
    //     uint256 _pf // percent fraction
    // ) public view returns (uint256) {
    //     return
    //         ABDKMath64x64.mulu(
    //             ABDKMath64x64.sub(
    //                 ABDKMath64x64.pow(
    //                     ABDKMath64x64.add(
    //                         ABDKMath64x64.fromUInt(1),
    //                         ABDKMath64x64.divu(_apr, 365 * 10**_pf)
    //                     ),
    //                     _term
    //                 ),
    //                 ABDKMath64x64.fromUInt(1)
    //             ),
    //             _amount
    //         );
    // } // ( ( ( 1+( _intrestRate/365 ) )^_term )-1 ) * _amount
}
