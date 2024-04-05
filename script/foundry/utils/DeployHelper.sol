/* solhint-disable no-console */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// external
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
// TODO: fix the install of this plugin for safer deployments
// import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { ERC6551Registry } from "erc6551/ERC6551Registry.sol";

// contracts
import { AccessController } from "contracts/access/AccessController.sol";
import { IPAccountImpl } from "contracts/IPAccountImpl.sol";
import { IIPAccount } from "contracts/interfaces/IIPAccount.sol";
import { IRoyaltyPolicyLAP } from "contracts/interfaces/modules/royalty/policies/IRoyaltyPolicyLAP.sol";
import { Governance } from "contracts/governance/Governance.sol";
import { AccessPermission } from "contracts/lib/AccessPermission.sol";
import { Errors } from "contracts/lib/Errors.sol";
import { PILFlavors } from "contracts/lib/PILFlavors.sol";
// solhint-disable-next-line max-line-length
import { DISPUTE_MODULE_KEY, ROYALTY_MODULE_KEY, LICENSING_MODULE_KEY, TOKEN_WITHDRAWAL_MODULE_KEY, CORE_METADATA_MODULE_KEY, CORE_METADATA_VIEW_MODULE_KEY } from "contracts/lib/modules/Module.sol";
import { IPAccountRegistry } from "contracts/registries/IPAccountRegistry.sol";
import { IPAssetRegistry } from "contracts/registries/IPAssetRegistry.sol";
import { ModuleRegistry } from "contracts/registries/ModuleRegistry.sol";
import { LicenseRegistry } from "contracts/registries/LicenseRegistry.sol";
import { LicensingModule } from "contracts/modules/licensing/LicensingModule.sol";
import { RoyaltyModule } from "contracts/modules/royalty/RoyaltyModule.sol";
import { RoyaltyPolicyLAP } from "contracts/modules/royalty/policies/RoyaltyPolicyLAP.sol";
import { DisputeModule } from "contracts/modules/dispute/DisputeModule.sol";
import { ArbitrationPolicySP } from "contracts/modules/dispute/policies/ArbitrationPolicySP.sol";
import { TokenWithdrawalModule } from "contracts/modules/external/TokenWithdrawalModule.sol";
// solhint-disable-next-line max-line-length
import { PILPolicyFrameworkManager, PILPolicy, RegisterPILPolicyParams } from "contracts/modules/licensing/PILPolicyFrameworkManager.sol";
import { MODULE_TYPE_HOOK } from "contracts/lib/modules/Module.sol";
import { IModule } from "contracts/interfaces/modules/base/IModule.sol";
import { IHookModule } from "contracts/interfaces/modules/base/IHookModule.sol";
import { IpRoyaltyVault } from "contracts/modules/royalty/policies/IpRoyaltyVault.sol";
import { CoreMetadataModule } from "contracts/modules/metadata/CoreMetadataModule.sol";
import { CoreMetadataViewModule } from "contracts/modules/metadata/CoreMetadataViewModule.sol";

// script
import { StringUtil } from "./StringUtil.sol";
import { BroadcastManager } from "./BroadcastManager.s.sol";
import { StorageLayoutChecker } from "./upgrades/StorageLayoutCheck.s.sol";
import { JsonDeploymentHandler } from "./JsonDeploymentHandler.s.sol";

// test
import { TestProxyHelper } from "test/foundry/utils/TestProxyHelper.sol";

contract DeployHelper is Script, BroadcastManager, JsonDeploymentHandler, StorageLayoutChecker {
    using StringUtil for uint256;
    using stdJson for string;

    ERC6551Registry internal immutable erc6551Registry;
    IPAccountImpl internal ipAccountImpl;

    // Registry
    IPAccountRegistry internal ipAccountRegistry;
    IPAssetRegistry internal ipAssetRegistry;
    LicenseRegistry internal licenseRegistry;
    ModuleRegistry internal moduleRegistry;

    // Core Module
    LicensingModule internal licensingModule;
    DisputeModule internal disputeModule;
    RoyaltyModule internal royaltyModule;
    CoreMetadataModule internal coreMetadataModule;

    // External Module
    CoreMetadataViewModule internal coreMetadataViewModule;
    TokenWithdrawalModule internal tokenWithdrawalModule;

    // Policy
    ArbitrationPolicySP internal arbitrationPolicySP;
    RoyaltyPolicyLAP internal royaltyPolicyLAP;
    UpgradeableBeacon internal ipRoyaltyVaultBeacon;
    IpRoyaltyVault internal ipRoyaltyVaultImpl;
    PILPolicyFrameworkManager internal pilPfm;

    // Misc.
    Governance internal governance;
    AccessController internal accessController;

    // Token
    ERC20 private immutable erc20; // keep private to avoid conflict with inheriting contracts

    // keep private to avoid conflict with inheriting contracts
    uint256 private immutable ARBITRATION_PRICE;
    uint256 private immutable MAX_ROYALTY_APPROVAL;

    // DeployHelper variable
    bool private writeDeploys;

    constructor(
        address erc6551Registry_,
        address erc20_,
        uint256 arbitrationPrice_,
        uint256 maxRoyaltyApproval_
    ) JsonDeploymentHandler("main") {
        erc6551Registry = ERC6551Registry(erc6551Registry_);
        erc20 = ERC20(erc20_);
        ARBITRATION_PRICE = arbitrationPrice_;
        MAX_ROYALTY_APPROVAL = maxRoyaltyApproval_;
    }

    /// @dev To use, run the following command (e.g. for Sepolia):
    /// forge script script/foundry/deployment/Main.s.sol:Main --rpc-url $RPC_URL --broadcast --verify -vvvv

    function run(
        address runDeployer,
        bool configByMultisig,
        bool runStorageLayoutCheck,
        bool writeDeploys_
    ) public virtual {
        writeDeploys = writeDeploys_;

        // This will run OZ storage layout check for all contracts. Requires --ffi flag.
        if (runStorageLayoutCheck) super.run();

        if (block.chainid == 31337) deployer = runDeployer; // set for local before _beginBroadcast
        _beginBroadcast(); // BroadcastManager.s.sol

        _deployProtocolContracts(runDeployer);
        if (!configByMultisig) {
            _configureDeployment();
        }

        if (writeDeploys) _writeDeployment();
        _endBroadcast(); // BroadcastManager.s.sol
    }

    function _deployProtocolContracts(address runDeployer) private {
        require(address(erc20) != address(0), "Deploy: Asset Not Set");

        string memory contractKey;

        // Core Protocol Contracts

        contractKey = "Governance";
        _predeploy(contractKey);
        governance = new Governance(runDeployer);
        _postdeploy(contractKey, address(governance));

        contractKey = "AccessController";
        _predeploy(contractKey);

        address impl = address(new AccessController());
        accessController = AccessController(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(AccessController.initialize, address(governance)))
        );
        impl = address(0); // Make sure we don't deploy wrong impl
        _postdeploy(contractKey, address(accessController));

        contractKey = "IPAccountImpl";
        _predeploy(contractKey);
        ipAccountImpl = new IPAccountImpl(address(accessController));
        _postdeploy(contractKey, address(ipAccountImpl));

        contractKey = "ModuleRegistry";
        _predeploy(contractKey);
        impl = address(new ModuleRegistry());
        moduleRegistry = ModuleRegistry(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(ModuleRegistry.initialize, address(governance)))
        );
        impl = address(0); // Make sure we don't deploy wrong impl
        _postdeploy(contractKey, address(moduleRegistry));

        contractKey = "IPAccountRegistry";
        _predeploy(contractKey);
        ipAccountRegistry = new IPAccountRegistry(address(erc6551Registry), address(ipAccountImpl));
        _postdeploy(contractKey, address(ipAccountRegistry));

        contractKey = "IPAssetRegistry";
        _predeploy(contractKey);
        ipAssetRegistry = new IPAssetRegistry(address(erc6551Registry), address(ipAccountImpl), address(governance));
        _postdeploy(contractKey, address(ipAssetRegistry));

        contractKey = "RoyaltyModule";
        _predeploy(contractKey);
        impl = address(new RoyaltyModule());
        royaltyModule = RoyaltyModule(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(RoyaltyModule.initialize, address(governance)))
        );
        impl = address(0);
        _postdeploy(contractKey, address(royaltyModule));

        contractKey = "DisputeModule";
        _predeploy(contractKey);
        impl = address(new DisputeModule(address(accessController), address(ipAssetRegistry)));
        disputeModule = DisputeModule(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(DisputeModule.initialize, address(governance)))
        );
        impl = address(0);
        _postdeploy(contractKey, address(disputeModule));

        contractKey = "LicenseRegistry";
        _predeploy(contractKey);
        impl = address(new LicenseRegistry());
        licenseRegistry = LicenseRegistry(
            TestProxyHelper.deployUUPSProxy(
                impl,
                abi.encodeCall(
                    LicenseRegistry.initialize,
                    (
                        address(governance),
                        "https://github.com/storyprotocol/protocol-core/blob/main/assets/license-image.gif"
                    )
                )
            )
        );
        impl = address(0); // Make sure we don't deploy wrong impl
        _postdeploy(contractKey, address(licenseRegistry));

        contractKey = "LicensingModule";
        _predeploy(contractKey);

        impl = address(
            new LicensingModule(
                address(accessController),
                address(ipAccountRegistry),
                address(royaltyModule),
                address(licenseRegistry),
                address(disputeModule)
            )
        );
        licensingModule = LicensingModule(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(LicensingModule.initialize, address(governance)))
        );
        impl = address(0); // Make sure we don't deploy wrong impl
        _postdeploy(contractKey, address(licensingModule));

        contractKey = "TokenWithdrawalModule";
        _predeploy(contractKey);
        tokenWithdrawalModule = new TokenWithdrawalModule(address(accessController), address(ipAccountRegistry));
        _postdeploy(contractKey, address(tokenWithdrawalModule));

        //
        // Story-specific Contracts
        //

        contractKey = "ArbitrationPolicySP";
        _predeploy(contractKey);
        impl = address(new ArbitrationPolicySP(address(disputeModule), address(erc20), ARBITRATION_PRICE));
        arbitrationPolicySP = ArbitrationPolicySP(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(ArbitrationPolicySP.initialize, address(governance)))
        );
        impl = address(0);
        _postdeploy(contractKey, address(arbitrationPolicySP));

        contractKey = "RoyaltyPolicyLAP";
        _predeploy(contractKey);
        impl = address(new RoyaltyPolicyLAP(address(royaltyModule), address(licensingModule)));
        royaltyPolicyLAP = RoyaltyPolicyLAP(
            TestProxyHelper.deployUUPSProxy(impl, abi.encodeCall(RoyaltyPolicyLAP.initialize, address(governance)))
        );
        impl = address(0);
        _postdeploy(contractKey, address(royaltyPolicyLAP));

        _predeploy("PILPolicyFrameworkManager");
        impl = address(
            new PILPolicyFrameworkManager(
                address(accessController),
                address(ipAccountRegistry),
                address(licensingModule)
            )
        );
        pilPfm = PILPolicyFrameworkManager(
            TestProxyHelper.deployUUPSProxy(
                impl,
                abi.encodeCall(
                    PILPolicyFrameworkManager.initialize,
                    ("pil", "https://github.com/storyprotocol/protocol-core/blob/main/PIL-Beta-2024-02.pdf")
                )
            )
        );
        impl = address(0); // Make sure we don't deploy wrong impl
        _postdeploy("PILPolicyFrameworkManager", address(pilPfm));

        _predeploy("IpRoyaltyVaultImpl");
        ipRoyaltyVaultImpl = new IpRoyaltyVault(address(royaltyPolicyLAP));
        _postdeploy("IpRoyaltyVaultImpl", address(ipRoyaltyVaultImpl));

        _predeploy("IpRoyaltyVaultBeacon");
        ipRoyaltyVaultBeacon = new UpgradeableBeacon(address(ipRoyaltyVaultImpl), address(governance));
        _postdeploy("IpRoyaltyVaultBeacon", address(ipRoyaltyVaultBeacon));

        _predeploy("CoreMetadataModule");
        coreMetadataModule = new CoreMetadataModule(address(accessController), address(ipAssetRegistry));
        _postdeploy("CoreMetadataModule", address(coreMetadataModule));

        _predeploy("CoreMetadataViewModule");
        coreMetadataViewModule = new CoreMetadataViewModule(address(ipAssetRegistry), address(moduleRegistry));
        _postdeploy("CoreMetadataViewModule", address(coreMetadataViewModule));
    }

    function _predeploy(string memory contractKey) private view {
        if (writeDeploys) console2.log(string.concat("Deploying ", contractKey, "..."));
    }

    function _postdeploy(string memory contractKey, address newAddress) private {
        if (writeDeploys) {
            _writeAddress(contractKey, newAddress);
            console2.log(string.concat(contractKey, " deployed to:"), newAddress);
        }
    }

    function _configureDeployment() private {
        // Module Registry
        moduleRegistry.registerModule(DISPUTE_MODULE_KEY, address(disputeModule));
        moduleRegistry.registerModule(LICENSING_MODULE_KEY, address(licensingModule));
        moduleRegistry.registerModule(ROYALTY_MODULE_KEY, address(royaltyModule));
        moduleRegistry.registerModule(CORE_METADATA_MODULE_KEY, address(coreMetadataModule));
        moduleRegistry.registerModule(CORE_METADATA_VIEW_MODULE_KEY, address(coreMetadataViewModule));
        moduleRegistry.registerModule(TOKEN_WITHDRAWAL_MODULE_KEY, address(tokenWithdrawalModule));

        // License Registry
        licenseRegistry.setDisputeModule(address(disputeModule));
        licenseRegistry.setLicensingModule(address(licensingModule));

        // Access Controller
        accessController.setAddresses(address(ipAccountRegistry), address(moduleRegistry));
        accessController.setGlobalPermission(
            address(ipAssetRegistry),
            address(licensingModule),
            bytes4(licensingModule.linkIpToParents.selector),
            AccessPermission.ALLOW
        );
        accessController.setGlobalPermission(
            address(ipAssetRegistry),
            address(licensingModule),
            bytes4(licensingModule.addPolicyToIp.selector),
            AccessPermission.ALLOW
        );

        // Royalty Module and SP Royalty Policy
        royaltyModule.setLicensingModule(address(licensingModule));
        royaltyModule.whitelistRoyaltyPolicy(address(royaltyPolicyLAP), true);
        royaltyModule.whitelistRoyaltyToken(address(erc20), true);
        royaltyPolicyLAP.setSnapshotInterval(7 days);
        royaltyPolicyLAP.setIpRoyaltyVaultBeacon(address(ipRoyaltyVaultBeacon));

        // Dispute Module and SP Dispute Policy
        address arbitrationRelayer = deployer;
        disputeModule.whitelistDisputeTag("PLAGIARISM", true);
        disputeModule.whitelistArbitrationPolicy(address(arbitrationPolicySP), true);
        disputeModule.whitelistArbitrationRelayer(address(arbitrationPolicySP), arbitrationRelayer, true);
        disputeModule.setBaseArbitrationPolicy(address(arbitrationPolicySP));

        // Core Metadata Module
        coreMetadataViewModule.updateCoreMetadataModule();
    }
}
