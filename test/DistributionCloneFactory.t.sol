// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/DistributionCloneFactory.sol";
import "../contracts/Distribution.sol";
import "./resources/FakePaymentToken.sol";
import "./resources/CloneCreators.sol";

contract DistributionCloneFactoryTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant owner = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant currencyProvider = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;
    address public constant trustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;

    bytes32 public constant EXAMPLE_SALT = bytes32(0);
    address public constant EXAMPLE_OWNER = address(0x1001);
    uint256 public constant EXAMPLE_TOTAL_CURRENCY = 100e6;

    uint64 public reassignAfter;
    uint256 public snapshotId;

    AllowList allowList;
    FakePaymentToken currency;
    Token token;
    DistributionCloneFactory factory;
    TokenProxyFactory tokenFactory;

    function setUp() public {
        reassignAfter = uint64(block.timestamp + 31 days);

        allowList = createAllowList(trustedForwarder, admin);
        currency = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(currency), TRUSTED_CURRENCY);

        address tokenLogic = address(new Token(trustedForwarder));
        tokenFactory = new TokenProxyFactory(tokenLogic);
        IFeeSettingsV2 feeSettings = createFeeSettings(trustedForwarder, admin, buildFeeTypes(0, 0, 0, admin, admin, admin));
        token = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "DistToken", "DST")
        );

        vm.startPrank(admin);
        token.grantRole(token.MINTALLOWER_ROLE(), admin);
        token.mint(admin, 1000e18); // give admin tokens so snapshot is non-zero
        snapshotId = token.createSnapshot();
        vm.stopPrank();

        factory = new DistributionCloneFactory(address(new Distribution(trustedForwarder)));
    }

    /// @dev Returns baseline DistributionInitializerArguments
    function _baseArgs() internal view returns (DistributionInitializerArguments memory) {
        return
            DistributionInitializerArguments({
                owner: EXAMPLE_OWNER,
                token: token,
                snapshotId: snapshotId,
                currency: IERC20(address(currency)),
                totalCurrencyAmount: EXAMPLE_TOTAL_CURRENCY,
                reassignAfter: reassignAfter
            });
    }

    /// @dev Predict address, fund, approve, and deploy
    function _deploy(
        bytes32 salt,
        address _trustedForwarder,
        DistributionInitializerArguments memory args
    ) internal returns (address) {
        address cloneAddr = factory.predictCloneAddress(salt, _trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        return factory.createDistributionClone(salt, _trustedForwarder, currencyProvider, args);
    }

    // ========== F1-D. Address Prediction ==========

    function testBothPredictOverloadsMatch() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        bytes32 precomputed = keccak256(abi.encode(EXAMPLE_SALT, trustedForwarder, args));

        address fromSalt = factory.predictCloneAddress(precomputed);
        address fromParams = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertEq(fromSalt, fromParams, "overloads disagree");
    }

    function testActualAddressMatchesPrediction() public {
        DistributionInitializerArguments memory args = _baseArgs();
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        address actual = _deploy(EXAMPLE_SALT, trustedForwarder, args);
        assertEq(predicted, actual);
    }

    function testNewCloneEventEmitted() public {
        DistributionInitializerArguments memory args = _baseArgs();
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(predicted, args.totalCurrencyAmount);
        vm.expectEmit(true, false, false, false, address(factory));
        emit CloneFactory.NewClone(predicted);
        factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    // ========== F2-D. Each Salt Parameter Changes the Address ==========

    function testRawSaltChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(bytes32(uint256(1)), trustedForwarder, args);
        address a2 = factory.predictCloneAddress(bytes32(uint256(2)), trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testTrustedForwarderChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, address(0x9999), args);
        assertFalse(a1 == a2);
    }

    function testOwnerChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.owner = address(0x9999);
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testTokenChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.token = Token(address(0x9999)); // different address for prediction only
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testSnapshotIdChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.snapshotId = snapshotId + 1;
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testCurrencyChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.currency = IERC20(address(0x9999));
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testTotalCurrencyAmountChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.totalCurrencyAmount = EXAMPLE_TOTAL_CURRENCY + 1;
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    function testReassignAfterChangesAddress() public view {
        DistributionInitializerArguments memory args = _baseArgs();
        address a1 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        args.reassignAfter = reassignAfter + 1;
        address a2 = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        assertFalse(a1 == a2);
    }

    // ========== F3-D. _currencyProvider Is Not in the Salt ==========

    function testCurrencyProviderDoesNotAffectAddress(address _currencyProvider) public {
        vm.assume(_currencyProvider != address(0));
        DistributionInitializerArguments memory args = _baseArgs();
        bytes32 salt = bytes32("salt");
        address cloneAddr = factory.predictCloneAddress(salt, trustedForwarder, args);
        currency.mint(_currencyProvider, args.totalCurrencyAmount);
        vm.prank(_currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        address _distribution = factory.createDistributionClone(salt, trustedForwarder, _currencyProvider, args);
        assertEq(_distribution, cloneAddr);
    }

    // ========== F4-D. Wrong Trusted Forwarder Reverts ==========

    function testCreateWithWrongForwarderReverts() public {
        DistributionInitializerArguments memory args = _baseArgs();
        address wrongForwarder = address(0xBAD);
        address predicted = factory.predictCloneAddress(EXAMPLE_SALT, wrongForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(predicted, args.totalCurrencyAmount);
        vm.expectRevert("DistributionCloneFactory: Unexpected trustedForwarder");
        factory.createDistributionClone(EXAMPLE_SALT, wrongForwarder, currencyProvider, args);
    }

    // ========== F5-D. Second Deployment Fails ==========

    function testSecondDeploymentReverts() public {
        DistributionInitializerArguments memory args = _baseArgs();
        _deploy(EXAMPLE_SALT, trustedForwarder, args);
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        vm.expectRevert("ERC1167: create2 failed");
        factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    // ========== F6-D. Initialization ==========

    function testStateVariablesSetCorrectly() public {
        DistributionInitializerArguments memory args = _baseArgs();
        Distribution clone = Distribution(_deploy(EXAMPLE_SALT, trustedForwarder, args));

        assertEq(clone.owner(), args.owner);
        assertEq(address(clone.token()), address(args.token));
        assertEq(clone.snapshotId(), args.snapshotId);
        assertEq(address(clone.currency()), address(args.currency));
        assertEq(clone.totalCurrencyAmount(), args.totalCurrencyAmount);
        assertEq(clone.reassignAfter(), args.reassignAfter);
        assertEq(currency.balanceOf(address(clone)), args.totalCurrencyAmount);
        assertTrue(clone.isTrustedForwarder(trustedForwarder));
    }

    function testReInitializingCloneReverts() public {
        DistributionInitializerArguments memory args = _baseArgs();
        Distribution clone = Distribution(_deploy(EXAMPLE_SALT, trustedForwarder, args));
        vm.expectRevert("Initializable: contract is already initialized");
        clone.initialize(args, currencyProvider);
    }

    // ========== F7-D. Funding via Clone Address Approval ==========

    function testApprovalToFactoryReverts() public {
        DistributionInitializerArguments memory args = _baseArgs();
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(address(factory), args.totalCurrencyAmount); // wrong target
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    function testApprovalBelowRequiredReverts() public {
        DistributionInitializerArguments memory args = _baseArgs();
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount - 1);
        vm.expectRevert("ERC20: insufficient allowance");
        factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
    }

    function testExactApprovalSucceeds() public {
        DistributionInitializerArguments memory args = _baseArgs();
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        currency.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        currency.approve(cloneAddr, args.totalCurrencyAmount);
        address actual = factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
        assertEq(currency.balanceOf(actual), args.totalCurrencyAmount);
    }

    // ========== F8-D. Invalid Currency Reverts ==========

    function testMissingTrustedCurrencyBitReverts() public {
        FakePaymentToken badCurrency = new FakePaymentToken(0, 6);
        // not set on allowList → 0 bits
        DistributionInitializerArguments memory args = _baseArgs();
        args.currency = IERC20(address(badCurrency));
        vm.expectRevert("currency needs to be on the allowlist with TRUSTED_CURRENCY attribute");
        factory.createDistributionClone(bytes32("bad"), trustedForwarder, currencyProvider, args);
    }

    function testTrustedNonEuroCurrencyAccepted() public {
        // Distribution only requires TRUSTED_CURRENCY, not EURO_CURRENCY
        FakePaymentToken nonEuro = new FakePaymentToken(0, 6);
        vm.prank(admin);
        allowList.set(address(nonEuro), TRUSTED_CURRENCY); // trusted, not EURO
        DistributionInitializerArguments memory args = _baseArgs();
        args.currency = IERC20(address(nonEuro));
        // approve and deploy — must succeed
        address cloneAddr = factory.predictCloneAddress(EXAMPLE_SALT, trustedForwarder, args);
        nonEuro.mint(currencyProvider, args.totalCurrencyAmount);
        vm.prank(currencyProvider);
        nonEuro.approve(cloneAddr, args.totalCurrencyAmount);
        address actual = factory.createDistributionClone(EXAMPLE_SALT, trustedForwarder, currencyProvider, args);
        assertFalse(actual == address(0));
    }
}
