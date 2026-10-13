// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockPKL is ERC20 {
    constructor() ERC20("Mock PKL", "PKL") { _mint(msg.sender, 1_000_000 ether); }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

interface IPots { function dropBid(uint8) external payable; function dropBidFor(uint8, address) external payable; }

// A "player" contract that cannot receive ETH, to prove a hostile winner can't freeze a jar.
contract RejectingPlayer {
    function bid(address pots, uint8 t) external payable { IPots(pots).dropBid{value: msg.value}(t); }
}
