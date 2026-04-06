// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";

import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/TokenExitRegistryCloneFactory.sol";
import "../contracts/TokenExitRegistry.sol";
import "../contracts/IExit.sol";
import "../contracts/Token.sol";
import "./resources/CloneCreators.sol";
import "./resources/FakePaymentToken.sol";

/// @dev Minimal IExit stub used for setExit() tests
contract FakeExit {
    function claim(uint256, address) external {}
}

/**
 * @title TokenExitRegistryTest
 * @notice Tests for TokenExitRegistry and TokenExitRegistryCloneFactory.
 */
contract TokenExitRegistryTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant nonAdmin = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant trustedForwarder = 0xa109709ecfA91A80626ff3989D68F67F5b1dD12a;

    AllowList allowList;
    IFeeSettingsV2 feeSettings;
    Token token;
    TokenProxyFactory tokenFactory;
    TokenExitRegistryCloneFactory tokenExitRegistryFactory;

    function setUp() public {
        allowList = createAllowList(trustedForwarder, admin);
        feeSettings = createFeeSettings(trustedForwarder, admin, buildFeeTypes(0, 0, 0, admin, admin, admin));

        address tokenLogic = address(new Token(trustedForwarder));
        tokenFactory = new TokenProxyFactory(tokenLogic);
        token = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "TestToken", "TTK")
        );

        TokenExitRegistry tokenExitRegistryLogic = new TokenExitRegistry(trustedForwarder);
        tokenExitRegistryFactory = new TokenExitRegistryCloneFactory(address(tokenExitRegistryLogic));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Initialize ───────────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testInitializeHappyPath() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );

        assertEq(address(tokenExitRegistry.token()), address(token), "token not set");
        assertEq(address(tokenExitRegistry.exit()), address(0), "exit should be zero initially");
    }

    function testInitializeRevertsIfTokenIsZero() public {
        // Attempt to create a clone with zero token address — factory should revert
        vm.expectRevert("token can not be zero address");
        tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, Token(address(0)));
    }

    function testLogicContractCannotBeReinitialized() public {
        // The logic contract constructor calls _disableInitializers();
        // deploying it via new is fine (factory pattern), but calling initialize on
        // a newly deployed logic contract should be blocked.
        TokenExitRegistry logicContract = new TokenExitRegistry(trustedForwarder);
        vm.expectRevert("Initializable: contract is already initialized");
        logicContract.initialize(token);
    }

    function testCloneCannotBeReinitializedAfterFactory() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        vm.expectRevert("Initializable: contract is already initialized");
        tokenExitRegistry.initialize(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── setExit ───────────────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSetExitHappyPath() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        FakeExit fakeExit = new FakeExit();

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(tokenExitRegistry));
        emit TokenExitRegistry.ExitSet(IExit(address(fakeExit)));
        tokenExitRegistry.setExit(IExit(address(fakeExit)));

        assertEq(address(tokenExitRegistry.exit()), address(fakeExit), "exit not set correctly");
    }

    function testSetExitRevertsIfCallerIsNotTokenAdmin() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        FakeExit fakeExit = new FakeExit();

        vm.prank(nonAdmin);
        vm.expectRevert("caller is not token admin");
        tokenExitRegistry.setExit(IExit(address(fakeExit)));
    }

    function testSetExitRevertsIfExitIsZeroAddress() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );

        vm.prank(admin);
        vm.expectRevert("exit can not be zero address");
        tokenExitRegistry.setExit(IExit(address(0)));
    }

    function testSetExitRevertsIfAlreadySet() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        FakeExit fakeExit1 = new FakeExit();
        FakeExit fakeExit2 = new FakeExit();

        vm.prank(admin);
        tokenExitRegistry.setExit(IExit(address(fakeExit1)));

        vm.prank(admin);
        vm.expectRevert("exit has already been set");
        tokenExitRegistry.setExit(IExit(address(fakeExit2)));
    }

    function testSetExitOnlyCallableByRoleHolder() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        FakeExit fakeExit = new FakeExit();

        // Grant DEFAULT_ADMIN_ROLE to nonAdmin
        bytes32 defaultAdminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.grantRole(defaultAdminRole, nonAdmin);

        // Now nonAdmin can set exit
        vm.prank(nonAdmin);
        tokenExitRegistry.setExit(IExit(address(fakeExit)));

        assertEq(address(tokenExitRegistry.exit()), address(fakeExit), "exit not set by new admin");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── TokenExitRegistryCloneFactory ────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testFactoryCreatesCloneWithCorrectToken() public {
        TokenExitRegistry tokenExitRegistry = TokenExitRegistry(
            tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token)
        );
        assertEq(address(tokenExitRegistry.token()), address(token));
    }

    function testFactoryPredictCloneAddressMatchesActual() public {
        address predicted = tokenExitRegistryFactory.predictCloneAddress(bytes32(0), trustedForwarder, token);
        address actual = tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token);
        assertEq(predicted, actual, "predicted address does not match actual");
    }

    function testFactoryDeterministicAddress_RawSaltChanges() public {
        address a1 = tokenExitRegistryFactory.predictCloneAddress(bytes32(0), trustedForwarder, token);
        address a2 = tokenExitRegistryFactory.predictCloneAddress(bytes32(uint256(1)), trustedForwarder, token);
        assertFalse(a1 == a2, "different raw salts should give different addresses");
    }

    function testFactoryDeterministicAddress_TokenChanges() public {
        Token token2 = Token(
            tokenFactory.createTokenProxy(
                bytes32(uint256(1)),
                trustedForwarder,
                feeSettings,
                admin,
                allowList,
                0,
                "Token2",
                "TT2"
            )
        );
        address a1 = tokenExitRegistryFactory.predictCloneAddress(bytes32(0), trustedForwarder, token);
        address a2 = tokenExitRegistryFactory.predictCloneAddress(bytes32(0), trustedForwarder, token2);
        assertFalse(a1 == a2, "different tokens should give different addresses");
    }

    function testFactorySecondDeploymentWithSameSaltReverts() public {
        tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token);
        vm.expectRevert("ERC1167: create2 failed");
        tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token);
    }

    function testFactoryEmitsNewCloneEvent() public {
        address predicted = tokenExitRegistryFactory.predictCloneAddress(bytes32(0), trustedForwarder, token);
        vm.expectEmit(true, false, false, false, address(tokenExitRegistryFactory));
        emit CloneFactory.NewClone(predicted);
        tokenExitRegistryFactory.createTokenExitRegistryClone(bytes32(0), trustedForwarder, token);
    }
}
