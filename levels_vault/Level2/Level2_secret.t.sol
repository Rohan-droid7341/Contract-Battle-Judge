// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/Level2.sol";

contract VaultAccessSecretTest is Test {
    VaultAccess public vault;

    function setUp() public {
        vault = new VaultAccess();
    }

    // --- SECRET DO NOT DISTRIBUTE ---
    // These tests are run by the Central Judge Docker container.
    // Make sure to test edge cases, 0 values, underflows, or reentrancy!

    function test_RevertIf_IncorrectPasskey() public {
        vm.expectRevert();
        vault.enter(12345); // Assuming 12345 is wrong
    }

    function test_CorrectPasskey() public {
        // Test whatever the correct passkey logic is
        vault.enter(9999);
        assertTrue(vault.hasAccess(address(this)));
    }
}
