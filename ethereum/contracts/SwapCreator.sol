// SPDX-License-Identifier: LGPLv3
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Secp256k1} from "./Secp256k1.sol";

// SwapCreator facilitates swapping between Alice, a party that has an EVM
// native currency or a token (ERC-20 or compatible API) that she wants to
// exchange cross-chain for a different currency, and Bob, a party that has the
// other chain's currency and wishes to exchange it for Alice's currency.
contract SwapCreator is Secp256k1 {
    using SafeERC20 for IERC20;

    // Stage represents the swap state. It is PENDING when `newSwap` is called
    // to create and fund the swap. Alice sets Stage to READY, via `setReady`,
    // after verifying that funds are locked on the other chain. Bob cannot
    // claim the swap funds until Alice sets the swap Stage to READY. The Stage
    // is set to COMPLETED when Bob calls `claim` or Alice calls `refund`.
    enum Stage {
        INVALID,
        PENDING,
        READY,
        COMPLETED
    }

    // swaps maps from a swap ID to the swap's current Stage
    mapping(bytes32 => Stage) public swaps;

    // Swap stores the swap parameters, the hash of which forms the swap ID.
    struct Swap {
        // owner is the address of Alice, who initiates the swap by calling
        // `newSwap`. Only the owner is allowed to call `setReady` or `refund`.
        address payable owner;
        // claimer is the address of Bob. Only the claimer can call `claim`.
        address payable claimer;
        // claimCommitment is the Keccak-256 hash of the expected secp256k1
        // public key derived from the secret (private key) that Bob sends when
        // claiming. Alice receives this commitment off-chain.
        bytes32 claimCommitment;
        // refundCommitment is the Keccak-256 hash of the expected secp256k1
        // public key derived from the secret (private key) that Alice sends if
        // refunding.
        bytes32 refundCommitment;
        // timeout1 is the block timestamp before which Alice can call
        // either `setReady` or `refund`.
        uint256 timeout1;
        // timeout2 is the block timestamp from which Bob cannot claim and Alice
        // can refund, until timeout3.
        uint256 timeout2;
        // timeout3 is the block timestamp from which Alice cannot refund, and
        // Bob can claim again.
        uint256 timeout3;
        // asset is address(0) for EVM native currency swaps, or it is the
        // address of the token that Alice is providing.
        address asset;
        // value is the wei or token unit amount that Alice locked in the contract
        uint256 value;
        // nonce is a random value chosen by Alice
        uint256 nonce;
    }

    // New carries the whole Swap, which callers must pass back
    event New(bytes32 swapID, Swap swap);
    event Ready(bytes32 indexed swapID);
    event Claimed(bytes32 indexed swapID, bytes32 indexed s);
    event Refunded(bytes32 indexed swapID, bytes32 indexed s);

    // thrown when the value parameter to `newSwap` is zero
    error ZeroValue();

    // thrown when either of the claimCommitment or refundCommitment parameters
    // passed to `newSwap` are zero
    error InvalidSwapKey();

    // thrown when the claimer parameter for `newSwap` is the zero address
    error InvalidClaimer();

    // thrown when a timeout duration parameter for `newSwap` is zero
    error InvalidTimeout();

    // thrown when msg.value of a `newSwap` transaction has the wrong value
    error InvalidValue();

    // thrown when trying to initiate a swap with an ID that already exists
    error SwapAlreadyExists();

    // thrown when trying to call `setReady` on a swap that is not in the
    // PENDING stage
    error SwapNotPending();

    // thrown when the caller of `setReady` or `refund` is not the swap owner
    error OnlySwapOwner();

    // thrown when the caller of `claim` is not the swap's claimer
    error OnlySwapClaimer();

    // thrown when trying to call `claim` or `refund` on an invalid swap
    error InvalidSwap();

    // thrown when trying to call `claim` or `refund` on a swap that's already
    // completed
    error SwapCompleted();

    // thrown when trying to call `claim` on a swap that's not set to ready or
    // the first timeout has not been reached
    error TooEarlyToClaim();

    // thrown when trying to call `claim` on a swap between the second and
    // third timeouts, when only Alice can refund
    error TooLateToClaim();

    // thrown when it's the counterparty's turn to claim and refunding is not
    // allowed, or timeout3 has been reached
    error NotTimeToRefund();

    // thrown when the provided secret does not match its expected public key
    // hash
    error InvalidSecret();

    // thrown when sending the EVM's native currency to a recipient fails
    error PayoutFailed();

    // `newSwap` creates a new Swap instance using the passed parameters and
    // locks Alice's native EVM currency or token asset in the contract. On
    // success, the swap ID is returned.
    //
    // Note that the duration values are distinct from the timeout values:
    //
    //   _timeoutDuration1:
    //      duration, in seconds, between the current block timestamp and
    //      timeout1
    //
    //   _timeoutDuration2:
    //      duration, in seconds, between timeout1 and timeout2
    //
    //   _timeoutDuration3:
    //      duration, in seconds, between timeout2 and timeout3
    //
    function newSwap(
        bytes32 _claimCommitment,
        bytes32 _refundCommitment,
        address payable _claimer,
        uint256 _timeoutDuration1,
        uint256 _timeoutDuration2,
        uint256 _timeoutDuration3,
        address _asset,
        uint256 _value,
        uint256 _nonce
    ) public payable returns (bytes32) {
        if (_value == 0) revert ZeroValue();
        if (_asset == address(0)) {
            if (_value != msg.value) revert InvalidValue();
        } else {
            // transfer the token amount to this contract
            // WARN: fee-on-transfer tokens are not supported
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), _value);
        }

        if (_claimCommitment == 0 || _refundCommitment == 0) revert InvalidSwapKey();
        if (_claimer == address(0)) revert InvalidClaimer();
        if (_timeoutDuration1 == 0 || _timeoutDuration2 == 0 || _timeoutDuration3 == 0)
            revert InvalidTimeout();

        Swap memory swap = Swap({
            owner: payable(msg.sender),
            claimCommitment: _claimCommitment,
            refundCommitment: _refundCommitment,
            claimer: _claimer,
            timeout1: block.timestamp + _timeoutDuration1,
            timeout2: block.timestamp + _timeoutDuration1 + _timeoutDuration2,
            timeout3: block.timestamp + _timeoutDuration1 + _timeoutDuration2 + _timeoutDuration3,
            asset: _asset,
            value: _value,
            nonce: _nonce
        });

        bytes32 swapID = keccak256(abi.encode(swap));

        // ensure that we are not overriding an existing swap
        if (swaps[swapID] != Stage.INVALID) revert SwapAlreadyExists();

        emit New(swapID, swap);
        swaps[swapID] = Stage.PENDING;
        return swapID;
    }

    // Alice should call `setReady` before timeout1 and after verifying that Bob
    // locked his swap funds.
    function setReady(Swap memory _swap) public {
        bytes32 swapID = keccak256(abi.encode(_swap));
        if (swaps[swapID] != Stage.PENDING) revert SwapNotPending();
        if (_swap.owner != msg.sender) revert OnlySwapOwner();
        swaps[swapID] = Stage.READY;
        emit Ready(swapID);
    }

    // Bob can call `claim` if any of these hold true:
    // (1) Alice has set the swap to `ready` and it's before timeout1
    // (2) It is between timeout1 and timeout2
    // (3) It is after timeout3, so Alice never refunded. Bob is paid and his
    //     secret lets Alice take the funds he locked on the other chain.
    function claim(Swap memory _swap, bytes32 _secret) public {
        if (msg.sender != _swap.claimer) revert OnlySwapClaimer();
        _claim(_swap, _secret);

        if (_swap.asset == address(0)) {
            // Transfer the swap value as the EVM's native currency
            sendNative(_swap.claimer, _swap.value);
        } else {
            // Transfer the swap value as a token amount.
            // WARNING: this will FAIL for fee-on-transfer or rebasing tokens if
            // the token transfer reverts (i.e. if this contract does not
            // contain _swap.value tokens), exposing Bob's secret while giving
            // him nothing.
            IERC20(_swap.asset).safeTransfer(_swap.claimer, _swap.value);
        }
    }

    function _claim(Swap memory _swap, bytes32 _secret) internal {
        bytes32 swapID = keccak256(abi.encode(_swap));
        Stage swapStage = swaps[swapID];
        if (swapStage == Stage.INVALID) revert InvalidSwap();
        if (swapStage == Stage.COMPLETED) revert SwapCompleted();
        if (block.timestamp < _swap.timeout1 && swapStage != Stage.READY) revert TooEarlyToClaim();
        if (block.timestamp >= _swap.timeout2 && block.timestamp < _swap.timeout3)
            revert TooLateToClaim();

        verifySecret(_secret, _swap.claimCommitment);
        emit Claimed(swapID, _secret);
        swaps[swapID] = Stage.COMPLETED;
    }

    // Alice can `refund` her swap funds:
    // - Before timeout1, unless she called `setReady`
    // - From timeout2 until timeout3, independent of whether she called `setReady`
    function refund(Swap memory _swap, bytes32 _secret) public {
        bytes32 swapID = keccak256(abi.encode(_swap));
        Stage swapStage = swaps[swapID];
        if (swapStage == Stage.INVALID) revert InvalidSwap();
        if (swapStage == Stage.COMPLETED) revert SwapCompleted();
        if (_swap.owner != msg.sender) revert OnlySwapOwner();
        if (
            block.timestamp < _swap.timeout2 &&
            (block.timestamp >= _swap.timeout1 || swapStage == Stage.READY)
        ) revert NotTimeToRefund();
        if (block.timestamp >= _swap.timeout3) revert NotTimeToRefund();

        verifySecret(_secret, _swap.refundCommitment);
        emit Refunded(swapID, _secret);

        // send asset back to swap owner
        swaps[swapID] = Stage.COMPLETED;
        if (_swap.asset == address(0)) {
            sendNative(_swap.owner, _swap.value);
        } else {
            IERC20(_swap.asset).safeTransfer(_swap.owner, _swap.value);
        }
    }

    // `transfer` forwards a 2300 gas stipend, which fails for recipients with
    // code: contract wallets, or EOAs delegated under EIP-7702. The stage is
    // already COMPLETED, so reentering can't pay out twice.
    function sendNative(address payable _to, uint256 _value) internal {
        (bool ok, ) = _to.call{value: _value}("");
        if (!ok) revert PayoutFailed();
    }

    function verifySecret(bytes32 _secret, bytes32 _hashedPubkey) internal pure {
        if (!mulVerify(uint256(_secret), uint256(_hashedPubkey))) revert InvalidSecret();
    }
}
