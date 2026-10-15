// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keelpad} from "../src/Keelpad.sol";

/// @dev All tokens stay within a closed set of actors. Every generated action must succeed or
/// explicitly demonstrate the expected atomic failure; unexpected handler reverts fail the run.
contract KeelpadHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Keelpad public immutable token;
    address[4] public actors;
    // Updated only from requested operations, never copied from token getters. Comparing every
    // entry catches corruption of unrelated holders/approvals that a sum-only invariant misses.
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(Keelpad token_) {
        token = token_;
        actors[0] = makeAddr("holder 0");
        actors[1] = makeAddr("holder 1");
        actors[2] = makeAddr("holder 2");
        actors[3] = makeAddr("holder 3");
        expectedBalance[actors[0]] = SUPPLY;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        assertEq(token.balanceOf(from), from == to ? beforeFrom : beforeFrom - amount);
        assertEq(token.balanceOf(to), from == to ? beforeTo : beforeTo + amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount);
    }

    function approveBoundary(uint256 ownerSeed, uint256 spenderSeed, uint8 choice) external {
        uint256[5] memory amounts = [uint256(0), 1, SUPPLY, type(uint256).max - 1, type(uint256).max];
        approve(ownerSeed, spenderSeed, amounts[choice % amounts.length]);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        assertEq(token.allowance(owner, spender), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeOwner = token.balanceOf(owner);
        uint256 beforeTo = token.balanceOf(to);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 limit = allowed < balance ? allowed : balance;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _recordTransferFrom(owner, spender, to, amount);
        assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
        assertEq(token.balanceOf(owner), owner == to ? beforeOwner : beforeOwner - amount);
        assertEq(token.balanceOf(to), owner == to ? beforeTo : beforeTo + amount);
    }

    function overdraw(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 balance = expectedBalance[from];
        _expectFailure(
            from,
            abi.encodeCall(token.transfer, (to, balance + 1)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        assertEq(token.balanceOf(from), beforeFrom);
        assertEq(token.balanceOf(to), beforeTo);
    }

    /// @dev Keep the current approval history and exercise both valid and invalid spends. The
    /// amount spans zero through total supply + 1, including empty owners and self-transfers.
    function attemptTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, SUPPLY + 1);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        bytes memory data = abi.encodeCall(token.transferFrom, (owner, to, amount));

        if (amount > allowed) {
            _expectFailure(
                spender,
                data,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else if (amount > balance) {
            _expectFailure(
                spender,
                data,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
        } else {
            vm.prank(spender);
            assertTrue(token.transferFrom(owner, to, amount));
            _recordTransferFrom(owner, spender, to, amount);
        }
    }

    /// @dev A failed balance check must roll back the allowance deduction, even after arbitrary
    /// earlier spending. This action always reaches that failure, with finite or infinite approval.
    function overdrawTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        approve(ownerSeed, spenderSeed, infinite ? type(uint256).max : amount);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 amount = bound(amountSeed, 0, allowed < balance ? allowed : balance);
        _expectFailure(
            spender,
            abi.encodeCall(token.transferFrom, (owner, address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        _expectFailure(
            actors[ownerSeed % actors.length],
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function transferFullBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = expectedBalance[from];
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
    }

    function _expectFailure(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success, "invalid operation succeeded");
        assertEq(result, expectedError, "unexpected failure reason");
        // Ghost state is deliberately unchanged: the invariants verify *all* balances/allowances.
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _recordTransferFrom(address owner, address spender, address to, uint256 amount) internal {
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
        _recordTransfer(owner, to, amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract KeelpadInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Keelpad internal token;
    KeelpadHandler internal handler;

    function setUp() public {
        token = new Keelpad();
        handler = new KeelpadHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.overdraw.selector;
        selectors[5] = handler.approveBoundary.selector;
        selectors[6] = handler.attemptTransferFrom.selector;
        selectors[7] = handler.overdrawTransferFrom.selector;
        selectors[8] = handler.transferFromToZero.selector;
        selectors[9] = handler.approveZeroSpender.selector;
        selectors[10] = handler.transferFullBalance.selector;
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
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_BalancesMatchAuthorizedTransfers() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "unexpected balance change");
        }
    }

    function invariant_AllAllowancesMatchOwnerAuthorizations() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(address(0), owner), 0);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "unexpected allowance change"
                );
            }
        }
    }

    /// @dev After every random history, every holder can still move its entire balance without
    /// a fee, freeze, or residual dust. Each transfer is a separate call to the real token.
    function afterInvariant() public {
        for (uint256 i = 1; i < 4; ++i) {
            handler.transferFullBalance(i, 0);
            assertEq(token.balanceOf(handler.actors(i)), 0);
        }
        assertEq(token.balanceOf(handler.actors(0)), SUPPLY);
        invariant_SupplyIsFixedAndAllBalancesAreConserved();
        invariant_BalancesMatchAuthorizedTransfers();
        invariant_AllAllowancesMatchOwnerAuthorizations();
    }
}
