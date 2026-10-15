# Keelpad (KEEL)

An immutable, fixed supply ERC-20 token. The complete supply is minted once in the
constructor to the immediate deploying address.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Source / Solidity identifier | `src/Keelpad.sol:Keelpad` |
| Name | `Keelpad` |
| Symbol | `KEEL` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Constructor arguments | None (`[]`; encoded arguments are empty) |
| Constructor transaction value | `0` native currency |
| Initial recipient | Constructor `msg.sender` (the immediate deployer) |
| Launch chain | Ethereum, chain ID `1` |
| Compiler / EVM target | Solidity `0.8.26` / Cancun |
| Optimizer | Enabled, `200` runs |
| Metadata hash | `none` |
| Linked libraries / application contracts | None |

The production contract inherits the vendored OpenZeppelin ERC-20 implementation
and adds only the fixed metadata, supply constant, and constructor mint. Its
constructor has no external calls or dependencies on contracts already deployed.

Deploy the creation bytecode from `out/Keelpad.sol/Keelpad.json` with no arguments
and no ETH. The equivalent Solidity expression is `new Keelpad()`. Deploy the
contract directly, without a proxy or initializer.

In the specified IdentityMD launch, the factory is the immediate deployer and
receives **all** tokens. The requesting wallet and transaction origin receive
nothing from the constructor. The external launch process handles the 10% swarm
allocation, 80% pool allocation, and 10% remainder after deployment; those
allocations are not performed by the token. Pool creation, trading fees, price,
and distribution policy belong to that process. No factory, router, pool manager,
recipient, or owner address is embedded in this token.

The later launch step supplies its own manifest and deploys the artifact. This
repository does not contain a launch manifest or a broadcasting script.

## Behavior and assumptions

- `transfer`, `approve`, and `transferFrom` return `true` on success and revert
  with OpenZeppelin ERC-20 custom errors on failure. Transfers deliver the exact
  requested amount; there are no token taxes, transfer burns, rebases, or fees.
- Zero-value transfers and self-transfers are supported. Transfers to the zero
  address and approvals for a zero spender revert.
- Finite allowances decrease when spent. An allowance of `type(uint256).max`
  represents unlimited approval and remains unchanged when spent. `approve`
  replaces the previous allowance, and approving zero revokes it.
- Minting emits `Transfer(address(0), deployer, INITIAL_SUPPLY)`. Transfers emit
  `Transfer`, and explicit approvals emit `Approval`. This version does not emit
  an additional `Approval` when `transferFrom` spends an allowance; indexers
  should read `allowance` for its current value.
- There are no public mint or burn methods, administrative roles, pause,
  blacklist, seizure, ownership, upgrade, permit, or recovery functions. The
  deployer has the same transfer rights as every other holder after the mint.
- The token makes no external calls, including calls to transfer recipients.
  Sending KEEL to a contract does not invoke a receiver callback. The supply
  remains constant even if tokens become inaccessible.
- Ordinary ETH transfers revert. Tokens sent to the token contract itself, and
  assets otherwise trapped there, have no recovery path.

No additional token transfer restrictions or administrative features were
requested. Standard ERC-20 behavior is the implementation assumption.

## Build and test

From this repository root, with Foundry and Solidity `0.8.26` available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xbe72c0a789c5efb898e641f1aeb8f8095ce10346e01ef6012720e2f6b4219bc0 forge test
forge fmt --check
```

All Solidity dependencies are ordinary vendored files under `lib/`. No package
installation, Git submodule, RPC, wallet, FFI, or filesystem cheatcode permission
is required. Once the pinned compiler is installed, the project also builds and
tests with the `--offline` CLI option. The compiler binary is not part of this
repository. See [DEPENDENCIES.md](DEPENDENCIES.md) for provenance and licenses.

Tests do not read or modify environment variables and have independent setup.
The shell seed above configures Foundry's fuzzer; it is not read by Solidity.
There is no seed override in `foundry.toml`.

`test/Keelpad.t.sol` covers metadata, the exact supply and mint event, direct and
CREATE2 factory deployment, exact launch distribution and token settlement
transfers, allowance isolation and revocation, finite and infinite allowances,
zero/self/full transfers, revert reasons and rollback, unavailable administrative
entry points, native currency rejection, runtime size, and forbidden opcodes.
Five fuzz tests each run 1,024 cases, including successful transfers and invalid
balance/allowance spends.

`test/Keelpad.invariant.t.sol` runs 256 sequences of 64 actions over four holders.
It mixes transfers, approvals, revocations, delegated spending, and attempted
overdraws, checking exact balance/allowance changes and conservation of the entire
supply. Unexpected handler reverts fail the run.

## After launch

There are no owner-settable settings, initialization calls, keepers, or recurring
token administration duties. The launch operator is responsible for deploying
the reviewed artifact, confirming metadata and the `10^27` initial balance at
the factory, completing the factory's distribution and pool setup, and verifying
the source on the block explorer. No deployment or transaction was performed by
this implementation task.

Holders are responsible for protecting their keys, checking recipient addresses,
and managing allowances. Prefer approvals sized for the intended use. When
replacing an active allowance, revoke it and confirm the revocation before
granting a new allowance to limit the standard ERC-20 approval race; a spender
can still spend an existing approval before its revocation is confirmed.

## Verification scope

Local verification passed: `forge build`, all 31 tests with the specified seed
(including 5,120 fuzz cases and 16,384 invariant actions), and `forge fmt --check`.
See [SECURITY.md](SECURITY.md) for the implementation review and its limits.

The supplied protected checks were read as acceptance inputs. Their complete
external launch harness, `OwnerChecks`, and Uniswap v4 dependencies are not part
of this repository. The local factory test checks token deployment and exact
settlement transfers; it does not claim to run an actual pool or the protected
launch suite. Those checks remain the independent verifier's responsibility.

