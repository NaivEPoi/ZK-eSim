# ZK-eSIM Project — Agent Knowledge Base

This file captures accumulated project knowledge for AI-assisted development.
It covers architecture, cryptographic design, known bugs and their fixes, and
testing/workflow conventions.

---

## Recent Notes (Apr 2026)

- BF38 eligibility signatures (`sigCred`, `authToken`, `sigRoot`) are emitted as raw 64-byte ECDSA (`r||s`), not DER. The applet now computes them at install time from the real self-signed eUICC cert; if traces show `30 44` / `30 45` inside BF38 `5F37`-related fields, the deployed CAP is stale.
- BF38 now emits two real DER certificates: `euiccCertificate` and `eumCertificate` both carry the same self-signed eUICC cert so `pysim` can use standard `AuthenticateServerResponse` decoding even in `--zk` mode.
- `osmo-smdpp.py` now uses the standard BF38 decoder in all modes. In `--zk`, it still skips EUM chain/root validation but continues verifying `euiccSignature1` over raw `euiccSigned1`.
- BF21 verification must use `SmdpSigned2` TLV followed by the full `5F37` euiccSignature1 DO from BF38. If PrepareDownload success cases start returning error `0x02`, check this concatenation first.
- `Apdu.MAX_REASSEMBLED_APDU` is `1536`; the old `1024` buffer was too small once BF38 carried two full DER certificates and triggered `6F00` during AuthenticateServer.
- BF36 now follows SGP.22 segmentation on the applet side. The card assembles the BPP piecewise (`BF36+BF23`, `A0` seqOf87 start, `A1` header + `88`s, optional `A2` seqOf87 start, `A3` header + `86`s) instead of expecting one monolithic `BF36`.
- Outer BPP protection uses real BSP keys derived from BF23 (`smdpOtpk` + CRT `hostId` + EID). `A2` is decrypted as `ReplaceSessionKeysRequest`, and `A3` is then verified with the received PPP keys (`initialMacChainingValue`, `ppkEnc`, `ppkCmac`) rather than hardcoded session keys.
- Temporary BF36 diagnostics were removed after stabilising the pySim path; keep only spec-visible responses.
- **APDU chaining uses proprietary `91xx`, not ISO `61xx`.** Reason: on real cards with CLA `0x81` transport, throwing `ISOException(0x61xx)` during response staging can cause immediate `6F00` instead of normal GET RESPONSE flow. `91xx` bypasses the T=0 runtime's auto-chaining special-casing. Host recognises `91xx` as equivalent to `61xx`: issue `00 C0 00 00 <sw2>` to pull the next chunk. lpac-side handling lives in `es10x_transmit_iter` and keys on `SW1_LAST || SW1_LAST_PROP` (`interface.private.h`). Diagnostic breadcrumbs must ignore normal `91xx` (and `61xx`) statuses — do not record as faults.
- Phase 1/2 runtime flow is now present: `BF42` builds a card-side `ZKProfileResponse` from the MNO challenge, and `BF43` installs MNO-issued `EligibilityData` into the buffers later emitted by BF38. `pysim/mno-server.py` owns `FIXED_MNO_PRIVATE_SCALAR`, verifies the BF42 statement signature, calls SM-DP+ ES2+ `downloadOrder` / `confirmOrder`, and returns a BF43 TLV to lpac. The lpac entry point is `lpac profile zk-download`.
- `zkesim_workflow.sh` intentionally uses two downloads. Phase 1c is always the normal SGP.22 bootstrap download through the default ISD-R AID; it loads the profile containing the ZK-eSIM applet and starts SM-DP+ without `--zk`. Phase 2 switches `LPAC_CUSTOM_ISD_R_AID` to the ZK applet AID; by default it restarts SM-DP+ with `--zk`, starts the MNO server, and runs `lpac profile zk-download` to exercise BF42/BF43 plus the standard ES10 chain through the applet. Set `ZK_DOWNLOAD=0` only to make this second/applet-targeted download legacy too.
- Workflow Python commands assume the caller has already activated the right shell environment (`pysim` conda env in current dev setup). Do not wrap script Python invocations in `conda run`; the script calls `python` directly and fails early if `python` is unavailable.
- Workflow defaults: `MNO_HOST=localhost`, `MNO_PORT=4443`, `LPAC_BUILD_DIR=${REPO_ROOT}/lpac/build`. If `lpac/build` was created by another user, fix ownership rather than changing the workflow default: `sudo chown -R "$USER":"$(id -gn)" lpac/build`.
- Workflow server logs go to `.zkesim-workflow/logs/` by default. SM-DP+ logs are named `smdpp-<zk_flag>-<timestamp>.log`; MNO logs are named `mno-<timestamp>.log`. The script refuses to start if the chosen SM-DP+ or MNO port is already occupied, because stale listeners previously caused false "server running" status.
- `pysim/mno-server.py` direct default port is `4443`. It logs JSON responses for MNO endpoints. lpac's `es12p.c` prints MNO HTTP status/body diagnostics when challenge/request/ack calls fail, which is useful for debugging early `es12p_get_mno_challenge` failures.
- SM-DP+ ES2+ `downloadOrder`, `confirmOrder`, and `releaseProfile` routes are available regardless of `--zk`; do not guard these endpoints by `zk_mode`. The MNO server itself is only launched by the workflow for the second ZK/MNO download.

---

## Repository Layout

```text
zkesim/
├── ZK-eSIM_applet/          JavaCard applet (source, tests, build)
├── lpac/                    SGP.22 LPA client (C)
├── pysim/                   Python SIM tools + SM-DP+ server
├── OpenEUICC/               Android LPA client (largely stock; not modified for ZK)
├── workdir/                 Transient build artefacts — not committed
├── zkesim_workflow.sh       End-to-end orchestration script
├── algtest_workflow.sh      Algorithm test runner
└── ZKESIM_WORKFLOW.md       Narrative workflow documentation
```

All four main directories are git submodules. After cloning:

```bash
git submodule update --init --recursive
```

## ZK-eSIM Protocol (Algorithm 6)

Only AuthenticateServerResponse (BF38) is structurally modified for ZK-eSIM.
GetEuiccInfo1 (BF20) is implemented for Phase 2 compatibility.
Other messages keep standard SGP.22 structure with ZK-context semantics:

- `euiccCertificate` -> `PCert_U` (pseudonym cert)
- `euiccOtpk` (`BF21`) -> `X_U` (ECDH ephemeral)
- `smdpOtpk` (`BF36` / `BF23`) -> `X_S` (server ECDH ephemeral)
- `euiccSignature1` -> session-binding signature over `euiccSigned1`

### BF38 EuiccSigned1 Extension

`EuiccSigned1` supports optional `eligibilityData [5]` containing:

- `hpid`
- `sigCred`
- `authToken`
- `accRoot`
- `sigRoot`
- `accProof`

With `AUTOMATIC TAGS` these are IMPLICIT on wire and encoded under `A5 { 80..85 }`.

### SM-DP+ ZK Mode

Run with `--zk` to enable:

- eligibility extraction from `BF38 euiccSigned1.eligibilityData`
- MNO signature and accumulator proof validation hooks
- ECDH-derived BSP session keys in `getBoundProfilePackage`
- skipping EUM certificate chain/root verification after BF38 decode

Without `--zk`, behavior remains standard SGP.22 flow.

### GetEuiccInfo1 (BF20) Support

The applet accepts `BF20` requests and returns a valid `EUICCInfo1` object:

- `svn` set to `2.4.0` (`02 04 00`)
- both `euiccCiPKIdListForVerification` and `euiccCiPKIdListForSigning` include the NIST CI SubjectKeyIdentifier

Implementation points:

- `Asn1.java`: decode tag `BF20` as `TYPE_GET_EUICC_INFO1_REQUEST`
- `ZkEsimApplet.java`: dispatch + `buildGetEuiccInfo1Response()`

---

## ZK-eSIM_applet

### Source files (`src/zk/esim/applet/`)

| File | Role |
|---|---|
| `ZkEsimApplet.java` | Applet entry point; dispatches ES10 APDUs (`BF2E`, `BF20`, `BF38`, `BF21`, `BF36`, `BF41`) |
| `Crypto.java` | All cryptographic operations (key gen, ECDSA, ECDH, ZKP, AES, cert build/verify) |
| `Asn1.java` | Strict DER decoder for inbound ES10 command objects (canonical-length checks enabled) |
| `Apdu.java` | APDU parsing helpers, request reassembly, response staging |
| `TlvWriter.java` | TLV serialisation |
| `ByteArrayUtil.java` | Byte-array utilities |
| `jcmathlib.java` | JCMathLib — BigNat arithmetic, EC operations; single-file vendored copy |

### Test files (`test/`)

| File | Role |
|---|---|
| `CryptoTestHarness.java` | Bootstrap applet for jCardSim; exposes `Crypto` for direct-call tests |
| `CryptoTest.java` | 10 JUnit 4 unit tests for `Crypto` methods; no APDU transmission |
| `ZkEsimAppletAuthenticateServerTest.java` | BF38 APDU integration tests |
| `ZkEsimAppletCancelSessionTest.java` | BF41 APDU integration tests |
| `ZkEsimAppletGetEuiccChallengeTest.java` | BF2E APDU integration tests |
| `ZkEsimAppletLoadBoundProfilePackageTest.java` | BF36 APDU integration tests |
| `ZkEsimAppletPrepareDownloadTest.java` | BF21 APDU integration tests |

### Build system (`build.xml`)

```bash
cd ZK-eSIM_applet
ant compile          # compile src/ -> build/classes/
ant compile-tests    # compile test/ -> build/test-classes/
ant test             # run all *Test.class under build/test-classes/
ant dist             # produce CAP file in output/
ant clean
```

The `test` target globs `**/*Test.class` automatically, so new test classes are picked up with no `build.xml` changes.

Classpath order:

- jCardSim 3.0.5
- JUnit 4.13.2
- JC SDK 3.2.0

All jars live in `ext/`.

### AIDs

| Purpose | AID (hex) |
|---|---|
| Production applet (package + instance) | `D0 70 02 CA 44 90 01 01` |
| Production load package | `D0 70 02 CA 44` |
| CryptoTestHarness (test only) | `D0 70 02 CA 44 90 01 FE` |

---

## Crypto.java — Public API

```java
// Key management
short exportPublicKey(byte[] out, short off)                     // 65-byte uncompressed P-256 point
PublicKey  getDevicePublicKey()
PrivateKey getDevicePrivateKey()

// ECDSA / verification
short sign(byte[] msg, short msgOff, short msgLen,
           byte[] sigOut, short sigOff)                          // DER-encoded ECDSA-SHA256
boolean verifyCertificate(PublicKey pk, byte[] serial, ...,
                          byte[] sig, short sigLen)

// Certificate construction
short buildCertificate(byte[] serial, ..., byte[] out, short off)

// Key agreement / session key
short deriveSessionKey(ECPublicKey peerPk,
                       byte[] sharedOut, short sharedOff,
                       byte[] sessionOut, short sessionOff)      // ECDH + SHA-256 KDF

// EID utilities
void  hashEidToPid(byte[] eid, byte[] pidOut)                    // SHA-256(eid)
short encryptEid(byte[] eid)                                     // AES-128-CBC with ephemeral key

// Zero-knowledge proof
short generateZkp(byte[] eid, byte[] pid, byte[] nonce,
                  byte[] outS, short sOff,
                  byte[] outT, short tOff)                       // returns tLen (65)
```

### ZKP Design (Schnorr-style sigma protocol)

1. Witness `w = H(SK || EID)` — scalar derived from the device private key and EID.
2. Randomise using ECDSA over `EID` to produce nonce `r` (the signature k-value).
3. Commitment `T = r·G` — random EC point.
4. Challenge `c = H(T || EID || pid || nonce)` — scalar.
5. Response `s = r + c·w mod n`.

Outputs:

- `s`: 32-byte scalar
- `T`: 65-byte uncompressed point

Verifier check:

- `s·G == T + c·W`, where `W = w·G` is the public witness commitment.

---

## Implementation Gotchas

### BF38 Response Shape

`AuthenticateServerResponse` success layout is:

- `BF38`
- `A0`
- raw `30` TLV for `euiccSigned1`
- `5F37` for `euiccSignature1`
- `30` for `euiccCertificate`
- `30` for `eumCertificate`

`pysim` now decodes this with the standard ASN.1 path in all modes.

### BF21 Signature Input

Live SM-DP+ signs:

- full `SmdpSigned2` TLV
- followed by full `5F37` DO containing `euiccSignature1`

The applet must verify exactly that byte sequence.

### BF36 Download Flow

Keep the protection layers separate:

- `A0`, `A1`, and `A2` are protected with outer BSP keys derived from BF23.
- `A2` carries `ReplaceSessionKeysRequest` (`BF26`) and is the source of PPP keys for the profile package phase.
- `A3` `LoadProfileElements` is verified with PPP `sMac`/`initialMacChainingValue` loaded from `A2`, not with the outer BSP state.

### APDU Buffering

`Apdu.MAX_REASSEMBLED_APDU = 1536` is intentional. Reducing it risks `6F00` once BF38 includes two full DER certificates.

### Response Chaining

Keep `91xx` handling intact unless the real-card transport behavior is revalidated. The host already treats `91xx` as “more data pending”.

---
