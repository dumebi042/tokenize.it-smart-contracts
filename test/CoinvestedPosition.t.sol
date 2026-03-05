// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";

import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/CoinvestedPositionCloneFactory.sol";
import "../contracts/CoinvestedPosition.sol";
import "../contracts/FeeSettings.sol";
import "./resources/FakePaymentToken.sol";
import "./resources/CloneCreators.sol";

// ── Malicious currency that re-enters CoinvestedPosition.buy() ──────────────
contract MaliciousCoinvestedToken is FakePaymentToken {
    CoinvestedPosition public target;
    bool public attacking;

    constructor() FakePaymentToken(0, 6) {}

    function setTarget(address _target) external {
        target = CoinvestedPosition(_target);
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if (attacking) return super.transferFrom(sender, recipient, amount);
        attacking = true;
        // Try to re-enter buy()
        target.buy(1e18, type(uint256).max, address(this));
        attacking = false;
        return super.transferFrom(sender, recipient, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────

contract CoinvestedPositionTest is Test {
    // ── Events ────────────────────────────────────────────────────────────────
    event TokensBought(address indexed buyer, uint256 tokenAmount, uint256 currencyAmount);
    event ReceiverChanged(address indexed newReceiver);
    event TokenPriceChanged(uint256 newTokenPrice);

    // ── Well-known addresses ──────────────────────────────────────────────────
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant owner = 0x6109709EcFA91A80626FF3989d68f67F5b1dd126;
    address public constant receiver = 0x7109709eCfa91A80626Ff3989D68f67f5b1dD127;
    address public constant buyer = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant leadA = 0x2109709EcFa91a80626Ff3989d68F67F5B1Dd122;
    address public constant leadB = 0x3109709ECfA91A80626fF3989D68f67F5B1Dd123;
    address public constant trustedForwarder = 0xa109709ecfA91A80626ff3989D68F67F5b1dD12a;
    address public constant tokenReceiver = 0x5109709EcFA91a80626ff3989d68f67F5B1dD125;
    address public constant feeCollector = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;

    // ── Test constants ────────────────────────────────────────────────────────
    // 10% of uint64.max (floor)
    uint64 public constant CARRY_10PCT = type(uint64).max / 10;
    // 5% of uint64.max (floor)
    uint64 public constant CARRY_5PCT = type(uint64).max / 20;
    // 2% of uint64.max (floor)
    uint64 public constant CARRY_2PCT = type(uint64).max / 50;

    // ── Shared state ──────────────────────────────────────────────────────────
    AllowList allowList;
    IFeeSettingsV2 feeSettings;
    Token token;
    TokenProxyFactory tokenFactory;

    // EURc: 6 decimals (the "base currency" used at init)
    FakePaymentToken eurc;
    // EURe: 18 decimals (used for cross-currency tests)
    FakePaymentToken eure;

    CoinvestedPosition logic;
    CoinvestedPositionCloneFactory factory;

    // The clone deployed for most tests
    CoinvestedPosition coinvestedPosition;

    // ── setUp ─────────────────────────────────────────────────────────────────
    function setUp() public {
        // Infrastructure
        allowList = createAllowList(trustedForwarder, admin);
        Fees memory zeroFees = Fees(0, 0, 0, 0);
        feeSettings = createFeeSettings(trustedForwarder, admin, zeroFees, admin, admin, admin);

        // EURc (6 dec) and EURe (18 dec)
        eurc = new FakePaymentToken(0, 6);
        eure = new FakePaymentToken(0, 18);

        // Register currencies on allowList
        vm.startPrank(admin);
        allowList.set(address(eurc), TRUSTED_CURRENCY | EURO_CURRENCY);
        allowList.set(address(eure), TRUSTED_CURRENCY | EURO_CURRENCY);
        vm.stopPrank();

        // Token (18 dec)
        address tokenLogic = address(new Token(trustedForwarder));
        tokenFactory = new TokenProxyFactory(tokenLogic);
        token = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "TestToken", "TTK")
        );

        // Grant mint role so tests can mint tokens to coinvestedPosition
        vm.startPrank(admin);
        token.grantRole(token.MINTALLOWER_ROLE(), admin);
        vm.stopPrank();

        // Factory
        logic = new CoinvestedPosition(trustedForwarder);
        factory = new CoinvestedPositionCloneFactory(address(logic));

        // Deploy default clone: basePrice=100e6 EURc, 10%+5% carry
        coinvestedPosition = _deployCoinvestedPosition(bytes32(0), 100e6, eurc, _defaultLeadInvestors());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Internal helpers ──────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function _defaultLeadInvestors() internal pure returns (LeadInvestor[] memory) {
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](2);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: CARRY_10PCT});
        leadInvestors[1] = LeadInvestor({account: leadB, carryFraction: CARRY_5PCT});
        return leadInvestors;
    }

    function _deployCoinvestedPosition(
        bytes32 salt,
        uint256 basePrice,
        FakePaymentToken baseCurrency,
        LeadInvestor[] memory leadInvestors
    ) internal returns (CoinvestedPosition) {
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: basePrice,
            baseCurrency: IERC20(address(baseCurrency)),
            token: token
        });
        return CoinvestedPosition(factory.createCoinvestedPositionClone(salt, trustedForwarder, args));
    }

    /// Mint tokens to coinvestedPosition then set price and unpause
    function _setupBuy(uint256 tokenAmount, uint256 tokenPrice) internal {
        vm.prank(admin);
        token.mint(address(coinvestedPosition), tokenAmount);
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(tokenPrice);
        vm.prank(owner);
        coinvestedPosition.unpause();
    }

    /// Give buyer currency and approve coinvestedPosition
    function _fundBuyer(FakePaymentToken currency, uint256 amount) internal {
        currency.mint(buyer, amount);
        vm.prank(buyer);
        currency.approve(address(coinvestedPosition), amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 1: Constructor / Logic Contract ───────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testLogicContractInitializeReverts() public {
        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: token
        });
        vm.expectRevert("Initializable: contract is already initialized");
        logic.initialize(args);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 2: initialize() — Validation ─────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testInitStateVarsCorrect() public view {
        assertEq(coinvestedPosition.owner(), owner, "owner");
        assertEq(coinvestedPosition.receiver(), receiver, "receiver");
        assertEq(address(coinvestedPosition.currency()), address(eurc), "currency");
        assertEq(address(coinvestedPosition.token()), address(token), "token");
        assertEq(coinvestedPosition.basePrice(), 100e6, "basePrice");
        assertEq(coinvestedPosition.basePriceDecimals(), 6, "basePriceDecimals");
        assertEq(coinvestedPosition.getLeadInvestorsCount(), 2, "leadInvestors length");
        (address acc0, uint64 frac0) = coinvestedPosition.leadInvestors(0);
        assertEq(acc0, leadA, "leadA account");
        assertEq(frac0, CARRY_10PCT, "leadA fraction");
        (address acc1, uint64 frac1) = coinvestedPosition.leadInvestors(1);
        assertEq(acc1, leadB, "leadB account");
        assertEq(frac1, CARRY_5PCT, "leadB fraction");
    }

    function testInitBasePriceDecimalsReflectsBaseCurrency() public {
        // Deploy with 18-dec currency → basePriceDecimals = 18
        CoinvestedPosition coinvestedPosition18 = _deployCoinvestedPosition(
            bytes32("salt"),
            100e18,
            eure,
            _defaultLeadInvestors()
        );
        assertEq(coinvestedPosition18.basePriceDecimals(), 18, "basePriceDecimals should be 18");
    }

    function testFuzz_InitBasePriceDecimalsAndPriceStoredCorrectly(uint8 decimals, uint256 basePrice) public {
        vm.assume(basePrice > 0);
        vm.assume(decimals <= 30);

        FakePaymentToken fuzzCurrency = new FakePaymentToken(0, decimals);
        vm.prank(admin);
        allowList.set(address(fuzzCurrency), TRUSTED_CURRENCY | EURO_CURRENCY);

        bytes32 salt = keccak256(abi.encodePacked(decimals, basePrice));
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: _defaultLeadInvestors(),
            basePrice: basePrice,
            baseCurrency: IERC20(address(fuzzCurrency)),
            token: token
        });
        CoinvestedPosition fuzzPosition = CoinvestedPosition(
            factory.createCoinvestedPositionClone(salt, trustedForwarder, args)
        );

        assertEq(fuzzPosition.basePriceDecimals(), decimals, "basePriceDecimals must match currency decimals");
        assertEq(fuzzPosition.basePrice(), basePrice, "basePrice must be stored as-is");
    }

    function testInitTokenPriceIsZero() public view {
        assertEq(coinvestedPosition.tokenPrice(), 0, "tokenPrice should start at 0");
    }

    function testInitContractStartsPaused() public view {
        assertTrue(coinvestedPosition.paused(), "contract should start paused");
    }

    function testInitNonEuroCurrencyReverts() public {
        // Currency with only TRUSTED but not EURO bit
        FakePaymentToken nonEuro = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(nonEuro), TRUSTED_CURRENCY); // no EURO_CURRENCY bit

        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(nonEuro)),
            token: token
        });
        vm.expectRevert("currency must be a trusted EURO currency");
        factory.createCoinvestedPositionClone(bytes32("nonEuro"), trustedForwarder, args);
    }

    function testInitNonTrustedCurrencyReverts() public {
        // Currency with only EURO but not TRUSTED bit
        FakePaymentToken nonTrusted = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(nonTrusted), EURO_CURRENCY); // no TRUSTED_CURRENCY bit

        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(nonTrusted)),
            token: token
        });
        vm.expectRevert("currency needs to be on the allowlist with TRUSTED_CURRENCY attribute");
        factory.createCoinvestedPositionClone(bytes32("nonTrusted"), trustedForwarder, args);
    }

    function testInitCurrencyNotOnAllowListReverts() public {
        FakePaymentToken noBit = new FakePaymentToken(0, 6);
        // not set on allowList at all
        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(noBit)),
            token: token
        });
        vm.expectRevert();
        factory.createCoinvestedPositionClone(bytes32("noBit"), trustedForwarder, args);

        // Adding the currency to the allowList with both required bits makes creation succeed
        vm.prank(admin);
        allowList.set(address(noBit), TRUSTED_CURRENCY | EURO_CURRENCY);
        factory.createCoinvestedPositionClone(bytes32("noBit"), trustedForwarder, args); // must not revert
    }

    function testInitEmptyLeadInvestorsReverts() public {
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](0);
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: token
        });
        vm.expectRevert("There must be at least one lead investor");
        factory.createCoinvestedPositionClone(bytes32("emptyLead"), trustedForwarder, args);
    }

    function testInitZeroAddressLeadInvestorReverts() public {
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](1);
        leadInvestors[0] = LeadInvestor({account: address(0), carryFraction: CARRY_10PCT});
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: token
        });
        vm.expectRevert("lead investor can not be zero address");
        factory.createCoinvestedPositionClone(bytes32("zeroLead"), trustedForwarder, args);
    }

    function testInitCarryFractionZeroReverts() public {
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](1);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: 0});
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: token
        });
        vm.expectRevert("lead investor carry fraction can not be zero");
        factory.createCoinvestedPositionClone(bytes32("zeroCarry"), trustedForwarder, args);
    }

    function testInitCarryFractionsSumOverflowReverts() public {
        // Two investors each with uint64.max: sum overflows uint64 → arithmetic revert
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](2);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: type(uint64).max});
        leadInvestors[1] = LeadInvestor({account: leadB, carryFraction: 1});
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: token
        });
        vm.expectRevert("panic: arithmetic underflow or overflow (0x11)"); // arithmetic overflow
        factory.createCoinvestedPositionClone(bytes32("overflow"), trustedForwarder, args);
    }

    function testInitCarryFractionsSumMaxAccepted() public {
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](1);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: type(uint64).max});
        CoinvestedPosition coinvestedPositionBoundary = _deployCoinvestedPosition(
            bytes32("boundary"),
            100e6,
            eurc,
            leadInvestors
        );
        assertEq(coinvestedPositionBoundary.getLeadInvestorsCount(), 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 3: setCurrency() ──────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSetCurrencyOnlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setCurrency(IERC20(address(eure)));
    }

    function testFuzz_SetCurrencyOnlyOwner(address caller) public {
        vm.assume(caller != owner && caller != address(0));
        vm.prank(caller);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setCurrency(IERC20(address(eure)));
    }

    function testSetCurrencyNonEuroReverts() public {
        FakePaymentToken nonEuro = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(nonEuro), TRUSTED_CURRENCY);
        vm.prank(owner);
        vm.expectRevert("currency must be a trusted EURO currency");
        coinvestedPosition.setCurrency(IERC20(address(nonEuro)));
    }

    function testSetCurrencyNonTrustedReverts() public {
        FakePaymentToken nonTrusted = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(nonTrusted), EURO_CURRENCY);
        vm.prank(owner);
        vm.expectRevert("currency must be a trusted EURO currency");
        coinvestedPosition.setCurrency(IERC20(address(nonTrusted)));
    }

    function testFuzz_SetCurrencyValidAccepted(uint8 decimals) public {
        FakePaymentToken newCurrency = new FakePaymentToken(0, decimals);

        // Not on allowList yet → revert
        vm.prank(owner);
        vm.expectRevert();
        coinvestedPosition.setCurrency(IERC20(address(newCurrency)));

        // Add to allowList with both required bits → accepted
        vm.prank(admin);
        allowList.set(address(newCurrency), TRUSTED_CURRENCY | EURO_CURRENCY);
        vm.prank(owner);
        coinvestedPosition.setCurrency(IERC20(address(newCurrency)));
        assertEq(address(coinvestedPosition.currency()), address(newCurrency));
    }

    function testSetCurrencyDoesNotUpdateBasePriceDecimals() public {
        uint8 decimalsBefore = coinvestedPosition.basePriceDecimals();
        // Ensure eure has different decimals so the assertion is meaningful
        assertTrue(eure.decimals() != decimalsBefore, "test requires new currency to have different decimals");
        vm.prank(owner);
        coinvestedPosition.setCurrency(IERC20(address(eure)));
        assertEq(coinvestedPosition.basePriceDecimals(), decimalsBefore, "basePriceDecimals must not change");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 4: setTokenPrice() / pause() / unpause() ─────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSetTokenPriceOnlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setTokenPrice(200e6);
    }

    function testPauseOnlyOwner() public {
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPosition.unpause();
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.pause();
    }

    function testUnpauseOnlyOwner() public {
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e6);
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.unpause();
    }

    function testUnpauseRevertsWhenTokenPriceZero() public {
        // tokenPrice is 0 after init
        assertEq(coinvestedPosition.tokenPrice(), 0);
        vm.prank(owner);
        vm.expectRevert("tokenPrice must be set before unpausing");
        coinvestedPosition.unpause();
    }

    function testSetTokenPriceZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert("_tokenPrice needs to be a non-zero amount");
        coinvestedPosition.setTokenPrice(0);
    }

    function testUnpauseSucceedsAfterSetTokenPrice() public {
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPosition.unpause();
        assertFalse(coinvestedPosition.paused());
    }

    function testPauseRePausesAndBuyReverts() public {
        _setupBuy(10e18, 200e6);
        vm.prank(owner);
        coinvestedPosition.pause();
        _fundBuyer(eurc, 2000e6);
        vm.prank(buyer);
        vm.expectRevert("Pausable: paused");
        coinvestedPosition.buy(1e18, type(uint256).max, tokenReceiver);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 5: setReceiver() ──────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSetReceiverOnlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setReceiver(buyer);
    }

    function testSetReceiverZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("receiver can not be zero address");
        coinvestedPosition.setReceiver(address(0));
    }

    function testSetReceiverStoresAndEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ReceiverChanged(leadA);
        coinvestedPosition.setReceiver(leadA);
        assertEq(coinvestedPosition.receiver(), leadA);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 6: buy() — Core Logic ────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testBuyWhenPausedReverts() public {
        // coinvestedPosition is paused after init
        eurc.mint(buyer, 1000e6);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition), 1000e6);
        vm.prank(buyer);
        vm.expectRevert("Pausable: paused");
        coinvestedPosition.buy(1e18, 1000e6, tokenReceiver);
    }

    function testBuyMaxCurrencyAmountTooLowReverts() public {
        _setupBuy(10e18, 200e6);
        _fundBuyer(eurc, 200e6);
        vm.prank(buyer);
        vm.expectRevert("Purchase more expensive than _maxCurrencyAmount");
        coinvestedPosition.buy(1e18, 100e6, tokenReceiver); // needs 200e6 but max=100e6
    }

    function testBuyTokensGoToTokenReceiver() public {
        _setupBuy(10e18, 200e6);
        _fundBuyer(eurc, 400e6);
        address differentReceiver = address(0xBEEF);
        vm.prank(buyer);
        coinvestedPosition.buy(1e18, 400e6, differentReceiver);
        assertEq(token.balanceOf(differentReceiver), 1e18, "tokens should go to tokenReceiver");
        assertEq(token.balanceOf(buyer), 0, "buyer should not receive tokens");
    }

    function testBuyEmitsTokensBoughtEvent() public {
        _setupBuy(10e18, 200e6);
        _fundBuyer(eurc, 400e6);
        vm.prank(buyer);
        vm.expectEmit(true, true, true, true);
        emit TokensBought(buyer, 1e18, 200e6);
        coinvestedPosition.buy(1e18, 400e6, tokenReceiver);
    }

    function testBuyZeroFeeCorrectCarrySplit() public {
        // 2 tokens at tokenPrice=200e6, basePrice=100e6
        // paid=400e6, fee=0, remaining=400e6, basePayout=200e6, carry=200e6
        // A (10%): floor(carry * CARRY_10PCT / uint64.max) = floor(200e6 * (uint64.max/10) / uint64.max) = 20e6
        // B (5%):  floor(carry * CARRY_5PCT / uint64.max)  = floor(200e6 * (uint64.max/20) / uint64.max) = 10e6
        // receiver: 400e6 - 20e6 - 10e6 = 370e6
        _setupBuy(10e18, 200e6);
        _fundBuyer(eurc, 400e6);

        uint256 carry = 200e6;
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedB = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = 400e6 - expectedA - expectedB;

        vm.prank(buyer);
        coinvestedPosition.buy(2e18, 400e6, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), expectedA, "leadA carry");
        assertEq(eurc.balanceOf(leadB), expectedB, "leadB carry");
        assertEq(eurc.balanceOf(receiver), expectedReceiver, "receiver");
    }

    function testBuyNonZeroFeeDeductedBeforeCarry() public {
        // Deploy with non-zero fee
        Fees memory fees = Fees(0, 100, 0, 0); // 1% crowdinvesting fee (bps = 100)
        IFeeSettingsV2 feeSettings100 = createFeeSettings(
            trustedForwarder,
            admin,
            fees,
            feeCollector,
            feeCollector,
            feeCollector
        );
        // Deploy new token with this fee settings
        Token tokenWithFee = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings100, admin, allowList, 0, "FeeToken", "FTK")
        );
        vm.startPrank(admin);
        tokenWithFee.grantRole(tokenWithFee.MINTALLOWER_ROLE(), admin);
        vm.stopPrank();

        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(eurc)),
            token: tokenWithFee
        });
        CoinvestedPosition coinvestedPositionWithFee = CoinvestedPosition(
            factory.createCoinvestedPositionClone(bytes32("fee"), trustedForwarder, args)
        );

        vm.prank(admin);
        tokenWithFee.mint(address(coinvestedPositionWithFee), 10e18);
        vm.prank(owner);
        coinvestedPositionWithFee.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPositionWithFee.unpause();

        uint256 currencyAmount = 400e6; // 2 tokens at 200e6
        eurc.mint(buyer, currencyAmount);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPositionWithFee), currencyAmount);

        // fee = 1% of 400e6 = 4e6
        uint256 fee = 4e6;
        uint256 remaining = currencyAmount - fee;
        // scaledBasePrice = 100e6 (same dec), basePayout for 2 tokens = 200e6
        uint256 carry = remaining > 200e6 ? remaining - 200e6 : 0;
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedB = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = remaining - expectedA - expectedB;

        vm.prank(buyer);
        coinvestedPositionWithFee.buy(2e18, currencyAmount, tokenReceiver);

        assertEq(eurc.balanceOf(feeCollector), fee, "fee collector");
        assertEq(eurc.balanceOf(leadA), expectedA, "leadA");
        assertEq(eurc.balanceOf(leadB), expectedB, "leadB");
        assertEq(eurc.balanceOf(receiver), expectedReceiver, "receiver");
    }

    function testBuyAtExactlyBasePriceCarryIsZero() public {
        // tokenPrice == basePrice → carry = 0, receiver gets everything
        _setupBuy(10e18, 100e6); // tokenPrice = basePrice = 100e6
        uint256 paid = 100e6; // 1 token
        _fundBuyer(eurc, paid);

        vm.prank(buyer);
        coinvestedPosition.buy(1e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), 0, "leadA should get 0");
        assertEq(eurc.balanceOf(leadB), 0, "leadB should get 0");
        assertEq(eurc.balanceOf(receiver), paid, "receiver gets everything");
    }

    function testBuyBelowBasePriceCarryIsZero() public {
        // tokenPrice < basePrice → remaining < basePayout → carry = 0
        // Need to set tokenPrice below basePrice (which is 100e6)
        _setupBuy(10e18, 50e6); // tokenPrice = 50e6 < basePrice = 100e6
        uint256 paid = 50e6; // 1 token at 50e6
        _fundBuyer(eurc, paid);

        vm.prank(buyer);
        coinvestedPosition.buy(1e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), 0, "leadA should get 0");
        assertEq(eurc.balanceOf(leadB), 0, "leadB should get 0");
        assertEq(eurc.balanceOf(receiver), paid, "receiver gets full remaining");
    }

    function testBuyConcreteExampleWithThreeLeadInvestors() public {
        // Setup: 0 fee, 2 Tokens (18 dec), basePrice = 300e6, tokenPrice = 400e6, currency 6 dec
        // Paid: 800e6. Fee: 0. Remaining: 800e6. BasePayout: 600e6. Carry: 200e6.
        // Lead investors: 5% + 2% + 10%
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](3);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: CARRY_5PCT}); // 5%
        leadInvestors[1] = LeadInvestor({account: leadB, carryFraction: CARRY_2PCT}); // 2%
        leadInvestors[2] = LeadInvestor({account: tokenReceiver, carryFraction: CARRY_10PCT}); // 10%
        CoinvestedPosition coinvestedPositionThreeLeads = _deployCoinvestedPosition(
            bytes32("3leads"),
            300e6,
            eurc,
            leadInvestors
        );

        vm.prank(admin);
        token.mint(address(coinvestedPositionThreeLeads), 10e18);
        vm.prank(owner);
        coinvestedPositionThreeLeads.setTokenPrice(400e6);
        vm.prank(owner);
        coinvestedPositionThreeLeads.unpause();

        uint256 paid = 800e6;
        eurc.mint(buyer, paid);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPositionThreeLeads), paid);

        uint256 carry = 200e6;
        uint256 shareA = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 shareB = (uint256(CARRY_2PCT) * carry) / type(uint64).max;
        uint256 shareC = (uint256(CARRY_10PCT) * carry) / type(uint64).max;

        vm.prank(buyer);
        coinvestedPositionThreeLeads.buy(2e18, paid, address(0xCAFE));

        assertEq(eurc.balanceOf(leadA), shareA, "5% share"); // 10e6
        assertEq(eurc.balanceOf(leadB), shareB, "2% share"); // 4e6
        assertEq(eurc.balanceOf(tokenReceiver), shareC, "10% share"); // 20e6
        assertEq(eurc.balanceOf(receiver), paid - shareA - shareB - shareC, "receiver");
    }

    function testBuyCurrencyAmountCeilingRounded() public {
        // 1 token at price 3 in a 0-decimal currency scenario:
        // currencyAmount = ceil(1 * 3 / 1) = 3 — trivial.
        // Instead test with indivisible: 1.5 token bits at price 1 = ceil(1.5) = 2 not 1.
        // tokenAmount = 1, tokenPrice = 3, token decimals = 18 → amount = ceil(1 * 3 / 1e18)
        // For a meaningful test: tokenAmount = 1e12 (sub-unit), tokenPrice = 1e6, ceil(1e12 * 1e6 / 1e18) = ceil(1) = 1
        // Test with non-divisible: tokenAmount = 1, tokenPrice = 1e6 → ceil(1 * 1e6 / 1e18) = 1
        // Better: tokenAmount = 1e12 + 1, tokenPrice = 1e6, need ceil((1e12+1)*1e6 / 1e18) = 2
        _setupBuy(10e18, 1e6); // tokenPrice = 1 eurc per token
        uint256 tokenAmt = 1e12 + 1; // slightly above 1 micro-token
        // exact = (1e12+1)*1e6 / 1e18 = 1.000001e6/1e6 → 1.000001... → ceiling = 2
        uint256 expectedCost = 2;
        eurc.mint(buyer, 10e6);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition), 10e6);

        uint256 balBefore = eurc.balanceOf(buyer);
        vm.prank(buyer);
        coinvestedPosition.buy(tokenAmt, 10e6, tokenReceiver);
        uint256 spent = balBefore - eurc.balanceOf(buyer);
        assertEq(spent, expectedCost, "ceiling rounding should charge 2 bits");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 7: buy() — Cross-currency Decimal Scaling ────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testScenarioA_Upscaling() public {
        // basePriceDecimals=6, setCurrency→EURe (18 dec), tokenPrice=200e18
        // scaledBasePrice = 100e6 scaled to 18 dec = 100e18
        // buy 2 tokens: paid=400e18, basePayout=200e18, carry=200e18
        assertEq(coinvestedPosition.basePriceDecimals(), 6, "basePriceDecimals unchanged");

        vm.prank(owner);
        coinvestedPosition.setCurrency(IERC20(address(eure)));

        vm.prank(admin);
        token.mint(address(coinvestedPosition), 10e18);
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e18);
        vm.prank(owner);
        coinvestedPosition.unpause();

        uint256 paid = 400e18;
        eure.mint(buyer, paid);
        vm.prank(buyer);
        eure.approve(address(coinvestedPosition), paid);

        uint256 carry = 200e18;
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedB = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = paid - expectedA - expectedB;

        vm.prank(buyer);
        coinvestedPosition.buy(2e18, paid, tokenReceiver);

        assertEq(eure.balanceOf(leadA), expectedA, "leadA (18dec)");
        assertEq(eure.balanceOf(leadB), expectedB, "leadB (18dec)");
        assertEq(eure.balanceOf(receiver), expectedReceiver, "receiver (18dec)");
    }

    function testScenarioB_Downscaling() public {
        // Deploy with EURe (18 dec) as baseCurrency → basePriceDecimals=18, basePrice=100e18
        // Then setCurrency→EURc (6 dec), tokenPrice=200e6
        // scaledBasePrice = 100e18 / 1e12 = 100e6
        CoinvestedPosition coinvestedPosition18 = _deployCoinvestedPosition(
            bytes32("18base"),
            100e18,
            eure,
            _defaultLeadInvestors()
        );
        assertEq(coinvestedPosition18.basePriceDecimals(), 18);

        vm.prank(owner);
        coinvestedPosition18.setCurrency(IERC20(address(eurc)));

        vm.prank(admin);
        token.mint(address(coinvestedPosition18), 10e18);
        vm.prank(owner);
        coinvestedPosition18.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPosition18.unpause();

        // buy 2 tokens: paid=400e6, scaledBasePrice=100e6, basePayout=200e6, carry=200e6
        uint256 paid = 400e6;
        eurc.mint(buyer, paid);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition18), paid);

        uint256 carry = 200e6;
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedB = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = paid - expectedA - expectedB;

        vm.prank(buyer);
        coinvestedPosition18.buy(2e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), expectedA, "leadA (downscaled)");
        assertEq(eurc.balanceOf(leadB), expectedB, "leadB (downscaled)");
        assertEq(eurc.balanceOf(receiver), expectedReceiver, "receiver (downscaled)");
    }

    function testScenarioC_EqualDecimals_NoScaling() public {
        // basePriceDecimals=6, currency=EURc (6 dec) — same decimals, no scaling
        _setupBuy(10e18, 200e6);
        uint256 paid = 200e6; // 1 token
        _fundBuyer(eurc, paid);

        uint256 carry = 200e6 - 100e6; // 100e6
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedB = (uint256(CARRY_5PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = paid - expectedA - expectedB;

        vm.prank(buyer);
        coinvestedPosition.buy(1e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), expectedA);
        assertEq(eurc.balanceOf(leadB), expectedB);
        assertEq(eurc.balanceOf(receiver), expectedReceiver);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 8: buy() — Sequential Partial Sells ───────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSequentialPartialSells() public {
        // 100 tokens total; basePrice=100e6 EURc (6 dec); leads A=10%, B=5%
        vm.prank(admin);
        token.mint(address(coinvestedPosition), 100e18);

        // ── Tranche 1: 5 tokens, EURc, tokenPrice=150e6 ──────────────────────
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(150e6);
        vm.prank(owner);
        coinvestedPosition.unpause();

        uint256 t1paid = 750e6; // 5 tokens * 150e6
        eurc.mint(buyer, t1paid);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition), t1paid);

        // basePayout = 5*100e6 = 500e6, carry = 250e6
        uint256 t1carry = 250e6;
        uint256 t1A = (uint256(CARRY_10PCT) * t1carry) / type(uint64).max;
        uint256 t1B = (uint256(CARRY_5PCT) * t1carry) / type(uint64).max;

        vm.prank(buyer);
        coinvestedPosition.buy(5e18, t1paid, tokenReceiver);

        assertEq(token.balanceOf(address(coinvestedPosition)), 95e18, "95 tokens after tranche 1");
        assertEq(eurc.balanceOf(leadA), t1A, "leadA after tranche 1");
        assertEq(eurc.balanceOf(leadB), t1B, "leadB after tranche 1");

        // ── Tranche 2: 40 tokens, EURe (18 dec), tokenPrice=200e18 ───────────
        vm.prank(owner);
        coinvestedPosition.pause();
        vm.prank(owner);
        coinvestedPosition.setCurrency(IERC20(address(eure)));
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e18);
        vm.prank(owner);
        coinvestedPosition.unpause();

        uint256 t2paid = 8000e18; // 40 tokens * 200e18
        eure.mint(buyer, t2paid);
        vm.prank(buyer);
        eure.approve(address(coinvestedPosition), t2paid);

        // scaledBasePrice: 100e6 scaled to 18 dec = 100e18
        // basePayout = 40 * 100e18 = 4000e18, carry = 4000e18
        uint256 t2carry = 4000e18;
        uint256 t2A = (uint256(CARRY_10PCT) * t2carry) / type(uint64).max;
        uint256 t2B = (uint256(CARRY_5PCT) * t2carry) / type(uint64).max;

        vm.prank(buyer);
        coinvestedPosition.buy(40e18, t2paid, tokenReceiver);

        assertEq(token.balanceOf(address(coinvestedPosition)), 55e18, "55 tokens after tranche 2");
        assertEq(eure.balanceOf(leadA), t2A, "leadA EURe after tranche 2");
        assertEq(eure.balanceOf(leadB), t2B, "leadB EURe after tranche 2");
        // EURc from tranche 1 unchanged
        assertEq(eurc.balanceOf(leadA), t1A, "leadA EURc unchanged");
        assertEq(eurc.balanceOf(leadB), t1B, "leadB EURc unchanged");

        // ── Tranche 3: 55 tokens, tokenPrice=80e18 (below base after scaling) ─
        vm.prank(owner);
        coinvestedPosition.pause();
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(80e18);
        vm.prank(owner);
        coinvestedPosition.unpause();

        uint256 t3paid = 55 * 80e18; // 4400e18
        eure.mint(buyer, t3paid);
        vm.prank(buyer);
        eure.approve(address(coinvestedPosition), t3paid);

        // scaledBasePrice = 100e18, basePayout = 55*100e18 = 5500e18 > 4400e18 → carry=0
        vm.prank(buyer);
        coinvestedPosition.buy(55e18, t3paid, tokenReceiver);

        assertEq(token.balanceOf(address(coinvestedPosition)), 0, "0 tokens after tranche 3");
        // EURe lead balances unchanged after tranche 3 (carry=0)
        assertEq(eure.balanceOf(leadA), t2A, "leadA EURe unchanged after tranche 3");
        assertEq(eure.balanceOf(leadB), t2B, "leadB EURe unchanged after tranche 3");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 9: _settle() Sweep Behavior ──────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSettleSweepsExtraSameCurrencyToReceiver() public {
        // Extra 500e6 EURc sent before buy. Buy 10 tokens at 200e6, basePrice=100e6.
        // carry from buyer = 1000e6; A gets 100e6; receiver gets 1000e6 + 500e6 = ...
        // Actually: contract balance before sweep = 2000e6 (from buyer) - 100e6 (A) + 500e6 (extra) = 2400e6
        // receiver sweep = 2400e6

        // Use a fresh coinvestedPosition with single 10% lead investor to simplify
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](1);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: CARRY_10PCT});
        CoinvestedPosition coinvestedPositionSweep = _deployCoinvestedPosition(
            bytes32("sweep"),
            100e6,
            eurc,
            leadInvestors
        );

        vm.prank(admin);
        token.mint(address(coinvestedPositionSweep), 10e18);
        vm.prank(owner);
        coinvestedPositionSweep.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPositionSweep.unpause();

        // Send extra currency directly to contract
        eurc.mint(address(coinvestedPositionSweep), 500e6);

        // Buyer pays 2000e6 for 10 tokens
        uint256 paid = 2000e6;
        eurc.mint(buyer, paid);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPositionSweep), paid);

        uint256 carry = 1000e6; // 2000e6 - 1000e6 basePayout
        uint256 expectedA = (uint256(CARRY_10PCT) * carry) / type(uint64).max;
        uint256 expectedReceiver = 2000e6 - expectedA + 500e6; // buyer payment minus A's share, plus extra

        vm.prank(buyer);
        coinvestedPositionSweep.buy(10e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), expectedA, "A's carry not inflated");
        assertEq(eurc.balanceOf(receiver), expectedReceiver, "receiver gets share + extra");
    }

    function testSettleSweepCarryZeroWithExtra() public {
        // tokenPrice == basePrice → carry=0; receiver gets everything including extra
        LeadInvestor[] memory leadInvestors = new LeadInvestor[](1);
        leadInvestors[0] = LeadInvestor({account: leadA, carryFraction: CARRY_10PCT});
        CoinvestedPosition coinvestedPositionZeroCarry = _deployCoinvestedPosition(
            bytes32("zeroExtra"),
            100e6,
            eurc,
            leadInvestors
        );

        vm.prank(admin);
        token.mint(address(coinvestedPositionZeroCarry), 10e18);
        vm.prank(owner);
        coinvestedPositionZeroCarry.setTokenPrice(100e6);
        vm.prank(owner);
        coinvestedPositionZeroCarry.unpause();

        eurc.mint(address(coinvestedPositionZeroCarry), 300e6); // extra

        uint256 paid = 100e6; // 1 token at base price
        eurc.mint(buyer, paid);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPositionZeroCarry), paid);

        vm.prank(buyer);
        coinvestedPositionZeroCarry.buy(1e18, paid, tokenReceiver);

        assertEq(eurc.balanceOf(leadA), 0, "lead investor gets 0 when carry=0");
        assertEq(eurc.balanceOf(receiver), paid + 300e6, "receiver gets all including extra");
    }

    function testSettleDifferentCurrencyNotSwept() public {
        // Active currency = EURe; a pre-existing EURc balance stays on the contract
        vm.prank(owner);
        coinvestedPosition.setCurrency(IERC20(address(eure)));

        vm.prank(admin);
        token.mint(address(coinvestedPosition), 10e18);
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e18);
        vm.prank(owner);
        coinvestedPosition.unpause();

        // Put EURc on the contract
        eurc.mint(address(coinvestedPosition), 1000e6);

        uint256 paid = 200e18;
        eure.mint(buyer, paid);
        vm.prank(buyer);
        eure.approve(address(coinvestedPosition), paid);

        vm.prank(buyer);
        coinvestedPosition.buy(1e18, paid, tokenReceiver);

        // EURc should remain on contract (not swept)
        assertEq(eurc.balanceOf(address(coinvestedPosition)), 1000e6, "EURc not swept");
        // EURe swept to receiver and leads
        assertEq(eure.balanceOf(address(coinvestedPosition)), 0, "EURe fully distributed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 10: Fuzz ──────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_BuyPayoutsSum(uint96 tokenAmt, uint64 priceAboveBase) public {
        vm.assume(tokenAmt > 0 && tokenAmt <= 1e24); // reasonable range
        uint256 tokenPrice = uint256(100e6) + uint256(priceAboveBase); // at or above base

        vm.prank(admin);
        token.mint(address(coinvestedPosition), tokenAmt);
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(tokenPrice);
        vm.prank(owner);
        coinvestedPosition.unpause();

        uint256 currencyAmount = (uint256(tokenAmt) * tokenPrice + 1e18 - 1) / 1e18; // ceil
        eurc.mint(buyer, currencyAmount);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition), currencyAmount);

        uint256 buyerBalBefore = eurc.balanceOf(buyer);

        vm.prank(buyer);
        coinvestedPosition.buy(tokenAmt, currencyAmount, tokenReceiver);

        uint256 spent = buyerBalBefore - eurc.balanceOf(buyer);
        uint256 totalOut = eurc.balanceOf(leadA) + eurc.balanceOf(leadB) + eurc.balanceOf(receiver);

        assertEq(spent, totalOut, "invariant: sum of payouts == currency paid");
    }

    function testFuzz_ScaleToDecimals(uint256 amount, uint8 targetDecimals) public {
        // basePriceDecimals = 6 (from setUp)
        vm.assume(targetDecimals <= 30);
        vm.assume(amount <= type(uint128).max); // prevent overflow

        // We test via buy() by observing no revert. Instead call directly via a helper.
        // We can't call _scaleToDecimals directly (internal). Test indirectly:
        // Deploy coinvestedPosition with eure (18 dec base), set currency to eurc (6 dec) → downscaling
        CoinvestedPosition coinvestedPosition18 = _deployCoinvestedPosition(
            bytes32("fuzz18"),
            100e18,
            eure,
            _defaultLeadInvestors()
        );

        // Just verify the deployment is fine and basePriceDecimals correct
        assertEq(coinvestedPosition18.basePriceDecimals(), 18);
        // The actual scaling is tested through buy() in other tests
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 11: Access Control (consolidated) ─────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testAccessControl_SetCurrency() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setCurrency(IERC20(address(eure)));
    }

    function testAccessControl_SetTokenPrice() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setTokenPrice(200e6);
    }

    function testAccessControl_SetReceiver() public {
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.setReceiver(buyer);
    }

    function testAccessControl_Pause() public {
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPosition.unpause();
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.pause();
    }

    function testAccessControl_Unpause() public {
        vm.prank(owner);
        coinvestedPosition.setTokenPrice(200e6);
        vm.prank(buyer);
        vm.expectRevert("Ownable: caller is not the owner");
        coinvestedPosition.unpause();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 12: Reentrancy ────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testReentrancyBuyReverts() public {
        // Deploy malicious currency
        MaliciousCoinvestedToken malicious = new MaliciousCoinvestedToken();

        // Register on allowList
        vm.prank(admin);
        allowList.set(address(malicious), TRUSTED_CURRENCY | EURO_CURRENCY);

        // Deploy a coinvestedPosition using malicious currency
        LeadInvestor[] memory leadInvestors = _defaultLeadInvestors();
        CoinvestedPositionInitializerArguments memory args = CoinvestedPositionInitializerArguments({
            owner: owner,
            receiver: receiver,
            leadInvestors: leadInvestors,
            basePrice: 100e6,
            baseCurrency: IERC20(address(malicious)),
            token: token
        });
        CoinvestedPosition coinvestedPositionMalicious = CoinvestedPosition(
            factory.createCoinvestedPositionClone(bytes32("mal"), trustedForwarder, args)
        );
        malicious.setTarget(address(coinvestedPositionMalicious));

        vm.prank(admin);
        token.mint(address(coinvestedPositionMalicious), 100e18);
        vm.prank(owner);
        coinvestedPositionMalicious.setTokenPrice(200e6);
        vm.prank(owner);
        coinvestedPositionMalicious.unpause();

        malicious.mint(buyer, 1000e6);
        vm.prank(buyer);
        malicious.approve(address(coinvestedPositionMalicious), 1000e6);

        vm.prank(buyer);
        vm.expectRevert("ReentrancyGuard: reentrant call");
        coinvestedPositionMalicious.buy(1e18, 1000e6, tokenReceiver);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Section 13: ERC2771 / Meta-transactions ───────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testERC2771BuyIdentifiesBuyer() public {
        _setupBuy(10e18, 200e6);
        eurc.mint(buyer, 400e6);
        vm.prank(buyer);
        eurc.approve(address(coinvestedPosition), 400e6);

        // Encode the call as a trusted forwarder would: calldata + buyer address appended
        bytes memory callData = abi.encodePacked(
            abi.encodeWithSelector(CoinvestedPosition.buy.selector, uint256(1e18), uint256(400e6), tokenReceiver),
            buyer
        );
        vm.prank(trustedForwarder);
        (bool success, ) = address(coinvestedPosition).call(callData);
        assertTrue(success, "ERC2771 buy should succeed");
        // The event buyer should be the appended address (buyer), not trustedForwarder
        assertEq(token.balanceOf(tokenReceiver), 1e18, "tokens transferred");
    }

    function testUntrustedForwarderCannotSpoofSender() public {
        _setupBuy(10e18, 200e6);
        // Mint to untrusted, not buyer
        address untrusted = address(0xDEAD);
        eurc.mint(untrusted, 400e6);
        vm.prank(untrusted);
        eurc.approve(address(coinvestedPosition), 400e6);

        // Untrusted tries to append buyer as sender
        bytes memory callData = abi.encodePacked(
            abi.encodeWithSelector(CoinvestedPosition.buy.selector, uint256(1e18), uint256(400e6), tokenReceiver),
            buyer // spoof buyer
        );
        // When called by untrusted forwarder, _msgSender() returns msg.sender (untrusted),
        // not the appended address (buyer). So transferFrom charges untrusted, not buyer.
        uint256 untrustedBefore = eurc.balanceOf(untrusted); // 400e6
        vm.prank(untrusted);
        (bool success, ) = address(coinvestedPosition).call(callData);
        // buyer has 0 balance throughout — it is never the msg.sender
        assertEq(eurc.balanceOf(buyer), 0, "buyer balance never changes");
        if (success) {
            // untrusted was charged (the buy succeeded but used untrusted as sender)
            assertLt(eurc.balanceOf(untrusted), untrustedBefore, "untrusted was charged, not buyer");
        }
        // Either way, the buyer was not spoofed as the payer
    }
}
