// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/ExitCloneFactory.sol";
import "../contracts/Exit.sol";
import "./resources/FakePaymentToken.sol";
import "./resources/CloneCreators.sol";

contract ExitCloneFactoryTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant owner = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant currencyProvider = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;
    address public constant trustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;

    // Constants that appear in example args
    bytes32 public constant EXAMPLE_SALT = bytes32(0);
    address public constant EXAMPLE_OWNER = address(0x1001);
    uint256 public constant EXAMPLE_PRICE = 2e6;
    uint64 public constant EXAMPLE_CLAIM_START = 1000;
    uint64 public constant EXAMPLE_DRAIN_START = 2000;
    uint256 public constant EXAMPLE_TOTAL_CURRENCY = 100e6;

    AllowList allowList;
    FakePaymentToken currency;
    Token token;
    ExitCloneFactory factory;
    TokenProxyFactory tokenFactory;

    function setUp() public {
        allowList = createAllowList(trustedForwarder, admin);
        currency = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(currency), TRUSTED_CURRENCY | EURO_CURRENCY);

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

        factory = new ExitCloneFactory(address(new Exit(trustedForwarder)));
    }

    /// @dev Returns baseline ExitInitializerArguments
    function _baseArgs() internal view returns (ExitInitializerArguments memory) {
        return
            ExitInitializerArguments({
                owner: EXAMPLE_OWNER,
                token: token,
                currency: IERC20(address(currency)),
                pricePerToken: EXAMPLE_PRICE,
                claimStart: EXAMPLE_CLAIM_START,
                drainStart: EXAMPLE_DRAIN_START,
                totalCurrencyAmount: EXAMPLE_TOTAL_CURRENCY
            });
    }

    /// @dev Predict address, fund currencyProvider, approve, and deploy
    function _deploy(
        bytes32 salt,
        address _trustedForwarder,
        ExitInitializerArguments memory args
    ) internal returns (address) {
        address cloneAddr = factory.predictCloneAddress(salt, _trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        return factory.createExitClone(salt, _trustedForwarder, currencyProvider, args);
    }

    // ========== F1-E. Address Prediction ==========

    function testBothPredictOverloadsMatch() public {
        ExitInitializerArguments memory args = _baseArgs();
        bytes32 precomputed = keccak256(abi.encode(EXAMPLE_SALT, trustedForwarder, args));

        address fromSalt = factory.predictCloneAddress(precomputed);
        address fromParams = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertEq(fromSalt, fromParams, "overloads disagree");
    }

    function testActualAddressMatchesPrediction() public {
        ExitInitializerArguments memory args = _baseArgs();
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        address actual = _deploy(EXAMPLE_SALT, trustedForwarder, args);
        assertEq(predicted, actual, "deployed address does not match prediction");
    }

    function testNewCloneEventEmitted() public {
        ExitInitializerArguments memory args = _baseArgs();
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(predicted, args.totalCurrencyAmount);
        vm.expectEmit(true, false, false, false, address(factory));
        emit CloneFactory.NewClone(predicted);
        factory.createExitClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    // ========== F2-E. Each Salt Parameter Changes the Address ==========

    function testSaltChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(bytes32(uint256(1)), trustedForwarder, args);
        address addr2 = factory.predictCloneAddress(bytes32(uint256(2)), trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testTrustedForwarderChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, address(0x9999), args);
        assertFalse(addr1 == addr2);
    }

    function testOwnerChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.owner = address(0x9999);
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testTokenChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        // Use a different token address for prediction only — no need to deploy
        args.token = Token(address(0x9999));
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testCurrencyChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        FakePaymentToken currency2 = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(currency2), TRUSTED_CURRENCY | EURO_CURRENCY);
        args.currency = IERC20(address(currency2));
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testPricePerTokenChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.pricePerToken = EXAMPLE_PRICE + 1;
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testClaimStartChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.claimStart = EXAMPLE_CLAIM_START + 1;
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testDrainStartChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.drainStart = EXAMPLE_DRAIN_START + 1;
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    function testTotalCurrencyAmountChangesAddress() public {
        ExitInitializerArguments memory args = _baseArgs();
        address addr1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.totalCurrencyAmount = EXAMPLE_TOTAL_CURRENCY + 1;
        address addr2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(addr1 == addr2);
    }

    // ========== F3-E. _currencyProvider Is Not in the Salt ==========

    function testCurrencyProviderDoesNotAffectAddress(address _currencyProvider) public {
        vm.assume(_currencyProvider != address(0));
        ExitInitializerArguments memory args = _baseArgs();
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);

        // Provider 1 deploys
        currency.mint(_currencyProvider, args.totalCurrencyAmount);
        vm.prank(_currencyProvider);
        currency.approve(predicted, args.totalCurrencyAmount);
        address actual = factory.createExitClone(EXAMPLE_SALT, trustedForwarder, _currencyProvider, args);
        assertEq(predicted, actual);
    }

    // ========== F4-E. Wrong Trusted Forwarder Reverts ==========

    function testCreateWithWrongForwarderReverts() public {
        // Deploy logic with trustedForwarder but create using a different forwarder
        ExitInitializerArguments memory args = _baseArgs();
        address wrongForwarder = address(0xBAD);
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, wrongForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(predicted, args.totalCurrencyAmount);
        vm.expectRevert("ExitCloneFactory: Unexpected trustedForwarder");
        factory.createExitClone(EXAMPLE_SALT, wrongForwarder, currencyProvider, args);
    }

    // ========== F5-E. Second Deployment Fails ==========

    function testSecondDeploymentWithSameSaltReverts() public {
        ExitInitializerArguments memory args = _baseArgs();
        _deploy(EXAMPLE_SALT, trustedForwarder, args);
        // Second deploy: predict same address, approve, then expect revert
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        vm.expectRevert("ERC1167: create2 failed");
        factory.createExitClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    // ========== F6-E. Initialization ==========

    function testStateVariablesSetCorrectly() public {
        ExitInitializerArguments memory args = _baseArgs();
        Exit clone = Exit(_deploy(EXAMPLE_SALT, trustedForwarder, args));

        assertEq(clone.owner(), args.owner);
        assertEq(address(clone.token()), address(args.token));
        assertEq(address(clone.currency()), address(args.currency));
        assertEq(clone.pricePerToken(), args.pricePerToken);
        assertEq(clone.claimStart(), args.claimStart);
        assertEq(clone.drainStart(), args.drainStart);
        assertEq(currency.balanceOf(address(clone)), args.totalCurrencyAmount);
        assertTrue(clone.isTrustedForwarder(trustedForwarder));
    }

    function testReInitializingCloneReverts() public {
        ExitInitializerArguments memory args = _baseArgs();
        Exit clone = Exit(_deploy(EXAMPLE_SALT, trustedForwarder, args));
        vm.expectRevert("Initializable: contract is already initialized");
        clone.initialize(args, currencyProvider);
    }

    // ========== F7-E. Funding via Clone Address Approval ==========

    function testApprovalToFactoryInsteadOfCloneReverts() public {
        ExitInitializerArguments memory args = _baseArgs();
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(address(factory), args.totalCurrencyAmount); // wrong address
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createExitClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    function testApprovalBelowRequiredReverts() public {
        ExitInitializerArguments memory args = _baseArgs();
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount - 1);
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createExitClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    function testExactApprovalSucceeds() public {
        ExitInitializerArguments memory args = _baseArgs();
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        address actual = factory.createExitClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
        assertEq(currency.balanceOf(actual), args.totalCurrencyAmount);
    }

    // ========== F8-E. Invalid Currency Reverts ==========

    function testMissingTrustedCurrencyBitReverts() public {
        FakePaymentToken badCurrency = new FakePaymentToken(0, 6);
        // only EURO, no TRUSTED
        vm.prank(admin);
        allowList.set(address(badCurrency), EURO_CURRENCY);
        ExitInitializerArguments memory args = _baseArgs();
        args.currency = IERC20(address(badCurrency));
        vm.expectRevert("currency needs to be a trusted EURO currency");
        factory.createExitClone(bytes32("bad1"), trustedForwarder, currencyProvider, args);
    }

    function testMissingEuroCurrencyBitReverts() public {
        FakePaymentToken nonEuro = new FakePaymentToken(0, 6);
        // only TRUSTED, no EURO
        vm.prank(admin);
        allowList.set(address(nonEuro), TRUSTED_CURRENCY);
        ExitInitializerArguments memory args = _baseArgs();
        args.currency = IERC20(address(nonEuro));
        vm.expectRevert("currency needs to be a trusted EURO currency");
        factory.createExitClone(bytes32("bad2"), trustedForwarder, currencyProvider, args);
    }

    function testBothBitsSetSucceeds() public {
        ExitInitializerArguments memory args = _baseArgs();
        address actual = _deploy(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(actual == address(0));
    }
}
