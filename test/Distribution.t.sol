// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/DistributionCloneFactory.sol";
import "../contracts/Distribution.sol";
import "./resources/FakePaymentToken.sol";
import "./resources/CloneCreators.sol";

/// @dev Minimal ERC1271 mock returning valid or invalid magic value
contract MockERC1271SmartAccount is IERC1271 {
    bool public valid;

    constructor(bool _valid) {
        valid = _valid;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        return valid ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

contract DistributionTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant owner = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant holderA = 0x2109709EcFa91a80626Ff3989d68F67F5B1Dd122;
    address public constant holderB = 0x3109709ECfA91A80626fF3989D68f67F5B1Dd123;
    address public constant holderC = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;
    address public constant recipient = 0x5109709EcFA91a80626ff3989d68f67F5B1dD125;
    address public constant currencyProvider = 0x6109709EcFA91A80626FF3989d68f67F5b1dd126;
    address public constant feeCollector = 0x7109709eCfa91A80626Ff3989D68f67f5b1dD127;
    address public constant trustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;

    uint8 public constant CURRENCY_DECIMALS = 6;
    // Total supply: 1000 tokens.  A=600, B=300, C=100.
    uint256 public constant SUPPLY_A = 600e18;
    uint256 public constant SUPPLY_B = 300e18;
    uint256 public constant SUPPLY_C = 100e18;
    uint256 public constant TOTAL_SUPPLY = SUPPLY_A + SUPPLY_B + SUPPLY_C;
    // 200 USDC total distribution
    uint256 public constant TOTAL_CURRENCY = 200e6;

    uint64 public reassignAfter;

    AllowList allowList;
    FakePaymentToken currency;
    Token token;
    Distribution distLogic;
    DistributionCloneFactory factory;
    Distribution dist;
    TokenProxyFactory tokenFactory;
    uint256 public snapshotId;

    function setUp() public {
        reassignAfter = uint64(block.timestamp + 31 days);

        allowList = createAllowList(trustedForwarder, admin);
        currency = new FakePaymentToken(0, CURRENCY_DECIMALS);
        vm.prank(admin);
        allowList.set(address(currency), TRUSTED_CURRENCY);

        address tokenLogic = address(new Token(trustedForwarder));
        tokenFactory = new TokenProxyFactory(tokenLogic);
        IFeeSettingsV2 feeSettings = createFeeSettings(
            trustedForwarder,
            admin,
            buildFeeTypes(0, 0, 0, admin, admin, admin)
        );
        token = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "DistToken", "DST")
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTALLOWER_ROLE(), admin);
        token.mint(holderA, SUPPLY_A);
        token.mint(holderB, SUPPLY_B);
        token.mint(holderC, SUPPLY_C);
        vm.stopPrank();

        vm.prank(admin);
        snapshotId = token.createSnapshot();

        distLogic = new Distribution(trustedForwarder);
        factory = new DistributionCloneFactory(address(distLogic));
        dist = _deployDist(bytes32(0), TOTAL_CURRENCY, reassignAfter);
    }

    /// @dev Helper: predict address, fund, and deploy a Distribution clone
    function _deployDist(bytes32 salt, uint256 totalCurrency, uint64 _reassignAfter) internal returns (Distribution) {
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snapshotId,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: totalCurrency,
            reassignAfter: _reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(salt, trustedForwarder, args);
        currency.mint(currencyProvider, totalCurrency);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, totalCurrency);
        return Distribution(factory.createDistributionClone(salt, trustedForwarder, currencyProvider, args));
    }

    // ========== D1. Constructor / Logic Contract ==========

    function testLogicContractInitializeReverts() public {
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snapshotId,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: 0,
            reassignAfter: reassignAfter
        });
        vm.expectRevert("Initializable: contract is already initialized");
        distLogic.initialize(args, currencyProvider);
    }

    function testSecondInitializeReverts() public {
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snapshotId,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: 0,
            reassignAfter: reassignAfter
        });
        vm.expectRevert("Initializable: contract is already initialized");
        dist.initialize(args, currencyProvider);
    }

    // ========== D2. initialize() — Validation & State ==========

    function testInitializeNonTrustedCurrencyReverts() public {
        FakePaymentToken badCurrency = new FakePaymentToken(0, 6);
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snapshotId,
            currency: IERC20(address(badCurrency)),
            totalCurrencyAmount: 0,
            reassignAfter: reassignAfter
        });
        vm.expectRevert("currency needs to be on the allowlist with TRUSTED_CURRENCY attribute");
        factory.createDistributionClone(bytes32("ntc"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeInsufficientAllowanceReverts() public {
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snapshotId,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: 500e6,
            reassignAfter: reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("lowA"), trustedForwarder, args);
        currency.mint(currencyProvider, 500e6);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, 499e6); // one short
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createDistributionClone(bytes32("lowA"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeStateVariables() public view {
        assertEq(address(dist.token()), address(token), "unexpected token address");
        assertEq(dist.snapshotId(), snapshotId, "unexpected snapshotId");
        assertEq(address(dist.currency()), address(currency), "unexpected currency address");
        assertEq(dist.totalCurrencyAmount(), TOTAL_CURRENCY, "unexpected totalCurrencyAmount");
        assertEq(dist.reassignAfter(), reassignAfter, "unexpected reassignAfter");
        assertEq(dist.owner(), owner, "unexpected owner");
        assertEq(currency.balanceOf(address(dist)), TOTAL_CURRENCY, "dist not fully funded");
    }

    function testInitializeZeroTotalSupplyReverts() public {
        // Take a snapshot before any tokens are minted on a fresh token
        IFeeSettingsV2 feeSettings = createFeeSettings(
            trustedForwarder,
            admin,
            buildFeeTypes(0, 0, 0, admin, admin, admin)
        );
        Token emptyToken = Token(
            tokenFactory.createTokenProxy(
                bytes32("empty"),
                trustedForwarder,
                feeSettings,
                admin,
                allowList,
                0,
                "EmptyToken",
                "EMP"
            )
        );
        vm.prank(admin);
        uint256 emptySnap = emptyToken.createSnapshot(); // total supply = 0

        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: emptyToken,
            snapshotId: emptySnap,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: TOTAL_CURRENCY,
            reassignAfter: reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("emptyDist"), trustedForwarder, args);
        currency.mint(currencyProvider, TOTAL_CURRENCY);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, TOTAL_CURRENCY);
        vm.expectRevert("snapshot has no tokens");
        factory.createDistributionClone(bytes32("emptyDist"), trustedForwarder, currencyProvider, args);
    }

    // ========== D3. eligible() — Math ==========

    function testEligibleConcreteExample() public view {
        // A: 600/1000 of 200e6 = 120e6
        assertEq(dist.eligible(holderA), 120e6, "holderA eligible amount wrong");
        // B: 300/1000 of 200e6 = 60e6
        assertEq(dist.eligible(holderB), 60e6, "holderB eligible amount wrong");
        // C: 100/1000 of 200e6 = 20e6
        assertEq(dist.eligible(holderC), 20e6, "holderC eligible amount wrong");
    }

    function testEligibleZeroBalanceIsZero() public view {
        assertEq(dist.eligible(address(42)), 0, "holder with zero balance should have zero eligible");
    }

    function testEligibleSumEqTotalCurrencyLimitedDust() public view {
        uint256 sumEligible = dist.eligible(holderA) + dist.eligible(holderB) + dist.eligible(holderC);
        assertLe(sumEligible, TOTAL_CURRENCY, "sum of eligible exceeds totalCurrencyAmount");
        // max dust = number of holders
        assertGe(sumEligible + 3, TOTAL_CURRENCY, "sum of eligible less than totalCurrencyAmount");
    }

    function testFuzzEligibleSumNeverExceedsTotal(uint128 totalCurrency, uint128 balA, uint128 balB) public {
        vm.assume(totalCurrency > 0);
        vm.assume(uint256(balA) + balB < type(uint128).max);
        uint256 balC = uint256(balA) + balB > 0 ? uint256(balA) + balB : 1;

        // Deploy a fresh token with three holders
        IFeeSettingsV2 feeSettings = createFeeSettings(
            trustedForwarder,
            admin,
            buildFeeTypes(0, 0, 0, admin, admin, admin)
        );
        Token fuzzToken = Token(
            tokenFactory.createTokenProxy(
                bytes32("fuzz"),
                trustedForwarder,
                feeSettings,
                admin,
                allowList,
                0,
                "FuzzToken",
                "FZT"
            )
        );
        vm.startPrank(admin);
        fuzzToken.grantRole(fuzzToken.MINTALLOWER_ROLE(), admin);
        if (balA > 0) fuzzToken.mint(holderA, balA);
        if (balB > 0) fuzzToken.mint(holderB, balB);
        fuzzToken.mint(holderC, balC);
        vm.stopPrank();
        vm.prank(admin);
        uint256 snap = fuzzToken.createSnapshot();

        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: fuzzToken,
            snapshotId: snap,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: totalCurrency,
            reassignAfter: reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("fuzz2"), trustedForwarder, args);
        currency.mint(currencyProvider, totalCurrency);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, totalCurrency);
        Distribution fuzzDistribution = Distribution(
            factory.createDistributionClone(bytes32("fuzz2"), trustedForwarder, currencyProvider, args)
        );

        uint256 sumE = fuzzDistribution.eligible(holderA) +
            fuzzDistribution.eligible(holderB) +
            fuzzDistribution.eligible(holderC);
        assertLe(sumE, totalCurrency, "sum of eligible exceeds totalCurrencyAmount");
        assertGe(sumE + 3, totalCurrency, "dust > number of holders");
    }

    // ========== D4. claim(address) — Direct Claim ==========

    function testClaimCorrectAmount() public {
        assertEq(currency.balanceOf(address(this)), 0, "already holding currency");
        dist.claim(recipient);
        assertEq(currency.balanceOf(address(this)), 0, "received currency");
        // msgSender is address(this), which has 0 snapshot balance → 0 currency
        // Test via holderA:
        assertEq(currency.balanceOf(recipient), 0, "recipient already holds currency");
        vm.prank(holderA);
        dist.claim(recipient);
        assertEq(currency.balanceOf(recipient), 120e6, "recipient did not receive holderA's share");
    }

    function testClaimUpdatesPayedOut() public {
        vm.prank(holderA);
        dist.claim(holderA);
        assertEq(dist.eligible(holderA), 0, "eligible should be zero after claim");
        assertEq(dist.paidOut(holderA), 120e6, "paidOut not updated after claim");
    }

    function testSecondClaimTransfersZero() public {
        vm.prank(holderA);
        dist.claim(holderA);
        uint256 balBefore = currency.balanceOf(holderA);
        vm.prank(holderA);
        dist.claim(holderA); // eligible = 0 → transfers 0, must not revert
        assertEq(currency.balanceOf(holderA), balBefore, "second claim should transfer nothing");
    }

    function testClaimRecipientDiffersFromSender() public {
        vm.prank(holderA);
        dist.claim(recipient);
        assertEq(currency.balanceOf(holderA), 0, "sender should not receive currency when recipient differs");
        assertEq(currency.balanceOf(recipient), 120e6, "recipient did not receive holderA's share");
    }

    function testMultipleHoldersClaimIndependently() public {
        vm.prank(holderA);
        dist.claim(holderA);
        vm.prank(holderB);
        dist.claim(holderB);
        vm.prank(holderC);
        dist.claim(holderC);
        assertEq(currency.balanceOf(holderA), 120e6, "holderA received wrong amount");
        assertEq(currency.balanceOf(holderB), 60e6, "holderB received wrong amount");
        assertEq(currency.balanceOf(holderC), 20e6, "holderC received wrong amount");
    }

    function testERC2771ClaimIdentifiesHolder() public {
        uint256 expected = 120e6;
        bytes memory callData = abi.encodePacked(
            abi.encodeWithSelector(bytes4(keccak256("claim(address)")), recipient),
            holderA
        );
        vm.prank(trustedForwarder);
        (bool success, ) = address(dist).call(callData);
        assertTrue(success, "ERC2771 claim call failed");
        assertEq(currency.balanceOf(recipient), expected, "recipient did not receive holderA's share via ERC2771");
    }

    // ========== D5. claim(IERC1271, ...) — ERC1271 Signature Claim ==========

    function testERC1271ValidSignatureClaims() public {
        MockERC1271SmartAccount wallet = new MockERC1271SmartAccount(true);
        // Give wallet a snapshot balance by deploying a new dist that includes its balance
        // Simpler: use the existing dist where wallet has 0 snapshot balance (eligible = 0)
        // so claim transfers 0. The key is that valid signature doesn't revert.
        dist.claim(IERC1271(address(wallet)), bytes32(0), "", recipient);
        assertEq(dist.eligible(address(wallet)), 0, "wallet with no snapshot balance should have zero eligible");
    }

    function testERC1271InvalidSignatureReverts() public {
        MockERC1271SmartAccount wallet = new MockERC1271SmartAccount(false);
        vm.expectRevert();
        dist.claim(IERC1271(address(wallet)), bytes32(0), "", recipient);
        // A wallet with a valid signature does not revert (proves signature check is the gating factor)
        MockERC1271SmartAccount validWallet = new MockERC1271SmartAccount(true);
        dist.claim(IERC1271(address(validWallet)), bytes32(0), "", recipient);
    }

    function testERC1271WithSnapshotBalanceClaims() public {
        // Deploy a new token snapshot including the wallet
        MockERC1271SmartAccount wallet = new MockERC1271SmartAccount(true);
        vm.prank(admin);
        token.mint(address(wallet), 200e18);
        vm.prank(admin);
        uint256 snap2 = token.createSnapshot();

        Distribution dist2 = _deployDistWithSnapshot(bytes32("erc1271"), snap2, TOTAL_CURRENCY);
        uint256 expected = (TOTAL_CURRENCY * 200e18) / token.totalSupplyAt(snap2);

        assertEq(currency.balanceOf(recipient), 0, "recipient has currency before");
        dist2.claim(IERC1271(address(wallet)), bytes32(0), "", recipient);
        assertEq(currency.balanceOf(recipient), expected, "recipient did not receive wallet's share via ERC1271");
    }

    /// @dev Helper to deploy a Distribution against a specific snapshot
    function _deployDistWithSnapshot(
        bytes32 salt,
        uint256 snap,
        uint256 totalCurrency
    ) internal returns (Distribution) {
        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: token,
            snapshotId: snap,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: totalCurrency,
            reassignAfter: reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(salt, trustedForwarder, args);
        currency.mint(currencyProvider, totalCurrency);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, totalCurrency);
        return Distribution(factory.createDistributionClone(salt, trustedForwarder, currencyProvider, args));
    }

    // ========== D7. reassign() ==========

    function testReassignNonOwnerReverts() public {
        vm.warp(reassignAfter);
        uint256 amount = dist.eligible(holderA);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(holderA);
        dist.reassign(holderA, holderB, amount);
    }

    function testReassignBeforeDeadlineReverts() public {
        uint256 amount = dist.eligible(holderA);
        vm.expectRevert("reassignment not yet available");
        vm.prank(owner);
        dist.reassign(holderA, holderB, amount);
    }

    function testReassignAtExactDeadlineSucceeds() public {
        vm.warp(reassignAfter);
        uint256 amount = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderB, amount);
    }

    function testFuzzReassignDeadline(uint64 warpTo) public {
        vm.assume(warpTo >= block.timestamp); // avoid warping to the past
        uint256 amount = dist.eligible(holderA);
        vm.warp(warpTo);
        assertEq(dist.eligible(holderA), amount, "holderA eligible should be non-zero before reassign");
        assertEq(dist.eligible(holderB), 60e6, "holderB eligible should be own share before reassign");
        if (warpTo < reassignAfter) {
            vm.expectRevert("reassignment not yet available");
            vm.prank(owner);
            dist.reassign(holderA, holderB, amount);
            assertEq(dist.eligible(holderA), amount, "holderA eligible should be non-zero after revert");
            assertEq(dist.eligible(holderB), 60e6, "holderB eligible should be own share after revert");
        } else {
            vm.prank(owner);
            dist.reassign(holderA, holderB, amount);
            assertEq(dist.eligible(holderA), 0, "holderA eligible should be zero after reassign");
            assertEq(dist.eligible(holderB), 60e6 + amount, "holderB eligible should include reassigned amount");
        }
    }

    function testReassignZeroAmountReverts() public {
        vm.warp(reassignAfter);
        vm.expectRevert("amount must be positive");
        vm.prank(owner);
        dist.reassign(holderA, holderB, 0);
    }

    function testReassignExceedsEligibleReverts() public {
        vm.warp(reassignAfter);
        vm.expectRevert("amount exceeds eligible");
        vm.prank(owner);
        dist.reassign(address(42), holderB, 1); // address(42) has no balance
    }

    function testReassignEffect() public {
        vm.warp(reassignAfter);
        assertEq(dist.eligible(holderA), 120e6, "holderA eligible should be 120e6 before reassign");
        assertEq(dist.eligible(holderB), 60e6, "holderB eligible should be 60e6 before reassign");
        uint256 amountA = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderB, amountA);

        assertEq(dist.eligible(holderA), 0, "holderA eligible should be zero after full reassign");
        assertEq(dist.paidOut(holderA), 120e6, "holderA paidOut not updated after reassign");
        // holderB gets own share + reassigned
        assertEq(dist.eligible(holderB), 60e6 + 120e6, "holderB eligible should include reassigned amount");
    }

    function testReassignEmitsEvent() public {
        vm.warp(reassignAfter);
        vm.expectEmit(true, true, false, true, address(dist));
        emit Distribution.Reassigned(holderA, holderB, 120e6);
        vm.prank(owner);
        dist.reassign(holderA, holderB, 120e6);
    }

    function testReassignStackingMultipleToSameRecipient() public {
        vm.warp(reassignAfter);
        uint256 amountB = dist.eligible(holderB);
        vm.prank(owner);
        dist.reassign(holderB, holderA, amountB); // A gets B's 60e6
        uint256 amountC = dist.eligible(holderC);
        vm.prank(owner);
        dist.reassign(holderC, holderA, amountC); // A gets C's 20e6

        assertEq(dist.eligible(holderA), 120e6 + 60e6 + 20e6, "holderA eligible should include all reassigned amounts");
        assertEq(dist.eligible(holderB), 0, "holderB eligible should be zero after full reassign");
        assertEq(dist.eligible(holderC), 0, "holderC eligible should be zero after full reassign");

        vm.prank(holderA);
        dist.claim(holderA);
        assertEq(
            currency.balanceOf(holderA),
            200e6,
            "holderA should receive full distribution after stacked reassigns"
        );
    }

    function testReassignSelfIsNoOp() public {
        vm.warp(reassignAfter);
        uint256 eligibleBefore = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderA, eligibleBefore); // self-reassign
        assertEq(dist.eligible(holderA), eligibleBefore, "self-reassign should leave eligible unchanged"); // unchanged
    }

    function testReassignAfterClaimReverts() public {
        vm.prank(holderA);
        dist.claim(holderA); // eligible drops to 0
        vm.warp(reassignAfter);
        vm.expectRevert("amount exceeds eligible");
        vm.prank(owner);
        dist.reassign(holderA, holderB, 1);
    }

    function testSecondReassignFromSameAddressReverts() public {
        vm.warp(reassignAfter);
        uint256 amountA = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderB, amountA);
        vm.expectRevert("amount exceeds eligible");
        vm.prank(owner);
        dist.reassign(holderA, holderC, 1); // eligible = 0 after first reassign
    }

    function testPartialReassign() public {
        vm.warp(reassignAfter);
        uint256 aliceEligible = dist.eligible(holderA); // 600e6

        vm.prank(owner);
        dist.reassign(holderA, holderB, aliceEligible / 2); // 300e6 to B
        assertEq(dist.eligible(holderA), aliceEligible / 2, "holderA eligible should be halved after partial reassign");
        assertEq(dist.eligible(holderB), 60e6 + aliceEligible / 2, "holderB eligible should include reassigned half");

        uint256 aliceRemaining = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderC, aliceRemaining); // remaining 300e6 to C
        assertEq(dist.eligible(holderA), 0, "holderA eligible should be zero after second partial reassign");
        assertEq(
            dist.eligible(holderC),
            20e6 + aliceEligible / 2,
            "holderC eligible should include reassigned remainder"
        );
    }

    function testChainedReassignAToB() public {
        // A → B → C (B has no snapshot balance)
        Distribution chainDist = _deployDist(bytes32("chain"), TOTAL_CURRENCY, reassignAfter);

        // initial state
        assertEq(chainDist.eligible(holderA), 120e6, "holderA initial eligible");
        assertEq(chainDist.eligible(holderB), 60e6, "holderB initial eligible");
        assertEq(chainDist.eligible(holderC), 20e6, "holderC initial eligible");

        vm.warp(reassignAfter);
        uint256 amountA = chainDist.eligible(holderA);
        vm.prank(owner);
        chainDist.reassign(holderA, holderB, amountA); // B now has 120+60=180e6

        // after A → B
        assertEq(chainDist.eligible(holderA), 0, "holderA eligible should be zero after first reassign");
        assertEq(chainDist.eligible(holderB), 180e6, "holderB eligible should be 180e6 after receiving A's share");
        assertEq(chainDist.eligible(holderC), 20e6, "holderC eligible should be unchanged after first reassign");

        uint256 amountB = chainDist.eligible(holderB);
        vm.prank(owner);
        chainDist.reassign(holderB, holderC, amountB); // C now has 20+180=200e6

        // after B → C
        assertEq(chainDist.eligible(holderA), 0, "holderA eligible should be zero after chained reassign");
        assertEq(chainDist.eligible(holderB), 0, "holderB eligible should be zero after chained reassign");
        assertEq(
            chainDist.eligible(holderC),
            TOTAL_CURRENCY,
            "holderC eligible should be full amount after chained reassign"
        );

        vm.prank(holderC);
        chainDist.claim(holderC);
        assertEq(
            currency.balanceOf(holderC),
            TOTAL_CURRENCY,
            "holderC should receive full distribution after chained reassign"
        );
    }

    function testChainedReassignSumOfEligibleInvariant() public {
        // After each reassign, sum of all eligible must remain constant
        uint256 sumBefore = dist.eligible(holderA) + dist.eligible(holderB) + dist.eligible(holderC);

        vm.warp(reassignAfter);
        uint256 amountA = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderB, amountA);

        uint256 sumAfter = dist.eligible(holderA) + dist.eligible(holderB) + dist.eligible(holderC);
        assertEq(sumBefore, sumAfter, "sum of eligible should be unchanged after reassign");
    }

    // ========== D8. Interaction: claim then reassign ==========

    function testClaimThenReassignReverts() public {
        vm.prank(holderA);
        dist.claim(holderA); // eligible(A) = 0
        vm.warp(reassignAfter);
        vm.expectRevert("amount exceeds eligible");
        vm.prank(owner);
        dist.reassign(holderA, holderB, 1);
    }

    // ========== D9. Interaction: reassign then claim by recipient ==========

    function testReassignThenClaimByRecipient() public {
        vm.warp(reassignAfter);
        uint256 amountA = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, holderB, amountA); // B gets 60 + 120 = 180e6

        vm.prank(holderB);
        dist.claim(holderB);
        assertEq(currency.balanceOf(holderB), 180e6, "holderB should receive own share plus reassigned amount");

        // A's paidOut covers their share: A claims 0
        vm.prank(holderA);
        dist.claim(holderA);
        assertEq(currency.balanceOf(holderA), 0, "holderA should receive nothing after full reassign");

        // total paid out ≤ totalCurrencyAmount
        assertLe(
            currency.balanceOf(holderB) + currency.balanceOf(holderA),
            TOTAL_CURRENCY,
            "total paid out exceeds totalCurrencyAmount"
        );
    }

    // ========== D10. Fuzz / Property-Based Tests ==========

    function testFuzzClaimNoDoublePay(uint8 claimOrder) public {
        // Any order of A, B, C claiming → sum of payouts ≤ totalCurrencyAmount
        address[3] memory holders = [holderA, holderB, holderC];
        // claimOrder low bits determine which subset claims
        for (uint256 i = 0; i < 3; i++) {
            if ((claimOrder >> i) & 1 == 1) {
                vm.prank(holders[i]);
                dist.claim(holders[i]);
            }
        }
        uint256 totalPaid = currency.balanceOf(holderA) + currency.balanceOf(holderB) + currency.balanceOf(holderC);
        assertLe(totalPaid, TOTAL_CURRENCY, "total paid out exceeds totalCurrencyAmount");
    }

    function testFuzzReassignSumInvariant(address reassignTo) public {
        vm.assume(reassignTo != address(0));
        vm.assume(reassignTo != holderA);
        vm.assume(reassignTo != holderB);
        vm.assume(reassignTo != holderC);
        uint256 sumBefore = dist.eligible(holderA) +
            dist.eligible(holderB) +
            dist.eligible(holderC) +
            dist.eligible(reassignTo);

        vm.warp(reassignAfter);
        uint256 amountA = dist.eligible(holderA);
        vm.prank(owner);
        dist.reassign(holderA, reassignTo, amountA);

        uint256 sumAfter = dist.eligible(holderA) +
            dist.eligible(holderB) +
            dist.eligible(holderC) +
            dist.eligible(reassignTo);
        assertEq(sumBefore, sumAfter, "sum of eligible should be unchanged after reassign");
    }

    // ========== D_Fee. Fee Collection at Initialization ==========

    /// @dev Deploy a Distribution backed by a token with 1% private offer fee.
    ///      Returns the deployed clone and the fee amount deducted from TOTAL_CURRENCY.
    function _deployDistWithNonZeroFee() internal returns (Distribution d, uint256 fee) {
        IFeeSettingsV2 feeSettingsWithFee = createFeeSettings(
            trustedForwarder,
            admin,
            buildFeeTypes(0, 0, 100, admin, admin, feeCollector)
        );
        Token feeToken = Token(
            tokenFactory.createTokenProxy(
                bytes32("feeTok"),
                trustedForwarder,
                feeSettingsWithFee,
                admin,
                allowList,
                0,
                "FeeToken",
                "FTK"
            )
        );
        vm.startPrank(admin);
        feeToken.grantRole(feeToken.MINTALLOWER_ROLE(), admin);
        feeToken.mint(holderA, SUPPLY_A);
        feeToken.mint(holderB, SUPPLY_B);
        feeToken.mint(holderC, SUPPLY_C);
        vm.stopPrank();
        vm.prank(admin);
        uint256 snap = feeToken.createSnapshot();

        DistributionInitializerArguments memory args = DistributionInitializerArguments({
            owner: owner,
            token: feeToken,
            snapshotId: snap,
            currency: IERC20(address(currency)),
            totalCurrencyAmount: TOTAL_CURRENCY,
            reassignAfter: reassignAfter
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("feeDist"), trustedForwarder, args);
        fee = feeSettingsWithFee.privateOfferFee(TOTAL_CURRENCY, address(feeToken));
        currency.mint(currencyProvider, TOTAL_CURRENCY);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, TOTAL_CURRENCY);
        d = Distribution(factory.createDistributionClone(bytes32("feeDist"), trustedForwarder, currencyProvider, args));
    }

    function testFeeDeductedFromTotalCurrencyAmount() public {
        assertEq(currency.balanceOf(feeCollector), 0, "feeCollector should have no currency before deployment");
        (Distribution localDistribution, uint256 fee) = _deployDistWithNonZeroFee();
        assertEq(
            currency.balanceOf(feeCollector),
            2e6,
            "feeCollector should have exactly 2e6 (1% of 200e6) after deployment"
        );
        assertGt(fee, 0, "fee should be positive");
        assertEq(
            localDistribution.totalCurrencyAmount(),
            TOTAL_CURRENCY - fee,
            "totalCurrencyAmount should be net of fee"
        );
        assertEq(
            currency.balanceOf(address(localDistribution)),
            TOTAL_CURRENCY - fee,
            "dist balance should be reduced by fee"
        );
    }

    function testFeeSentToFeeCollector() public {
        (, uint256 fee) = _deployDistWithNonZeroFee();
        assertEq(currency.balanceOf(feeCollector), fee, "feeCollector did not receive the fee");
    }

    function testEligibleBasedOnNetAmountAfterFee() public {
        (Distribution d, uint256 fee) = _deployDistWithNonZeroFee();
        uint256 net = TOTAL_CURRENCY - fee;
        assertEq(
            d.eligible(holderA),
            (net * SUPPLY_A) / TOTAL_SUPPLY,
            "holderA eligible should be based on net amount"
        );
        assertEq(
            d.eligible(holderB),
            (net * SUPPLY_B) / TOTAL_SUPPLY,
            "holderB eligible should be based on net amount"
        );
        assertEq(
            d.eligible(holderC),
            (net * SUPPLY_C) / TOTAL_SUPPLY,
            "holderC eligible should be based on net amount"
        );
    }

    function testFuzzReassignAndClaimWithFee(uint256 amount) public {
        (Distribution d, uint256 fee) = _deployDistWithNonZeroFee();
        uint256 net = TOTAL_CURRENCY - fee;

        uint256 eligibleA = d.eligible(holderA);
        uint256 eligibleB = d.eligible(holderB);
        uint256 eligibleC = d.eligible(holderC);

        assertEq(eligibleA, (net * SUPPLY_A) / TOTAL_SUPPLY, "holderA eligible wrong before reassign");
        assertEq(eligibleB, (net * SUPPLY_B) / TOTAL_SUPPLY, "holderB eligible wrong before reassign");
        assertEq(eligibleC, (net * SUPPLY_C) / TOTAL_SUPPLY, "holderC eligible wrong before reassign");
        uint256 sumBefore = eligibleA + eligibleB + eligibleC;
        assertLe(sumBefore, net, "sum of eligible exceeds net before reassign");
        assertGe(sumBefore + 3, net, "sum of eligible too far below net before reassign");

        amount = bound(amount, 1, eligibleA);

        vm.warp(reassignAfter);
        vm.prank(owner);
        d.reassign(holderA, holderB, amount);

        assertEq(d.eligible(holderA), eligibleA - amount, "holderA eligible wrong after reassign");
        assertEq(d.eligible(holderB), eligibleB + amount, "holderB eligible wrong after reassign");
        assertEq(d.eligible(holderC), eligibleC, "holderC eligible unchanged after reassign");
        assertEq(
            d.eligible(holderA) + d.eligible(holderB) + d.eligible(holderC),
            sumBefore,
            "sum of eligible changed after reassign"
        );

        vm.prank(holderA);
        d.claim(holderA);
        vm.prank(holderB);
        d.claim(holderB);
        vm.prank(holderC);
        d.claim(holderC);

        assertEq(currency.balanceOf(holderA), eligibleA - amount, "holderA balance wrong after claim");
        assertEq(currency.balanceOf(holderB), eligibleB + amount, "holderB balance wrong after claim");
        assertEq(currency.balanceOf(holderC), eligibleC, "holderC balance wrong after claim");
        assertEq(
            currency.balanceOf(holderA) + currency.balanceOf(holderB) + currency.balanceOf(holderC),
            sumBefore,
            "total paid out does not match sum of eligible before reassign"
        );
    }
}
