// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { RLS } from "../../src/token/RLS.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

contract RLSV3Mock is RLS {
    function versionV3() public pure returns (string memory) {
        return "3.0.0";
    }
}

contract RLSTest is Test {
    RLS public rls;
    RLS public impl;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address minter = makeAddr("minter");
    address burner = makeAddr("burner");
    address pauser = makeAddr("pauser");
    address upgrader = makeAddr("upgrader");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INITIAL_SUPPLY = 1_000_000_000 ether; // 1B
    uint256 constant MAX_SUPPLY = 10_000_000_000 ether; // 10B

    // Cache role hashes (avoid external calls consuming vm.prank)
    bytes32 MINTER_ROLE;
    bytes32 BURNER_ROLE;
    bytes32 PAUSER_ROLE;
    bytes32 UPGRADER_ROLE;
    bytes32 DEFAULT_ADMIN_ROLE;

    function setUp() public {
        impl = new RLS();
        bytes memory initData = abi.encodeCall(RLS.initialize, (admin, treasury, INITIAL_SUPPLY));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        rls = RLS(address(proxy));

        // Cache role hashes
        MINTER_ROLE = rls.MINTER_ROLE();
        BURNER_ROLE = rls.BURNER_ROLE();
        PAUSER_ROLE = rls.PAUSER_ROLE();
        UPGRADER_ROLE = rls.UPGRADER_ROLE();
        DEFAULT_ADMIN_ROLE = rls.DEFAULT_ADMIN_ROLE();

        // Grant roles
        vm.startPrank(admin);
        rls.grantRole(MINTER_ROLE, minter);
        rls.grantRole(BURNER_ROLE, burner);
        rls.grantRole(PAUSER_ROLE, pauser);
        rls.grantRole(UPGRADER_ROLE, upgrader);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.1  mint() succeeds with MINTER_ROLE
    // ═══════════════════════════════════════════════════════════════════

    function test_mint_with_minter_role() public {
        vm.prank(minter);
        rls.mint(alice, 1000 ether);

        assertEq(rls.balanceOf(alice), 1000 ether);
        assertEq(rls.totalSupply(), INITIAL_SUPPLY + 1000 ether);
    }

    function test_mint_emits_event() public {
        vm.prank(minter);
        vm.expectEmit(true, false, false, true);
        emit RLS.TokensMinted(alice, 500 ether);
        rls.mint(alice, 500 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.2  mint() reverts without MINTER_ROLE
    // ═══════════════════════════════════════════════════════════════════

    function test_mint_reverts_without_minter_role() public {
        vm.prank(alice);
        vm.expectRevert();
        rls.mint(alice, 100 ether);
    }

    function test_mint_reverts_for_burner_role() public {
        vm.prank(burner);
        vm.expectRevert();
        rls.mint(alice, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.3  mint() enforces MAX_SUPPLY (10B)
    // ═══════════════════════════════════════════════════════════════════

    function test_mint_up_to_max_supply() public {
        uint256 remaining = MAX_SUPPLY - rls.totalSupply();
        vm.prank(minter);
        rls.mint(alice, remaining);
        assertEq(rls.totalSupply(), MAX_SUPPLY);
    }

    function test_mint_reverts_exceeding_max_supply() public {
        uint256 remaining = MAX_SUPPLY - rls.totalSupply();
        vm.prank(minter);
        vm.expectRevert(RLS.MaxSupplyExceeded.selector);
        rls.mint(alice, remaining + 1);
    }

    function test_mint_reverts_zero_amount() public {
        vm.prank(minter);
        vm.expectRevert(RLS.ZeroAmount.selector);
        rls.mint(alice, 0);
    }

    function test_mint_reverts_zero_address() public {
        vm.prank(minter);
        vm.expectRevert(RLS.InvalidAddress.selector);
        rls.mint(address(0), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.4  burn() by token holder (self-burn)
    // ═══════════════════════════════════════════════════════════════════

    function test_burn_own_tokens() public {
        // Treasury burns some of its tokens
        vm.prank(treasury);
        rls.burn(100 ether);

        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY - 100 ether);
        assertEq(rls.totalSupply(), INITIAL_SUPPLY - 100 ether);
    }

    function test_burn_reverts_zero_amount() public {
        vm.prank(treasury);
        vm.expectRevert(RLS.ZeroAmount.selector);
        rls.burn(0);
    }

    function test_burn_reverts_insufficient_balance() public {
        vm.prank(alice); // alice has 0 tokens
        vm.expectRevert();
        rls.burn(1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.5  burnFrom() by BURNER_ROLE bypasses allowance
    // ═══════════════════════════════════════════════════════════════════

    function test_burnFrom_by_burner_role_no_allowance() public {
        // Burner can burn treasury tokens without approval
        uint256 before = rls.balanceOf(treasury);
        vm.prank(burner);
        rls.burnFrom(treasury, 100 ether);

        assertEq(rls.balanceOf(treasury), before - 100 ether);
    }

    function test_burnFrom_by_minter_role_no_allowance() public {
        // Minter also has bridge burn capability
        uint256 before = rls.balanceOf(treasury);
        vm.prank(minter);
        rls.burnFrom(treasury, 50 ether);

        assertEq(rls.balanceOf(treasury), before - 50 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.6  burnFrom() by non-BURNER requires allowance
    // ═══════════════════════════════════════════════════════════════════

    function test_burnFrom_non_bridge_requires_allowance() public {
        // Alice has no allowance from treasury
        vm.prank(alice);
        vm.expectRevert();
        rls.burnFrom(treasury, 100 ether);
    }

    function test_burnFrom_non_bridge_with_allowance() public {
        // Treasury approves alice
        vm.prank(treasury);
        rls.approve(alice, 200 ether);

        vm.prank(alice);
        rls.burnFrom(treasury, 100 ether);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY - 100 ether);
        // Allowance consumed
        assertEq(rls.allowance(treasury, alice), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.7  mint() and burnFrom() bypass pause (bridge ops)
    // ═══════════════════════════════════════════════════════════════════

    function test_mint_bypasses_pause() public {
        vm.prank(pauser);
        rls.pause();
        assertTrue(rls.paused());

        // Minter can still mint while paused
        vm.prank(minter);
        rls.mint(alice, 100 ether);
        assertEq(rls.balanceOf(alice), 100 ether);
    }

    function test_burnFrom_by_burner_bypasses_pause() public {
        vm.prank(pauser);
        rls.pause();

        // Burner can still burn while paused
        vm.prank(burner);
        rls.burnFrom(treasury, 100 ether);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY - 100 ether);
    }

    function test_burnFrom_by_minter_bypasses_pause() public {
        vm.prank(pauser);
        rls.pause();

        vm.prank(minter);
        rls.burnFrom(treasury, 50 ether);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY - 50 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.8  Regular transfer() blocked when paused
    // ═══════════════════════════════════════════════════════════════════

    function test_transfer_blocked_when_paused() public {
        // Give alice some tokens first
        vm.prank(minter);
        rls.mint(alice, 100 ether);

        vm.prank(pauser);
        rls.pause();

        vm.prank(alice);
        vm.expectRevert();
        rls.transfer(bob, 50 ether);
    }

    function test_transferFrom_blocked_when_paused() public {
        vm.prank(minter);
        rls.mint(alice, 100 ether);

        vm.prank(alice);
        rls.approve(bob, 100 ether);

        vm.prank(pauser);
        rls.pause();

        vm.prank(bob);
        vm.expectRevert();
        rls.transferFrom(alice, bob, 50 ether);
    }

    function test_self_burn_blocked_when_paused() public {
        // Self-burn is NOT a bridge operation (msg.sender isn't necessarily MINTER/BURNER)
        vm.prank(pauser);
        rls.pause();

        vm.prank(treasury);
        vm.expectRevert();
        rls.burn(100 ether);
    }

    function test_transfer_works_after_unpause() public {
        vm.prank(minter);
        rls.mint(alice, 100 ether);

        vm.prank(pauser);
        rls.pause();

        vm.prank(pauser);
        rls.unpause();

        vm.prank(alice);
        rls.transfer(bob, 50 ether);
        assertEq(rls.balanceOf(bob), 50 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.9  Role granting/revoking by DEFAULT_ADMIN
    // ═══════════════════════════════════════════════════════════════════

    function test_admin_grants_minter_role() public {
        address newMinter = makeAddr("newMinter");
        assertFalse(rls.hasRole(MINTER_ROLE, newMinter));

        vm.prank(admin);
        rls.grantRole(MINTER_ROLE, newMinter);
        assertTrue(rls.hasRole(MINTER_ROLE, newMinter));

        // New minter can mint
        vm.prank(newMinter);
        rls.mint(alice, 10 ether);
        assertEq(rls.balanceOf(alice), 10 ether);
    }

    function test_admin_revokes_minter_role() public {
        vm.prank(admin);
        rls.revokeRole(MINTER_ROLE, minter);
        assertFalse(rls.hasRole(MINTER_ROLE, minter));

        // Revoked minter can no longer mint
        vm.prank(minter);
        vm.expectRevert();
        rls.mint(alice, 10 ether);
    }

    function test_non_admin_cannot_grant_roles() public {
        vm.prank(alice);
        vm.expectRevert();
        rls.grantRole(MINTER_ROLE, bob);
    }

    function test_admin_grants_all_roles() public {
        address target = makeAddr("target");

        vm.startPrank(admin);
        rls.grantRole(MINTER_ROLE, target);
        rls.grantRole(BURNER_ROLE, target);
        rls.grantRole(PAUSER_ROLE, target);
        rls.grantRole(UPGRADER_ROLE, target);
        vm.stopPrank();

        assertTrue(rls.hasRole(MINTER_ROLE, target));
        assertTrue(rls.hasRole(BURNER_ROLE, target));
        assertTrue(rls.hasRole(PAUSER_ROLE, target));
        assertTrue(rls.hasRole(UPGRADER_ROLE, target));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.10  UUPS upgrade with UPGRADER_ROLE
    // ═══════════════════════════════════════════════════════════════════

    function test_upgrade_with_upgrader_role() public {
        RLSV3Mock newImpl = new RLSV3Mock();

        vm.prank(upgrader);
        rls.upgradeToAndCall(address(newImpl), "");

        assertEq(RLSV3Mock(address(rls)).versionV3(), "3.0.0");
        // State preserved
        assertEq(rls.totalSupply(), INITIAL_SUPPLY);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY);
        assertEq(rls.name(), "Rayls");
        assertEq(rls.symbol(), "RLS");
    }

    function test_upgrade_reverts_without_upgrader_role() public {
        RLSV3Mock newImpl = new RLSV3Mock();

        vm.prank(alice);
        vm.expectRevert();
        rls.upgradeToAndCall(address(newImpl), "");
    }

    function test_state_preserved_after_upgrade() public {
        // Mint some tokens before upgrade
        vm.prank(minter);
        rls.mint(alice, 500 ether);

        RLSV3Mock newImpl = new RLSV3Mock();
        vm.prank(upgrader);
        rls.upgradeToAndCall(address(newImpl), "");

        assertEq(rls.balanceOf(alice), 500 ether);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY);
        assertTrue(rls.hasRole(MINTER_ROLE, minter));
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1.11  Fuzz: random mint/burn sequences preserve supply invariant
    // ═══════════════════════════════════════════════════════════════════

    function testFuzz_mint_burn_supply_invariant(uint256 mintAmt, uint256 burnAmt) public {
        uint256 maxMintable = MAX_SUPPLY - rls.totalSupply();
        mintAmt = bound(mintAmt, 1, maxMintable);

        vm.prank(minter);
        rls.mint(alice, mintAmt);

        burnAmt = bound(burnAmt, 1, rls.balanceOf(alice));

        vm.prank(alice);
        rls.burn(burnAmt);

        assertEq(rls.totalSupply(), INITIAL_SUPPLY + mintAmt - burnAmt);
        assertEq(rls.balanceOf(alice), mintAmt - burnAmt);
    }

    function testFuzz_burnFrom_bridge_no_allowance(uint256 amount) public {
        amount = bound(amount, 1, rls.balanceOf(treasury));

        vm.prank(burner);
        rls.burnFrom(treasury, amount);
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY - amount);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Additional: initialization guards
    // ═══════════════════════════════════════════════════════════════════

    function test_initialize_cannot_be_called_twice() public {
        vm.expectRevert();
        rls.initialize(admin, treasury, 1000 ether);
    }

    function test_initialize_reverts_zero_admin() public {
        RLS newImpl = new RLS();
        vm.expectRevert(RLS.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), abi.encodeCall(RLS.initialize, (address(0), treasury, 1000 ether)));
    }

    function test_initialize_reverts_zero_treasury() public {
        RLS newImpl = new RLS();
        vm.expectRevert(RLS.InvalidAddress.selector);
        new ERC1967Proxy(address(newImpl), abi.encodeCall(RLS.initialize, (admin, address(0), 1000 ether)));
    }

    function test_initialize_with_zero_supply() public {
        RLS newImpl = new RLS();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(newImpl), abi.encodeCall(RLS.initialize, (admin, treasury, 0))
        );
        RLS zeroSupply = RLS(address(proxy));
        assertEq(zeroSupply.totalSupply(), 0);
    }

    function test_initialize_reverts_over_max_supply() public {
        RLS newImpl = new RLS();
        vm.expectRevert(RLS.MaxSupplyExceeded.selector);
        new ERC1967Proxy(
            address(newImpl), abi.encodeCall(RLS.initialize, (admin, treasury, MAX_SUPPLY + 1))
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Additional: ERC-20 basics and metadata
    // ═══════════════════════════════════════════════════════════════════

    function test_name_and_symbol() public view {
        assertEq(rls.name(), "Rayls");
        assertEq(rls.symbol(), "RLS");
    }

    function test_decimals() public view {
        assertEq(rls.decimals(), 18);
    }

    function test_version() public view {
        assertEq(rls.version(), "2.0.0");
    }

    function test_initial_supply_in_treasury() public view {
        assertEq(rls.balanceOf(treasury), INITIAL_SUPPLY);
        assertEq(rls.totalSupply(), INITIAL_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Additional: pause access control
    // ═══════════════════════════════════════════════════════════════════

    function test_pause_reverts_without_pauser_role() public {
        vm.prank(alice);
        vm.expectRevert();
        rls.pause();
    }

    function test_unpause_reverts_without_pauser_role() public {
        vm.prank(pauser);
        rls.pause();

        vm.prank(alice);
        vm.expectRevert();
        rls.unpause();
    }

    // ════════���══════════════════════════════════════════════════════════
    // RLS-002: Bridge pause — independent kill switch for bridge ops
    // ���═══════════════════════════════════════════��══════════════════════

    function test_bridgePause_blocksMint() public {
        vm.prank(pauser);
        rls.pauseBridge();

        vm.prank(minter);
        vm.expectRevert(RLS.BridgeOperationsPaused.selector);
        rls.mint(alice, 100 ether);
    }

    function test_bridgePause_blocksBurnFrom() public {
        // Give alice tokens to burn
        vm.prank(minter);
        rls.mint(alice, 100 ether);

        vm.prank(pauser);
        rls.pauseBridge();

        // Bridge burn should be blocked
        vm.prank(burner);
        vm.expectRevert(RLS.BridgeOperationsPaused.selector);
        rls.burnFrom(alice, 50 ether);
    }

    function test_bridgePause_doesNotBlockRegularTransfers() public {
        // Bridge paused but regular transfers still work
        vm.prank(pauser);
        rls.pauseBridge();

        vm.prank(treasury);
        rls.transfer(alice, 100 ether);
        assertEq(rls.balanceOf(alice), 100 ether);
    }

    function test_regularPause_doesNotBlockBridge() public {
        // Regular pause: bridge operations still work (unless bridge is also paused)
        vm.prank(pauser);
        rls.pause();

        vm.prank(minter);
        rls.mint(alice, 100 ether);
        assertEq(rls.balanceOf(alice), 100 ether);
    }

    function test_bothPaused_blocksEverything() public {
        vm.startPrank(pauser);
        rls.pause();
        rls.pauseBridge();
        vm.stopPrank();

        // Regular transfer blocked
        vm.prank(treasury);
        vm.expectRevert();
        rls.transfer(alice, 100 ether);

        // Bridge mint blocked
        vm.prank(minter);
        vm.expectRevert(RLS.BridgeOperationsPaused.selector);
        rls.mint(alice, 100 ether);
    }

    function test_unpauseBridge_restoresBridgeOps() public {
        vm.startPrank(pauser);
        rls.pauseBridge();
        rls.unpauseBridge();
        vm.stopPrank();

        vm.prank(minter);
        rls.mint(alice, 100 ether);
        assertEq(rls.balanceOf(alice), 100 ether);
    }

    function test_pauseBridge_requiresPauserRole() public {
        vm.prank(alice);
        vm.expectRevert();
        rls.pauseBridge();
    }

    // ── EIP-2612 permit (gasless approvals) ──────────────────────────────────
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _permitSig(uint256 pk, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", rls.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_permit_grantsAllowanceAndEnablesTransferFrom() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        vm.prank(minter);
        rls.mint(owner, 1000 ether);

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = rls.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, owner, bob, 500 ether, nonce, deadline);

        rls.permit(owner, bob, 500 ether, deadline, v, r, s);

        assertEq(rls.allowance(owner, bob), 500 ether);
        assertEq(rls.nonces(owner), nonce + 1);

        // the gasless approval is real and usable
        vm.prank(bob);
        rls.transferFrom(owner, bob, 500 ether);
        assertEq(rls.balanceOf(bob), 500 ether);
    }

    function testRevert_permit_replayedSignatureReverts() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        vm.prank(minter);
        rls.mint(owner, 1000 ether);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, owner, bob, 500 ether, rls.nonces(owner), deadline);
        rls.permit(owner, bob, 500 ether, deadline, v, r, s);

        // replaying the same signature must fail — the nonce is already consumed, so the
        // digest changes and ecrecover yields a signer ≠ owner (recovered addr unpredictable,
        // so match the selector only)
        vm.expectPartialRevert(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector);
        rls.permit(owner, bob, 500 ether, deadline, v, r, s);
    }

    function testRevert_permit_expiredDeadlineReverts() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        vm.warp(1 days);
        uint256 deadline = block.timestamp - 1; // already past
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, owner, bob, 500 ether, rls.nonces(owner), deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        rls.permit(owner, bob, 500 ether, deadline, v, r, s);
    }

    function testRevert_permit_forgedSignatureReverts() public {
        (address owner,) = makeAddrAndKey("permitOwner");
        (address attacker, uint256 attackerPk) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 days;

        // a signature NOT from owner must not grant an allowance over owner's tokens:
        // ecrecover yields the attacker, which the contract rejects as ≠ owner
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(attackerPk, owner, bob, 500 ether, rls.nonces(owner), deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, attacker, owner));
        rls.permit(owner, bob, 500 ether, deadline, v, r, s);
    }
}
