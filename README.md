# T3 Builders — fork PoCs

Foundry tests fork Base mainnet at pinned block **58431348** and target the
deployed Appendix A proxies (BuildersV4, BuildersTreasuryV2, RewardPool,
FeeConfig). `forge-std` is vendored under `lib/` (copied from a local repo,
no network install needed).

Run (needs a Base RPC URL):
  BASE_RPC_URL=https://mainnet.base.org forge test -vvv

Tests (`test/T3Builders.t.sol`):
- `testSubnetAdminPermanentlyLocksStakersPrincipal` — T3-01 MAIN PoC: a free,
  permissionless subnet admin raises the withdraw lock to type(uint128).max
  after deposits; victim's withdraw reverts with panic 0x11 immediately and
  100 years later; 1000 MOR (~$700) permanently locked. Asserts the loss.
- `testSubnetAdminHundredYearLock` — T3-01b: same with a 100-year lock.
- `testUnprivilegedCannotAcquireRolesOrTouchOthersSubnets` — T3-04 negative:
  owner/treasury/fee setters + чужой subnet edit/claim all revert for an
  unprivileged address.
- `testEqualStakesEarnEqualRewards` — T3-03 negative: equal stakes in two
  subnets over the same 30-day window earn equal claims (within dust).

No privileged accounts are used: attacker/victim are fresh addresses anyone
can control; no `vm.prank` as owner/admin/multisig. Local fork execution only.
