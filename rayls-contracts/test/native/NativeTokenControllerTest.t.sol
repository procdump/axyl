// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {NativeTokenController} from "src/native/NativeTokenController.sol";
import {INativeTokenController} from "src/interfaces/INativeTokenController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract NativeTokenControllerTest is Test {
    NativeTokenController public controller;
    NativeTokenController public implementation;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public nobody = makeAddr("nobody");
    address public recipient = makeAddr("recipient");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        // Deploy implementation
        implementation = new NativeTokenController();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            NativeTokenController.initialize.selector,
            admin
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        controller = NativeTokenController(address(proxy));

        // Grant minter role
        vm.prank(admin);
        controller.grantRole(MINTER_ROLE, minter);
    }

    // ========== INITIALIZATION ==========

    function test_initialize_setsAdmin() public view {
        assertTrue(controller.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_initialize_setsUpgraderRole() public view {
        assertTrue(controller.hasRole(UPGRADER_ROLE, admin));
    }

    function test_initialize_revertsOnZeroAdmin() public {
        NativeTokenController newImpl = new NativeTokenController();
        bytes memory initData = abi.encodeWithSelector(
            NativeTokenController.initialize.selector,
            address(0)
        );
        vm.expectRevert(NativeTokenController.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        controller.initialize(admin);
    }

    function test_implementation_cannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin);
    }

    // ========== ROLES ==========

    function test_roles_minterCanMint() public {
        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("mint(address,uint256)", recipient, 100),
            abi.encode(true)
        );

        vm.prank(minter);
        controller.mint(recipient, 100);
    }

    function test_roles_nonMinterCannotMint() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nobody,
                MINTER_ROLE
            )
        );
        controller.mint(recipient, 100);
    }

    function test_roles_minterCanBurn() public {
        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("burnFrom(address,uint256)", recipient, 100),
            abi.encode(true)
        );

        vm.prank(minter);
        controller.burn(recipient, 100);
    }

    function test_roles_nonMinterCannotBurn() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nobody,
                MINTER_ROLE
            )
        );
        controller.burn(recipient, 100);
    }

    function test_roles_adminCanGrantAndRevoke() public {
        address newMinter = makeAddr("newMinter");

        vm.startPrank(admin);
        controller.grantRole(MINTER_ROLE, newMinter);
        assertTrue(controller.hasRole(MINTER_ROLE, newMinter));

        controller.revokeRole(MINTER_ROLE, newMinter);
        assertFalse(controller.hasRole(MINTER_ROLE, newMinter));
        vm.stopPrank();
    }

    function test_roles_nonAdminCannotGrant() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nobody,
                DEFAULT_ADMIN_ROLE
            )
        );
        controller.grantRole(MINTER_ROLE, nobody);
    }

    // ========== MINT ==========

    function test_mint_success() public {
        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("mint(address,uint256)", recipient, 1000),
            abi.encode(true)
        );

        vm.expectEmit(true, false, true, true);
        emit NativeTokenController.Minted(minter, recipient, 1000);

        vm.prank(minter);
        controller.mint(recipient, 1000);
    }

    function test_mint_revertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(NativeTokenController.ZeroAddress.selector);
        controller.mint(address(0), 100);
    }

    function test_mint_revertsOnZeroAmount() public {
        vm.prank(minter);
        vm.expectRevert(NativeTokenController.ZeroAmount.selector);
        controller.mint(recipient, 0);
    }

    function test_mint_revertsOnPrecompileFailure() public {
        vm.mockCallRevert(
            address(0x0400),
            abi.encodeWithSignature("mint(address,uint256)", recipient, 100),
            "precompile: revert"
        );

        vm.prank(minter);
        vm.expectRevert();
        controller.mint(recipient, 100);
    }

    // ========== BURN ==========

    function test_burn_success() public {
        address account = makeAddr("account");
        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("burnFrom(address,uint256)", account, 500),
            abi.encode(true)
        );

        vm.expectEmit(true, false, true, true);
        emit NativeTokenController.Burned(minter, account, 500);

        vm.prank(minter);
        controller.burn(account, 500);
    }

    function test_burn_revertsOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(NativeTokenController.ZeroAddress.selector);
        controller.burn(address(0), 100);
    }

    function test_burn_revertsOnZeroAmount() public {
        vm.prank(minter);
        vm.expectRevert(NativeTokenController.ZeroAmount.selector);
        controller.burn(recipient, 0);
    }

    function test_burn_revertsOnPrecompileFailure() public {
        vm.mockCallRevert(
            address(0x0400),
            abi.encodeWithSignature("burnFrom(address,uint256)", recipient, 100),
            "precompile: revert"
        );

        vm.prank(minter);
        vm.expectRevert();
        controller.burn(recipient, 100);
    }

    // ========== HELPER FUNCTIONS ==========

    function test_addMinter() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(admin);
        controller.addMinter(newMinter);

        assertTrue(controller.isMinter(newMinter));
    }

    function test_addMinter_revertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(NativeTokenController.ZeroAddress.selector);
        controller.addMinter(address(0));
    }

    function test_removeMinter() public {
        vm.prank(admin);
        controller.removeMinter(minter);

        assertFalse(controller.isMinter(minter));
    }

    function test_isMinter() public view {
        assertTrue(controller.isMinter(minter));
        assertFalse(controller.isMinter(nobody));
    }

    function test_nonAdminCannotAddMinter() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nobody,
                DEFAULT_ADMIN_ROLE
            )
        );
        controller.addMinter(nobody);
    }

    // ========== UPGRADE ==========

    function test_upgrade_upgraderCanUpgrade() public {
        NativeTokenController newImpl = new NativeTokenController();

        vm.prank(admin);
        controller.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_nonUpgraderCannotUpgrade() public {
        NativeTokenController newImpl = new NativeTokenController();

        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                nobody,
                UPGRADER_ROLE
            )
        );
        controller.upgradeToAndCall(address(newImpl), "");
    }

    // ========== CONSTANTS ==========

    function test_constants_precompile() public view {
        assertEq(address(controller.PRECOMPILE()), address(0x0400));
    }

    function test_constants_roles() public view {
        assertEq(controller.MINTER_ROLE(), keccak256("MINTER_ROLE"));
    }

    // ========== FUZZ ==========

    function testFuzz_mint_anyAmount(uint256 amount) public {
        vm.assume(amount > 0);

        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("mint(address,uint256)", recipient, amount),
            abi.encode(true)
        );

        vm.prank(minter);
        controller.mint(recipient, amount);
    }

    function testFuzz_burn_anyAmount(address account, uint256 amount) public {
        vm.assume(amount > 0);
        vm.assume(account != address(0));

        vm.mockCall(
            address(0x0400),
            abi.encodeWithSignature("burnFrom(address,uint256)", account, amount),
            abi.encode(true)
        );

        vm.prank(minter);
        controller.burn(account, amount);
    }
}
