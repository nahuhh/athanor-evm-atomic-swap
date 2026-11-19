// SPDX-License-Identifier: LGPLv3
pragma solidity ^0.8.19;

import {SwapCreator} from "../ethereum/contracts/SwapCreator.sol";

interface Vm {
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function deal(address who, uint256 amount) external;
    function addr(uint256 key) external pure returns (address);
}

// Claims while being paid, to try a second payout of the same swap.
contract ReentrantClaimer {
    SwapCreator internal immutable sc;
    SwapCreator.Swap internal swap;
    bytes32 internal secret;
    bool internal entered;
    bytes4 public innerError;

    constructor(SwapCreator _sc) {
        sc = _sc;
    }

    function claim(SwapCreator.Swap memory _swap, bytes32 _secret) external {
        swap = _swap;
        secret = _secret;
        sc.claim(_swap, _secret);
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try sc.claim(swap, secret) {
            innerError = bytes4(0xffffffff);
        } catch (bytes memory err) {
            innerError = bytes4(err);
        }
    }
}

contract SwapCreatorTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant CLAIM_KEY = 0xC1A1;
    uint256 internal constant REFUND_KEY = 0x2EF0;
    uint256 internal constant D = 1 hours;
    uint256 internal constant VALUE = 1 ether;
    uint256 internal constant START = 1_000_000;

    SwapCreator internal sc;
    address payable internal claimer;
    uint256 internal nonce;
    uint256 internal refundsReceived;

    // Writes storage, so a payout with transfer()'s 2300 gas stipend would fail
    receive() external payable {
        refundsReceived += msg.value;
    }

    function setUp() public {
        sc = new SwapCreator();
        claimer = payable(vm.addr(CLAIM_KEY));
        vm.deal(address(this), 1000 ether);
        vm.warp(START);
    }

    function commitment(uint256 key) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(vm.addr(key))));
    }

    function newSwap(address payable to, bytes32 refundCommitment)
        internal
        returns (SwapCreator.Swap memory s)
    {
        nonce++;
        sc.newSwap{value: VALUE}(
            commitment(CLAIM_KEY), refundCommitment, to, D, D, D, address(0), VALUE, nonce
        );
        s = SwapCreator.Swap({
            owner: payable(address(this)),
            claimer: to,
            claimCommitment: commitment(CLAIM_KEY),
            refundCommitment: refundCommitment,
            timeout1: block.timestamp + D,
            timeout2: block.timestamp + 2 * D,
            timeout3: block.timestamp + 3 * D,
            asset: address(0),
            value: VALUE,
            nonce: nonce
        });
    }

    function newSwap() internal returns (SwapCreator.Swap memory) {
        return newSwap(claimer, commitment(REFUND_KEY));
    }

    function tryClaim(SwapCreator.Swap memory s, uint256 secret) internal returns (bytes4) {
        vm.prank(s.claimer);
        try sc.claim(s, bytes32(secret)) {
            return 0;
        } catch (bytes memory err) {
            return bytes4(err);
        }
    }

    function tryRefund(SwapCreator.Swap memory s, uint256 secret) internal returns (bytes4) {
        try sc.refund(s, bytes32(secret)) {
            return 0;
        } catch (bytes memory err) {
            return bytes4(err);
        }
    }

    function expect(bytes4 got, bytes4 want, string memory what) internal pure {
        require(got == want, what);
    }

    // A fresh swap per call, so each cell sees the stage it was set up with
    function checkCell(bool ready, uint256 offset, bytes4 claimResult, bytes4 refundResult)
        internal
    {
        vm.warp(START);
        SwapCreator.Swap memory s = newSwap();
        if (ready) sc.setReady(s);
        vm.warp(START + offset);
        uint256 before = claimer.balance;
        expect(tryClaim(s, CLAIM_KEY), claimResult, "claim");
        if (claimResult == 0) require(claimer.balance == before + VALUE, "claim paid");

        vm.warp(START);
        s = newSwap();
        if (ready) sc.setReady(s);
        vm.warp(START + offset);
        before = refundsReceived;
        expect(tryRefund(s, REFUND_KEY), refundResult, "refund");
        if (refundResult == 0) require(refundsReceived == before + VALUE, "refund paid");
    }

    function checkWindows(bool ready) internal {
        bytes4 early = ready ? bytes4(0) : SwapCreator.TooEarlyToClaim.selector;
        bytes4 earlyRefund = ready ? SwapCreator.NotTimeToRefund.selector : bytes4(0);
        bytes4 notRefund = SwapCreator.NotTimeToRefund.selector;
        bytes4 late = SwapCreator.TooLateToClaim.selector;

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

    function testSecretAboveN() public {
        SwapCreator.Swap memory s = newSwap();
        vm.warp(s.timeout1);
        expect(tryClaim(s, CLAIM_KEY + N), SwapCreator.InvalidSecret.selector, "claim s+n");
        expect(tryClaim(s, CLAIM_KEY + 1), SwapCreator.InvalidSecret.selector, "claim s+1");
        expect(tryClaim(s, CLAIM_KEY), 0, "claim s");
    }

    // ecrecover fails to address(0); a commitment with low 160 bits zero must not open
    function testZeroAddressCommitment() public {
        SwapCreator.Swap memory s = newSwap(claimer, bytes32(uint256(1) << 160));
        expect(tryRefund(s, 0), SwapCreator.InvalidSecret.selector, "refund 0");
        expect(tryRefund(s, N), SwapCreator.InvalidSecret.selector, "refund n");
    }

    function testMulVerify() public view {
        uint256 c = uint256(commitment(CLAIM_KEY));
        require(sc.mulVerify(CLAIM_KEY, c), "key");
        require(!sc.mulVerify(CLAIM_KEY + 1, c), "key + 1");
        require(!sc.mulVerify(CLAIM_KEY + N, c), "key + n");
        require(!sc.mulVerify(0, c), "zero");
    }

    function testReentrantClaimPaysOnce() public {
        ReentrantClaimer wallet = new ReentrantClaimer(sc);
        SwapCreator.Swap memory s = newSwap(payable(address(wallet)), commitment(REFUND_KEY));
        vm.warp(s.timeout1);
        wallet.claim(s, bytes32(CLAIM_KEY));
        require(address(wallet).balance == VALUE, "paid once");
        require(address(sc).balance == 0, "contract emptied");
        expect(wallet.innerError(), SwapCreator.SwapCompleted.selector, "inner claim");
    }

    function testOnlyClaimerClaims() public {
        SwapCreator.Swap memory s = newSwap();
        vm.warp(s.timeout1);
        vm.prank(address(0xBAD));
        try sc.claim(s, bytes32(CLAIM_KEY)) {
            revert("claimed by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapCreator.OnlySwapClaimer.selector, "stranger claim");
        }
    }

    function testOnlyOwnerRefundsOrReadies() public {
        SwapCreator.Swap memory s = newSwap();
        vm.prank(address(0xBAD));
        try sc.refund(s, bytes32(REFUND_KEY)) {
            revert("refunded by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapCreator.OnlySwapOwner.selector, "stranger refund");
        }
        vm.prank(address(0xBAD));
        try sc.setReady(s) {
            revert("readied by a stranger");
        } catch (bytes memory err) {
            expect(bytes4(err), SwapCreator.OnlySwapOwner.selector, "stranger setReady");
        }
    }

    function testCompletedSwapIsFinal() public {
        SwapCreator.Swap memory s = newSwap();
        expect(tryRefund(s, REFUND_KEY), 0, "refund");
        expect(tryRefund(s, REFUND_KEY), SwapCreator.SwapCompleted.selector, "refund twice");
        vm.warp(s.timeout3);
        expect(tryClaim(s, CLAIM_KEY), SwapCreator.SwapCompleted.selector, "claim after refund");
    }
}
