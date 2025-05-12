// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.15;

import {Clone} from "clones-with-immutable-args/Clone.sol";

import {LibMulticaller} from "multicaller/LibMulticaller.sol";

import "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import "./base/Errors.sol";
import "./base/Constants.sol";
import {ERC20} from "./base/ERC20.sol";
import {Ownable} from "./base/Ownable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {HookletLib} from "./lib/HookletLib.sol";
import {IHooklet} from "./interfaces/IHooklet.sol";
import {IBunniHub} from "./interfaces/IBunniHub.sol";
import {IBunniToken} from "./interfaces/IBunniToken.sol";
import {ERC20Referrer} from "./base/ERC20Referrer.sol";

/// @title BunniToken
/// @author zefram.eth
/// @notice ERC20 token that represents a user's LP position
contract BunniToken is IBunniToken, ERC20Referrer, Clone, Ownable {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for *;
    using HookletLib for IHooklet;
    using SafeTransferLib for address;
    using CurrencyLibrary for Currency;

    /// -----------------------------------------------------------------------
    /// Storage
    /// -----------------------------------------------------------------------

    string public metadataURI;

    /// @notice The latest referrer reward per token0
    uint256 public referrerRewardPerToken0;

    /// @notice The referrer reward per token0 paid
    mapping(address referrer => uint256) public referrerRewardPerTokenPaid0;

    /// @notice The referrer reward in token0 unclaimed
    mapping(address referrer => uint256) public referrerRewardUnclaimed0;

    /// @notice The referrer reward per token1 stored
    uint256 public referrerRewardPerToken1;

    /// @notice The referrer reward per token1 paid
    mapping(address referrer => uint256) public referrerRewardPerTokenPaid1;

    /// @notice The referrer reward in token1 unclaimed
    mapping(address referrer => uint256) public referrerRewardUnclaimed1;

    /// -----------------------------------------------------------------------
    /// Immutable params
    /// -----------------------------------------------------------------------
    /// Packed data layout:
    /// [0:20] address hub
    /// [20:40] address token0
    /// [40:60] address token1
    /// [60:92] bytes32 name
    /// [92:124] bytes32 symbol
    /// [124:144] address poolManager
    /// [144:147] uint24 fee
    /// [147:150] int24 tickSpacing
    /// [150:170] address hooks
    /// [170:190] address hooklet
    /// -----------------------------------------------------------------------

    function hub() public pure override returns (IBunniHub) {
        return IBunniHub(_getArgAddress(0));
    }

    function token0() public pure override returns (Currency) {
        return Currency.wrap(_getArgAddress(20));
    }

    function token1() public pure override returns (Currency) {
        return Currency.wrap(_getArgAddress(40));
    }

    function name() public pure override(ERC20, IERC20) returns (string memory) {
        return string(abi.encodePacked(_getArgUint256(60)));
    }

    function symbol() public pure override(ERC20, IERC20) returns (string memory) {
        return string(abi.encodePacked(_getArgUint256(92)));
    }

    function poolManager() public pure override returns (IPoolManager) {
        return IPoolManager(_getArgAddress(124));
    }

    function poolKey() public pure override returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(_getArgAddress(20)),
            currency1: Currency.wrap(_getArgAddress(40)),
            fee: _getArgUint24(144),
            tickSpacing: int24(_getArgUint24(147)),
            hooks: IHooks(_getArgAddress(150))
        });
    }

    function hooklet() public pure override returns (IHooklet) {
        return IHooklet(_getArgAddress(170));
    }

    /// -----------------------------------------------------------------------
    /// Initialization
    /// -----------------------------------------------------------------------

    function initialize(address owner_, string calldata metadataURI_) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();
        _initializeOwner(owner_);
        metadataURI = metadataURI_;
        emit SetMetadataURI(metadataURI_);
    }

    /// -----------------------------------------------------------------------
    /// Minting & burning
    /// -----------------------------------------------------------------------

    function mint(address to, uint256 amount) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();

        _mint(to, amount);
    }

    function mint(address to, uint256 amount, address referrer) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();

        _mint(to, amount, referrer);
    }

    function burn(address from, uint256 amount) external override {
        if (msg.sender != address(hub())) revert BunniToken__NotBunniHub();

        _burn(from, amount);
    }

    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /// -----------------------------------------------------------------------
    /// Metadata
    /// -----------------------------------------------------------------------

    function setMetadataURI(string calldata metadataURI_) external override onlyOwner {
        metadataURI = metadataURI_;
        emit SetMetadataURI(metadataURI_);
    }

    /// -----------------------------------------------------------------------
    /// Referral
    /// -----------------------------------------------------------------------

    /// @inheritdoc IBunniToken
    function distributeReferralRewards(bool isToken0, uint256 amount) external override {
        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        Currency token;
        if (isToken0) {
            token = token0();
            referrerRewardPerToken0 += amount.fullMulDiv(REFERRAL_REWARD_PER_TOKEN_PRECISION, totalSupply());
        } else {
            token = token1();
            referrerRewardPerToken1 += amount.fullMulDiv(REFERRAL_REWARD_PER_TOKEN_PRECISION, totalSupply());
        }

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // pull PoolManager claims tokens from msg.sender
        poolManager().transferFrom(msg.sender, address(this), token.toId(), amount);
    }

    /// @inheritdoc IBunniToken
    function claimReferralRewards(address referrer) external override returns (uint256 reward0, uint256 reward1) {
        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 rewardPerToken0 = referrerRewardPerToken0;
        uint256 rewardPerToken1 = referrerRewardPerToken1;
        uint256 referrerScore = scoreOf(referrer);

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // compute unclaimed reward 0
        reward0 = _updatedUnclaimedReward(
            referrerScore, rewardPerToken0, referrerRewardPerTokenPaid0[referrer], referrerRewardUnclaimed0[referrer]
        );
        referrerRewardPerTokenPaid0[referrer] = rewardPerToken0;
        delete referrerRewardUnclaimed0[referrer];

        // compute unclaimed reward 1
        reward1 = _updatedUnclaimedReward(
            referrerScore, rewardPerToken1, referrerRewardPerTokenPaid1[referrer], referrerRewardUnclaimed1[referrer]
        );
        referrerRewardPerTokenPaid1[referrer] = rewardPerToken1;
        delete referrerRewardUnclaimed1[referrer];

        /// -----------------------------------------------------------------------
        /// External calls
        /// -----------------------------------------------------------------------

        // call PoolManager to convert claim tokens into underlying tokens
        address recipient = referrer == address(0) ? hub().getReferralRewardRecipient() : referrer;
        poolManager().unlock(abi.encode(recipient, reward0, reward1));

        // emit event
        emit ClaimReferralRewards(referrer, reward0, reward1);
    }

    /// @inheritdoc IBunniToken
    function getClaimableReferralRewards(address referrer)
        external
        view
        override
        returns (uint256 reward0, uint256 reward1)
    {
        reward0 = _updatedUnclaimedReward(
            scoreOf(referrer),
            referrerRewardPerToken0,
            referrerRewardPerTokenPaid0[referrer],
            referrerRewardUnclaimed0[referrer]
        );
        reward1 = _updatedUnclaimedReward(
            scoreOf(referrer),
            referrerRewardPerToken1,
            referrerRewardPerTokenPaid1[referrer],
            referrerRewardUnclaimed1[referrer]
        );
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // verify sender
        IPoolManager manager = poolManager();
        if (msg.sender != address(manager)) revert BunniToken__NotPoolManager();

        // decode input
        (address recipient, uint256 reward0, uint256 reward1) = abi.decode(data, (address, uint256, uint256));

        // burn claim tokens and take underlying tokens for referrer
        if (reward0 != 0) {
            Currency token = token0();
            manager.burn(address(this), token.toId(), reward0);
            manager.take(token, recipient, reward0);
        }
        if (reward1 != 0) {
            Currency token = token1();
            manager.burn(address(this), token.toId(), reward1);
            manager.take(token, recipient, reward1);
        }

        // fallback
        return bytes("");
    }

    /// @dev Should accrue rewards for the referrers of `from` and `to` in both token0 and token1
    /// If we're minting tokens to an account to referrer == 0 with a non-zero referrer, we need to accrue rewards
    /// to the new referrer before minting to avoid double counting the account's balance for the new referrer.
    function _beforeTokenTransfer(address from, address to, uint256 amount, address newReferrer) internal override {
        uint256 rewardPerToken0 = referrerRewardPerToken0;
        uint256 rewardPerToken1 = referrerRewardPerToken1;

        address fromReferrer = from == address(0) ? address(0) : referrerOf(from);
        uint256 fromReferrerScore = scoreOf(fromReferrer);

        // accrue token0 rewards
        referrerRewardUnclaimed0[fromReferrer] = _updatedUnclaimedReward(
            fromReferrerScore,
            rewardPerToken0,
            referrerRewardPerTokenPaid0[fromReferrer],
            referrerRewardUnclaimed0[fromReferrer]
        );
        referrerRewardPerTokenPaid0[fromReferrer] = rewardPerToken0;

        // accrue token1 rewards
        referrerRewardUnclaimed1[fromReferrer] = _updatedUnclaimedReward(
            fromReferrerScore,
            rewardPerToken1,
            referrerRewardPerTokenPaid1[fromReferrer],
            referrerRewardUnclaimed1[fromReferrer]
        );
        referrerRewardPerTokenPaid1[fromReferrer] = rewardPerToken1;

        address toReferrer = to == address(0) ? address(0) : referrerOf(to);

        // no need to accrue rewards again if from and to have the same referrer
        if (fromReferrer != toReferrer) {
            uint256 toReferrerScore = scoreOf(toReferrer);

            // accrue token0 rewards
            referrerRewardUnclaimed0[toReferrer] = _updatedUnclaimedReward(
                toReferrerScore,
                rewardPerToken0,
                referrerRewardPerTokenPaid0[toReferrer],
                referrerRewardUnclaimed0[toReferrer]
            );
            referrerRewardPerTokenPaid0[toReferrer] = rewardPerToken0;

            // accrue token1 rewards
            referrerRewardUnclaimed1[toReferrer] = _updatedUnclaimedReward(
                toReferrerScore,
                rewardPerToken1,
                referrerRewardPerTokenPaid1[toReferrer],
                referrerRewardUnclaimed1[toReferrer]
            );
            referrerRewardPerTokenPaid1[toReferrer] = rewardPerToken1;
        }

        // should accrue rewards to new referrer if the referrer of `to` will be updated
        // referrer is immutable after set so the only time this can happen is when `toReferrer == 0`
        // and `newReferrer != 0`
        // also should not accrue rewards if `newReferrer == fromReferrer` since we already accrued rewards for `fromReferrer`
        if (toReferrer == address(0) && newReferrer != address(0) && newReferrer != fromReferrer) {
            uint256 newReferrerScore = scoreOf(newReferrer);

            // accrue token0 rewards to new referrer
            referrerRewardUnclaimed0[newReferrer] = _updatedUnclaimedReward(
                newReferrerScore,
                rewardPerToken0,
                referrerRewardPerTokenPaid0[newReferrer],
                referrerRewardUnclaimed0[newReferrer]
            );
            referrerRewardPerTokenPaid0[newReferrer] = rewardPerToken0;

            // accrue token1 rewards to new referrer
            referrerRewardUnclaimed1[newReferrer] = _updatedUnclaimedReward(
                newReferrerScore,
                rewardPerToken1,
                referrerRewardPerTokenPaid1[newReferrer],
                referrerRewardUnclaimed1[newReferrer]
            );
            referrerRewardPerTokenPaid1[newReferrer] = rewardPerToken1;
        }

        // call hooklet
        // occurs after the referral reward accrual to prevent the hooklet from
        // messing up the accounting
        IHooklet hooklet_ = hooklet();
        if (hooklet_.hasPermission(HookletLib.BEFORE_TRANSFER_FLAG)) {
            address msgSender = LibMulticaller.senderOrSigner();
            hooklet_.hookletBeforeTransfer(msgSender, poolKey(), this, from, to, amount);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // call hooklet
        IHooklet hooklet_ = hooklet();
        if (hooklet_.hasPermission(HookletLib.AFTER_TRANSFER_FLAG)) {
            address msgSender = LibMulticaller.senderOrSigner();
            hooklet_.hookletAfterTransfer(msgSender, poolKey(), this, from, to, amount);
        }
    }

    /// -----------------------------------------------------------------------
    /// EIP-2612
    /// -----------------------------------------------------------------------

    function incrementNonce() external override {
        address msgSender = LibMulticaller.senderOrSigner();
        _incrementNonce(msgSender);
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    /// @dev Compute the updated unclaimed reward of a referrer
    function _updatedUnclaimedReward(
        uint256 referrerScore,
        uint256 rewardPerToken,
        uint256 rewardPerTokenPaid,
        uint256 rewardUnclaimed
    ) internal pure returns (uint256) {
        return referrerScore.fullMulDiv(rewardPerToken - rewardPerTokenPaid, REFERRAL_REWARD_PER_TOKEN_PRECISION)
            + rewardUnclaimed;
    }

    /// @notice Reads an immutable arg with type uint24
    /// @param argOffset The offset of the arg in the packed data
    /// @return arg The arg value
    function _getArgUint24(uint256 argOffset) internal pure returns (uint24 arg) {
        uint256 offset = _getImmutableArgsOffset();
        // solhint-disable-next-line no-inline-assembly
        assembly {
            arg := shr(0xe8, calldataload(add(offset, argOffset)))
        }
    }
}
