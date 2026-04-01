// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    ⚠️ You are NOT supposed to just "complete functions".
    ⚠️ You are supposed to UNDERSTAND the system.

    Some logic is:
    - Missing
    - Misleading
    - Slightly wrong

    Fixing blindly will break invariants.

    Think before you write.
*/

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract RepuFiSBT is ERC721, Ownable, ReentrancyGuard {

    uint256 public constant REPUTATION_REQUEST_FEE = 0.0001 ether;
    uint256 public constant MIN_GITHUB_SCORE = 7;

    struct Vouch {
        address backer;
        address borrower;
        uint128 amount;
        uint256 expiry;
        bool withdrawn;
        uint256 pairedTokenId;
        bool forceExpired;
        string metadataCID;
    }

    struct ReputationRequest {
        address borrower;
        string description;
        uint256 duration;
        bool fulfilled;
        uint256 githubScore;
        uint256 stake;
    }

    uint256 public tokenIdCounter;
    uint256 public requestCounter;

    mapping(uint256 => Vouch) public vouches;
    mapping(uint256 => ReputationRequest) public requests;
    mapping(address => uint256) public lastRequestId;

    // ⚠️ Missing mappings on purpose
    // mapping(uint256 => uint256) public tokenPairs;
    // mapping(uint256 => address) public tokenOwners;

    event RequestCreated(uint256 id, address borrower);
    event VouchCreated(uint256 id1, uint256 id2);

    constructor() ERC721("RepuFi", "RFI") Ownable(msg.sender) {}

    // =============================================================
    // 🧾 PART 1: REQUEST CREATION
    // =============================================================

    function createRequest(
        string calldata description,
        uint256 duration,
        uint256 githubScore
    ) external payable {

        // ❌ Missing validation(s)
        // ❓ What assumptions does system make about score?

        if (msg.value < REPUTATION_REQUEST_FEE) {
            revert("fee?");
        }

        uint256 id = ++requestCounter;

        requests[id] = ReputationRequest({
            borrower: msg.sender,
            description: description,
            duration: duration,
            fulfilled: false,
            githubScore: githubScore,
            stake: msg.value
        });

        lastRequestId[msg.sender] = id;

        emit RequestCreated(id, msg.sender);
    }

    // =============================================================
    // 💰 PART 2: VOUCHING
    // =============================================================

    function vouch(address borrower) external payable {

        uint256 id = lastRequestId[borrower];
        ReputationRequest storage r = requests[id];

        // ❌ This check is incomplete
        if (r.borrower == address(0)) {
            revert("no request");
        }

        // ❓ Is this enough?
        if (msg.value == 0) revert();

        // ❌ Missing critical state change?

        _createVouch(borrower, r.duration);

        r.fulfilled = true;
    }

    // =============================================================
    // 🔗 PART 3: CORE VOUCH LOGIC (MOST IMPORTANT)
    // =============================================================

    function _createVouch(address borrower, uint256 duration) internal {

        // ❌ Some validations intentionally missing
        // ❓ Should msg.sender == borrower be allowed?

        uint256 id1 = ++tokenIdCounter;
        uint256 id2 = ++tokenIdCounter;

        uint256 expiry = block.timestamp + duration;

        // ❌ Only ONE side stored → inconsistent state
        vouches[id1] = Vouch({
            backer: msg.sender,
            borrower: borrower,
            amount: uint128(msg.value),
            expiry: expiry,
            withdrawn: false,
            pairedTokenId: id2,
            forceExpired: false,
            metadataCID: ""
        });

        // ❌ Second vouch missing OR incorrect?
        // vouches[id2] = ????

        // Minting
        _safeMint(msg.sender, id1);

        // ❌ Borrower token missing?

        // ❌ Pair tracking missing

        emit VouchCreated(id1, id2);
    }

    // =============================================================
    // ⏳ PART 4: WITHDRAWAL
    // =============================================================

    function release(uint256 tokenId) external nonReentrant {

        Vouch storage v = vouches[tokenId];

        // ❌ Incomplete validation
        if (v.withdrawn) revert();

        // ❓ expiry logic missing?
        // ❓ forceExpire case?

        // ❌ Who should be allowed to call this?

        v.withdrawn = true;

        // ❌ Paired token NOT handled → critical bug

        // ❌ Transfer logic naive
        (bool ok,) = v.backer.call{value: v.amount}("");
        require(ok);

    }

    // =============================================================
    // 🔒 PART 5: SBT LOGIC
    // =============================================================

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {

        address from = _ownerOf(tokenId);

        // ❌ This logic is subtly incomplete
        if (from != address(0) && to != address(0)) {
            revert("non transferable");
        }

        return super._update(to, tokenId, auth);
    }

    function _ownerOf(uint256 tokenId) internal view override returns (address) {
        // ❌ This is WRONG but compiles
        return super._ownerOf(tokenId);
    }
}