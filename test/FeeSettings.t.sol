// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../lib/forge-std/src/Test.sol";
import "../lib/forge-std/src/console.sol";
import "../contracts/Token.sol";
import "../contracts/factories/FeeSettingsCloneFactory.sol";
import "../contracts/interfaces/IFeeSettings.sol";
import "./resources/CloneCreators.sol";

contract FeeSettingsTest is Test {
    uint32 constant MAX_TOKEN = 500;
    uint32 constant MAX_CROWDINVESTING = 1000;
    uint32 constant MAX_PRIVATE_OFFER = 500;

    event SetFee(uint32 tokenFeeNumerator, uint32 crowdinvestingFeeNumerator, uint32 privateOfferFeeNumerator);
    event FeeCollectorsChanged(
        address indexed newTokenFeeCollector,
        address indexed newCrowdinvestingFeeCollector,
        address indexed newPrivateOfferFeeCollector
    );
    event ManagerAdded(address indexed manager);
    event ManagerRemoved(address indexed manager);

    FeeSettings feeSettings;
    FeeSettingsCloneFactory feeSettingsCloneFactory;
    Token token;
    Token currency;

    uint256 MAX_INT = type(uint256).max;

    address public constant admin = 0x0109709eCFa91a80626FF3989D68f67f5b1dD120;
    address public constant buyer = 0x1109709ecFA91a80626ff3989D68f67F5B1Dd121;
    address public constant mintAllower = 0x2109709EcFa91a80626Ff3989d68F67F5B1Dd122;
    address public constant minter = 0x3109709ECfA91A80626fF3989D68f67F5B1Dd123;
    address public constant owner = 0x6109709EcFA91A80626FF3989d68f67F5b1dd126;
    address public constant receiver = 0x7109709eCfa91A80626Ff3989D68f67f5b1dD127;
    address public constant paymentTokenProvider = 0x8109709ecfa91a80626fF3989d68f67F5B1dD128;
    address public constant trustedForwarder = 0x9109709EcFA91A80626FF3989D68f67F5B1dD129;

    uint256 public constant price = 10000000;

    address public constant exampleTokenAddress = address(74);

    function _buildFeeTypes(address collector) internal pure returns (FeeSettings.FeeTypeInit[] memory) {
        FeeSettings.FeeTypeInit[] memory feeTypes = new FeeSettings.FeeTypeInit[](6);
        feeTypes[0] = FeeSettings.FeeTypeInit(FeeTypes.TOKEN, 500, 1, collector);
        feeTypes[1] = FeeSettings.FeeTypeInit(FeeTypes.CROWDINVESTING, 1000, 2, collector);
        feeTypes[2] = FeeSettings.FeeTypeInit(FeeTypes.PRIVATE_OFFER, 500, 3, collector);
        feeTypes[3] = FeeSettings.FeeTypeInit(FeeTypes.SECONDARY_MARKET, 500, 0, collector);
        feeTypes[4] = FeeSettings.FeeTypeInit(FeeTypes.DISTRIBUTION, 500, 0, collector);
        feeTypes[5] = FeeSettings.FeeTypeInit(FeeTypes.EXIT, 500, 0, collector);
        return feeTypes;
    }

    function setUp() public {
        FeeSettings logic = new FeeSettings(trustedForwarder);
        feeSettingsCloneFactory = new FeeSettingsCloneFactory(address(logic));

        vm.prank(admin);
        feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, _buildFeeTypes(admin))
        );
    }

    function testLogicContractCannotBeInitialized() public {
        FeeSettings logic = new FeeSettings(trustedForwarder);
        vm.expectRevert("Initializable: contract is already initialized");
        logic.initialize(admin, _buildFeeTypes(admin));

        assertEq(logic.owner(), address(0), "Owner should be 0");
    }

    function testEnforceFeeRangeInInitializer(uint32 numerator, uint32 denominator) public {
        vm.assume(denominator > 0);
        vm.assume(!tokenOrPrivateOfferFeeInValidRange(numerator));

        console.log("Testing token fee");
        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.TOKEN, 500, numerator, admin);
            vm.expectRevert("default exceeds max");
            feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType);
        }

        console.log("Testing Crowdinvesting fee");
        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.CROWDINVESTING, 1000, numerator, admin);
            if (!crowdinvestingFeeInValidRange(numerator)) {
                vm.expectRevert("default exceeds max");
                feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType);
            } else {
                // this should not revert, as the fee is in valid range for crowdinvesting
                feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType);
            }
        }

        console.log("Testing PrivateOffer fee");
        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.PRIVATE_OFFER, 500, numerator, admin);
            vm.expectRevert("default exceeds max");
            feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType);
        }
    }

    function testEnforceTokenFeeRangeInFeeChanger(uint32 numerator, uint32 denominator) public {
        vm.assume(denominator > 0);
        vm.assume(!tokenOrPrivateOfferFeeInValidRange(numerator));

        vm.expectRevert("exceeds max numerator");
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.TOKEN, numerator, uint64(block.timestamp + 7884001));
    }

    function testEnforceCrowdinvestingFeeRangeInFeeChanger(uint32 numerator, uint32 denominator) public {
        vm.assume(denominator > 0);
        vm.assume(!crowdinvestingFeeInValidRange(numerator));

        vm.expectRevert("exceeds max numerator");
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, numerator, uint64(block.timestamp + 7884001));
    }

    function testEnforcePrivateOfferFeeRangeInFeeChanger(uint32 numerator, uint32 denominator) public {
        vm.assume(denominator > 0);
        vm.assume(!tokenOrPrivateOfferFeeInValidRange(numerator));

        vm.expectRevert("exceeds max numerator");
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, numerator, uint64(block.timestamp + 7884001));
    }

    function testEnforceFeeChangeDelayOnIncrease(uint delay, uint32 startNumerator, uint32 newNumerator) public {
        vm.assume(delay <= 12 weeks);
        vm.assume(newNumerator <= MAX_PRIVATE_OFFER);
        vm.assume(newNumerator > startNumerator);
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                admin,
                buildFeeTypes(startNumerator, startNumerator, startNumerator, admin, admin, admin)
            )
        );

        vm.prank(admin);
        vm.expectRevert("fee increase needs 12 week delay");
        _feeSettings.planFeeChange(FeeTypes.TOKEN, newNumerator, uint64(block.timestamp + delay));

        vm.prank(admin);
        vm.expectRevert("fee increase needs 12 week delay");
        _feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, newNumerator, uint64(block.timestamp + delay));

        vm.prank(admin);
        vm.expectRevert("fee increase needs 12 week delay");
        _feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, newNumerator, uint64(block.timestamp + delay));
    }

    function testExecuteFeeChangeTooEarly(
        uint delayAnnounced,
        uint32 tokenFeeNumerator,
        uint32 investmentFeeNumerator
    ) public {
        vm.assume(delayAnnounced > 12 weeks && delayAnnounced < 1000000000000);
        vm.assume(tokenOrPrivateOfferFeeInValidRange(tokenFeeNumerator));
        vm.assume(tokenOrPrivateOfferFeeInValidRange(investmentFeeNumerator));

        uint64 activationDate = uint64(block.timestamp + delayAnnounced);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.TOKEN, tokenFeeNumerator, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, investmentFeeNumerator, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, investmentFeeNumerator, activationDate);

        vm.prank(admin);
        vm.expectRevert("activation date not reached");
        vm.warp(activationDate - 1);
        feeSettings.executeFeeChange(FeeTypes.TOKEN);
    }

    function testExecuteFeeChangeProperly(
        uint delayAnnounced,
        uint32 tokenFeeNumerator,
        uint32 crowdinvestingFeeNumerator,
        uint32 privateOfferFeeNumerator
    ) public {
        vm.assume(delayAnnounced > 12 weeks && delayAnnounced < 100000000000);
        tokenFeeNumerator = tokenFeeNumerator % MAX_TOKEN;
        crowdinvestingFeeNumerator = crowdinvestingFeeNumerator % MAX_CROWDINVESTING;
        privateOfferFeeNumerator = privateOfferFeeNumerator % MAX_PRIVATE_OFFER;
        vm.assume(tokenFeeNumerator <= MAX_TOKEN);
        vm.assume(crowdinvestingFeeNumerator <= MAX_CROWDINVESTING);
        vm.assume(privateOfferFeeNumerator <= MAX_PRIVATE_OFFER);

        uint64 activationDate = uint64(block.timestamp + delayAnnounced);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.TOKEN, tokenFeeNumerator, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, crowdinvestingFeeNumerator, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, privateOfferFeeNumerator, activationDate);

        vm.prank(admin);
        vm.warp(activationDate + 1);
        feeSettings.executeFeeChange(FeeTypes.TOKEN);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.CROWDINVESTING);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.PRIVATE_OFFER);

        (, uint32 _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, uint32 _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, uint32 _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, tokenFeeNumerator);
        assertEq(_crowdinvestingFeeNumerator, crowdinvestingFeeNumerator);
        assertEq(_privateOfferFeeNumerator, privateOfferFeeNumerator);
    }

    function testSetFeeTo0Immediately() public {
        uint64 activationDate = uint64(block.timestamp);

        (, uint32 _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, uint32 _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, uint32 _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, 1);
        assertEq(_crowdinvestingFeeNumerator, 2);
        assertEq(_privateOfferFeeNumerator, 3);

        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.TOKEN, 0, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, 0, activationDate);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, 0, activationDate);

        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.TOKEN);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.CROWDINVESTING);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.PRIVATE_OFFER);

        (, _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, 0);
        assertEq(_crowdinvestingFeeNumerator, 0);
        assertEq(_privateOfferFeeNumerator, 0);

        (uint32 proposedNumerator, uint64 proposedActivationDate) = feeSettings.proposedFeeChanges(FeeTypes.TOKEN);

        assertEq(proposedNumerator, 0, "Token fee denominator mismatch");
        assertEq(proposedActivationDate, 0, "Time mismatch");
    }

    function testSetFeeToXFrom0Immediately() public {
        vm.prank(admin);
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                admin,
                buildFeeTypes(0, 0, 0, admin, admin, admin)
            )
        );

        (, uint32 _tokenFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, uint32 _crowdinvestingFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, uint32 _privateOfferFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, 0, "Token fee numerator mismatch");
        assertEq(_crowdinvestingFeeNumerator, 0, "Crowdinvesting fee numerator mismatch");
        assertEq(_privateOfferFeeNumerator, 0, "PrivateOffer fee numerator mismatch");

        vm.prank(admin);
        vm.expectRevert("fee increase needs 12 week delay");
        _feeSettings.planFeeChange(FeeTypes.TOKEN, 1, 0);
    }

    function testReduceFeeImmediately(uint32 tokenFee, uint32 crowdinvestingFee, uint32 privateOfferFee) public {
        vm.assume(tokenFee <= MAX_TOKEN);
        vm.assume(crowdinvestingFee <= MAX_CROWDINVESTING);
        vm.assume(privateOfferFee <= MAX_PRIVATE_OFFER);

        // create new fee settings with max fee
        feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                admin,
                buildFeeTypes(MAX_TOKEN, MAX_CROWDINVESTING, MAX_PRIVATE_OFFER, admin, admin, admin)
            )
        );

        (, uint32 _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, uint32 _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, uint32 _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, MAX_TOKEN);
        assertEq(_crowdinvestingFeeNumerator, MAX_CROWDINVESTING);
        assertEq(_privateOfferFeeNumerator, MAX_PRIVATE_OFFER);

        // change fee to something lower (immediate since it's a decrease)
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.TOKEN, tokenFee, 0);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.CROWDINVESTING, crowdinvestingFee, 0);
        vm.prank(admin);
        feeSettings.planFeeChange(FeeTypes.PRIVATE_OFFER, privateOfferFee, 0);

        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.TOKEN);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.CROWDINVESTING);
        vm.prank(admin);
        feeSettings.executeFeeChange(FeeTypes.PRIVATE_OFFER);

        (, _tokenFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, _crowdinvestingFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, _privateOfferFeeNumerator) = feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, tokenFee);
        assertEq(_crowdinvestingFeeNumerator, crowdinvestingFee);
        assertEq(_privateOfferFeeNumerator, privateOfferFee);
    }

    function testSetFeeInInitializer(
        uint32 tokenFeeNumerator,
        uint32 crowdinvestingFeeNumerator,
        uint32 privateOfferFeeNumerator
    ) public {
        vm.assume(
            tokenFeeNumerator <= MAX_TOKEN &&
                crowdinvestingFeeNumerator <= MAX_CROWDINVESTING &&
                privateOfferFeeNumerator <= MAX_PRIVATE_OFFER
        );
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt2",
                trustedForwarder,
                admin,
                buildFeeTypes(
                    tokenFeeNumerator,
                    crowdinvestingFeeNumerator,
                    privateOfferFeeNumerator,
                    admin,
                    admin,
                    admin
                )
            )
        );

        (, uint32 _tokenFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.TOKEN);
        (, uint32 _crowdinvestingFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.CROWDINVESTING);
        (, uint32 _privateOfferFeeNumerator) = _feeSettings.feeTypeConfigs(FeeTypes.PRIVATE_OFFER);

        assertEq(_tokenFeeNumerator, tokenFeeNumerator, "Token fee numerator mismatch");
        assertEq(_crowdinvestingFeeNumerator, crowdinvestingFeeNumerator, "Crowdinvesting fee numerator mismatch");
        assertEq(_privateOfferFeeNumerator, privateOfferFeeNumerator, "PrivateOffer fee numerator mismatch");
    }

    function testFeeCollector0FailsInInitializer() public {
        FeeSettings _feeSettings;

        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.TOKEN, 500, 1, address(0));
            vm.expectRevert("Fee collector cannot be 0x0");
            _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType)
            );
        }

        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.CROWDINVESTING, 1000, 2, address(0));
            vm.expectRevert("Fee collector cannot be 0x0");
            _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType)
            );
        }

        {
            FeeSettings.FeeTypeInit[] memory feeType = new FeeSettings.FeeTypeInit[](1);
            feeType[0] = FeeSettings.FeeTypeInit(FeeTypes.PRIVATE_OFFER, 500, 3, address(0));
            vm.expectRevert("Fee collector cannot be 0x0");
            _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, admin, feeType)
            );
        }
    }

    function testOwner0FailsInInitializer() public {
        vm.expectRevert("owner can not be zero address");
        feeSettingsCloneFactory.createFeeSettingsClone("salt", trustedForwarder, address(0), _buildFeeTypes(admin));
    }

    function testFeeCollector0FailsInSetter() public {
        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setDefaultFeeCollector(FeeTypes.TOKEN, address(0));
        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setDefaultFeeCollector(FeeTypes.CROWDINVESTING, address(0));
        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setDefaultFeeCollector(FeeTypes.PRIVATE_OFFER, address(0));
    }

    function testUpdateFeeCollectors(
        address newTokenFeeCollector,
        address newCrowdinvestingFeeCollector,
        address newPrivateOfferFeeCollector
    ) public {
        vm.assume(newTokenFeeCollector != address(0));
        vm.assume(newCrowdinvestingFeeCollector != address(0));
        vm.assume(newPrivateOfferFeeCollector != address(0));

        vm.startPrank(admin);
        feeSettings.setDefaultFeeCollector(FeeTypes.TOKEN, newTokenFeeCollector);
        feeSettings.setDefaultFeeCollector(FeeTypes.CROWDINVESTING, newCrowdinvestingFeeCollector);
        feeSettings.setDefaultFeeCollector(FeeTypes.PRIVATE_OFFER, newPrivateOfferFeeCollector);
        vm.stopPrank();
        assertEq(feeSettings.feeCollector(), newTokenFeeCollector); // IFeeSettingsV1
        assertEq(feeSettings.tokenFeeCollector(address(4)), newTokenFeeCollector);
        assertEq(feeSettings.crowdinvestingFeeCollector(address(4)), newCrowdinvestingFeeCollector);
        assertEq(feeSettings.privateOfferFeeCollector(address(4)), newPrivateOfferFeeCollector);
    }

    function tokenOrPrivateOfferFeeInValidRange(uint32 numerator) internal pure returns (bool) {
        return numerator <= 500;
    }

    function crowdinvestingFeeInValidRange(uint32 numerator) internal pure returns (bool) {
        return numerator <= 1000;
    }

    function testCalculateProperFees(
        uint32 tokenFeeNumerator,
        uint32 crowdinvestingFeeNumerator,
        uint32 privateOfferFeeNumerator,
        uint256 amount
    ) public {
        vm.assume(tokenFeeNumerator <= MAX_TOKEN);
        vm.assume(crowdinvestingFeeNumerator <= MAX_CROWDINVESTING);
        vm.assume(privateOfferFeeNumerator <= MAX_PRIVATE_OFFER);
        vm.assume(amount < UINT256_MAX / MAX_CROWDINVESTING);

        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt5",
                trustedForwarder,
                admin,
                buildFeeTypes(
                    tokenFeeNumerator,
                    crowdinvestingFeeNumerator,
                    privateOfferFeeNumerator,
                    admin,
                    admin,
                    admin
                )
            )
        );

        assertEq(
            _feeSettings.tokenFee(amount, address(0)),
            (amount * tokenFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
            "Token fee mismatch"
        );
        assertEq(
            _feeSettings.crowdinvestingFee(amount, address(0)),
            (amount * crowdinvestingFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
            "Investment fee mismatch"
        );
        assertEq(
            _feeSettings.privateOfferFee(amount, address(0)),
            (amount * privateOfferFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
            "Private offer fee mismatch"
        );
    }

    function testCalculate0FeesForAnyAmount(
        uint32 tokenFeeNumerator,
        uint32 crowdinvestingFeeNumerator,
        uint32 privateOfferFeeNumerator,
        uint256 amount
    ) public {
        vm.assume(tokenFeeNumerator <= MAX_TOKEN);
        vm.assume(crowdinvestingFeeNumerator <= MAX_CROWDINVESTING);
        vm.assume(privateOfferFeeNumerator <= MAX_PRIVATE_OFFER);
        vm.assume(amount < UINT256_MAX / MAX_CROWDINVESTING);

        // only token fee is 0

        {
            FeeSettings _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone(
                    "salt4",
                    trustedForwarder,
                    admin,
                    buildFeeTypes(0, crowdinvestingFeeNumerator, privateOfferFeeNumerator, admin, admin, admin)
                )
            );

            assertEq(_feeSettings.tokenFee(amount, address(0)), 0, "Token fee mismatch");
            assertEq(
                _feeSettings.crowdinvestingFee(amount, address(0)),
                (amount * crowdinvestingFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Investment fee mismatch"
            );
            assertEq(
                _feeSettings.privateOfferFee(amount, address(0)),
                (amount * privateOfferFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Private offer fee mismatch"
            );
        }

        // only crowdinvesting fee is 0

        {
            FeeSettings _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone(
                    "salt3",
                    trustedForwarder,
                    admin,
                    buildFeeTypes(tokenFeeNumerator, 0, privateOfferFeeNumerator, admin, admin, admin)
                )
            );
            assertEq(
                _feeSettings.tokenFee(amount, address(0)),
                (amount * tokenFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Token fee mismatch"
            );
            assertEq(_feeSettings.crowdinvestingFee(amount, address(0)), 0, "Investment fee mismatch");
            assertEq(
                _feeSettings.privateOfferFee(amount, address(0)),
                (amount * privateOfferFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Private offer fee mismatch"
            );
        }

        // only private offer fee is 0

        {
            FeeSettings _feeSettings = FeeSettings(
                feeSettingsCloneFactory.createFeeSettingsClone(
                    "salt2",
                    trustedForwarder,
                    admin,
                    buildFeeTypes(tokenFeeNumerator, crowdinvestingFeeNumerator, 0, admin, admin, admin)
                )
            );
            assertEq(
                _feeSettings.tokenFee(amount, address(0)),
                (amount * tokenFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Token fee mismatch"
            );
            assertEq(
                _feeSettings.crowdinvestingFee(amount, address(0)),
                (amount * crowdinvestingFeeNumerator) / _feeSettings.FEE_DENOMINATOR(),
                "Investment fee mismatch"
            );
            assertEq(_feeSettings.privateOfferFee(amount, address(0)), 0, "Private offer fee mismatch");
        }
    }

    function testERC165IsAvailable() public view {
        assertEq(
            feeSettings.supportsInterface(0x01ffc9a7), // type(IERC165).interfaceId
            true,
            "ERC165 not supported"
        );
    }

    function testIFeeSettingsV1IsAvailable(uint256 _amount) public view {
        vm.assume(_amount < UINT256_MAX / 3);
        assertEq(feeSettings.supportsInterface(type(IFeeSettingsV1).interfaceId), true, "IFeeSettingsV1 not supported");

        // these functions must be present, so the call can not revert

        assertEq(
            feeSettings.continuousFundraisingFee(_amount),
            feeSettings.crowdinvestingFee(_amount, address(0)),
            "Crowdinvesting Fee mismatch"
        );

        assertEq(
            feeSettings.privateOfferFee(_amount, address(0)),
            feeSettings.personalInviteFee(_amount),
            "Private offer fee mismatch"
        );
        assertEq(feeSettings.feeCollector(), feeSettings.tokenFeeCollector(address(0)), "Fee collector mismatch");
    }

    function testIFeeSettingsV2IsAvailable() public view {
        assertEq(feeSettings.supportsInterface(type(IFeeSettingsV2).interfaceId), true, "IFeeSettingsV2 not supported");
    }

    function testNonsenseInterfacesAreNotAvailable(bytes4 _nonsenseInterface) public view {
        vm.assume(_nonsenseInterface != type(IFeeSettingsV1).interfaceId);
        vm.assume(_nonsenseInterface != type(IFeeSettingsV2).interfaceId);
        vm.assume(_nonsenseInterface != 0x01ffc9a7);

        assertEq(feeSettings.supportsInterface(0x01ffc9b7), false, "This interface should not be supported");
    }

    function testAddingCustomFees(address _someTokenAddress) public {
        vm.assume(_someTokenAddress != address(0));

        // deploying from here makes address(this) the admin
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                address(this),
                buildFeeTypes(11, 22, 55, address(this), address(this), address(this))
            )
        );
        // check there is no entry for this token address
        {
            (uint32 tokenNum, uint64 tokenValidity) = _feeSettings.customFees(FeeTypes.TOKEN, _someTokenAddress);
            (uint32 ciNum, uint64 ciValidity) = _feeSettings.customFees(FeeTypes.CROWDINVESTING, _someTokenAddress);
            (uint32 poNum, uint64 poValidity) = _feeSettings.customFees(FeeTypes.PRIVATE_OFFER, _someTokenAddress);
            assertEq(tokenNum, 0, "Token fee numerator should be 0");
            assertEq(ciNum, 0, "Crowdinvesting fee numerator should be 0");
            assertEq(poNum, 0, "Private offer fee numerator should be 0");
            assertEq(tokenValidity, 0, "End time should be 0");
            assertEq(ciValidity, 0, "End time should be 0");
            assertEq(poValidity, 0, "End time should be 0");
        }

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(10000, _someTokenAddress), 11, "Token fee should be 11");
        assertEq(_feeSettings.crowdinvestingFee(10000, _someTokenAddress), 22, "Crowdinvesting fee should be 22");
        assertEq(_feeSettings.privateOfferFee(10000, _someTokenAddress), 55, "Private offer fee should be 55");

        // add custom fee entry for this token address
        uint256 realEndTime = block.timestamp + 100;
        _feeSettings.setCustomFee(FeeTypes.TOKEN, _someTokenAddress, 3, uint64(realEndTime));
        _feeSettings.setCustomFee(FeeTypes.CROWDINVESTING, _someTokenAddress, 4, uint64(realEndTime));
        _feeSettings.setCustomFee(FeeTypes.PRIVATE_OFFER, _someTokenAddress, 2, uint64(realEndTime));

        // check the token fee, private offer fee and crowdinvesting fee change as expected
        assertEq(_feeSettings.tokenFee(10000, _someTokenAddress), 3, "Token fee should be 3 now");
        assertEq(_feeSettings.crowdinvestingFee(10000, _someTokenAddress), 4, "Crowdinvesting fee should be 4 now");
        assertEq(_feeSettings.privateOfferFee(10000, _someTokenAddress), 2, "Private offer fee should be 2 now");

        // check the custom fee entry is as expected
        {
            (uint32 tokenNum, uint64 tokenValidity) = _feeSettings.customFees(FeeTypes.TOKEN, _someTokenAddress);
            (uint32 ciNum, ) = _feeSettings.customFees(FeeTypes.CROWDINVESTING, _someTokenAddress);
            (uint32 poNum, ) = _feeSettings.customFees(FeeTypes.PRIVATE_OFFER, _someTokenAddress);
            assertEq(tokenNum, 3, "Token fee numerator should be 3");
            assertEq(ciNum, 4, "Crowdinvesting fee numerator should be 4");
            assertEq(poNum, 2, "Private offer fee numerator should be 2");
            assertEq(tokenValidity, realEndTime, "End time should match");
        }

        // check that the custom fee is not applied after the end time
        vm.warp(realEndTime + 1);
        assertEq(_feeSettings.tokenFee(10000, _someTokenAddress), 11, "Token fee should be 11 again");
        assertEq(_feeSettings.crowdinvestingFee(10000, _someTokenAddress), 22, "Crowdinvesting fee should be 22 again");
        assertEq(_feeSettings.privateOfferFee(10000, _someTokenAddress), 55, "Private offer fee should be 55 again");
    }

    function testOnlyManagerCanAddCustomFees(address _rando) public {
        address someTokenAddress = address(74);
        vm.assume(_rando != address(0));
        vm.assume(_rando != admin);
        vm.assume(_rando != trustedForwarder);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.setCustomFee(FeeTypes.TOKEN, someTokenAddress, 1, uint64(block.timestamp + 100));
    }

    function testCustomFeesAreNotAppliedToOtherTokens(address _someTokenAddress, address _otherTokenAddress) public {
        vm.assume(_someTokenAddress != address(0));
        vm.assume(_otherTokenAddress != address(0));
        vm.assume(_someTokenAddress != _otherTokenAddress);

        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                address(this),
                buildFeeTypes(10, 20, 50, admin, admin, admin)
            )
        );
        // add custom fee entry for this token address
        uint64 customFeeValidity = uint64(block.timestamp + 100);
        _feeSettings.setCustomFee(FeeTypes.TOKEN, _someTokenAddress, 3, customFeeValidity);
        _feeSettings.setCustomFee(FeeTypes.CROWDINVESTING, _someTokenAddress, 4, customFeeValidity);
        _feeSettings.setCustomFee(FeeTypes.PRIVATE_OFFER, _someTokenAddress, 2, customFeeValidity);

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(10000, _otherTokenAddress), 10, "Token fee should be 10");
        assertEq(_feeSettings.crowdinvestingFee(10000, _otherTokenAddress), 20, "Crowdinvesting fee should be 20");
        assertEq(_feeSettings.privateOfferFee(10000, _otherTokenAddress), 50, "Private offer fee should be 50");
    }

    function testCustomFeesDoNotIncreaseFee() public {
        address someTokenAddress = address(74);
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                address(this),
                buildFeeTypes(0, 0, 0, admin, admin, admin)
            )
        );

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(type(uint256).max, someTokenAddress), 0, "Token fee should be 0");
        assertEq(
            _feeSettings.crowdinvestingFee(type(uint256).max, someTokenAddress),
            0,
            "Crowdinvesting fee should be 0"
        );
        assertEq(_feeSettings.privateOfferFee(type(uint256).max, someTokenAddress), 0, "Private offer fee should be 0");

        // add custom fee entry for this token address
        uint64 customValidity = uint64(block.timestamp + 100);
        _feeSettings.setCustomFee(FeeTypes.TOKEN, someTokenAddress, 1, customValidity);
        _feeSettings.setCustomFee(FeeTypes.CROWDINVESTING, someTokenAddress, 1, customValidity);
        _feeSettings.setCustomFee(FeeTypes.PRIVATE_OFFER, someTokenAddress, 1, customValidity);

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(type(uint256).max, someTokenAddress), 0, "Token fee should still be 0");
        assertEq(
            _feeSettings.crowdinvestingFee(type(uint256).max, someTokenAddress),
            0,
            "Crowdinvesting fee should still be 0"
        );
        assertEq(
            _feeSettings.privateOfferFee(type(uint256).max, someTokenAddress),
            0,
            "Private offer fee should still be 0"
        );
    }

    function testRemovingCustomFee() public {
        address someTokenAddress = address(74);
        FeeSettings _feeSettings = FeeSettings(
            feeSettingsCloneFactory.createFeeSettingsClone(
                "salt",
                trustedForwarder,
                address(this),
                buildFeeTypes(10, 20, 50, admin, admin, admin)
            )
        );
        // add custom fee entry for this token address
        uint64 customFeeValidity = uint64(block.timestamp + 100);
        _feeSettings.setCustomFee(FeeTypes.TOKEN, someTokenAddress, 3, customFeeValidity);
        _feeSettings.setCustomFee(FeeTypes.CROWDINVESTING, someTokenAddress, 4, customFeeValidity);
        _feeSettings.setCustomFee(FeeTypes.PRIVATE_OFFER, someTokenAddress, 2, customFeeValidity);

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(10000, someTokenAddress), 3, "Token fee should be 3");
        assertEq(_feeSettings.crowdinvestingFee(10000, someTokenAddress), 4, "Crowdinvesting fee should be 4");
        assertEq(_feeSettings.privateOfferFee(10000, someTokenAddress), 2, "Private offer fee should be 2");

        // remove custom fee entry for this token address
        _feeSettings.removeCustomFee(FeeTypes.TOKEN, someTokenAddress);
        _feeSettings.removeCustomFee(FeeTypes.CROWDINVESTING, someTokenAddress);
        _feeSettings.removeCustomFee(FeeTypes.PRIVATE_OFFER, someTokenAddress);

        // check the token fee, private offer fee and crowdinvesting fee are as expected
        assertEq(_feeSettings.tokenFee(10000, someTokenAddress), 10, "Token fee should be 10");
        assertEq(_feeSettings.crowdinvestingFee(10000, someTokenAddress), 20, "Crowdinvesting fee should be 20");
        assertEq(_feeSettings.privateOfferFee(10000, someTokenAddress), 50, "Private offer fee should be 50");
    }

    function testOnlyManagerCanRemoveCustomFees(address _rando) public {
        address someTokenAddress = address(74);
        vm.assume(feeSettings.managers(_rando) == false);
        vm.assume(_rando != trustedForwarder);
        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.removeCustomFee(FeeTypes.TOKEN, someTokenAddress);
    }

    function testOwnerCanAddManager(address _manager) public {
        vm.assume(_manager != address(0));
        vm.assume(_manager != trustedForwarder);
        vm.assume(_manager != admin);

        assertEq(feeSettings.managers(_manager), false, "Should not be manager yet");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(feeSettings));
        emit ManagerAdded(_manager);
        feeSettings.addManager(_manager);

        assertEq(feeSettings.managers(_manager), true, "Manager should be added");
    }

    function testRandoCanNotAddManager(address _rando) public {
        vm.assume(_rando != address(0));
        vm.assume(_rando != admin);
        vm.assume(_rando != trustedForwarder);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(_rando);
        feeSettings.addManager(_rando);
    }

    function testOwnerCanRemoveManager(address _manager) public {
        vm.assume(_manager != address(0));
        vm.assume(_manager != trustedForwarder);
        vm.assume(_manager != admin);

        vm.prank(admin);
        feeSettings.addManager(_manager);

        assertEq(feeSettings.managers(_manager), true, "Should be manager");

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(feeSettings));
        emit ManagerRemoved(_manager);
        feeSettings.removeManager(_manager);

        assertEq(feeSettings.managers(_manager), false, "Manager should be removed");
    }

    function testRandoCanNotRemoveManager(address _rando) public {
        vm.assume(_rando != address(0));
        vm.assume(_rando != admin);
        vm.assume(_rando != trustedForwarder);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(_rando);
        feeSettings.removeManager(_rando);
    }

    function testAddingCustomTokenFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(
            feeSettings.tokenFeeCollector(exampleTokenAddress),
            feeSettings.feeCollector(),
            "Fee collector mismatch between V1 and V2"
        );
        assertEq(feeSettings.tokenFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            _feeCollector,
            "Custom fee collector wrong"
        );
        assertEq(
            feeSettings.tokenFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );
        assertEq(admin, feeSettings.feeCollector(), "V1 fee collector should still be default value");
    }

    function testRemovingCustomTokenFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.tokenFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );

        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress);

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(
            feeSettings.tokenFeeCollector(exampleTokenAddress),
            feeSettings.feeCollector(),
            "Fee collector mismatch between V1 and V2"
        );
        assertEq(feeSettings.tokenFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");
    }

    function testAddingCustomCrowdinvestingFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(feeSettings.crowdinvestingFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            _feeCollector,
            "Custom fee collector wrong"
        );
        assertEq(
            feeSettings.crowdinvestingFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );
    }

    function testRemovingCustomCrowdinvestingFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.crowdinvestingFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );

        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress);

        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(feeSettings.crowdinvestingFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");
    }

    function testAddingCustomPrivateOfferFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(feeSettings.privateOfferFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            _feeCollector,
            "Custom fee collector wrong"
        );
        assertEq(
            feeSettings.privateOfferFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );
    }

    function testRemovingCustomPrivateOfferFeeCollector(address _feeCollector) public {
        vm.assume(_feeCollector != address(0));
        vm.assume(_feeCollector != admin);

        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress, _feeCollector);

        assertEq(
            feeSettings.privateOfferFeeCollector(exampleTokenAddress),
            _feeCollector,
            "Fee collector wrong with custom fee collector"
        );

        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress);

        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        assertEq(feeSettings.privateOfferFeeCollector(exampleTokenAddress), admin, "Fee collector not admin address");
    }

    function testManagerCanSetAndRemoveCustomFeeCollector(address _manager, address _customFeeCollector) public {
        vm.assume(_manager != address(0));
        vm.assume(_manager != trustedForwarder);
        vm.assume(_manager != admin);
        vm.assume(_customFeeCollector != address(0));
        vm.assume(_customFeeCollector != admin);

        vm.prank(admin);
        feeSettings.addManager(_manager);

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );

        vm.startPrank(_manager);
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress, _customFeeCollector);
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress, _customFeeCollector);
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress, _customFeeCollector);
        vm.stopPrank();

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            _customFeeCollector,
            "Custom fee collector wrong"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            _customFeeCollector,
            "Custom fee collector wrong"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            _customFeeCollector,
            "Custom fee collector wrong"
        );

        vm.startPrank(_manager);
        feeSettings.removeCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress);
        feeSettings.removeCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress);
        feeSettings.removeCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress);
        vm.stopPrank();

        assertEq(
            feeSettings.collectors(FeeTypes.TOKEN, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.CROWDINVESTING, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );
        assertEq(
            feeSettings.collectors(FeeTypes.PRIVATE_OFFER, exampleTokenAddress),
            address(0),
            "Should not be custom fee collector yet"
        );
    }

    function testRandoCanNotSetOrRemoveCustomFeeCollectors(address _rando, address _customFeeCollector) public {
        vm.assume(_rando != address(0));
        vm.assume(_rando != admin);
        vm.assume(_rando != trustedForwarder);
        vm.assume(_customFeeCollector != address(0));
        vm.assume(_customFeeCollector != admin);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress, _customFeeCollector);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress, _customFeeCollector);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress, _customFeeCollector);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.removeCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.removeCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress);

        vm.expectRevert("Only managers can call this function");
        vm.prank(_rando);
        feeSettings.removeCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress);
    }

    function testSettingCustomFeeCollectorFor0AddressReverts() public {
        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, exampleTokenAddress, address(0));

        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, exampleTokenAddress, address(0));

        vm.expectRevert("collector cannot be 0x0");
        vm.prank(admin);
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, exampleTokenAddress, address(0));
    }

    function testSettingCustomFeesFor0AddressReverts() public {
        vm.expectRevert("token cannot be 0x0");
        vm.prank(admin);
        feeSettings.setCustomFee(FeeTypes.TOKEN, address(0), 1, uint64(block.timestamp + 100));
    }

    function testCustomFeeCollectorsOnlyApplyToSpecifiedAddress(address specifiedAddress, address someAddress) public {
        vm.assume(specifiedAddress != address(0));
        vm.assume(specifiedAddress != someAddress);

        address customFeeCollector = address(75);
        assertTrue(customFeeCollector != admin);

        vm.startPrank(admin);

        // check token fee collector
        feeSettings.setCustomFeeCollector(FeeTypes.TOKEN, specifiedAddress, customFeeCollector);
        assertEq(
            feeSettings.tokenFeeCollector(specifiedAddress),
            customFeeCollector,
            "Token fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.crowdinvestingFeeCollector(specifiedAddress),
            admin,
            "Crowdinvesting fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.privateOfferFeeCollector(specifiedAddress),
            admin,
            "Token fee collector wrong for specifiedAddress"
        );

        assertEq(feeSettings.tokenFeeCollector(someAddress), admin, "Token fee collector wrong");
        assertEq(feeSettings.crowdinvestingFeeCollector(someAddress), admin, "Crowdinvesting fee collector wrong");
        assertEq(feeSettings.privateOfferFeeCollector(someAddress), admin, "Private offer fee collector wrong");

        feeSettings.removeCustomFeeCollector(FeeTypes.TOKEN, specifiedAddress);

        // test crowdinvesting fee collector
        feeSettings.setCustomFeeCollector(FeeTypes.CROWDINVESTING, specifiedAddress, customFeeCollector);
        assertEq(
            feeSettings.tokenFeeCollector(specifiedAddress),
            admin,
            "Token fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.crowdinvestingFeeCollector(specifiedAddress),
            customFeeCollector,
            "Crowdinvesting fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.privateOfferFeeCollector(specifiedAddress),
            admin,
            "Token fee collector wrong for specifiedAddress"
        );

        assertEq(feeSettings.tokenFeeCollector(someAddress), admin, "Token fee collector wrong");
        assertEq(feeSettings.crowdinvestingFeeCollector(someAddress), admin, "Crowdinvesting fee collector wrong");
        assertEq(feeSettings.privateOfferFeeCollector(someAddress), admin, "Private offer fee collector wrong");

        feeSettings.removeCustomFeeCollector(FeeTypes.CROWDINVESTING, specifiedAddress);

        // test private offer fee collector
        feeSettings.setCustomFeeCollector(FeeTypes.PRIVATE_OFFER, specifiedAddress, customFeeCollector);
        assertEq(
            feeSettings.tokenFeeCollector(specifiedAddress),
            admin,
            "Token fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.crowdinvestingFeeCollector(specifiedAddress),
            admin,
            "Crowdinvesting fee collector wrong for specifiedAddress"
        );
        assertEq(
            feeSettings.privateOfferFeeCollector(specifiedAddress),
            customFeeCollector,
            "Token fee collector wrong for specifiedAddress"
        );

        assertEq(feeSettings.tokenFeeCollector(someAddress), admin, "Token fee collector wrong");
        assertEq(feeSettings.crowdinvestingFeeCollector(someAddress), admin, "Crowdinvesting fee collector wrong");
        assertEq(feeSettings.privateOfferFeeCollector(someAddress), admin, "Private offer fee collector wrong");
    }

    function testRemovingCustomFeeFor0AddressReverts() public {
        vm.expectRevert("token cannot be 0x0");
        vm.prank(admin);
        feeSettings.removeCustomFee(FeeTypes.TOKEN, address(0));
    }

    function testRemovingCustomFeeCollectorsFor0AddressReverts() public {
        vm.expectRevert("token cannot be 0x0");
        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.TOKEN, address(0));

        vm.expectRevert("token cannot be 0x0");
        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.CROWDINVESTING, address(0));

        vm.expectRevert("token cannot be 0x0");
        vm.prank(admin);
        feeSettings.removeCustomFeeCollector(FeeTypes.PRIVATE_OFFER, address(0));
    }

    function testAllFeeTypesRegisteredWithUniqueSettings() public {
        bytes32[] memory allFeeTypes = new bytes32[](6);
        allFeeTypes[0] = FeeTypes.TOKEN;
        allFeeTypes[1] = FeeTypes.CROWDINVESTING;
        allFeeTypes[2] = FeeTypes.PRIVATE_OFFER;
        allFeeTypes[3] = FeeTypes.SECONDARY_MARKET;
        allFeeTypes[4] = FeeTypes.DISTRIBUTION;
        allFeeTypes[5] = FeeTypes.EXIT;

        FeeSettings.FeeTypeInit[] memory feeTypeInits = new FeeSettings.FeeTypeInit[](allFeeTypes.length);
        for (uint256 i = 0; i < allFeeTypes.length; i++) {
            uint32 maxNumerator = uint32((i + 1) * 100);
            uint32 defaultNumerator = uint32((i + 1) * 50);
            address collector = address(uint160(i + 1));
            feeTypeInits[i] = FeeSettings.FeeTypeInit(allFeeTypes[i], maxNumerator, defaultNumerator, collector);
        }

        FeeSettings logic = new FeeSettings(trustedForwarder);
        FeeSettingsCloneFactory factory = new FeeSettingsCloneFactory(address(logic));
        FeeSettings freshFeeSettings = FeeSettings(
            factory.createFeeSettingsClone("all-types-salt", trustedForwarder, admin, feeTypeInits)
        );

        for (uint256 i = 0; i < allFeeTypes.length; i++) {
            uint32 expectedMax = uint32((i + 1) * 100);
            uint32 expectedDefault = uint32((i + 1) * 50);
            address expectedCollector = address(uint160(i + 1));

            (uint32 actualMax, uint32 actualDefault) = freshFeeSettings.feeTypeConfigs(allFeeTypes[i]);
            assertEq(actualMax, expectedMax, "maxNumerator wrong");
            assertEq(actualDefault, expectedDefault, "defaultNumerator wrong");
            assertEq(freshFeeSettings.feeCollector(allFeeTypes[i], address(0)), expectedCollector, "collector wrong");
        }
    }

    function testFuzz_RegisterFeeTypeRevertsIfMaxNumeratorTooLarge(bytes32 feeType, uint32 maxNumerator) public {
        vm.assume(feeType != bytes32(0));
        vm.assume(maxNumerator >= feeSettings.FEE_DENOMINATOR());

        vm.expectRevert("maxNumerator too large");
        vm.prank(admin);
        feeSettings.registerFeeType(feeType, maxNumerator, 0, admin);
    }

    function testFuzz_UnknownFeeTypeReturnsZeroFee(bytes32 feeType, uint256 amount, address tokenAddress) public {
        // Exclude all fee types that are already registered in setUp
        vm.assume(feeType != FeeTypes.TOKEN);
        vm.assume(feeType != FeeTypes.CROWDINVESTING);
        vm.assume(feeType != FeeTypes.PRIVATE_OFFER);
        vm.assume(feeType != FeeTypes.SECONDARY_MARKET);
        vm.assume(feeType != FeeTypes.DISTRIBUTION);
        vm.assume(feeType != FeeTypes.EXIT);

        assertEq(feeSettings.fee(feeType, amount, tokenAddress), 0, "Unknown fee type must return 0");
    }

    function testFuzz_FeeCalculationAndCollectorReturnedCorrectly(
        bytes32 feeType,
        uint32 maxNumerator,
        uint32 defaultNumerator,
        address collector,
        uint256 amount
    ) public {
        // constraints from _registerFeeType
        vm.assume(feeType != bytes32(0));
        vm.assume(maxNumerator > 0 && maxNumerator < feeSettings.FEE_DENOMINATOR());
        vm.assume(defaultNumerator <= maxNumerator);
        vm.assume(collector != address(0));
        // avoid overflow: amount * maxNumerator must not exceed uint256 max
        vm.assume(amount <= type(uint256).max / feeSettings.FEE_DENOMINATOR());

        // deploy a fresh FeeSettings with no pre-registered fee types
        FeeSettings logic = new FeeSettings(trustedForwarder);
        FeeSettingsCloneFactory factory = new FeeSettingsCloneFactory(address(logic));
        FeeSettings.FeeTypeInit[] memory emptyFeeTypes = new FeeSettings.FeeTypeInit[](0);
        FeeSettings freshFeeSettings = FeeSettings(
            factory.createFeeSettingsClone("fuzz-salt", trustedForwarder, admin, emptyFeeTypes)
        );

        vm.startPrank(admin);
        freshFeeSettings.registerFeeType(feeType, maxNumerator, defaultNumerator, collector);
        vm.stopPrank();

        uint256 expectedFee = (amount * defaultNumerator) / freshFeeSettings.FEE_DENOMINATOR();
        assertEq(freshFeeSettings.fee(feeType, amount, exampleTokenAddress), expectedFee, "Fee calculation wrong");
        assertEq(freshFeeSettings.feeCollector(feeType, exampleTokenAddress), collector, "Collector wrong");
    }
}
