// SPDX-License-Identifier: LGPLv3
pragma solidity ^0.8.28;

interface IPayoutTo {
    function payoutTo() external view returns (address payable);
}

// Deployed by SwapFactory with CREATE2 at a swap's address. Sends the whole
// balance to the winner the factory names and leaves no code; the address's
// nonce then blocks a second deployment.
contract Payout {
    error PayoutFailed();

    constructor() {
        (bool ok, ) = IPayoutTo(msg.sender).payoutTo().call{value: address(this).balance}("");
        if (!ok) revert PayoutFailed();
        assembly {
            return(0, 0)
        }
    }
}
