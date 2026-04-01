// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Level1.sol";

contract Level1SecretTest is Test {
    GalacticRegistry public registry;

    // Redefine event for testing with vm.expectEmit
    event Registered(address indexed pilot, string name);

    function setUp() public {
        registry = new GalacticRegistry();
    }

    // --- ACCESS & LOGIC TESTS ---

    function test_RevertIf_EmptyName() public {
        vm.expectRevert(); // Forge will now expect the very next line to fail
        registry.register("");
    }

    function test_RevertIf_DuplicateRegistration() public {
        registry.register("Pilot_A");
        
        vm.expectRevert(); // Expect this second attempt from the same sender to fail
        registry.register("Pilot_B"); 
    }

    function test_MultipleDifferentUsers() public {
        for(uint160 i = 10; i < 25; i++) {
            address pilot = address(i);
            vm.prank(pilot);
            string memory name = string(abi.encodePacked("Pilot_", vm.toString(i)));
            registry.register(name);
            assertEq(registry.getPilotName(pilot), name);
        }
    }

    // --- DATA INTEGRITY TESTS ---

    function test_NamePersistence() public {
        vm.prank(address(0xBEEF));
        registry.register("Rocket");
        // Verify a user can't overwrite their own name
        vm.prank(address(0xBEEF));
        vm.expectRevert(); 
        registry.register("Star-Lord"); 
    }

    function test_LongName() public {
        string memory longName = "ThisIsAVeryLongPilotNameThatShouldStillBeAcceptedByTheRegistryBecauseStringsAreDynamic";
        registry.register(longName);
        assertEq(registry.getPilotName(address(this)), longName);
    }

    function test_SpecialCharacters() public {
        string memory special = "!@#$%^&*()_+12345";
        registry.register(special);
        assertEq(registry.getPilotName(address(this)), special);
    }

    // --- EVENT TESTS ---

    function test_RegistrationEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Registered(address(this), "Groot");
        registry.register("Groot");
    }

    // --- GAS & STRESS TESTS ---

    function test_GasUsagePerRegister() public {
        uint256 gasStart = gasleft();
        registry.register("EfficientPilot");
        uint256 gasUsed = gasStart - gasleft();
        // Ensure they aren't doing something insanely gas-heavy
        assertTrue(gasUsed < 150000, "Gas usage too high for simple registration");
    }

    function test_RegisterWithZeroAddress() public {
        vm.prank(address(0));
        registry.register("VoidWalker");
        assertEq(registry.getPilotName(address(0)), "VoidWalker");
    }

    function test_RegistrationStateBoolean() public {
        address user = address(0x123);
        assertFalse(registry.hasRegistered(user));
        vm.prank(user);
        registry.register("User123");
        assertTrue(registry.hasRegistered(user));
    }
}
