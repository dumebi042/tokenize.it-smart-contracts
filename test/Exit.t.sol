// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/ExitCloneFactory.sol";
import "../contracts/Exit.sol";
import "./resources/FakePaymentToken.sol";
import "./resources/CloneCreators.sol";

contract ExitTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant owner = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant holder = 0x2109709EcFa91a80626Ff3989d68F67F5B1Dd122;
    address public constant recipient = 0x3109709ECfA91A80626fF3989D68f67F5B1Dd123;
    address public constant currencyProvider = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;
    address public constant feeCollector = 0x5109709EcFA91a80626ff3989d68f67F5B1dD125;
    address public constant trustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;

    uint8 public constant CURRENCY_DECIMALS = 6;
    // 2 currency units (6 dec) per token (18 dec)
    uint256 public constant PRICE_PER_TOKEN = 2e6;
    uint256 public constant TOKEN_SUPPLY = 100e18;
    uint256 public constant TOTAL_CURRENCY = 200e6; // 100 tokens × 2e6

    uint64 public claimStart;
    uint64 public drainStart;

    AllowList allowList;
    FakePaymentToken currency;
    Token token;
    Exit exitLogic;
    ExitCloneFactory factory;
    Exit exitContract;
    TokenProxyFactory tokenFactory;

    function setUp() public {
        claimStart = uint64(block.timestamp + 1 days);
        drainStart = uint64(block.timestamp + 30 days);

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
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "ExitToken", "EXT")
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTALLOWER_ROLE(), admin);
        token.mint(holder, TOKEN_SUPPLY);
        vm.stopPrank();

        currency.mint(currencyProvider, TOTAL_CURRENCY);
        exitLogic = new Exit(trustedForwarder);
        factory = new ExitCloneFactory(address(exitLogic));
        exitContract = _deployExit(bytes32(0), PRICE_PER_TOKEN, claimStart, drainStart, TOTAL_CURRENCY);

        vm.prank(holder);
        token.approve(address(exitContract), TOKEN_SUPPLY);
    }

    /// @dev Helper: predict address, approve, and deploy an Exit clone
    function _deployExit(
        bytes32 salt,
        uint256 price,
        uint64 start,
        uint64 end,
        uint256 totalCurrency
    ) internal returns (Exit) {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: price,
            claimStart: start,
            drainStart: end,
            totalCurrencyAmount: totalCurrency
        });
        address cloneAddr = factory.predictCloneAddress(salt, trustedForwarder, args);
        currency.mint(currencyProvider, totalCurrency);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, totalCurrency);
        return Exit(factory.createExitClone(salt, trustedForwarder, currencyProvider, args));
    }

    // ========== E1. Constructor / Logic Contract ==========

    function testLogicContractInitializeReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("Initializable: contract is already initialized");
        exitLogic.initialize(args, currencyProvider);
    }

    function testLogicContractStateIsZero() public view {
        assertEq(address(exitLogic.token()), address(0), "logic contract token should be zero");
        assertEq(address(exitLogic.currency()), address(0), "logic contract currency should be zero");
        assertEq(exitLogic.pricePerToken(), 0, "logic contract pricePerToken should be zero");
        assertEq(exitLogic.claimStart(), 0, "logic contract claimStart should be zero");
        assertEq(exitLogic.drainStart(), 0, "logic contract drainStart should be zero");
        assertEq(exitLogic.owner(), address(0), "logic contract owner should be zero");
    }

    function testLogicContractClaimReverts() public {
        // claimStart is 0, so timestamp >= claimStart passes; claim then tries
        // safeTransferFrom on token=address(0) which reverts (no code at address)
        vm.expectRevert("Address: call to non-contract");
        exitLogic.claim(1e18, recipient, 0);
    }

    function testLogicContractDrainReverts() public {
        // owner is address(0) on uninitialized logic contract → onlyOwner blocks everyone
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert("Ownable: caller is not the owner");
        exitLogic.drain(recipient);
    }

    function testSecondInitializeReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 100
        });
        vm.expectRevert("Initializable: contract is already initialized");
        exitContract.initialize(args, currencyProvider);
    }

    // ========== E2. initialize() — Validation & State ==========

    function testInitializeZeroPriceReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: 0,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("price must be positive");
        factory.createExitClone(bytes32("p0"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeZeroClaimStartReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: 0,
            drainStart: drainStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("claimStart must be set");
        factory.createExitClone(bytes32("cs0"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeDrainStartEqualToStartReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: claimStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("drainStart must be after claimStart");
        factory.createExitClone(bytes32("ce0"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeCurrencyEqualsTokenReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(token)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("currency and token must be different");
        factory.createExitClone(bytes32("cet"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeNonTrustedCurrencyReverts() public {
        FakePaymentToken badCurrency = new FakePaymentToken(0, 6);
        // not set on allowList → 0 attributes
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(badCurrency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 0
        });
        vm.expectRevert("currency needs to be on the allowlist with TRUSTED_CURRENCY attribute");
        factory.createExitClone(bytes32("ntc"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeInsufficientAllowanceReverts() public {
        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: token,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: 1000e6
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("lowApproval"), trustedForwarder, args);
        currency.mint(currencyProvider, 1000e6);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, 999e6); // one unit short
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createExitClone(bytes32("lowApproval"), trustedForwarder, currencyProvider, args);
    }

    function testInitializeStateVariables() public view {
        assertEq(address(exitContract.token()), address(token), "token address mismatch");
        assertEq(address(exitContract.currency()), address(currency), "currency address mismatch");
        assertEq(exitContract.pricePerToken(), PRICE_PER_TOKEN, "pricePerToken mismatch");
        assertEq(exitContract.claimStart(), claimStart, "claimStart mismatch");
        assertEq(exitContract.drainStart(), drainStart, "drainStart mismatch");
        assertEq(exitContract.owner(), owner, "owner mismatch");
        assertEq(currency.balanceOf(address(exitContract)), TOTAL_CURRENCY, "exitContract currency balance mismatch");
    }

    // ========== E3. claim(uint256, address) — Direct Claim ==========

    function testClaimBeforeStartReverts() public {
        vm.expectRevert("exit not yet started");
        vm.prank(holder);
        exitContract.claim(1e18, recipient, 0);
    }

    function testClaimAtStartBoundarySucceeds() public {
        vm.warp(claimStart);
        vm.prank(holder);
        exitContract.claim(1e18, recipient, 0);
    }

    function testClaimAfterEndSucceeds() public {
        vm.warp(drainStart + 1);
        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before claim");
        vm.prank(holder);
        exitContract.claim(1e18, recipient, 0);
        assertGt(currency.balanceOf(recipient), 0, "recipient should have received currency after claim");
    }

    function testClaimTransfersTokensToExitNotBurned() public {
        vm.warp(claimStart);
        uint256 claimAmt = 10e18;
        assertEq(token.balanceOf(address(exitContract)), 0, "exitContract token balance should be zero before claim");
        assertEq(token.balanceOf(holder), TOKEN_SUPPLY, "holder token balance should be full before claim");
        vm.prank(holder);
        exitContract.claim(claimAmt, recipient, 0);
        // tokens go to Exit, not burned
        assertEq(token.balanceOf(address(exitContract)), claimAmt, "exitContract should hold claimed tokens");
        assertEq(
            token.balanceOf(holder),
            TOKEN_SUPPLY - claimAmt,
            "holder token balance should be reduced by claimed amount"
        );
    }

    function testClaimSendsCurrencyToRecipient() public {
        vm.warp(claimStart);
        uint256 claimAmt = 10e18;
        uint256 expectedCurrency = (claimAmt * PRICE_PER_TOKEN) / 1e18;
        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before claim");
        assertEq(currency.balanceOf(holder), 0, "holder currency balance should be zero before claim");
        vm.prank(holder);
        exitContract.claim(claimAmt, recipient, 0);
        assertEq(currency.balanceOf(recipient), expectedCurrency, "recipient should receive exact currency amount");
        assertEq(currency.balanceOf(holder), 0, "holder should not receive any currency");
    }

    function testClaimRecipientDiffersFromSender() public {
        vm.warp(claimStart);
        assertEq(currency.balanceOf(holder), 0, "holder currency balance should be zero before claim");
        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before claim");
        vm.prank(holder);
        exitContract.claim(1e18, recipient, 0);
        assertEq(currency.balanceOf(holder), 0, "holder should not receive any currency");
        assertGt(currency.balanceOf(recipient), 0, "recipient should have received currency");
    }

    function testClaimWithoutTokenApprovalReverts() public {
        vm.warp(claimStart);
        address stranger = address(42);
        vm.prank(admin);
        token.mint(stranger, 10e18);
        // no approval → safeTransferFrom fails
        vm.expectRevert("ERC20: insufficient allowance");
        vm.prank(stranger);
        exitContract.claim(10e18, stranger, 0);
    }

    function testMultipleSequentialClaims() public {
        vm.warp(claimStart);
        address holder2 = address(43);
        vm.prank(admin);
        token.mint(holder2, 50e18);
        vm.prank(holder2);
        token.approve(address(exitContract), 50e18);

        uint256 expected1 = (10e18 * PRICE_PER_TOKEN) / 1e18;
        uint256 expected2 = (50e18 * PRICE_PER_TOKEN) / 1e18;

        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before claims");
        assertEq(currency.balanceOf(address(44)), 0, "address(44) currency balance should be zero before claims");
        assertEq(
            currency.balanceOf(address(exitContract)),
            TOTAL_CURRENCY,
            "exitContract should hold full currency before claims"
        );
        vm.prank(holder);
        exitContract.claim(10e18, recipient, 0);
        vm.prank(holder2);
        exitContract.claim(50e18, address(44), 0);

        assertEq(currency.balanceOf(recipient), expected1, "recipient should receive correct currency amount");
        assertEq(currency.balanceOf(address(44)), expected2, "address(44) should receive correct currency amount");
        assertEq(
            currency.balanceOf(address(exitContract)),
            TOTAL_CURRENCY - expected1 - expected2,
            "exitContract currency balance should reflect both claims"
        );
    }

    function testClaimExceedingFundedAmountReverts() public {
        vm.warp(claimStart);
        assertEq(
            currency.balanceOf(address(exitContract)),
            TOTAL_CURRENCY,
            "exitContract should hold full currency before drain claim"
        );
        // Drain exit fully first
        vm.prank(holder);
        exitContract.claim(TOKEN_SUPPLY, recipient, 0);
        assertEq(currency.balanceOf(address(exitContract)), 0, "exitContract should be empty after full claim");

        // One more token has nowhere to pull from
        address extra = address(45);
        vm.prank(admin);
        token.mint(extra, 1e18);
        vm.prank(extra);
        token.approve(address(exitContract), 1e18);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(extra);
        exitContract.claim(1e18, extra, 0);
    }

    // ========== E6. drain() ==========

    function testDrainNonOwnerReverts() public {
        vm.warp(drainStart + 1);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(holder);
        exitContract.drain(recipient);
    }

    function testFuzzDrainNonOwnerReverts(address caller) public {
        vm.assume(caller != owner);
        vm.assume(caller != address(0));
        vm.assume(caller != trustedForwarder);
        vm.warp(drainStart + 1);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(caller);
        exitContract.drain(recipient);
    }

    function testFuzzDrainTiming(uint64 timestamp) public {
        vm.assume(timestamp < type(uint64).max - 1);
        vm.warp(timestamp);
        if (timestamp <= drainStart) {
            vm.expectRevert("exit window not yet closed");
            vm.prank(owner);
            exitContract.drain(recipient);
        } else {
            uint256 contractBalance = currency.balanceOf(address(exitContract));
            uint256 balBefore = currency.balanceOf(recipient);
            vm.prank(owner);
            exitContract.drain(recipient);
            assertEq(
                currency.balanceOf(recipient),
                balBefore + contractBalance,
                "recipient should receive full contract balance after drain"
            );
            assertEq(currency.balanceOf(address(exitContract)), 0, "exitContract should be empty after drain");
        }
    }

    function testDrainAtDrainStartReverts() public {
        vm.warp(drainStart);
        vm.expectRevert("exit window not yet closed");
        vm.prank(owner);
        exitContract.drain(recipient);
    }

    function testDrainAfterDrainStartTransfersFullBalance() public {
        vm.warp(drainStart + 1);
        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before drain");
        assertEq(
            currency.balanceOf(address(exitContract)),
            TOTAL_CURRENCY,
            "exitContract should hold full currency before drain"
        );
        vm.prank(owner);
        exitContract.drain(recipient);
        assertEq(
            currency.balanceOf(recipient),
            TOTAL_CURRENCY,
            "recipient should receive full currency balance after drain"
        );
        assertEq(currency.balanceOf(address(exitContract)), 0, "exitContract should be empty after drain");
    }

    // ========== E7. Math & Rounding ==========

    function testMathRoundsDown() public {
        vm.warp(claimStart);
        // 1 token (1e18 wei) + 1 extra wei at PRICE_PER_TOKEN = 2e6:
        // (1e18 + 1) * 2e6 / 1e18 = 2e6, same as exactly 1 token — the extra wei is rounded away
        uint256 claimAmt = 1e18 + 1;
        vm.prank(admin);
        token.mint(address(this), claimAmt);
        token.approve(address(exitContract), claimAmt);

        uint256 balBefore = currency.balanceOf(address(this));
        exitContract.claim(claimAmt, address(this), 0);
        assertEq(
            currency.balanceOf(address(this)) - balBefore,
            PRICE_PER_TOKEN, // exactly 1 token's worth; the +1 wei is rounded away
            "sub-wei token remainder should not increase currency payout"
        );
    }

    function testFuzzMathMultipleClaims(uint128 fuzzAmt) public {
        // price = 2e18 currency-wei per token (2 currency units if currency has 18 decimals)
        // fixed claim amounts: 1 token, 1.5 tokens, 3e6 token-wei (sub-unit, often rounds to 0)
        uint256 claim1 = 1e18;
        uint256 expected1 = 2e18; // 1e18  * 2e18 / 1e18
        uint256 claim2 = 15e17;
        uint256 expected2 = 3e18; // 15e17 * 2e18 / 1e18
        uint256 claim3 = 3e6;
        uint256 expected3 = 6e6; // 3e6   * 2e18 / 1e18
        vm.assume(uint256(fuzzAmt) <= 100e18 - claim1 - claim2 - claim3);

        // 100e18 tokens * 2e18 / 1e18 = 200e18 total currency
        Exit fuzzExit = _deployExit(keccak256(abi.encode("fuzzMath", fuzzAmt)), 2e18, claimStart, drainStart, 200e18);

        vm.prank(admin);
        token.mint(address(this), claim1 + claim2 + claim3 + uint256(fuzzAmt));
        token.approve(address(fuzzExit), claim1 + claim2 + claim3 + uint256(fuzzAmt));

        vm.warp(claimStart);

        fuzzExit.claim(claim1, address(0x1001), 0);
        fuzzExit.claim(claim2, address(0x1002), 0);
        fuzzExit.claim(claim3, address(0x1003), 0);
        fuzzExit.claim(uint256(fuzzAmt), address(0x1004), 0);

        assertEq(currency.balanceOf(address(0x1001)), expected1, "claim1 payout wrong");
        assertEq(currency.balanceOf(address(0x1002)), expected2, "claim2 payout wrong");
        assertEq(currency.balanceOf(address(0x1003)), expected3, "claim3 payout wrong");
        assertEq(currency.balanceOf(address(0x1004)), (uint256(fuzzAmt) * 2e18) / 1e18, "fuzz claim payout wrong");

        uint256 expectedRemainder = 200e18 - expected1 - expected2 - expected3 - (uint256(fuzzAmt) * 2e18) / 1e18;
        assertEq(currency.balanceOf(address(fuzzExit)), expectedRemainder, "contract balance wrong after claims");
    }

    function testFuzzMathNeverOverpays(uint128 tokenAmt) public {
        vm.assume(tokenAmt > 0);
        vm.warp(claimStart);
        uint256 expectedCurrency = (uint256(tokenAmt) * PRICE_PER_TOKEN) / 1e18;
        vm.assume(expectedCurrency <= TOTAL_CURRENCY);

        vm.prank(admin);
        token.mint(address(this), tokenAmt);
        token.approve(address(exitContract), tokenAmt);

        uint256 balBefore = currency.balanceOf(address(this));
        exitContract.claim(tokenAmt, address(this), 0);
        uint256 received = currency.balanceOf(address(this)) - balBefore;
        assertEq(received, expectedCurrency, "received currency should match floor division");
        // floor division: received ≤ what a full-precision calculation would give
        assertLe(
            received,
            (uint256(tokenAmt) * PRICE_PER_TOKEN) / 1e18 + 1,
            "received currency must not exceed full-precision result"
        );
    }

    // ========== E8. ERC2771 / Meta-transactions ==========

    function testERC2771IdentifiesHolderAsSender() public {
        vm.warp(claimStart);
        uint256 claimAmt = 5e18;
        uint256 expectedCurrency = (claimAmt * PRICE_PER_TOKEN) / 1e18;

        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before meta-tx");
        assertEq(token.balanceOf(holder), TOKEN_SUPPLY, "holder token balance should be full before meta-tx");
        // Build meta-tx calldata: claim(tokenAmount, recipient) + appended holder address
        bytes memory callData = abi.encodePacked(
            abi.encodeWithSelector(
                bytes4(keccak256("claim(uint256,address,uint256)")),
                claimAmt,
                recipient,
                uint256(0)
            ),
            holder
        );
        vm.prank(trustedForwarder);
        (bool success, ) = address(exitContract).call(callData);
        assertTrue(success, "meta-tx call should succeed");
        assertEq(
            currency.balanceOf(recipient),
            expectedCurrency,
            "recipient should receive correct currency via meta-tx"
        );
        // tokens pulled from holder (approved in setUp)
        assertEq(
            token.balanceOf(holder),
            TOKEN_SUPPLY - claimAmt,
            "holder token balance should be reduced after meta-tx"
        );
    }

    // ========== E_Fee. Fee Collection per Claim ==========

    /// @dev Deploy an Exit backed by a token with 1% private offer fee.
    ///      Also approves the exit to spend holder's tokens.
    function _deployExitWithNonZeroFee()
        internal
        returns (Exit feeExit, IFeeSettingsV2 feeSettingsWithFee, Token feeToken)
    {
        feeSettingsWithFee = createFeeSettings(
            trustedForwarder,
            admin,
            buildFeeTypes(0, 0, 100, admin, admin, feeCollector)
        );
        feeToken = Token(
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
        feeToken.mint(holder, TOKEN_SUPPLY);
        vm.stopPrank();

        ExitInitializerArguments memory args = ExitInitializerArguments({
            owner: owner,
            token: feeToken,
            currency: IERC20(address(currency)),
            pricePerToken: PRICE_PER_TOKEN,
            claimStart: claimStart,
            drainStart: drainStart,
            totalCurrencyAmount: TOTAL_CURRENCY
        });
        address cloneAddr = factory.predictCloneAddress(bytes32("feeExit"), trustedForwarder, args);
        currency.mint(currencyProvider, TOTAL_CURRENCY);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, TOTAL_CURRENCY);
        feeExit = Exit(factory.createExitClone(bytes32("feeExit"), trustedForwarder, currencyProvider, args));

        vm.prank(holder);
        feeToken.approve(address(feeExit), TOKEN_SUPPLY);
    }

    function testClaimWithFeeDeductsFromRecipient() public {
        (Exit feeExit, IFeeSettingsV2 feeSettingsWithFee, Token feeToken) = _deployExitWithNonZeroFee();
        uint256 claimAmt = 10e18;
        uint256 currencyAmount = (claimAmt * PRICE_PER_TOKEN) / 10 ** feeToken.decimals();
        uint256 fee = feeSettingsWithFee.privateOfferFee(currencyAmount, address(feeToken));

        vm.warp(claimStart);
        assertEq(currency.balanceOf(recipient), 0, "recipient currency balance should be zero before claim");
        vm.prank(holder);
        feeExit.claim(claimAmt, recipient, 0);

        assertGt(fee, 0, "fee should be positive");
        assertEq(currency.balanceOf(recipient), currencyAmount - fee, "recipient should receive currency minus fee");
    }

    function testClaimWithFeeSendsToFeeCollector() public {
        (Exit feeExit, IFeeSettingsV2 feeSettingsWithFee, Token feeToken) = _deployExitWithNonZeroFee();
        uint256 claimAmt = 10e18;
        uint256 currencyAmount = (claimAmt * PRICE_PER_TOKEN) / 10 ** feeToken.decimals();
        uint256 fee = feeSettingsWithFee.privateOfferFee(currencyAmount, address(feeToken));

        vm.warp(claimStart);
        assertEq(currency.balanceOf(feeCollector), 0, "feeCollector currency balance should be zero before claim");
        vm.prank(holder);
        feeExit.claim(claimAmt, recipient, 0);

        assertEq(currency.balanceOf(feeCollector), fee, "feeCollector should receive exact fee amount");
    }

    // ========== E_MinPayout. minPayout guard ==========

    /// minPayout == 0 always passes (no minimum)
    function testClaimMinPayoutZeroAlwaysPasses() public {
        vm.warp(claimStart);
        vm.prank(holder);
        exitContract.claim(1e18, recipient, 0);
        assertGt(currency.balanceOf(recipient), 0, "recipient should receive currency");
    }

    /// minPayout exactly equal to net payout succeeds
    function testClaimMinPayoutExactNetSucceeds() public {
        uint256 claimAmt = 1e18;
        uint256 expectedNet = (claimAmt * PRICE_PER_TOKEN) / 10 ** token.decimals();
        vm.warp(claimStart);
        vm.prank(holder);
        exitContract.claim(claimAmt, recipient, expectedNet);
        assertEq(currency.balanceOf(recipient), expectedNet, "recipient should receive exactly expectedNet");
    }

    /// minPayout one above net payout reverts
    function testClaimMinPayoutAboveNetReverts() public {
        uint256 claimAmt = 1e18;
        uint256 expectedNet = (claimAmt * PRICE_PER_TOKEN) / 10 ** token.decimals();
        vm.warp(claimStart);
        vm.prank(holder);
        vm.expectRevert("payout below minimum");
        exitContract.claim(claimAmt, recipient, expectedNet + 1);
    }

    /// With a fee, minPayout exactly equal to net-after-fee succeeds
    function testClaimMinPayoutExactNetAfterFeeSucceeds() public {
        (Exit feeExit, IFeeSettingsV2 feeSettingsWithFee, Token feeToken) = _deployExitWithNonZeroFee();
        uint256 claimAmt = 1e18;
        uint256 gross = (claimAmt * PRICE_PER_TOKEN) / 10 ** feeToken.decimals();
        uint256 fee = feeSettingsWithFee.privateOfferFee(gross, address(feeToken));
        uint256 expectedNet = gross - fee;
        vm.warp(claimStart);
        vm.prank(holder);
        feeExit.claim(claimAmt, recipient, expectedNet);
        assertEq(currency.balanceOf(recipient), expectedNet, "recipient should receive net after fee");
    }

    /// With a fee, minPayout equal to gross (before fee) reverts because actual payout is gross - fee
    function testClaimMinPayoutAboveNetAfterFeeReverts() public {
        (Exit feeExit, , Token feeToken) = _deployExitWithNonZeroFee();
        uint256 claimAmt = 1e18;
        uint256 gross = (claimAmt * PRICE_PER_TOKEN) / 10 ** feeToken.decimals();
        vm.warp(claimStart);
        vm.prank(holder);
        vm.expectRevert("payout below minimum");
        feeExit.claim(claimAmt, recipient, gross); // gross > net
    }

    /// Fuzz: claim always succeeds when minPayout <= net, reverts when minPayout > net
    function testFuzzClaimMinPayoutBoundary(uint256 claimAmt, uint256 minPayout) public {
        claimAmt = bound(claimAmt, 1e15, TOKEN_SUPPLY); // at least 0.001 tokens
        uint256 net = (claimAmt * PRICE_PER_TOKEN) / 10 ** token.decimals();
        vm.assume(net > 0);
        vm.warp(claimStart);
        vm.prank(holder);
        if (minPayout <= net) {
            exitContract.claim(claimAmt, recipient, minPayout);
            assertEq(currency.balanceOf(recipient), net, "recipient should receive net");
        } else {
            vm.expectRevert("payout below minimum");
            exitContract.claim(claimAmt, recipient, minPayout);
        }
    }

    function testDrainWithFeeReflectsCorrectRemainder() public {
        (Exit feeExit, IFeeSettingsV2 feeSettingsWithFee, Token feeToken) = _deployExitWithNonZeroFee();
        uint256 claimAmt = 10e18;
        uint256 currencyAmount = (claimAmt * PRICE_PER_TOKEN) / 10 ** feeToken.decimals();

        vm.warp(claimStart);
        assertEq(
            currency.balanceOf(address(feeExit)),
            TOTAL_CURRENCY,
            "feeExit should hold full currency before claim"
        );
        assertEq(currency.balanceOf(feeCollector), 0, "feeCollector should start with zero balance");

        uint256 fee = feeSettingsWithFee.privateOfferFee(currencyAmount, address(feeToken));
        vm.prank(holder);
        feeExit.claim(claimAmt, recipient, 0);

        assertEq(currency.balanceOf(feeCollector), fee, "feeCollector should receive fee on claim");

        // Both the fee and the net payout leave the contract, so the remainder is TOTAL_CURRENCY - currencyAmount
        uint256 expected = TOTAL_CURRENCY - currencyAmount;
        assertEq(
            currency.balanceOf(address(feeExit)),
            expected,
            "feeExit currency balance should reflect full payout including fee"
        );

        vm.warp(drainStart + 1);
        vm.prank(owner);
        feeExit.drain(owner);
        assertEq(currency.balanceOf(owner), expected, "owner should receive remaining currency after drain");
        assertEq(currency.balanceOf(address(feeExit)), 0, "feeExit should be empty after drain");
        assertEq(currency.balanceOf(feeCollector), fee, "feeCollector should not receive additional currency on drain");
    }
}
