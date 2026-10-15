// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keelpad} from "src/Keelpad.sol";

/// @dev Complements the constructor/basic ERC-20 suite with allowance lifecycle and amount edges.
/// forge-config: default.fuzz.runs = 1024
contract KeelpadEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Keelpad internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new Keelpad();
        alice = makeAddr("edge holder");
        bob = makeAddr("edge second spender");
        spender = makeAddr("edge spender");
    }

    function test_OneWeiRoundTrip() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumTransferRevertsWithBalanceError() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumDelegatedTransferCannotOverflowOrConsumeInfiniteApproval() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_MaximumMinusOneAllowanceIsFinite() public {
        uint256 allowance = type(uint256).max - 1;
        assertTrue(token.approve(spender, allowance));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), allowance - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY - 1));
        assertEq(token.allowance(address(this), spender), allowance - SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteApprovalCanBeReducedAndRevokedAfterSpending() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max);

        assertTrue(token.approve(spender, 2));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2, 3));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 3);
        assertEq(token.allowance(address(this), spender), 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), 1);

        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2);
    }

    function test_TransferFromOwnerStillRequiresItsOwnAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);

        assertTrue(token.approve(address(this), 1));
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_ApprovalIsNotTransitiveAndSpenderMayReceiveTokens() public {
        assertTrue(token.approve(spender, 7));
        vm.prank(spender);
        assertTrue(token.approve(bob, 7));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 7);
        assertEq(token.allowance(spender, bob), 7);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), spender, 7));
        assertEq(token.balanceOf(spender), 7);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 7);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(spender, bob), 7);
    }

    function test_SpendingAndRevokingOneApprovalDoesNotChangeAnother() public {
        assertTrue(token.approve(spender, 7));
        assertTrue(token.approve(bob, 11));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 3));
        assertEq(token.allowance(address(this), spender), 4);
        assertEq(token.allowance(address(this), bob), 11);

        assertTrue(token.approve(spender, 0));
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 11));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.balanceOf(alice), 14);
        assertEq(token.balanceOf(address(this)), SUPPLY - 14);
    }

    function test_ApprovalSurvivesFailedSpendAndCanUseFutureDeposit() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);

        assertTrue(token.transfer(alice, 10));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
    }

    function test_SelfTransferCannotBypassBalanceCheck() public {
        assertTrue(token.transfer(alice, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(alice);
        token.transfer(alice, 2);

        vm.prank(alice);
        assertTrue(token.approve(spender, 2));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(spender);
        token.transferFrom(alice, alice, 2);
        assertEq(token.allowance(alice, spender), 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroDelegatedTransferEmitsEventAndPreservesApproval() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, 7));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 7);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ZeroApprovalToZeroSpenderStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_InfiniteApprovalCannotBurnViaTransferFromToZero() public {
        assertTrue(token.approve(spender, type(uint256).max));
        for (uint256 amount; amount <= 1; ++amount) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(address(this), address(0), amount);
            assertEq(token.allowance(address(this), spender), type(uint256).max);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.balanceOf(address(0)), 0);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function testFuzz_TransferRoundTripPreservesBalancesAndApprovals(uint256 amountSeed, uint256 allowance) public {
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        assertTrue(token.approve(spender, allowance));
        vm.prank(alice);
        assertTrue(token.approve(bob, allowance));
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), amount));

        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), allowance);
        assertEq(token.allowance(alice, bob), allowance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_SplitTransferEqualsSingleTransfer(uint256 amountSeed, uint256 splitSeed) public {
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        uint256 first = bound(splitSeed, 0, amount);
        Keelpad single = new Keelpad();
        assertTrue(single.transfer(alice, amount));
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, amount - first));

        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), single.balanceOf(address(this)));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(single.totalSupply(), SUPPLY);
    }

    function testFuzz_DelegatedOverdrawRestoresAnyFiniteAllowance(
        uint256 balanceSeed,
        uint256 allowanceSeed,
        uint256 amountSeed
    ) public {
        uint256 balance = bound(balanceSeed, 0, SUPPLY);
        uint256 allowance = bound(allowanceSeed, balance + 1, type(uint256).max - 1);
        uint256 amount = bound(amountSeed, balance + 1, allowance);
        assertTrue(token.transfer(alice, balance));
        vm.prank(alice);
        assertTrue(token.approve(spender, allowance));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);

        assertEq(token.allowance(alice, spender), allowance);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_ApprovalReplacementAfterPartialSpending(
        uint256 allowanceSeed,
        uint256 spentSeed,
        uint256 replacement
    ) public {
        uint256 allowance = bound(allowanceSeed, 1, SUPPLY);
        uint256 spent = bound(spentSeed, 0, allowance);
        assertTrue(token.approve(spender, allowance));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, spent));
        assertEq(token.allowance(address(this), spender), allowance - spent);
        assertTrue(token.approve(spender, replacement));

        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), spent);
        assertEq(token.balanceOf(address(this)), SUPPLY - spent);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
