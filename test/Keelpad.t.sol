// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Keelpad} from "../src/Keelpad.sol";

/// @dev Test fixture only; exercises the immediate creator and CREATE2 deployment semantics.
contract TokenFactoryHarness {
    function deploy(bytes32 salt) external returns (Keelpad) {
        return new Keelpad{salt: salt}();
    }

    function move(Keelpad token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// forge-config: default.fuzz.runs = 1024
contract KeelpadTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    Keelpad internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new Keelpad();
    }

    function test_MetadataAndEntireInitialSupply() public view {
        assertEq(token.name(), "Keelpad");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_ConstructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        vm.prank(deployer);
        Keelpad deployed = new Keelpad();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_Create2FactoryReceivesEverythingAndDistributesExactAmounts() public {
        TokenFactoryHarness factory = new TokenFactoryHarness();
        bytes32 salt = keccak256("Keelpad launch test");
        address predicted = computeCreate2Address(salt, keccak256(type(Keelpad).creationCode), address(factory));
        vm.prank(alice, alice);
        Keelpad launched = factory.deploy(salt);

        assertEq(address(launched), predicted);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(alice), 0, "the caller/origin must not receive the mint");

        address distributor = makeAddr("distributor fixture");
        address poolManager = makeAddr("pool manager fixture");
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY * 80 / 100;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, poolManager, pool));
        assertTrue(factory.move(launched, alice, remainder));
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.balanceOf(alice), remainder);

        vm.prank(distributor);
        assertTrue(launched.transfer(bob, swarm));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(bob), swarm);

        // These are token-side settlement flows, not a simulation of Uniswap pricing or liquidity.
        vm.prank(poolManager);
        assertTrue(launched.transfer(alice, 50 ether));
        vm.prank(alice);
        assertTrue(launched.transfer(poolManager, 50 ether));
        assertEq(launched.balanceOf(alice), remainder);
        assertEq(launched.balanceOf(poolManager), pool);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_TransferDeliversExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 12 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 12 ether));
        assertEq(token.balanceOf(deployer), SUPPLY - 12 ether);
        assertEq(token.balanceOf(alice), 12 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFullBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_ZeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SelfTransferPreservesBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenTransferExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenTransferToZeroEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ApproveReplacesAllowanceAndCanRevoke() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 100 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 100 ether));
        assertEq(token.allowance(deployer, spender), 100 ether);

        vm.prank(deployer);
        assertTrue(token.approve(spender, 5 ether));
        assertEq(token.allowance(deployer, spender), 5 ether);

        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 0);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_ApprovalDoesNotRequireBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenApprovingZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 100);
        assertEq(token.allowance(deployer, address(0)), 0);
    }

    function test_TransferFromConsumesFiniteAllowanceAndEmitsTransfer() public {
        vm.prank(deployer);
        token.approve(spender, 30 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, alice, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 10 ether));
        assertEq(token.allowance(deployer, spender), 20 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 10 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 20 ether));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferFromPreservesInfiniteAllowance() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1 ether));
        assertTrue(token.transferFrom(deployer, bob, SUPPLY - 1 ether));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
    }

    function test_ZeroTransferFromWithoutApproval() public {
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_TransferFromToSelfConsumesAllowanceWithoutChangingBalance() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 10 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_RevertWhenTransferFromHasNoAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenTransferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2 ether, 3 ether)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, 3 ether);
        assertEq(token.allowance(deployer, spender), 2 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_RevertWhenAllowanceWasRevoked() public {
        vm.startPrank(deployer);
        token.approve(spender, 10 ether);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
    }

    function test_RevertWhenTransferFromExceedsBalanceRestoresAllowance() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, spender), 10 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhenTransferFromToZeroRestoresAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 10 ether);
        assertEq(token.allowance(deployer, spender), 10 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhenDeployerTriesToSpendHolderFundsWithoutApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_NoMintBurnOrAdministrativeEntryPoints() public {
        bytes[] memory attempts = new bytes[](15);
        attempts[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        attempts[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        attempts[2] = abi.encodeWithSignature("mint()");
        attempts[3] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        attempts[4] = abi.encodeWithSignature("burnFrom(address,uint256)", deployer, 1 ether);
        attempts[5] = abi.encodeWithSignature("initialize(address)", alice);
        attempts[6] = abi.encodeWithSignature("pause()");
        attempts[7] = abi.encodeWithSignature("blacklist(address)", deployer);
        attempts[8] = abi.encodeWithSignature("freeze(address)", deployer);
        attempts[9] = abi.encodeWithSignature("seize(address)", deployer);
        attempts[10] = abi.encodeWithSignature("setMinter(address)", alice);
        attempts[11] = abi.encodeWithSignature("transferOwnership(address)", alice);
        attempts[12] = abi.encodeWithSignature("upgradeTo(address)", alice);
        attempts[13] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        attempts[14] = abi.encodeWithSignature("_mint(address,uint256)", alice, 1 ether);

        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(deployer);
            (bool deployerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(deployerSucceeded, "deployer gained an unexpected privilege");
            vm.prank(alice);
            (bool strangerSucceeded,) = address(token).call(attempts[i]);
            assertFalse(strangerSucceeded, "unexpected public entry point");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
    }

    function test_RevertWhenSendingEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, 1 ether);
    }

    function test_RuntimeSizeAndForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testFuzz_TransferConservesSupply(address recipient, uint256 rawAmount) public {
        recipient = address(uint160(bound(uint256(uint160(recipient)), 1, type(uint160).max)));
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(recipient, amount));
        if (recipient == deployer) {
            assertEq(token.balanceOf(deployer), SUPPLY);
        } else {
            assertEq(token.balanceOf(deployer), SUPPLY - amount);
            assertEq(token.balanceOf(recipient), amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_TransferFromConsumesOnlyApprovedAmount(uint256 rawAllowance, uint256 rawAmount) public {
        uint256 approved = bound(rawAllowance, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, approved);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), approved - amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_OverdrawRevertsAtomically(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_InsufficientAllowanceRevertsAtomically(uint256 rawApproved, uint256 rawExcess) public {
        uint256 approved = bound(rawApproved, 0, SUPPLY - 1);
        uint256 amount = approved + bound(rawExcess, 1, SUPPLY - approved);
        vm.prank(deployer);
        token.approve(spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, amount);
        assertEq(token.allowance(deployer, spender), approved);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_ApprovalIsIsolatedToOwnerAndSpender(uint256 amount) public {
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.allowance(bob, spender), 0);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

