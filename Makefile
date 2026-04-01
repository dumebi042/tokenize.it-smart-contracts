# Backwards-Compatibility Tests
# ==============================
# Verifies that old versions of Token and PrivateOffer still work with the current FeeSettings.
# Uses pre-compiled bytecode from npm packages — no source compilation of old code.
#
# How to add a new version:
#   1. Add an install-legacy-v<VERSION> target below (copy an existing one as template).
#   2. Add that target as a dependency of test-backwards-compatibility.
#   3. Add a test/backwards-compatibility/BackwardsCompatibilityV<VERSION>.t.sol test file.
#
# The test/legacy/*/node_modules/ directories are gitignored. Packages are installed fresh on every run.

.PHONY: test-backwards-compatibility
test-backwards-compatibility: install-legacy-v4.2.0-beta.0 install-legacy-v5.0.1 install-legacy-v6.1.0
	FOUNDRY_PROFILE=backwards-compatibility forge test -vv

.PHONY: install-legacy-v4.2.0-beta.0
install-legacy-v4.2.0-beta.0:
	@mkdir -p test/legacy/v4.2.0-beta.0
	npm install --prefix test/legacy/v4.2.0-beta.0 @tokenize.it/contracts@4.2.0-beta.0 --silent

.PHONY: install-legacy-v5.0.1
install-legacy-v5.0.1:
	@mkdir -p test/legacy/v5.0.1
	npm install --prefix test/legacy/v5.0.1 @tokenize.it/contracts@5.0.1 --silent

.PHONY: install-legacy-v6.1.0
install-legacy-v6.1.0:
	@mkdir -p test/legacy/v6.1.0
	npm install --prefix test/legacy/v6.1.0 @tokenize.it/contracts@6.1.0 --silent
