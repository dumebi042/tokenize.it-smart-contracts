// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";

import "../contracts/factories/TokenProxyFactory.sol";
import "../contracts/factories/TimeLockMasterCloneFactory.sol";
import "../contracts/TimeLockMaster.sol";
import "../contracts/IExit.sol";
import "../contracts/Token.sol";
import "./resources/CloneCreators.sol";
import "./resources/FakePaymentToken.sol";

/// @dev Minimal IExit stub used for setExit() tests
contract FakeExit {
    function claim(uint256, address) external {}
}

/**
 * @title TimeLockMasterTest
 * @notice Tests for TimeLockMaster and TimeLockMasterCloneFactory.
 */
contract TimeLockMasterTest is Test {
    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant nonAdmin = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant trustedForwarder = 0xa109709ecfA91A80626ff3989D68F67F5b1dD12a;

    AllowList allowList;
    IFeeSettingsV2 feeSettings;
    Token token;
    TokenProxyFactory tokenFactory;
    TimeLockMasterCloneFactory timeLockMasterFactory;

    function setUp() public {
        allowList = createAllowList(trustedForwarder, admin);
        feeSettings = createFeeSettings(trustedForwarder, admin, buildFeeTypes(0, 0, 0, admin, admin, admin));

        address tokenLogic = address(new Token(trustedForwarder));
        tokenFactory = new TokenProxyFactory(tokenLogic);
        token = Token(
            tokenFactory.createTokenProxy(0, trustedForwarder, feeSettings, admin, allowList, 0, "TestToken", "TTK")
        );

        TimeLockMaster timeLockMasterLogic = new TimeLockMaster();
        timeLockMasterFactory = new TimeLockMasterCloneFactory(address(timeLockMasterLogic));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── Initialize ───────────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testInitializeHappyPath() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );

        assertEq(address(timeLockMaster.token()), address(token), "token not set");
        assertEq(address(timeLockMaster.exit()), address(0), "exit should be zero initially");
    }

    function testInitializeRevertsIfTokenIsZero() public {
        // Attempt to create a clone with zero token address — factory should revert
        vm.expectRevert("token can not be zero address");
        timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), Token(address(0)));
    }

    function testLogicContractCannotBeReinitialized() public {
        // The logic contract constructor calls _disableInitializers();
        // deploying it via new is fine (factory pattern), but calling initialize on
        // a newly deployed logic contract should be blocked.
        TimeLockMaster logicContract = new TimeLockMaster();
        vm.expectRevert("Initializable: contract is already initialized");
        logicContract.initialize(token);
    }

    function testCloneCannotBeReinitializedAfterFactory() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        vm.expectRevert("Initializable: contract is already initialized");
        timeLockMaster.initialize(token);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── setExit ───────────────────────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testSetExitHappyPath() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        FakeExit fakeExit = new FakeExit();

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(timeLockMaster));
        emit TimeLockMaster.ExitSet(IExit(address(fakeExit)));
        timeLockMaster.setExit(IExit(address(fakeExit)));

        assertEq(address(timeLockMaster.exit()), address(fakeExit), "exit not set correctly");
    }

    function testSetExitRevertsIfCallerIsNotTokenAdmin() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        FakeExit fakeExit = new FakeExit();

        vm.prank(nonAdmin);
        vm.expectRevert("caller is not token admin");
        timeLockMaster.setExit(IExit(address(fakeExit)));
    }

    function testSetExitRevertsIfExitIsZeroAddress() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );

        vm.prank(admin);
        vm.expectRevert("exit can not be zero address");
        timeLockMaster.setExit(IExit(address(0)));
    }

    function testSetExitRevertsIfAlreadySet() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        FakeExit fakeExit1 = new FakeExit();
        FakeExit fakeExit2 = new FakeExit();

        vm.prank(admin);
        timeLockMaster.setExit(IExit(address(fakeExit1)));

        vm.prank(admin);
        vm.expectRevert("exit has already been set");
        timeLockMaster.setExit(IExit(address(fakeExit2)));
    }

    function testSetExitOnlyCallableByRoleHolder() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        FakeExit fakeExit = new FakeExit();

        // Grant DEFAULT_ADMIN_ROLE to nonAdmin
        bytes32 defaultAdminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.grantRole(defaultAdminRole, nonAdmin);

        // Now nonAdmin can set exit
        vm.prank(nonAdmin);
        timeLockMaster.setExit(IExit(address(fakeExit)));

        assertEq(address(timeLockMaster.exit()), address(fakeExit), "exit not set by new admin");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ── TimeLockMasterCloneFactory ────────────────────────────────────────────
    // ─────────────────────────────────────────────────────────────────────────

    function testFactoryCreatesCloneWithCorrectToken() public {
        TimeLockMaster timeLockMaster = TimeLockMaster(
            timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token)
        );
        assertEq(address(timeLockMaster.token()), address(token));
    }

    function testFactoryPredictCloneAddressMatchesActual() public {
        address predicted = timeLockMasterFactory.predictCloneAddress(bytes32(0), token);
        address actual = timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token);
        assertEq(predicted, actual, "predicted address does not match actual");
    }

    function testFactoryDeterministicAddress_RawSaltChanges() public {
        address a1 = timeLockMasterFactory.predictCloneAddress(bytes32(0), token);
        address a2 = timeLockMasterFactory.predictCloneAddress(bytes32(uint256(1)), token);
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
        address a1 = timeLockMasterFactory.predictCloneAddress(bytes32(0), token);
        address a2 = timeLockMasterFactory.predictCloneAddress(bytes32(0), token2);
        assertFalse(a1 == a2, "different tokens should give different addresses");
    }

    function testFactorySecondDeploymentWithSameSaltReverts() public {
        timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token);
        vm.expectRevert("ERC1167: create2 failed");
        timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token);
    }

    function testFactoryEmitsNewCloneEvent() public {
        address predicted = timeLockMasterFactory.predictCloneAddress(bytes32(0), token);
        vm.expectEmit(true, false, false, false, address(timeLockMasterFactory));
        emit CloneFactory.NewClone(predicted);
        timeLockMasterFactory.createTimeLockMasterClone(bytes32(0), token);
    }
}
