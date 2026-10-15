// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keelpad} from "../src/Keelpad.sol";

/// @dev All tokens stay within a closed set of actors. Every generated action must succeed or
/// explicitly demonstrate the expected atomic failure; unexpected handler reverts fail the run.
contract KeelpadHandler is Test {
    Keelpad public immutable token;
    address[4] public actors;

    constructor(Keelpad token_) {
        token = token_;
        actors[0] = makeAddr("holder 0");
        actors[1] = makeAddr("holder 1");
        actors[2] = makeAddr("holder 2");
        actors[3] = makeAddr("holder 3");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 amount = bound(amountSeed, 0, beforeFrom);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(from), from == to ? beforeFrom : beforeFrom - amount);
        assertEq(token.balanceOf(to), from == to ? beforeTo : beforeTo + amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(owner, spender), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeOwner = token.balanceOf(owner);
        uint256 beforeTo = token.balanceOf(to);
        uint256 allowed = token.allowance(owner, spender);
        uint256 limit = allowed < beforeOwner ? allowed : beforeOwner;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
        assertEq(token.balanceOf(owner), owner == to ? beforeOwner : beforeOwner - amount);
        assertEq(token.balanceOf(to), owner == to ? beforeTo : beforeTo + amount);
    }

    function overdraw(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        vm.prank(from);
        (bool success,) = address(token).call(abi.encodeCall(token.transfer, (to, beforeFrom + 1)));
        assertFalse(success);
        assertEq(token.balanceOf(from), beforeFrom);
        assertEq(token.balanceOf(to), beforeTo);
    }
}

contract KeelpadInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Keelpad internal token;
    KeelpadHandler internal handler;

    function setUp() public {
        token = new Keelpad();
        handler = new KeelpadHandler(token);
        token.transfer(handler.actors(0), SUPPLY);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.overdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyIsFixedAndAllBalancesAreConserved() public view {
        uint256 accounted;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actors(i));
            assertLe(balance, SUPPLY);
            accounted += balance;
        }
        assertEq(accounted, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}
