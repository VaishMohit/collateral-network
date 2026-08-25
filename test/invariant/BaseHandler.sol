// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TestBase} from "../TestBase.sol";
import {LibConstants as C} from "../../script/LibConstants.sol";
import {CustodyRegistry} from "../../src/CustodyRegistry.sol";
import {AttestationRegistry} from "../../src/AttestationRegistry.sol";
import {CollateralManager} from "../../src/CollateralManager.sol";

/**
 * @title BaseHandler
 * @notice Shared invariant-test harness. Deploys the full network, then exposes
 *         weighted `action*` entry points that the Foundry invariant fuzzer
 *         composes into random call sequences.
 *
 * @dev The only fuzz target is `address(this)`: every mutation flows through
 *      these actions, never directly into the workflow contracts.
 *
 *      `fail_on_revert = true` (foundry.toml) means an action whose underlying
 *      call reverts fails the run. Every action therefore checks its own
 *      preconditions and returns early instead of reverting.
 *
 *      Ghost state mirrors expected on-chain state; invariant suites compare
 *      the two. `_setStatus` polices transitions — any edge outside the legal
 *      set reverts, which fail_on_revert surfaces as a failed run.
 */
abstract contract BaseHandler is TestBase {
    // CollateralStatus mirror (uint8) — order matches the on-chain enum.
    uint8 internal constant S_AVAILABLE = 0;
    uint8 internal constant S_RESERVED = 1;
    uint8 internal constant S_PLEDGED = 2;
    uint8 internal constant S_RELEASE_REQUESTED = 3;
    uint8 internal constant S_RELEASED = 4;
    uint8 internal constant S_DEFAULTED = 5;
    uint8 internal constant S_RECOVERY = 6;

    bytes32 internal marginObligation = keccak256(abi.encode("HANDLER-MARGIN-OBLIGATION"));

    // Fuzzable indices: two assets, two banks.
    bytes32[2] internal assetIds;
    address[2] internal banks;

    uint256 internal priceNonce;
    uint256 internal renewalCounter;

    // ------------------------------------------------------------------
    // Ghost state
    // ------------------------------------------------------------------

    struct GhostPosition {
        bytes32 positionId;
        bytes32 assetId;
        address provider;
        address receiver;
        bytes32 repoId; // obligation this position is linked to (0 if none)
        uint256 quantity;
        uint8 status;
        bool pendingSub;
        bool exists;
    }

    struct GhostRepo {
        bytes32 repoId;
        address borrower;
        address lender;
        uint256 cashAmount;
        uint256 maturity;
        bool active; // settled, not yet closed/defaulted
        bool closed;
        bool defaulted;
        bool exists;
    }

    bytes32[] internal positionIds;
    mapping(bytes32 => GhostPosition) internal ghosts;

    bytes32[] internal repoIds;
    mapping(bytes32 => GhostRepo) internal ghostRepos;

    /// (assetId, owner) pairs ever touched — iteration keys for ledger/custody.
    bytes32[] internal custodyKeysA;
    address[] internal custodyKeysO;
    mapping(bytes32 => mapping(address => bool)) internal custodyKeyTracked;

    /// Cumulative quantity per (asset, provider) removed from the pool via
    /// enforcement (tokens leave the vault to the entitled party).
    mapping(bytes32 => mapping(address => uint256)) internal enforcedOut;

    /// Cumulative quantity per (asset, owner) received via enforcement.
    mapping(bytes32 => mapping(address => uint256)) internal enforcedIn;

    /// old position => replacement while a substitution is pending.
    mapping(bytes32 => bytes32) internal pendingReplacementOf;

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    function setUp() public virtual {
        _deployHandlerNetwork();
        targetContract(address(this));
    }

    function _deployHandlerNetwork() internal {
        _deployNetwork();

        assetIds[0] = C.T_BOND;
        assetIds[1] = C.CORP_BOND;
        banks[0] = bankA;
        banks[1] = bankB;
        priceNonce = 1;

        vm.startPrank(admin);
        tBondToken.mint(bankA, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankA, C.CORP_BOND_QUANTITY);
        tBondToken.mint(bankB, C.T_BOND_QUANTITY);
        corpBondToken.mint(bankB, C.CORP_BOND_QUANTITY);
        vm.stopPrank();

        for (uint256 b = 0; b < 2; b++) {
            _attest(C.T_BOND, banks[b], C.T_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
            _attest(C.CORP_BOND, banks[b], C.CORP_BOND_QUANTITY, custodianA, C.PK_CUSTODIAN_A);
            if (!complianceRegistry.isCompliant(banks[b])) _submitCompliance(banks[b]);
            _trackCustodyKey(C.T_BOND, banks[b]);
            _trackCustodyKey(C.CORP_BOND, banks[b]);
        }
        _submitPriceTracked(C.T_BOND, C.T_BOND_PRICE);
        _submitPriceTracked(C.CORP_BOND, C.CORP_BOND_PRICE);

        // Dedicated margin obligation: half of Bank A's treasury pledged to
        // Bank B; requirement just below live value so a modest price drop
        // triggers a margin call and a recovery satisfies it.
        bytes32 marginPosId = _pledge(C.T_BOND, C.T_BOND_QUANTITY / 2, bankB, marginObligation);
        vm.prank(bankB);
        marginManager.setRequirement(marginObligation, 45_000_000);

        ghosts[marginPosId] = GhostPosition({
            positionId: marginPosId,
            assetId: C.T_BOND,
            provider: bankA,
            receiver: bankB,
            repoId: marginObligation,
            quantity: C.T_BOND_QUANTITY / 2,
            status: S_PLEDGED,
            pendingSub: false,
            exists: true
        });
        positionIds.push(marginPosId);
    }

    // ------------------------------------------------------------------
    // Fuzz actions
    // ------------------------------------------------------------------

    /// Full pledge lifecycle for a random (asset, provider, quantity).
    function actionPledge(uint256 assetSeed, uint256 providerSeed, uint256 quantitySeed) public {
        bytes32 asset = assetIds[bound(assetSeed, 0, 1)];
        uint256 pIdx = bound(providerSeed, 0, 1);
        address provider = banks[pIdx];
        address receiver = banks[1 - pIdx];

        _refreshMarketData();
        if (!eligibility.isEligible(asset, provider)) return; // e.g. asset matured

        uint256 avail = collateralManager.availableQuantity(asset, provider);
        if (avail == 0) return;
        uint256 quantity = bound(quantitySeed, 1, avail);

        vm.prank(provider);
        bytes32 positionId = pledgeManager.requestPledge(asset, quantity, receiver, bytes32(0));
        vm.prank(collateralAgent);
        pledgeManager.verifyCollateral(positionId);
        vm.prank(provider);
        pledgeManager.reserveCollateral(positionId);
        vm.prank(receiver);
        pledgeManager.approvePledge(positionId);
        vm.prank(provider);
        pledgeManager.finalizePledge(positionId);

        ghosts[positionId] = GhostPosition({
            positionId: positionId,
            assetId: asset,
            provider: provider,
            receiver: receiver,
            repoId: bytes32(0),
            quantity: quantity,
            status: S_PLEDGED,
            pendingSub: false,
            exists: true
        });
        positionIds.push(positionId);
        _trackCustodyKey(asset, provider);
    }

    /// PLEDGED -> RELEASE_REQUESTED. Unlinked positions only: repo collateral
    /// exits through repay/default so obligation bookkeeping stays exact.
    function actionRequestRelease(uint256 positionSeed) public {
        bytes32 pid = _pickWithStatus(positionSeed, S_PLEDGED);
        if (pid == bytes32(0)) return;
        GhostPosition storage g = ghosts[pid];
        if (g.repoId != bytes32(0) || g.pendingSub) return;
        vm.prank(g.provider);
        pledgeManager.requestRelease(g.positionId);
        _setStatus(g.positionId, S_RELEASE_REQUESTED);
    }

    /// RELEASE_REQUESTED -> RELEASED via agent approval.
    function actionApproveRelease(uint256 positionSeed) public {
        bytes32 pid = _pickWithStatus(positionSeed, S_RELEASE_REQUESTED);
        if (pid == bytes32(0)) return;
        GhostPosition storage g = ghosts[pid];
        vm.prank(collateralAgent);
        pledgeManager.approveRelease(g.positionId);
        _setStatus(g.positionId, S_RELEASED);
    }

    /// Start a substitution against a PLEDGED position: create + validate +
    /// reserve a replacement sized to cover the old position's CURRENT value.
    function actionStartSubstitution(uint256 oldSeed, uint256 newAssetSeed, uint256 quantitySeed) public {
        bytes32 oldId = _pickWithStatus(oldSeed, S_PLEDGED);
        if (oldId == bytes32(0)) return;
        GhostPosition storage old = ghosts[oldId];
        if (old.pendingSub) return;

        bytes32 newAsset = assetIds[bound(newAssetSeed, 0, 1)];
        address provider = old.provider;
        _refreshMarketData();
        if (!eligibility.isEligible(newAsset, provider)) return;

        (, uint256 oldValue) = eligibility.getCollateralValue(old.assetId, old.quantity);
        (uint256 newPrice, ) = oracle.peekPrice(newAsset);
        uint256 perUnit = (newPrice * (10_000 - eligibility.getHaircut(newAsset))) / 10_000;
        if (perUnit == 0) return;

        uint256 avail = collateralManager.availableQuantity(newAsset, provider);
        // Minimum quantity whose collateral value covers the old position's
        // current value (+1 unit of headroom against floor rounding).
        uint256 qMin = oldValue / perUnit + 1;
        if (avail < qMin) return;
        uint256 quantity = qMin + bound(quantitySeed, 0, avail - qMin);

        vm.prank(provider);
        bytes32 replId = pledgeManager.requestSubstitution(old.positionId, newAsset, quantity);
        vm.prank(collateralAgent);
        pledgeManager.validateReplacement(replId);
        vm.prank(provider);
        pledgeManager.reserveReplacement(replId);

        ghosts[replId] = GhostPosition({
            positionId: replId,
            assetId: newAsset,
            provider: provider,
            receiver: old.receiver,
            repoId: bytes32(0),
            quantity: quantity,
            status: S_RESERVED,
            pendingSub: false,
            exists: true
        });
        positionIds.push(replId);
        _trackCustodyKey(newAsset, provider);
        old.pendingSub = true;
        pendingReplacementOf[old.positionId] = replId;
    }

    /// Finish (activate or cancel) a pending substitution.
    function actionFinishSubstitution(uint256 oldSeed, bool cancel) public {
        bytes32 oldId = _pickPendingSub(oldSeed);
        if (oldId == bytes32(0)) return;
        GhostPosition storage old = ghosts[oldId];
        bytes32 replId = pendingReplacementOf[old.positionId];
        GhostPosition storage repl = ghosts[replId];

        if (cancel) {
            vm.prank(old.provider);
            pledgeManager.cancelSubstitution(old.positionId);
            _setStatus(replId, S_AVAILABLE);
        } else {
            vm.prank(old.provider);
            pledgeManager.activateSubstitution(old.positionId);
            _setStatus(old.positionId, S_RELEASED);
            _setStatus(replId, S_PLEDGED);
            // Replacement inherits the old position's obligation linkage.
            repl.repoId = old.repoId;
        }
        old.pendingSub = false;
        delete pendingReplacementOf[old.positionId];
    }

    /// Create + DvP-settle a repo against an unlinked PLEDGED position.
    function actionCreateRepo(uint256 positionSeed, uint256 amountSeed, uint256 rateSeed, uint256 tenorSeed) public {
        bytes32 pid = _pickWithStatus(positionSeed, S_PLEDGED);
        if (pid == bytes32(0)) return;
        GhostPosition storage g = ghosts[pid];
        if (g.repoId != bytes32(0)) return;

        CollateralManager.CollateralPosition memory p = collateralManager.getPosition(g.positionId);
        if (p.collateralValue == 0) return;

        uint256 cashAmount = bound(amountSeed, 1, p.collateralValue);
        uint256 rate = bound(rateSeed, 0, 2000); // <= 20% annual
        uint256 tenor = bound(tenorSeed, 1 hours, 30 days);

        address borrower = g.provider;
        address lender = g.receiver;

        vm.prank(borrower);
        bytes32 repoId = repoManager.createRepo(borrower, lender, g.positionId, cashAmount, rate, tenor);
        _ensureCash(lender, cashAmount);
        vm.prank(lender);
        cash.approve(address(settlement), cashAmount);
        vm.prank(borrower);
        repoManager.settleRepo(repoId);

        ghostRepos[repoId] = GhostRepo({
            repoId: repoId,
            borrower: borrower,
            lender: lender,
            cashAmount: cashAmount,
            maturity: block.timestamp + tenor,
            active: true,
            closed: false,
            defaulted: false,
            exists: true
        });
        repoIds.push(repoId);
        g.repoId = repoId;
    }

    /// Warp past maturity and repay an ACTIVE repo, releasing its collateral.
    function actionRepayRepo(uint256 repoSeed) public {
        bytes32 repoId = _pickActiveRepo(repoSeed);
        if (repoId == bytes32(0)) return;
        GhostRepo storage r = ghostRepos[repoId];
        _warpTo(r.maturity + 1);

        uint256 owed = repoManager.amountOwed(r.repoId);
        _ensureCash(r.borrower, owed);
        vm.startPrank(r.borrower);
        cash.approve(address(repoManager), owed);
        uint256 repaid = repoManager.repayAndClose(r.repoId);
        vm.stopPrank();
        assertEq(repaid, owed, "repaid != principal+interest");

        r.active = false;
        r.closed = true;
        _transitionLinked(r.repoId, S_PLEDGED, S_RELEASED);
    }

    /// Warp past maturity and default an ACTIVE repo.
    function actionDefaultRepo(uint256 repoSeed) public {
        bytes32 repoId = _pickActiveRepo(repoSeed);
        if (repoId == bytes32(0)) return;
        GhostRepo storage r = ghostRepos[repoId];
        _warpTo(r.maturity + 1);

        vm.prank(r.lender);
        repoManager.defaultRepo(r.repoId);

        r.active = false;
        r.defaulted = true;
        _transitionLinked(r.repoId, S_PLEDGED, S_DEFAULTED);
    }

    /// Post-default enforcement: locked securities move to the lender.
    function actionEnforce(uint256 repoSeed) public {
        bytes32 repoId = _pickDefaultedRepo(repoSeed);
        if (repoId == bytes32(0)) return;
        GhostRepo storage r = ghostRepos[repoId];

        bytes32 posId = _firstLinkedWithStatus(r.repoId, S_DEFAULTED);
        if (posId == bytes32(0)) return;
        GhostPosition storage g = ghosts[posId];

        vm.prank(settlementAgent);
        settlement.enforceCollateral(posId, r.lender);
        _setStatus(posId, S_RECOVERY);
        enforcedOut[g.assetId][g.provider] += g.quantity;
        enforcedIn[g.assetId][r.lender] += g.quantity;
    }

    /// Refresh prices to seeded values, optionally move the requirement, then
    /// drive the margin-call lifecycle (create on shortfall, satisfy on cure).
    function actionMarginCycle(uint256 tPriceSeed, uint256 cPriceSeed, uint256 requirementSeed) public {
        _submitPriceTracked(C.T_BOND, bound(tPriceSeed, 8_000, 12_000));
        _submitPriceTracked(C.CORP_BOND, bound(cPriceSeed, 8_000, 12_000));
        _refreshMarketData();

        if (bound(requirementSeed, 0, 999) < 200) {
            vm.prank(bankB);
            marginManager.setRequirement(marginObligation, bound(requirementSeed, 10_000_000, 80_000_000));
        }

        uint256 live = collateralManager.liveCollateralValueForObligation(marginObligation);
        uint256 required = marginManager.getRequirement(marginObligation);
        bool callActive = marginManager.getMarginStatus(marginObligation).active;

        if (live < required && !callActive) {
            vm.prank(bankB);
            marginManager.createMarginCall(marginObligation);
        } else if (callActive && live >= required) {
            vm.prank(bankB);
            marginManager.satisfyMarginCall(marginObligation);
        }
    }

    // ------------------------------------------------------------------
    // Ghost helpers
    // ------------------------------------------------------------------

    function _setStatus(bytes32 positionId, uint8 to) internal {
        GhostPosition storage g = ghosts[positionId];
        require(_legalTransition(g.status, to), "illegal status transition");
        g.status = to;
    }

    function _legalTransition(uint8 from, uint8 to) internal pure returns (bool) {
        if (from == S_RELEASED || from == S_RECOVERY) return false; // terminal
        if (from == S_AVAILABLE && to == S_RESERVED) return true;
        if (from == S_RESERVED && to == S_AVAILABLE) return true; // cancel paths
        if (from == S_RESERVED && to == S_PLEDGED) return true;
        if (from == S_PLEDGED && to == S_RELEASE_REQUESTED) return true;
        if (from == S_PLEDGED && to == S_RELEASED) return true;
        if (from == S_PLEDGED && to == S_DEFAULTED) return true;
        if (from == S_RELEASE_REQUESTED && to == S_RELEASED) return true;
        if (from == S_RELEASE_REQUESTED && to == S_DEFAULTED) return true;
        if (from == S_DEFAULTED && to == S_RECOVERY) return true;
        return false;
    }

    /// Pick a tracked position in exactly `status`, skipping positions whose
    /// exit path is the repo lifecycle (linked PLEDGED) or a pending substitution.
    /// Returns bytes32(0) when no candidate matches.
    function _pickWithStatus(uint256 seed, uint8 status) internal view returns (bytes32) {
        uint256 n = positionIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            GhostPosition storage cand = ghosts[positionIds[(start + i) % n]];
            if (!cand.exists || cand.status != status) continue;
            if (cand.pendingSub) continue;
            if (status == S_PLEDGED && cand.repoId != bytes32(0)) continue;
            return cand.positionId;
        }
        return bytes32(0);
    }

    function _pickPendingSub(uint256 seed) internal view returns (bytes32) {
        uint256 n = positionIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            GhostPosition storage cand = ghosts[positionIds[(start + i) % n]];
            if (cand.exists && cand.pendingSub) return cand.positionId;
        }
        return bytes32(0);
    }

    function _pickActiveRepo(uint256 seed) internal view returns (bytes32) {
        uint256 n = repoIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            GhostRepo storage cand = ghostRepos[repoIds[(start + i) % n]];
            if (cand.exists && cand.active) return cand.repoId;
        }
        return bytes32(0);
    }

    function _pickDefaultedRepo(uint256 seed) internal view returns (bytes32) {
        uint256 n = repoIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            GhostRepo storage cand = ghostRepos[repoIds[(start + i) % n]];
            if (cand.exists && cand.defaulted) return cand.repoId;
        }
        return bytes32(0);
    }

    function _transitionLinked(bytes32 repoId, uint8 fromStatus, uint8 toStatus) internal {
        for (uint256 i = 0; i < positionIds.length; i++) {
            GhostPosition storage g = ghosts[positionIds[i]];
            if (g.exists && g.repoId == repoId && g.status == fromStatus) {
                _setStatus(g.positionId, toStatus);
            }
        }
    }

    function _firstLinkedWithStatus(bytes32 repoId, uint8 status) internal view returns (bytes32) {
        for (uint256 i = 0; i < positionIds.length; i++) {
            GhostPosition storage g = ghosts[positionIds[i]];
            if (g.exists && g.repoId == repoId && g.status == status) return g.positionId;
        }
        return bytes32(0);
    }

    function _trackCustodyKey(bytes32 assetId, address owner) internal {
        if (!custodyKeyTracked[assetId][owner]) {
            custodyKeyTracked[assetId][owner] = true;
            custodyKeysA.push(assetId);
            custodyKeysO.push(owner);
        }
    }

    function _warpTo(uint256 t) internal {
        if (t > block.timestamp) vm.warp(t);
    }

    function _ensureCash(address who, uint256 amount) internal {
        uint256 bal = cash.balanceOf(who);
        if (bal < amount) {
            vm.prank(admin);
            cash.mint(who, amount - bal);
        }
    }

    function _submitPriceTracked(bytes32 assetId, uint256 price) internal {
        _submitPrice(assetId, price, priceNonce++);
    }

    /**
     * @notice Keep compliance alive, attestations valid, prices fresh.
     * @dev Attestation renewal carries the CURRENT encumbered quantity — the
     *      real CSD attests the encumbrance it observes; resetting it to zero
     *      would desynchronize the custody mirror from the vault.
     */
    function _refreshMarketData() internal {
        for (uint256 b = 0; b < 2; b++) {
            if (!complianceRegistry.isCompliant(banks[b])) _submitCompliance(banks[b]);
            for (uint256 a = 0; a < 2; a++) {
                bytes32 asset = assetIds[a];
                if (!eligibility.isEligible(asset, banks[b])) {
                    CustodyRegistry.CustodyState memory cs = custodyRegistry.getCustodyState(asset, banks[b]);
                    AttestationRegistry.AssetAttestation memory att;
                    // Unique id: two renewals may land in the same block, and
                    // the registry rejects duplicate attestation ids.
                    att.attestationId = keccak256(
                        abi.encode("CUSTODY-RENEWAL", asset, banks[b], cs.totalQuantity, renewalCounter++)
                    );
                    att.assetId = asset;
                    att.subject = banks[b];
                    att.owner = banks[b];
                    att.custodian = custodianA;
                    att.quantity = cs.totalQuantity;
                    att.encumberedQuantity = cs.encumberedQuantity;
                    att.timestamp = block.timestamp;
                    att.expiry = block.timestamp + C.ATTESTATION_TTL;
                    att.dataHash = keccak256(abi.encode("CSD-RECORD", asset, banks[b], cs.totalQuantity));
                    att.attestor = custodianA;
                    _submitCustodyAttestation(att, C.PK_CUSTODIAN_A);
                }
            }
        }
        _submitPriceTracked(C.T_BOND, C.T_BOND_PRICE);
        _submitPriceTracked(C.CORP_BOND, C.CORP_BOND_PRICE);
    }
}
