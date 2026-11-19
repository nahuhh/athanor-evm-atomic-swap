// SPDX-License-Identifier: LGPLv3
pragma solidity ^0.8.28;

import {SwapFactory} from "../ethereum/contracts/SwapFactory.sol";
import {Payout} from "../ethereum/contracts/Payout.sol";

interface Vm {
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function deal(address who, uint256 amount) external;
    function addr(uint256 key) external pure returns (address);
    function getNonce(address account) external view returns (uint64);
    function store(address target, bytes32 slot, bytes32 value) external;
}

contract ReentrantClaimer {
    SwapFactory internal immutable sf;
    SwapFactory.Swap internal swap;
    bytes32 internal secret;
    bool internal entered;
    bytes4 public innerError;

    constructor(SwapFactory _sf) {
        sf = _sf;
    }

    function claim(SwapFactory.Swap memory _swap, bytes32 _secret) external {
        swap = _swap;
        secret = _secret;
        sf.claim(_swap, _secret);
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try sf.claim(swap, secret) {
            innerError = bytes4(0xffffffff);
        } catch (bytes memory err) {
            innerError = bytes4(err);
        }
    }
}

contract TogglingClaimer {
    SwapFactory internal immutable sf;
    bool public accepting;

    constructor(SwapFactory _sf) {
        sf = _sf;
    }

    function setAccepting(bool _accepting) external {
        accepting = _accepting;
    }

    function claim(SwapFactory.Swap memory _swap, bytes32 _secret) external {
        sf.claim(_swap, _secret);
    }

    receive() external payable {
        require(accepting);
    }
}

contract NestedClaimer {
    SwapFactory internal immutable sf;
    SwapFactory.Swap internal inner;
    bytes32 internal innerSecret;
    bool internal entered;

    constructor(SwapFactory _sf) {
        sf = _sf;
    }

    function claim(
        SwapFactory.Swap memory _outer,
        SwapFactory.Swap memory _inner,
        bytes32 _secret
    ) external {
        inner = _inner;
        innerSecret = _secret;
        sf.claim(_outer, _secret);
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        sf.claim(inner, innerSecret);
    }
}

contract SwapFactoryTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant CLAIM_KEY = 0xC1A1;
    uint256 internal constant REFUND_KEY = 0x2EF0;
    uint256 internal constant D = 1 hours;
    uint256 internal constant VALUE = 1 ether;
    uint256 internal constant START = 1_000_000;

    SwapFactory internal sf;
    address payable internal claimer;
    uint256 internal nonce;
    uint256 internal refundsReceived;

    receive() external payable {
        refundsReceived += msg.value;
    }

    function setUp() public {
        sf = new SwapFactory();
        claimer = payable(vm.addr(CLAIM_KEY));
        vm.deal(address(this), 1000 ether);
        vm.warp(START);
    }

    function commitment(uint256 key) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(vm.addr(key))));
    }

    function swapTerms(address payable to, bytes32 refundCommitment)
        internal
        returns (SwapFactory.Swap memory)
    {
        nonce++;
        return SwapFactory.Swap({
            owner: payable(address(this)),
            claimer: to,
            claimCommitment: commitment(CLAIM_KEY),
            refundCommitment: refundCommitment,
            timeout1: block.timestamp + D,
            timeout2: block.timestamp + 2 * D,
            timeout3: block.timestamp + 3 * D,
            value: VALUE,
            nonce: nonce
        });
    }

    function fund(address to, uint256 value) internal {
        (bool ok, ) = to.call{value: value}("");
        require(ok, "fund");
    }

    function tryLock(SwapFactory.Swap memory s, uint256 deadline, uint256 value)
        internal
        returns (bytes4)
    {
        try sf.lock{value: value}(s, deadline) {
            return 0;
        } catch (bytes memory err) {
            return bytes4(err);
        }
    }

    function newSwap(address payable to, bytes32 refundCommitment)
        internal
        returns (SwapFactory.Swap memory s)
    {
        s = swapTerms(to, refundCommitment);
        expect(tryLock(s, block.timestamp, VALUE), 0, "lock");
    }

    function newSwap() internal returns (SwapFactory.Swap memory) {
        return newSwap(claimer, commitment(REFUND_KEY));
    }

    function tryClaim(SwapFactory.Swap memory s, uint256 secret) internal returns (bytes4) {
        vm.prank(s.claimer);
        try sf.claim(s, bytes32(secret)) {
            return 0;
        } catch (bytes memory err) {
            return bytes4(err);
        }
    }

    function tryRefund(SwapFactory.Swap memory s, uint256 secret) internal returns (bytes4) {
        try sf.refund(s, bytes32(secret)) {
            return 0;
        } catch (bytes memory err) {
            return bytes4(err);
        }
    }

    function expect(bytes4 got, bytes4 want, string memory what) internal pure {
        require(got == want, what);
    }

    function checkCell(bool ready, uint256 offset, bytes4 claimResult, bytes4 refundResult)
        internal
    {
        vm.warp(START);
        SwapFactory.Swap memory s = newSwap();
        if (ready) sf.setReady(s);
        vm.warp(START + offset);
        uint256 before = claimer.balance;
        expect(tryClaim(s, CLAIM_KEY), claimResult, "claim");
        if (claimResult == 0) require(claimer.balance == before + VALUE, "claim paid");

        vm.warp(START);
        s = newSwap();
        if (ready) sf.setReady(s);
        vm.warp(START + offset);
        before = refundsReceived;
        expect(tryRefund(s, REFUND_KEY), refundResult, "refund");
        if (refundResult == 0) require(refundsReceived == before + VALUE, "refund paid");
    }

    function checkWindows(bool ready) internal {
        bytes4 early = ready ? bytes4(0) : SwapFactory.TooEarlyToClaim.selector;
        bytes4 earlyRefund = ready ? SwapFactory.NotTimeToRefund.selector : bytes4(0);
        bytes4 notRefund = SwapFactory.NotTimeToRefund.selector;
        bytes4 late = SwapFactory.TooLateToClaim.selector;

        checkCell(ready, 0, early, earlyRefund);
        checkCell(ready, D - 1, early, earlyRefund);
        checkCell(ready, D, 0, notRefund);
        checkCell(ready, 2 * D - 1, 0, notRefund);
        checkCell(ready, 2 * D, late, 0);
        checkCell(ready, 3 * D - 1, late, 0);
        checkCell(ready, 3 * D, 0, notRefund);
        checkCell(ready, 30 * D, 0, notRefund);
    }

    function testWindowsPending() public {
        checkWindows(false);
    }

    function testWindowsReady() public {
        checkWindows(true);
    }

    function testSwapAddress() public {
        SwapFactory.Swap memory s = newSwap();
        bytes32 initHash = keccak256(type(Payout).creationCode);
        require(sf.PAYOUT_INIT_CODE_HASH() == initHash, "init code hash");
        address want = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(sf), keccak256(abi.encode(s)), initHash
                        )
                    )
                )
            )
        );
        require(sf.swapAddress(s) == want, "address");
        s.nonce++;
        require(sf.swapAddress(s) != want, "nonce in the address");
    }

    function testPayoutLeavesNoCodeAndANonce() public {
        SwapFactory.Swap memory s = newSwap();
        address a = sf.swapAddress(s);
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), 0, "claim");
        require(a.balance == 0, "emptied");
        require(a.code.length == 0, "no code");
        require(vm.getNonce(a) == 1, "nonce");
    }

    function testFactoryHoldsNothing() public {
        SwapFactory.Swap memory s = newSwap();
        require(address(sf).balance == 0, "factory unfunded");
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), 0, "claim");
        require(address(sf).balance == 0, "factory still unfunded");
    }

    function testPaysWholeBalance() public {
        SwapFactory.Swap memory s = newSwap();
        fund(sf.swapAddress(s), VALUE);
        uint256 before = claimer.balance;
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), 0, "claim");
        require(claimer.balance == before + 2 * VALUE, "whole balance");
    }

    function testStrayDepositAfterCompletion() public {
        SwapFactory.Swap memory s = newSwap();
        expect(tryRefund(s, REFUND_KEY), 0, "refund");
        expect(tryRefund(s, REFUND_KEY), SwapFactory.SwapCompleted.selector, "refund emptied");
        fund(sf.swapAddress(s), VALUE);
        try sf.refund{gas: 50000}(s, bytes32(REFUND_KEY)) {
            revert("refunded twice");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.SwapCompleted.selector, "cheap revert");
        }
        expect(tryRefund(s, REFUND_KEY), SwapFactory.SwapCompleted.selector, "refund twice");
        vm.warp(s.timeout3);
        expect(tryClaim(s, CLAIM_KEY), SwapFactory.SwapCompleted.selector, "claim after refund");
        require(sf.swapAddress(s).balance == VALUE, "stray deposit stays");
    }

    function testPaidOutAddressRefusesASecondPayout() public {
        SwapFactory.Swap memory s = newSwap();
        bytes32 id = sf.swapID(s);
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), 0, "claim");
        vm.store(address(sf), keccak256(abi.encode(id, uint256(0))), bytes32(uint256(1)));
        require(sf.stage(id) == SwapFactory.Stage.LOCKED, "stage reset");
        fund(sf.swapAddress(s), VALUE);
        uint256 before = claimer.balance;
        expect(tryClaim(s, CLAIM_KEY), SwapFactory.SwapCompleted.selector, "claim twice");
        require(claimer.balance == before, "paid twice");
        require(sf.swapAddress(s).balance == VALUE, "stray deposit stays");
    }

    function testNeverLockedSwap() public {
        SwapFactory.Swap memory s = swapTerms(claimer, commitment(REFUND_KEY));
        fund(sf.swapAddress(s), 1);
        expect(tryRefund(s, REFUND_KEY), SwapFactory.SwapNotPending.selector, "refund");
        try sf.setReady(s) {
            revert("readied unlocked");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.SwapNotPending.selector, "setReady");
        }
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), SwapFactory.SwapNotPending.selector, "claim dust");
    }

    function testDustBeforeLock() public {
        SwapFactory.Swap memory s = swapTerms(claimer, commitment(REFUND_KEY));
        fund(sf.swapAddress(s), 1);
        expect(tryLock(s, block.timestamp, VALUE), 0, "lock");
        uint256 before = claimer.balance;
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY), 0, "claim");
        require(claimer.balance == before + VALUE + 1, "claimer paid lock and dust");
    }

    function testLockDeadline() public {
        SwapFactory.Swap memory s = swapTerms(claimer, commitment(REFUND_KEY));
        expect(tryLock(s, s.timeout1, VALUE), SwapFactory.LockTooLate.selector, "deadline at t1");
        uint256 deadline = block.timestamp + 60;
        vm.warp(deadline + 1);
        expect(tryLock(s, deadline, VALUE), SwapFactory.LockTooLate.selector, "past deadline");
        vm.warp(s.timeout1 + 10);
        expect(tryLock(s, s.timeout1 - 1, VALUE), SwapFactory.LockTooLate.selector, "after t1");
        vm.warp(deadline);
        expect(tryLock(s, deadline, VALUE), 0, "at deadline");
        require(sf.swapAddress(s).balance == VALUE, "forwarded");
        require(address(sf).balance == 0, "factory unfunded");
    }

    function testLockValue() public {
        SwapFactory.Swap memory s = swapTerms(claimer, commitment(REFUND_KEY));
        expect(tryLock(s, block.timestamp, 0), SwapFactory.WrongValue.selector, "zero");
        expect(tryLock(s, block.timestamp, 1), SwapFactory.WrongValue.selector, "dust");
        expect(tryLock(s, block.timestamp, VALUE + 1), SwapFactory.WrongValue.selector, "more");
        s.value = 0;
        expect(tryLock(s, block.timestamp, 0), SwapFactory.WrongValue.selector, "zero swap");
    }

    function testLockOnce() public {
        SwapFactory.Swap memory s = newSwap();
        expect(tryLock(s, block.timestamp, VALUE), SwapFactory.SwapNotPending.selector, "twice");
        sf.setReady(s);
        expect(tryLock(s, block.timestamp, VALUE), SwapFactory.SwapNotPending.selector, "ready");
    }

    function testOnlyOwnerLocks() public {
        SwapFactory.Swap memory s = swapTerms(claimer, commitment(REFUND_KEY));
        vm.deal(address(0xBAD), VALUE);
        vm.prank(address(0xBAD));
        expect(tryLock(s, block.timestamp, VALUE), SwapFactory.OnlySwapOwner.selector, "stranger");
    }

    function testClaimGasFloor() public {
        uint256 lo = 21000;
        uint256 hi = 300000;
        SwapFactory.Swap memory s = newSwap();
        sf.setReady(s);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            address a = sf.swapAddress(s);
            uint256 before = claimer.balance;
            vm.prank(claimer);
            (bool ok, ) = address(sf).call{gas: mid}(
                abi.encodeCall(SwapFactory.claim, (s, bytes32(CLAIM_KEY)))
            );
            if (ok) {
                require(claimer.balance == before + VALUE, "settled unpaid");
                require(vm.getNonce(a) == 1 && a.balance == 0, "settled, not completed");
                hi = mid;
                s = newSwap();
                sf.setReady(s);
            } else {
                require(claimer.balance == before, "failed claim paid");
                require(vm.getNonce(a) == 0 && a.balance == VALUE, "failed claim moved funds");
                lo = mid;
            }
        }
        require(hi < 300000, "never passed");
    }

    function testNestedPayout() public {
        NestedClaimer wallet = new NestedClaimer(sf);
        SwapFactory.Swap memory outer = newSwap(payable(address(wallet)), commitment(REFUND_KEY));
        SwapFactory.Swap memory inner = swapTerms(payable(address(wallet)), commitment(REFUND_KEY));
        inner.value = 2 * VALUE;
        expect(tryLock(inner, block.timestamp, 2 * VALUE), 0, "lock inner");
        vm.warp(outer.timeout1);
        wallet.claim(outer, inner, bytes32(CLAIM_KEY));
        require(address(wallet).balance == 3 * VALUE, "both paid");
        require(sf.swapAddress(outer).balance == 0, "outer emptied");
        require(sf.swapAddress(inner).balance == 0, "inner emptied");
        require(vm.getNonce(sf.swapAddress(outer)) == 1, "outer completed");
        require(vm.getNonce(sf.swapAddress(inner)) == 1, "inner completed");
    }

    function testRetryAfterPayoutFails() public {
        TogglingClaimer wallet = new TogglingClaimer(sf);
        SwapFactory.Swap memory s = newSwap(payable(address(wallet)), commitment(REFUND_KEY));
        vm.warp(s.timeout1);
        try wallet.claim(s, bytes32(CLAIM_KEY)) {
            revert("paid a refusing claimer");
        } catch (bytes memory err) {
            expect(bytes4(err), Payout.PayoutFailed.selector, "refused payout");
        }
        wallet.setAccepting(true);
        wallet.claim(s, bytes32(CLAIM_KEY));
        require(address(wallet).balance == VALUE, "paid on retry");
    }

    function testSecretAboveN() public {
        SwapFactory.Swap memory s = newSwap();
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY + N), SwapFactory.InvalidSecret.selector, "claim s+n");
        expect(tryClaim(s, CLAIM_KEY + 1), SwapFactory.InvalidSecret.selector, "claim s+1");
        expect(tryClaim(s, CLAIM_KEY), 0, "claim s");
    }

    function testZeroAddressCommitment() public {
        SwapFactory.Swap memory s = newSwap(claimer, bytes32(uint256(1) << 160));
        expect(tryRefund(s, 0), SwapFactory.InvalidSecret.selector, "refund 0");
        expect(tryRefund(s, N), SwapFactory.InvalidSecret.selector, "refund n");
    }

    function testReentrantClaimPaysOnce() public {
        ReentrantClaimer wallet = new ReentrantClaimer(sf);
        SwapFactory.Swap memory s = newSwap(payable(address(wallet)), commitment(REFUND_KEY));
        vm.warp(s.timeout1);
        wallet.claim(s, bytes32(CLAIM_KEY));
        require(address(wallet).balance == VALUE, "paid once");
        require(sf.swapAddress(s).balance == 0, "emptied");
        expect(wallet.innerError(), SwapFactory.SwapCompleted.selector, "inner claim");
    }

    function testOnlyClaimerClaims() public {
        SwapFactory.Swap memory s = newSwap();
        vm.warp(s.timeout1);
        vm.prank(address(0xBAD));
        try sf.claim(s, bytes32(CLAIM_KEY)) {
            revert("claimed by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.OnlySwapClaimer.selector, "stranger claim");
        }
    }

    function testOnlyOwnerRefundsOrReadies() public {
        SwapFactory.Swap memory s = newSwap();
        vm.prank(address(0xBAD));
        try sf.refund(s, bytes32(REFUND_KEY)) {
            revert("refunded by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.OnlySwapOwner.selector, "stranger refund");
        }
        vm.prank(address(0xBAD));
        try sf.setReady(s) {
            revert("readied by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.OnlySwapOwner.selector, "stranger setReady");
        }
    }

    function testReadyOnce() public {
        SwapFactory.Swap memory s = newSwap();
        sf.setReady(s);
        try sf.setReady(s) {
            revert("readied twice");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapFactory.SwapNotPending.selector, "ready twice");
        }
    }
}
