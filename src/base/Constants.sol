// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0;
pragma abicoder v2;

uint256 constant WAD = 1e18;
uint256 constant Q96 = 0x1000000000000000000000000;
uint256 constant MAX_NONCE = 1e6;
uint256 constant MIN_INITIAL_SHARES = 1e12;
uint256 constant MAX_SWAP_FEE_RATIO = 2.88e20; // max ratio that avoids overflow in swap fee calculation, roughly sqrt(SWAP_FEE_BASE) * sqrt(sqrt((type(uint256).max - SWAP_FEE_BASE) / type(uint24).max) - 1)
uint256 constant SWAP_FEE_BASE = 1e6;
uint256 constant SWAP_FEE_BASE_SQUARED = 1e12;
uint256 constant RAW_TOKEN_RATIO_BASE = 1e6;
uint256 constant LN2_WAD = 693147180559945309;
uint256 constant MAX_VAULT_FEE_ERROR = 1e6;
uint256 constant MAX_CARDINALITY = 2 ** 24 - 1;
uint56 constant WITHDRAW_DELAY = 1 minutes;
uint56 constant WITHDRAW_GRACE_PERIOD = 3 minutes;
uint256 constant MODIFIER_BASE = 1e6;
uint256 constant MIN_DEPOSIT_BALANCE_INCREASE = 1e6;
uint24 constant MAX_AMAMM_FEE = 0.1e6;
uint256 constant REBALANCE_MAX_SLIPPAGE_BASE = 1e5;
uint16 constant MAX_SURGE_HALFLIFE = 1 hours;
uint16 constant MAX_SURGE_AUTOSTART_TIME = 1 hours;
uint16 constant MAX_REBALANCE_MAX_SLIPPAGE = 0.25e5; // max value for rebalanceMaxSlippage is 25%
uint16 constant MAX_REBALANCE_TWAP_SECONDS_AGO = 3 hours;
uint16 constant MAX_REBALANCE_ORDER_TTL = 1 hours;
uint256 constant CURATOR_FEE_BASE = 1e5;
