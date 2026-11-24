// SPDX-License-Identifier: LGPLv3
pragma solidity ^0.8.28;

import {Payout, IPayoutTo} from "./Payout.sol";
import {Secp256k1} from "./Secp256k1.sol";

// SwapFactory runs SwapCreator's swap without holding funds. Each swap's coins
// sit at their own address, `swapAddress(swap)`, which `lock` forwards them to.
// Claim or refund deploys Payout there, which pays the winner. A freeze of one
// swap's address leaves every other swap alone.
contract SwapFactory is Secp256k1, IPayoutTo {
    struct Swap {
        address payable owner;
        address payable claimer;
        bytes32 claimCommitment;
        bytes32 refundCommitment;
        // Absolute block timestamps, fixed before the lock is signed
        uint256 timeout1;
        uint256 timeout2;
        uint256 timeout3;
        uint256 value;
        // Chosen by the owner when locking, after the claimer's fields are
        // fixed, so the claimer can't grind the address
        uint256 nonce;
    }

    bytes32 public immutable PAYOUT_INIT_CODE_HASH = keccak256(type(Payout).creationCode);

    enum Stage {
        NONE,
        LOCKED,
        READY,
        COMPLETED
    }

    mapping(bytes32 => Stage) public stage;

    // The secret `claim` or `refund` revealed, readable without searching logs
    mapping(bytes32 => bytes32) public secrets;

    address payable private transient _payoutTo;

    event Locked(bytes32 indexed swapID);
    event Ready(bytes32 indexed swapID);
    event Claimed(bytes32 indexed swapID, bytes32 indexed s);
    event Refunded(bytes32 indexed swapID, bytes32 indexed s);

    error SwapNotPending();
    error OnlySwapOwner();
    error OnlySwapClaimer();
    error SwapCompleted();
    error LockTooLate();
    error WrongValue();
    error LockFailed();
    error TooEarlyToClaim();
    error TooLateToClaim();
    error NotTimeToRefund();
    error InvalidSecret();

    function swapID(Swap memory _swap) public pure returns (bytes32) {
        return keccak256(abi.encode(_swap));
    }

    function swapAddress(Swap memory _swap) public view returns (address) {
        return addressOf(swapID(_swap));
    }

    function addressOf(bytes32 _id) internal view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), address(this), _id, PAYOUT_INIT_CODE_HASH)
                        )
                    )
                )
            );
    }

    function payoutTo() external view returns (address payable) {
        return _payoutTo;
    }

    // A lock mined late would open the claim window at once, so it reverts
    // past the owner's deadline, which must fall before timeout1
    function lock(Swap memory _swap, uint256 _deadline) external payable {
        if (_swap.owner != msg.sender) revert OnlySwapOwner();
        if (block.timestamp > _deadline || _deadline >= _swap.timeout1) revert LockTooLate();
        if (msg.value == 0 || msg.value != _swap.value) revert WrongValue();
        bytes32 id = swapID(_swap);
        if (stage[id] != Stage.NONE) revert SwapNotPending();
        stage[id] = Stage.LOCKED;
        emit Locked(id);
        (bool ok, ) = addressOf(id).call{value: msg.value}("");
        if (!ok) revert LockFailed();
    }

    function setReady(Swap memory _swap) public {
        if (_swap.owner != msg.sender) revert OnlySwapOwner();
        bytes32 id = swapID(_swap);
        if (stage[id] != Stage.LOCKED) revert SwapNotPending();
        stage[id] = Stage.READY;
        emit Ready(id);
    }

    // As SwapCreator: before timeout1 once ready, from timeout1 until
    // timeout2, and from timeout3
    function claim(Swap memory _swap, bytes32 _secret) public {
        if (msg.sender != _swap.claimer) revert OnlySwapClaimer();
        bytes32 id = swapID(_swap);
        Stage st = stage[id];
        if (st == Stage.NONE) revert SwapNotPending();
        if (st == Stage.COMPLETED) revert SwapCompleted();
        if (block.timestamp < _swap.timeout1 && st != Stage.READY) revert TooEarlyToClaim();
        if (block.timestamp >= _swap.timeout2 && block.timestamp < _swap.timeout3)
            revert TooLateToClaim();
        verifySecret(_secret, _swap.claimCommitment);
        emit Claimed(id, _secret);
        secrets[id] = _secret;
        payout(id, _swap.claimer);
    }

    // As SwapCreator: before timeout1 unless ready, and from timeout2 until
    // timeout3
    function refund(Swap memory _swap, bytes32 _secret) public {
        if (_swap.owner != msg.sender) revert OnlySwapOwner();
        bytes32 id = swapID(_swap);
        Stage st = stage[id];
        if (st == Stage.NONE) revert SwapNotPending();
        if (st == Stage.COMPLETED) revert SwapCompleted();
        if (
            block.timestamp < _swap.timeout2 &&
            (block.timestamp >= _swap.timeout1 || st == Stage.READY)
        ) revert NotTimeToRefund();
        if (block.timestamp >= _swap.timeout3) revert NotTimeToRefund();
        verifySecret(_secret, _swap.refundCommitment);
        emit Refunded(id, _secret);
        secrets[id] = _secret;
        payout(id, _swap.owner);
    }

    // COMPLETED reverts a second payout cheaply; CREATE2 into an address with a
    // nonce (paid out) also fails, burning the gas it was given. A reverting
    // Payout bubbles its error.
    function payout(bytes32 _id, address payable _to) internal {
        stage[_id] = Stage.COMPLETED;
        _payoutTo = _to;
        bytes memory code = type(Payout).creationCode;
        bool completed;
        assembly {
            if iszero(create2(0, add(code, 0x20), mload(code), _id)) {
                if returndatasize() {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
                completed := 1
            }
        }
        if (completed) revert SwapCompleted();
    }

    function verifySecret(bytes32 _secret, bytes32 _hashedPubkey) internal pure {
        if (!mulVerify(uint256(_secret), uint256(_hashedPubkey))) revert InvalidSecret();
    }
}
