// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title RepuFiSBT
 * @notice Reputation-backed Soulbound Token protocol.
 *
 * SYSTEM INVARIANTS (must hold after every state-changing call):
 *   I1. Every minted token ID has a corresponding Vouch entry on BOTH sides.
 *   I2. vouches[id1].pairedTokenId == id2  &&  vouches[id2].pairedTokenId == id1
 *   I3. When either side is released/withdrawn, the paired side is also marked withdrawn.
 *   I4. A ReputationRequest can only be fulfilled once.
 *   I5. Backer and borrower must always be different addresses.
 *   I6. Only requests with githubScore >= MIN_GITHUB_SCORE are accepted.
 *   I7. SBTs are non-transferable; only mint (from==0) and burn (to==0) are allowed.
 */
contract RepuFiSBT is ERC721, Ownable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────

    uint256 public constant REPUTATION_REQUEST_FEE = 0.0001 ether;
    uint256 public constant MIN_GITHUB_SCORE = 7;

    // ─────────────────────────────────────────────────────────────
    // Data structures
    // ─────────────────────────────────────────────────────────────

    struct Vouch {
        address backer;         // staked ETH, holds id1 (backer token)
        address borrower;       // beneficiary, holds id2 (borrower token)
        uint128 amount;         // ETH staked (safe: checked <= type(uint128).max on creation)
        uint256 expiry;         // unix timestamp after which backer may withdraw
        bool    withdrawn;      // true once ETH has been returned to backer
        uint256 pairedTokenId;  // the counterpart SBT (invariant I2)
        bool    forceExpired;   // set by owner to slash / early-terminate a vouch
        string  metadataCID;    // optional IPFS CID for off-chain metadata
    }

    struct ReputationRequest {
        address borrower;
        string  description;
        uint256 duration;    // seconds the vouch should remain locked
        bool    fulfilled;   // true once a backer has vouched (I4: cannot be re-fulfilled)
        uint256 githubScore; // must be >= MIN_GITHUB_SCORE (I6)
        uint256 stake;       // ETH sent with createRequest (held as borrower skin-in-game)
    }

    // ─────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────

    uint256 public tokenIdCounter;
    uint256 public requestCounter;

    mapping(uint256 => Vouch)             public vouches;
    mapping(uint256 => ReputationRequest) public requests;

    /// @notice Maps each borrower address to their most recent request ID.
    mapping(address => uint256) public lastRequestId;

    /// @notice Tracks the counterpart token for each SBT (invariant I2).
    mapping(uint256 => uint256) public tokenPairs;

    // ─────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────

    event RequestCreated(uint256 indexed id, address indexed borrower);
    event VouchCreated(uint256 indexed backerTokenId, uint256 indexed borrowerTokenId);
    event VouchReleased(uint256 indexed tokenId, address indexed backer, uint256 amount);
    event VouchForceExpired(uint256 indexed tokenId, address indexed byOwner);

    // ─────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────

    constructor() ERC721("RepuFi", "RFI") Ownable(msg.sender) {}

    // =============================================================
    // PART 1 — REQUEST CREATION
    // =============================================================

    /**
     * @notice A borrower declares they want reputation-backed trust.
     *
     * FIX 1: Enforce MIN_GITHUB_SCORE — the constant existed but was never checked.
     *         Without this, any score (even 0) could be submitted, breaking I6.
     *
     * FIX 2: Prevent overwriting an active, unfulfilled request.
     *         Without this, a borrower could replace their pending request mid-flow,
     *         causing a backer who read the old request to vouch against stale data.
     *
     * @param description  Human-readable context for backers.
     * @param duration     How long (seconds) funds should be locked once vouched.
     * @param githubScore  Off-chain reputation score; must be >= MIN_GITHUB_SCORE.
     */
    function createRequest(
        string calldata description,
        uint256 duration,
        uint256 githubScore
    ) external payable {

        // FIX 1 — github score gate
        if (githubScore < MIN_GITHUB_SCORE) {
            revert("score too low");
        }

        // Basic fee check
        if (msg.value < REPUTATION_REQUEST_FEE) {
            revert("insufficient fee");
        }

        // FIX 2 — prevent overwriting an open, unfulfilled request
        uint256 existingId = lastRequestId[msg.sender];
        if (existingId != 0 && !requests[existingId].fulfilled) {
            revert("existing open request");
        }

        uint256 id = ++requestCounter;

        requests[id] = ReputationRequest({
            borrower:    msg.sender,
            description: description,
            duration:    duration,
            fulfilled:   false,
            githubScore: githubScore,
            stake:       msg.value
        });

        lastRequestId[msg.sender] = id;

        emit RequestCreated(id, msg.sender);
    }

    // =============================================================
    // PART 2 — VOUCHING
    // =============================================================

    /**
     * @notice A backer stakes ETH to vouch for a borrower.
     *
     * FIX 3: Check r.fulfilled before proceeding — prevents double-vouching (I4).
     *         The original code only checked r.borrower != address(0), which does not
     *         mean the request is still open.
     *
     * FIX 4: Block self-vouch (backer == borrower) — violates I5 and lets anyone
     *         mint free SBTs for themselves with no real counterparty.
     *
     * FIX 5: Mark r.fulfilled = true BEFORE calling _createVouch.
     *         Even with ReentrancyGuard, state should update before any external
     *         interactions (mint calls onERC721Received on arbitrary contracts).
     *
     * @param borrower  Address whose most-recent unfulfilled request to fulfil.
     */
    function vouch(address borrower) external payable nonReentrant {

        // FIX 4 — no self-vouching
        if (msg.sender == borrower) {
            revert("cannot vouch for yourself");
        }

        uint256 id = lastRequestId[borrower];
        ReputationRequest storage r = requests[id];

        // Original check was incomplete — address(0) only catches "no request ever"
        if (r.borrower == address(0)) {
            revert("no request found");
        }

        // FIX 3 — reject already-fulfilled requests
        if (r.fulfilled) {
            revert("request already fulfilled");
        }

        if (msg.value == 0) {
            revert("must send ETH to vouch");
        }

        // FIX 5 — flip state BEFORE any external call (mint)
        r.fulfilled = true;

        _createVouch(borrower, r.duration);
    }

    // =============================================================
    // PART 3 — CORE VOUCH LOGIC
    // =============================================================

    /**
     * @dev Mints a paired SBT for backer and borrower and records the Vouch.
     *
     * FIX 6: Write vouches[id2] — the original contract stored only the backer's
     *         side, leaving the borrower's token with no Vouch entry. This breaks
     *         invariant I1 and means release() cannot find the paired token.
     *
     * FIX 7: Mint the borrower's token (id2) — without this the borrower receives
     *         no SBT, so the "proof of trust" is one-sided and invisible on-chain.
     *
     * FIX 8: Record tokenPairs[id1] and tokenPairs[id2] so release() can
     *         invalidate both sides atomically (invariant I2).
     *
     * FIX 9: Guard against ETH amount exceeding uint128 to prevent silent truncation.
     *         If msg.value > type(uint128).max the cast would silently record a wrong
     *         amount and the backer would lose ETH on withdrawal.
     */
    function _createVouch(address borrower, uint256 duration) internal {

        // FIX 9 — safe downcast guard
        if (msg.value > type(uint128).max) {
            revert("stake exceeds uint128");
        }

        uint256 id1 = ++tokenIdCounter; // backer's token
        uint256 id2 = ++tokenIdCounter; // borrower's token

        uint256 expiry = block.timestamp + duration;

        // Backer's vouch record
        vouches[id1] = Vouch({
            backer:       msg.sender,
            borrower:     borrower,
            amount:       uint128(msg.value),
            expiry:       expiry,
            withdrawn:    false,
            pairedTokenId: id2,
            forceExpired: false,
            metadataCID:  ""
        });

        // FIX 6 — borrower's vouch record (mirrors id1, points back to id1)
        vouches[id2] = Vouch({
            backer:       msg.sender,
            borrower:     borrower,
            amount:       uint128(msg.value),  // same stake recorded on both sides
            expiry:       expiry,
            withdrawn:    false,
            pairedTokenId: id1,
            forceExpired: false,
            metadataCID:  ""
        });

        // FIX 8 — pair tracking (invariant I2)
        tokenPairs[id1] = id2;
        tokenPairs[id2] = id1;

        // Mint backer's SBT
        _safeMint(msg.sender, id1);

        // FIX 7 — mint borrower's SBT
        _safeMint(borrower, id2);

        emit VouchCreated(id1, id2);
    }

    // =============================================================
    // PART 4 — WITHDRAWAL / RELEASE
    // =============================================================

    /**
     * @notice Backer reclaims staked ETH after the vouch period expires
     *         (or after a force-expiry by the owner).
     *
     * FIX 10: Enforce that caller is the backer — anyone could drain ETH otherwise.
     *
     * FIX 11: Enforce expiry or forceExpired. Without this check, the backer could
     *         withdraw immediately after vouching, defeating the lock-up mechanism.
     *
     * FIX 12: Mark the paired token withdrawn atomically (invariant I3).
     *         The original code only marked the called token, leaving the paired token
     *         in a "not withdrawn" state that could be exploited.
     *
     * @param tokenId  The backer's token (id1).
     */
    function release(uint256 tokenId) external nonReentrant {

        Vouch storage v = vouches[tokenId];

        // FIX 10 — only the backer may release their own stake
        if (v.backer != msg.sender) {
            revert("not the backer");
        }

        // Guard: check withdrawn on caller's token
        if (v.withdrawn) {
            revert("already withdrawn");
        }

        // FIX 11 — time lock: funds are locked until expiry OR force-expired by owner
        if (block.timestamp < v.expiry && !v.forceExpired) {
            revert("vouch period not over");
        }

        // FIX 12 — mark BOTH sides withdrawn atomically (invariant I3)
        v.withdrawn = true;
        uint256 paired = tokenPairs[tokenId];
        if (paired != 0) {
            vouches[paired].withdrawn = true;
        }

        uint256 amount = v.amount;

        emit VouchReleased(tokenId, msg.sender, amount);

        // Transfer ETH to backer last (checks-effects-interactions)
        (bool ok,) = v.backer.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    // =============================================================
    // PART 4b — FORCE EXPIRY (owner slash mechanism)
    // =============================================================

    /**
     * @notice Protocol owner can mark a vouch as force-expired.
     *         This allows the backer to withdraw early — used when a vouch is
     *         challenged and deemed fraudulent (slash logic would extend this).
     *
     * @param tokenId  Either side of the paired vouch.
     */
    function forceExpire(uint256 tokenId) external onlyOwner {
        Vouch storage v = vouches[tokenId];
        if (v.backer == address(0)) revert("vouch not found");
        if (v.withdrawn) revert("already withdrawn");

        v.forceExpired = true;
        uint256 paired = tokenPairs[tokenId];
        if (paired != 0) {
            vouches[paired].forceExpired = true;
        }

        emit VouchForceExpired(tokenId, msg.sender);
    }

    // =============================================================
    // PART 5 — SBT (SOULBOUND) TRANSFER LOCK
    // =============================================================

    /**
     * @dev Override ERC721 _update to block all transfers.
     *      Mints (from == address(0)) and burns (to == address(0)) are allowed.
     *      Any lateral transfer (from != 0 && to != 0) is rejected.
     *
     *      The original logic was correct for this check, but is preserved here
     *      with a clearer revert message.
     *
     * NOTE: _ownerOf override calling super._ownerOf is correct — ERC721 already
     *       stores owner data internally. The custom override added no value and
     *       was misleadingly annotated as "WRONG". It is removed here.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {

        address from = _ownerOf(tokenId);

        // Block transfers; allow mint (from==0) and burn (to==0)
        if (from != address(0) && to != address(0)) {
            revert("RepuFiSBT: soulbound — transfers disabled");
        }

        return super._update(to, tokenId, auth);
    }

    // =============================================================
    // UTILITIES
    // =============================================================

    /**
     * @notice Returns whether a vouch is currently active
     *         (not withdrawn, not expired, not force-expired).
     */
    function isVouchActive(uint256 tokenId) external view returns (bool) {
        Vouch storage v = vouches[tokenId];
        if (v.backer == address(0)) return false;
        if (v.withdrawn)            return false;
        if (v.forceExpired)         return false;
        if (block.timestamp >= v.expiry) return false;
        return true;
    }

    /**
     * @notice Owner can withdraw the accumulated protocol fees
     *         (the REPUTATION_REQUEST_FEE amounts paid by borrowers).
     */
    function withdrawFees() external onlyOwner {
        (bool ok,) = owner().call{value: address(this).balance}("");
        require(ok, "fee withdrawal failed");
    }

    receive() external payable {}
}