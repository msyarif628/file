# Sentinel — Deployed (live, 2026-11-17)

> Testnets only. No real money, no mainnet. Deployer is a throwaway
> testnet-only key (private key in `.env`, chmod 600, gitignored).

## The working deployment (v3)

| Contract | Chain | Address |
|---|---|---|
| SentinelToken (v3) | Sepolia (11155111) | `0x572B05c0cA43100BF485C2ddedA5eB405fCf842c` |
| SentinelVault (v3) | Sepolia (11155111) | `0x4019e0A7A0cc6C9A3f5B040784Dff6d23A1Fbe5C` |
| SentinelReactive (v3) | Lasna (5318007) | `0x68335C83ceFAd79316d5808BffD46141BC747495` |

- Deployer: `0x5eEF4e0Aa8a43346fAa12CBD15DDFe78CF1b2e53`
- Vault v3: `callbackSender` = RSC v3, `paused() = true` (after the
  video-take re-run, 2026-11-17 ~19:17 WIB), 48,780 SENT,
  0.04999999996941836 ETH (0.05 minus ~3.06e-11 ETH
  callback-delivery fee).
- Reactscan RSC v3: https://lasna.reactscan.net/address/0x68335C83ceFAd79316d5808BffD46141BC747495
  — status `active`, Transfer subscription listed (Sepolia 11155111,
  contract = token v3, topic0 `0xddf252ad...`).
- Sepolia Etherscan (vault): https://sepolia.etherscan.io/address/0x4019e0A7A0cc6C9A3f5B040784Dff6d23A1Fbe5C

## The live demo (2026-11-17, full loop proven)

1. **Normal withdrawal, 10 SENT** — vault stayed unpaused.
   Tx: `0x8d1e29b1cbdaaba82efff905a7422d9f763e6ba0b0cebb80883b110b9cf212ed`
   Lasna react: Scored 10 SENT → **score 3** (no callback).
2. **Drain burst, 5 × 800 SENT** (rapid, to fresh addresses).
   - Burst 1 (trigger): `0x92377ecb89f9b43e53ce81a59282847534b976a1a859f6af1562768413700540`
   - Burst 2: `0x043fdce2124a54eff5795ade8c7294290105ffbd5488c09d9390c0e7e0fce225`
     (succeeded — the pause had not landed yet when it was sent)
   - Bursts 3–5: **reverted** — vault already paused (circuit breaker working).
3. **Lasna reactive tx** (burst 1): `0x3e9c86bf24c527af4c78ab3ee04e08ca903f517ee09996890dd816fd2fce5a8b`
   (block 8569229) — Scored 800 SENT → **score 9985** → Callback +
   CallbackRequested. Burst 2 also scored (9997) but the RSC latch was
   already set, so no second callback — one request per event, by design.
4. **Sepolia callback tx**: `0x6fa26e8e4a7d9e0261ffd4ea6c8246a43eb236899193ea1c75d0535f980ec3e0`
   (block 12154292, status 1, from Reactive Signer
   `0xf7e866d7...`, via the Sepolia callback proxy
   `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`, gas 85,496) —
   `onAnomaly()` ran, `VaultPaused` emitted, `paused() = true`.

Vault balance after the demo: 50,390 SENT
(52,000 − 10 normal − 800 burst 1 − 800 burst 2; bursts 3–5 reverted).

## Video take — clean re-run on v3 (2026-11-17 ~19:17 WIB)

The v3 vault was PAUSED after the first demo, so the video needs a fresh
run. **A fresh vault v4 against the same RSC v3 does NOT work** — verified
on-chain 2026-11-17: `SentinelReactive.vault()` is an **immutable**
(`0x4019e0A7A0cc6C9A3f5B040784Dff6d23A1Fbe5C`, the v3 vault), and `react()`
returns early for any Transfer not FROM that address. `setRecipient(v4)`
only changes the callback *destination*, not the event filter — a v4
vault's withdrawals would never be scored, never trigger a callback, and
never pause. (If fully fresh addresses are wanted, deploy a v4 vault
**and** a v4 RSC together, following script/DEPLOY.md steps 2–5; that was
NOT done — the task forbids redeploying the RSC.)

So the video take re-ran the demo on v3 after re-arming it:
- `unpause()` on vault v3 (owner, 19:16:38 WIB):
  `0x5740045e50a408b319172cc00c818f682bda950b80957d7977a9709c0f811523`
  (status 1)
- `resetPauseFlag()` on RSC v3 (owner, 19:16:38 WIB):
  `0xe8a17259a71d141bb113251c7bd2e613a360544f2de3a67098d86623ee9236a9`
  (status 1) — NOTE: the latch does NOT auto-reset after the 10-min
  cooldown; it needs this manual call. The cooldown
  (`lastPauseRequestAt` 1794917221 + 600 s) had elapsed before the burst.
- Then `bash script/demo.sh` with TOKEN / VAULT / RSC = v3 addresses
  (started 19:17:44 WIB).

1. **Normal withdrawal, 10 SENT** — vault stayed unpaused.
   Tx: `0xe7699dce82767e8be26f08ac4e631676a7eb868c8a5cbfb405cfb243c71d5f3b`
   Lasna react: Scored 10 SENT → **score 3** (no callback).
   (Deposit 1,000 SENT first:
   `0x8c1624586897f87a020738cdc84e9d73c3202f8590292dc4f721f7964b971bed`)
2. **Drain burst, 5 × 800 SENT**.
   - Burst 1 (trigger):
     `0x5489174c1952dcc226065c833ceddd3b08333c3df71b6b3cd16b614392098682`
     (block 12154349)
   - Burst 2:
     `0xad5e584b8a8c92784d8343a753d1c9160397a8240b3925281dc8277fff03964c`
     (succeeded — the pause had not landed yet when it was sent)
   - Bursts 3–5: **reverted** — vault already paused.
3. **Lasna reactive tx** (burst 1):
   `0x80adfe9d254080c4772beac0d1c39b58e7e687115782fd29efe70e0a364a6fcb`
   (block 8567330, 19:18:37 WIB) — Scored 800 SENT → **score 9985** →
   Callback + CallbackRequested. Burst 2 also scored (9997) but the
   latch suppressed the 2nd callback.
4. **Sepolia callback tx**:
   `0x5b5e8c485c8213e7b1912853e35ec7afea88d1caecc38ede3f87a4d529c272f6`
   (block 12154350, 19:18:48 WIB, status 1, from Reactive Signer
   `0xf7e866d7...`, via the Sepolia callback proxy
   `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`, gas 85,496) —
   `onAnomaly()` ran, `VaultPaused` emitted (score 9985), `paused() = true`.

Vault balance after the re-run: 48,780 SENT
(50,390 − 10 normal − 800 burst 1 − 800 burst 2; bursts 3–5 reverted).
RSC `callbacksRequested` = 2, debt 0, reserves ~0.82 lREACT.
Deployer Sepolia ETH after the re-run: ~0.93202 ETH
(the whole re-arm + re-run cost ~0.000022 ETH).

For ANOTHER video take: repeat the re-arm (`unpause()` the vault +
`resetPauseFlag()` the RSC, wait out the 10-min cooldown from
`lastPauseRequestAt`) and run `bash script/demo.sh` again.

## Deployment transactions (v3)

| Step | Tx hash |
|---|---|
| Token v3 deploy | `0xa3becc3f65a1843e7f4353b5b2de24ff6edbf01ce44eeaba19d9345eae88d5ba` |
| Vault v3 deploy | `0xa78c998641f8f74ce689f1c26039c1ee6e61be5825be196fc7f4cc05e7aaa2e0` |
| RSC v3 deploy (`forge create`, `--value 0.1ether`) | `0xb3b67f87d550923b767ac84847ccf1ae0316779f1f74aae9c14b1daf06ff827b` |
| setRecipient (RSC → vault) | `0x73bc2a45c2b05e988c799846440ba1bca31e81c5f920e815da8c69d5aeff4f74` |
| depositTo 1 lREACT (debt 0, reserves 1) | `0x8ed730b317d9ae1780e5d2bea4460eed5418dbb21c3edeacc438d369bf9623a5` |
| Vault deposit 1,000 SENT (demo setup) | `0xb3005775242c38a309634ea4029812dab0aa273330f4ff55cbafd894ddd5b753` |

The RSC v3 address matched its prediction exactly (Lasna nonce 6):
`0x68335C83ceFAd79316d5808BffD46141BC747495`.

## What broke in v1/v2 (and the fix)

- **v1** (Omni-only subscribe): RSC `0xfB20d78FDFf8b633d68f6077B713c073de58BecD`.
  react() fired 6/6, legacy `emit Callback(...)` emitted, RSC paused,
  callbacksRequested=1 — but NO callback ever reached Sepolia after 8+
  min; vault ETH untouched, no VaultPaused event.
- **v2** (Omni + legacy `service.subscribe`): RSC
  `0xf12025C983534504e57E94cD2094F7904C5b1989`. Same result — react()
  fired exactly once per transfer (no double delivery), Callback
  emitted again, still no delivery.
- **The fix (v3)**: `react()` now requests the callback the Omni way —
  a low-level call to `SYSTEM_OMNI.requestCallbackV_1_0` with the
  `CallbackConfiguration_V_1_0` struct (docs-research.md §3.2). The
  published lib (v0.2.0) does not declare it, so it is called via
  `abi.encodeWithSignature` (same technique as subscribe). The legacy
  `emit Callback(...)` is kept too (tests + observability); a double
  delivery would be harmless (`onAnomaly` is idempotent). The request
  is NOT `require()`d — a failed request must not roll back the
  window/score state, and the latch only sets on success
  (`CallbackRequestFailed` is emitted otherwise).
- **demo.sh reporting bug (fixed in v3)**: `paused()` used to return the
  raw 32-byte hex from `cast call`, but the script compared it to the
  string `"true"` — so the live demo paused the vault yet the script
  printed "vault did NOT pause within 120 s". `paused()` now returns
  `true`/`false`.

## Still missing for the DoraHacks submission

- [ ] Push this repo to GitHub (gh not authenticated in this VM — parent
      handles it).
- [ ] Register the project on DoraHacks (Reactive Omni Buildathon, free).
- [ ] Record the 3-minute demo video (the live demo above is the script:
      normal 10 SENT → no pause; 5×800 SENT → vault pauses, bursts 3–5
      revert). A clean video take was already run 2026-11-17 ~19:17 WIB
      (hashes in the "Video take" section above) — film by re-running
      `bash script/demo.sh` the same way. The vault is paused again
      after the take; that is the expected end state. For another take,
      re-arm first: `unpause()` the vault + `resetPauseFlag()` the RSC
      (the latch does NOT auto-reset) and wait out the 10-min cooldown
      from `lastPauseRequestAt`. Do NOT deploy a fresh vault v4 against
      RSC v3 — the RSC's immutable `vault` filter would ignore it (see
      "Video take").
- [ ] Submit before the buildathon closes (~6 Dec 2026 12:00 UTC).
- [ ] (Optional) Verify the three contracts on Sourcify
      (see script/DEPLOY.md §8).
