# Level 2 - Central Vault Access

**Mission:** You successfully registered your ship. Now you must bypass the Central Vault's lock mechanism.

**Your Task:**
Complete the `enter` function inside `src/Level2.sol`.

## Requirements:
- The passkey must be exactly `9999`.
- If the passkey is correct, set `hasAccess[msg.sender] = true`.
- If the passkey is incorrect, `revert` the transaction.

*Tip: Make sure you use a `require` statement to enforce the passkey!*
