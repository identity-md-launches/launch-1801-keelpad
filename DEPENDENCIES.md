# Vendored dependencies

Dependencies are included as ordinary source files, with no submodules and no
installation step. Their upstream files are unmodified. The exact retained files,
individual SHA-256 checksums, archive URLs, and downloaded archive checksums are
recorded in [dependencies.lock.json](dependencies.lock.json).

| Dependency | Pinned release | Retained files | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `v5.0.2` | `ERC20.sol`, its four transitive source dependencies, and license | [MIT](lib/openzeppelin-contracts/LICENSE) |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `v1.9.7` | Complete `src/` tree and both licenses; used only by tests | [MIT](lib/forge-std/LICENSE-MIT) / [Apache-2.0](lib/forge-std/LICENSE-APACHE) |

`foundry.toml` maps `@openzeppelin/contracts/` and `forge-std/` to these local
directories. OpenZeppelin provides the production ERC-20 behavior. Forge Standard
Library supplies test assertions, fuzz helpers, and cheatcode interfaces; none of
its code is linked into the deployed token.

Only the ERC-20 dependency subset is vendored from OpenZeppelin. Other modules
from that release are not available unless explicitly added. Upstream dependency
comments are preserved; allowance event behavior is determined by the code in
`_spendAllowance`, which disables the `Approval` event for allowance spending.

