pragma solidity 0.6.12;

import "forge-std/Script.sol";
import "centre-tokens.git/contracts/v2/FiatTokenV2_1.sol";

contract USDCDeployScript is Script {
    address private masterMinterAddress;
    address private tokenMinterAddress;
    address private dummyAddress;

    uint256 private masterMinterPrivateKey;
    uint256 private usdcMinterAllowance = 10000;

    /**
     * @notice deploys and initializes USDC
     * @param privateKey Private Key for signing the transactions
     * @return FiatTokenV2_1 USDC instance
     */
    function deploy(uint256 privateKey) private returns (FiatTokenV2_1) {
        vm.startBroadcast(privateKey);

        // Deploy USDC contract
        FiatTokenV2_1 usdc = new FiatTokenV2_1();

        // Initialize V1
        usdc.initialize(
            "USDC",
            "USDC",
            "USDC",
            0,
            masterMinterAddress,
            dummyAddress,
            dummyAddress,
            masterMinterAddress
        );

        // Initialize V2
        usdc.initializeV2("USDC");

        // Initialize V2_1
        usdc.initializeV2_1(dummyAddress);
        vm.stopBroadcast();
        return usdc;
    }

    /**
     * @notice Configures master minter and tokenMinter with mint allowances and funds test address
     * @param privateKey Private Key for signing the transactions
     * @param usdc USDC contract instance
     */
    function configureMintersAndBalances(uint256 privateKey, FiatTokenV2_1 usdc) public {
        vm.startBroadcast(privateKey);

        usdc.configureMinter(masterMinterAddress, usdcMinterAllowance);
        usdc.configureMinter(tokenMinterAddress, usdcMinterAllowance);

        usdc.mint(dummyAddress, 1000);
        usdc.mint(tokenMinterAddress, 1000);

        vm.stopBroadcast();
    }

    /**
     * @notice initialize variables from environment
     */
    function setUp() public {
        masterMinterAddress = vm.envAddress("MASTER_MINTER_ADDRESS");
        tokenMinterAddress = vm.envAddress("TOKEN_MINTER_ADDRESS");
        dummyAddress = vm.envAddress("DUMMY_ADDRESS");
        masterMinterPrivateKey = vm.envUint("MASTER_MINTER_KEY");
    }

    /**
     * @notice main function that will be run by forge
     */
    function run() public {
        FiatTokenV2_1 usdc = deploy(masterMinterPrivateKey);
        configureMintersAndBalances(masterMinterPrivateKey, usdc);
    }
}
