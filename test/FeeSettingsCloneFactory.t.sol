// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "../lib/forge-std/src/console.sol";
import "../contracts/factories/FeeSettingsCloneFactory.sol";
import "../contracts/interfaces/IFeeSettings.sol";

contract tokenTest is Test {
    FeeSettingsCloneFactory factory;

    bytes32 exampleRawSalt = "salt";
    address public constant exampleToken = 0x8109709ecfa91a80626fF3989d68f67F5B1dD128;
    address public constant exampleTrustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;
    address public constant exampleOwner = 0x2109709EcFa91a80626Ff3989d68F67F5B1Dd122;
    address public constant exampleTokenFeeCollector = 0x3109709ECfA91A80626fF3989D68f67F5B1Dd123;
    address public constant exampleCrowdinvestingFeeCollector = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;
    address public constant examplePrivateOfferFeeCollector = 0x4109709eCFa91A80626ff3989d68F67f5b1DD124;

    // exampleFees1: tokenFee=1, crowdinvestingFee=2, privateOfferFee=3
    // exampleFees2: tokenFee=70, crowdinvestingFee=80, privateOfferFee=90

    function setUp() public {
        factory = new FeeSettingsCloneFactory(address(new FeeSettings(exampleTrustedForwarder)));
    }

    function _buildFeeTypes(
        uint32 tokenNum,
        uint32 ciNum,
        uint32 poNum,
        address tokenCollector,
        address ciCollector,
        address poCollector
    ) internal pure returns (FeeSettings.FeeTypeInit[] memory) {
        FeeSettings.FeeTypeInit[] memory feeType= new FeeSettings.FeeTypeInit[](6);
        feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.TOKEN_FEE, 500, tokenNum, tokenCollector);
        feeType[1] = FeeSettings.FeeTypeInit(FeeTypes.CROWDINVESTING_FEE, 1000, ciNum, ciCollector);
        feeType[2] = FeeSettings.FeeTypeInit(FeeTypes.PRIVATE_OFFER_FEE, 500, poNum, poCollector);
        feeType[3] = FeeSettings.FeeTypeInit(FeeTypes.SECONDARY_MARKET_FEE, 500, 0, poCollector);
        feeType[4] = FeeSettings.FeeTypeInit(FeeTypes.DISTRIBUTION_FEE, 500, 0, poCollector);
        feeType[5] = FeeSettings.FeeTypeInit(FeeTypes.EXIT_FEE, 500, 0, poCollector);
        return feeType;
    }

    function _buildFeeTypesAllSame(
        uint32 tokenNum,
        uint32 ciNum,
        uint32 poNum,
        address collector
    ) internal pure returns (FeeSettings.FeeTypeInit[] memory) {
        return _buildFeeTypes(tokenNum, ciNum, poNum, collector, collector, collector);
    }

    function testAddressPrediction(
        bytes32 _rawSalt,
        address _owner,
        address _tokenFeeCollector,
        address _crowdinvestingFeeCollector,
        address _privateOfferFeeCollector
    ) public {
        vm.assume(_owner != address(0));
        vm.assume(_tokenFeeCollector != address(0));
        vm.assume(_crowdinvestingFeeCollector != address(0));
        vm.assume(_privateOfferFeeCollector != address(0));

        FeeSettings.FeeTypeInit[] memory feeTypes = _buildFeeTypes(
            1,
            2,
            3,
            _tokenFeeCollector,
            _crowdinvestingFeeCollector,
            _privateOfferFeeCollector
        );

        bytes32 salt = keccak256(abi.encode(_rawSalt, exampleTrustedForwarder, _owner, feeTypes));

        address expected1 = factory.predictCloneAddress(salt);
        address expected2 = factory.predictCloneAddress(_rawSalt, exampleTrustedForwarder, _owner, feeTypes);

        address actual = factory.createFeeSettingsClone(_rawSalt, exampleTrustedForwarder, _owner, feeTypes);

        assertEq(expected1, expected2, "address prediction with salt and params not equal");
        assertEq(expected1, actual, "address prediction failed");
    }

    function testChangingParametersChangesAddress() public view {
        address someAddress = address(42);

        FeeSettings.FeeTypeInit[] memory baseFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );

        address base = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, exampleOwner, baseFeeTypes);

        FeeSettings.FeeTypeInit[] memory changedFeeTypes;

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );
        address changed = factory.predictCloneAddress("0", exampleTrustedForwarder, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with raw salt changed");

        changedFeeTypes = _buildFeeTypes(
            70,
            80,
            90,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );
        changed = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with fees changed");

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );
        changed = factory.predictCloneAddress(exampleRawSalt, someAddress, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with trustedForwarder changed");

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );
        changed = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, someAddress, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with owner changed");

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            someAddress,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );
        changed = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with tokenFeeCollector changed");

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            someAddress,
            examplePrivateOfferFeeCollector
        );
        changed = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with crowdinvestingFeeCollector changed");

        changedFeeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            someAddress
        );
        changed = factory.predictCloneAddress(exampleRawSalt, exampleTrustedForwarder, exampleOwner, changedFeeTypes);
        assertTrue(base != changed, "addresses equal with privateOfferFeeCollector changed");
    }

    function testSecondDeploymentFails() public {
        FeeSettings.FeeTypeInit[] memory feeTypes = _buildFeeTypes(
            1,
            2,
            3,
            exampleTokenFeeCollector,
            exampleCrowdinvestingFeeCollector,
            examplePrivateOfferFeeCollector
        );

        factory.createFeeSettingsClone(exampleRawSalt, exampleTrustedForwarder, exampleOwner, feeTypes);

        vm.expectRevert("ERC1167: create2 failed");
        factory.createFeeSettingsClone(exampleRawSalt, exampleTrustedForwarder, exampleOwner, feeTypes);
    }

    function testInitialization(
        address _owner,
        address _tokenFeeCollector,
        address _crowdinvestingFeeCollector,
        address _privateOfferFeeCollector
    ) public {
        vm.assume(_owner != address(0));
        vm.assume(_tokenFeeCollector != address(0));
        vm.assume(_crowdinvestingFeeCollector != address(0));
        vm.assume(_privateOfferFeeCollector != address(0));

        FeeSettings.FeeTypeInit[] memory feeTypes = _buildFeeTypes(
            1,
            2,
            3,
            _tokenFeeCollector,
            _crowdinvestingFeeCollector,
            _privateOfferFeeCollector
        );

        FeeSettings feeSettings = FeeSettings(
            factory.createFeeSettingsClone(exampleRawSalt, exampleTrustedForwarder, _owner, feeTypes)
        );

        assertEq(feeSettings.owner(), _owner, "owner not set");
        assertEq(feeSettings.tokenFeeCollector(exampleToken), _tokenFeeCollector, "tokenFeeCollector not set");
        assertEq(
            feeSettings.crowdinvestingFeeCollector(exampleToken),
            _crowdinvestingFeeCollector,
            "crowdinvestingFeeCollector not set"
        );

        assertEq(
            feeSettings.privateOfferFeeCollector(exampleToken),
            _privateOfferFeeCollector,
            "privateOfferFeeCollector not set"
        );

        (, uint32 _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN_FEE);
        (, uint32 _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING_FEE);
        (, uint32 _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER_FEE);

        assertEq(_tokenFeeNumerator, 1, "defaultTokenFeeNumerator not set");
        assertEq(_crowdinvestingFeeNumerator, 2, "defaultCrowdinvestingFeeNumerator not set");
        assertEq(_privateOfferFeeNumerator, 3, "defaultPrivateOfferFeeNumerator not set");
    }
}
