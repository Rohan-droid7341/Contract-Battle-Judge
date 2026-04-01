// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "./Level2.sol";

contract VaultAccessLocalTest is Test {
    VaultAccess public vault;

    function setUp() public {
        vault = new VaultAccess();
    }

    // These tests will be visible to the player locally to test their baseline logic!
    function test_InitialState() public {
        assertFalse(vault.hasAccess(address(this)));
    }
}
