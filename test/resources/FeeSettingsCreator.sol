// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import "../../lib/forge-std/src/Test.sol";
import "../../contracts/factories/FeeSettingsCloneFactory.sol";

function createFeeSettings(
    address _trustedForwarder,
    address _owner,
    Fees memory _fees,
    address _tokenFeeCollector,
    address _crowdinvestingFeeCollector,
    address _privateOfferFeeCollector
) returns (FeeSettings) {
    FeeSettings.FeeTypeInit[] memory feeTypes = new FeeSettings.FeeTypeInit[](6);
    feeTypes[0] = FeeSettings.FeeTypeInit(FeeTypes.TOKEN_FEE, 500, _fees.tokenFeeNumerator, _tokenFeeCollector);
    feeTypes[1] = FeeSettings.FeeTypeInit(
        FeeTypes.CROWDINVESTING_FEE,
        1000,
        _fees.crowdinvestingFeeNumerator,
        _crowdinvestingFeeCollector
    );
    feeTypes[2] = FeeSettings.FeeTypeInit(
        FeeTypes.PRIVATE_OFFER_FEE,
        500,
        _fees.privateOfferFeeNumerator,
        _privateOfferFeeCollector
    );
    feeTypes[3] = FeeSettings.FeeTypeInit(
        FeeTypes.SECONDARY_MARKET_FEE,
        500,
        _fees.privateOfferFeeNumerator,
        _privateOfferFeeCollector
    );
    feeTypes[4] = FeeSettings.FeeTypeInit(
        FeeTypes.DISTRIBUTION_FEE,
        500,
        _fees.privateOfferFeeNumerator,
        _privateOfferFeeCollector
    );
    feeTypes[5] = FeeSettings.FeeTypeInit(
        FeeTypes.EXIT_FEE,
        500,
        _fees.privateOfferFeeNumerator,
        _privateOfferFeeCollector
    );

    FeeSettings logicContract = new FeeSettings(_trustedForwarder);
    FeeSettingsCloneFactory factory = new FeeSettingsCloneFactory(address(logicContract));
    FeeSettings clone = FeeSettings(factory.createFeeSettingsClone("someSalt", _trustedForwarder, _owner, feeTypes));

    return clone;
}
