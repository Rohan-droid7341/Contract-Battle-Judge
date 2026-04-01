// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./Level2.sol";

contract RepuFiSBTLocalTest is Test {
    RepuFiSBT public repuFi;

    function setUp() public {
        repuFi = new RepuFiSBT();
    }

    // These tests will be visible to the player locally to test their baseline logic!
    function test_InitialDeployment() public {
        assertEq(repuFi.tokenIdCounter(), 0);
        assertEq(repuFi.requestCounter(), 0);
    }
}
