# Implement all ZK-eSIM protocols: separate roles, complete Phase 0-6 flow, fix workflow

## Context

The current `zk_setup` branch (HEAD `66e2e9d`) added Phase 0
(`RegisterAndIssue` + `CertInit`) on top of the existing Phase 1/2/3/4
prototype, but it did so by copying new MNO/PCA responsibilities into
`pysim/osmo-smdpp.py`. The implementation now has the right ingredients in
pieces, but the role boundaries and execution order do not match the protocol.

Current state to fix:

- **SM-DP+ still contains duplicated MNO logic.** `getMNOChallenge`,
  `zkRequest`, and `ack` exist in both `pysim/mno-server.py` and
  `pysim/osmo-smdpp.py`.
- **SM-DP+ is also acting as PCA.** `registerChallenge`,
  `registerCredential`, and `certInitRequest` currently live in
  `osmo-smdpp.py`; `certInitRequest` signs `PCert_U` with the MNO key.
- **No PCA server exists.** `pysim/pca-server.py` and
  `pysim/smdpp-data/certs/PCA/` are missing.
- **`mno-server.py` cannot load.** It imports `extract_pcert_from_bf` and
  `ecdsa_der_to_tr03111`, but `pysim/pySim/esim/zk_utils.py` does not export
  them yet.
- **ASN.1 is broken.** `pysim/pySim/esim/asn1/rsp/rsp.asn` defines BF42/BF43
  twice; the later copy has the needed credential-binding field, while the
  earlier copy is missing it.
- **The workflow order is wrong.** In the ZK branch,
  `zkesim_workflow.sh` runs `lpac profile zk-download` before Phase 0
  registration/cert-init, so BF42 cannot use a fresh `sk_U`/`PCert_U`.
- **The workflow is not cleanly portable.** It has started moving toward
  macOS/Linux portability, but server lifecycle, port probing, job counts, and
  shell helpers need to be made deliberately cross-platform.

Target outcome: implement all protocol roles and phases provided in the paper
at protocol-flow fidelity while keeping the current prototype crypto
stand-ins. The flow should be:

```text
Setup -> RegisterAndIssue -> CertInit -> ZKRequest -> OrderProfile -> MutualAuthAndProvision
```

Out of scope for this pass:

- Do not replace the applet's existing prototype crypto with production ZK,
  commitment, blind-signature, PKE, or KDF constructions.
- Keep existing applet Phase 0/BF42/BF43/BF38 behavior unless a wire mismatch
  is found while integrating.
- Do not add production trust-anchor policy. Local PCA/MNO TLS certificates are
  development credentials.

## Target architecture

```text
UE / eUICC applet          lpac                  MNO :4443       PCA :5443       SM-DP+ :443
----------------          ----                  ---------       --------       -----------

Setup
  shared test parameters, CI roots, MNO/PCA/LEA public keys, local applet state

RegisterAndIssue (Alg. 2, BF44/BF45)
                       registerChallenge  ---->
                       <---- requestId, MNO nonce commitment
  <---- BF44 --------  MNO nonce commitment
  ---- BF44 -------->  blinded eligibility challenge, device auth signature
                       registerCredential ---->
                       <---- MNO partial signature
  <---- BF45 --------  MNO partial signature
  ---- BF45 -------->  eligibility credential stored in eUICC

CertInit (Alg. 3, BF46/BF47)
  <---- BF46 --------  session key seed
  ---- BF46 -------->  user public key, binding signature, credential binding hash
                       zk-certinit / certInitRequest ---------->
                       <------------------------ pseudonym certificate
  <---- BF47 --------  pseudonym certificate
  ---- BF47 -------->  session key and PCert_U installed

ZKRequest + OrderProfile (Alg. 4/5, BF42/BF43)
                       getMNOChallenge  ---->
                       <---- MNO challenge
  <---- BF42 --------  MNO challenge
  ---- BF42 -------->  ZK statement, PCert_U, request proof
                       zkRequest       ---->
                                            ES2+ downloadOrder ------------>
                                            <------------ ICCID
                                            ES2+ confirmOrder ------------>
                                            <------------ matchingId, smdpAddress
                       <---- BF43 SetEligibilityData TLV
  <---- BF43 --------  MNO-issued eligibility data
  ---- BF43 -------->  eligibility data stored
                       ack ------------>

MutualAuthAndProvision (Alg. 6, standard SGP.22 messages with ZK semantics)
  BF2E/BF38/BF21/BF36 via lpac <-----------------------------------------> SM-DP+
```

Server ownership:

- **MNO (`pysim/mno-server.py`, default port 4443):**
  Phase 0.a, ZKRequest, OrderProfile. Owns `L_auth`, verifies
  `pi_auth`/BF42 proof/PCert binding, calls SM-DP+ ES2+, and signs
  `credentialSignature`, `authorizationToken`, and `rootSignature`.
- **PCA (`pysim/pca-server.py`, default port 5443):**
  CertInit only. Verifies `bindingSignature`, signs `PCert_U` with
  `sk_PCA`, embeds the credential-binding hash as extension
  `2.23.146.1.2.1.8`, and keeps no session state.
- **SM-DP+ (`pysim/osmo-smdpp.py`, default port 443):**
  ES2+ order endpoints and ES9+ mutual authentication/provisioning only.
  In `--zk` mode it verifies Algorithm 6 eligibility data and token
  freshness/spend state; it does not expose MNO or PCA protocol endpoints.

## Work breakdown

### 1. ASN.1 cleanup and human-readable ZK definitions

File: `pysim/pySim/esim/asn1/rsp/rsp.asn`.

1. Delete the duplicate BF42/BF43 block near the end of the file.
2. Keep one canonical ZK block after `EligibilityData`.
3. Use human-friendly field names for all ZK additions. Avoid opaque names
   like `rMno`, `e`, `s`, `pkU`, `piBind`, and `hSigmaEid` in ASN.1.
4. Add comments that map each field to the protocol symbol and explain its
   wire size where fixed.

Canonical BF42/BF43 definitions:

```asn1
-- ZK-eSIM Algorithm 4: ZKRequest.
-- BF42 request carries only the server challenge from the MNO.  The applet
-- already has the fixed MNO/LEA public keys and local eUICC state.

ZKProfileRequest ::= [66] SEQUENCE { -- Tag 'BF42'
    mnoChallenge Octet16
        -- Protocol nonce from the MNO.  This is the single-use challenge that
        -- binds the BF42 proof to one OrderProfile attempt.
}

ZKProfileResponse ::= [66] CHOICE { -- Tag 'BF42'
    zkProfileResponseOk    ZKProfileResponseOk,
    zkProfileResponseError ZKProfileResponseError
}

ZKProfileResponseOk ::= SEQUENCE {
    zkStatement ZKStatement,
        -- Public statement x from Algorithm 4.
    pseudonymCertificate Certificate,
        -- PCert_U issued during CertInit.  In the SGP.22 download phase this
        -- same certificate is later sent as euiccCertificate.
    requestProof [APPLICATION 55] OCTET STRING
        -- Prototype pi_req.  Current applet encoding is Schnorr-style
        -- R || s, 65 + 32 = 97 bytes, under tag '5F37'.
}

ZKStatement ::= SEQUENCE {
    mnoPublicKey [0] OCTET STRING,
        -- pk_MNO, 65-byte uncompressed P-256 point.
    leaPublicKey [1] OCTET STRING,
        -- pk_LEA, 65-byte uncompressed P-256 point.
    userPublicKey [2] OCTET STRING,
        -- pk_U derived in CertInit, 65-byte uncompressed P-256 point.
    mnoChallenge [3] Octet16,
        -- Same MNO challenge as the request; checked for freshness.
    pseudonymId [4] Octet32,
        -- pid = PRF/KDF output used by the MNO to compute Hpid.
    encryptedEid [5] OCTET STRING,
        -- Prototype ECIES encryption of EID for the LEA; current applet
        -- encoding is ephemeral public key (65) || ciphertext (16) = 81 bytes.
    credentialBindingHash [6] Octet32
        -- SHA-256 of the sealed eligibility credential sigma_EID.  This binds
        -- the BF42 statement to the credential used when PCA issued PCert_U.
}
```

Canonical `EligibilityData` names:

```asn1
EligibilityData ::= SEQUENCE {
    hashedPseudonym Octet32,
        -- Hpid = H'(pid), used as the accumulator leaf.
    credentialSignature OCTET STRING,
        -- sigma_cred: MNO signature over Hpid || h_cert || mnoid.
    authorizationToken OCTET STRING,
        -- T_i: MNO one-time authorization token bound to Hpid and PCert_U.
    authorizationRoot OCTET STRING,
        -- root_auth: Merkle accumulator root after adding Hpid.
    rootSignature OCTET STRING,
        -- MNO signature over authorizationRoot.
    inclusionProof OCTET STRING
        -- Serialized accumulator inclusion proof pi_inc.
}
```

Add Phase 0 definitions with descriptive names:

```asn1
-- ZK-eSIM Algorithm 2: RegisterAndIssue, leg 1.
-- The MNO sends a nonce commitment to the eUICC; the eUICC answers with a
-- blinded challenge plus a device-authentication signature.

ZkRegisterChallengeRequest ::= [68] SEQUENCE { -- Tag 'BF44'
    mnoNonceCommitment OCTET STRING (SIZE(65))
        -- R_MNO = r_MNO * G, uncompressed P-256 point.
}

ZkRegisterChallengeResponse ::= [68] CHOICE { -- Tag 'BF44'
    zkRegisterChallengeOk    ZkRegisterChallengeOk,
    zkRegisterChallengeError ZkRegisterError
}

ZkRegisterChallengeOk ::= SEQUENCE {
    blindedEligibilityChallenge Octet32,
        -- Protocol e.  This is sent back to the MNO for blind signing.
    deviceAuthSignature OCTET STRING
        -- Prototype pi_auth = ECDSA-SHA256(sk_b, e), DER encoded.
}

-- ZK-eSIM Algorithm 2: RegisterAndIssue, leg 2.
-- The MNO signs the blinded challenge; the eUICC unblinds and seals sigma_EID.

ZkRegisterCredentialRequest ::= [69] SEQUENCE { -- Tag 'BF45'
    mnoPartialSignature Octet32
        -- Protocol s = r_MNO - e * sk_MNO mod q.
}

ZkRegisterCredentialResponse ::= [69] CHOICE { -- Tag 'BF45'
    zkRegisterCredentialOk    SEQUENCE {},
    zkRegisterCredentialError ZkRegisterError
}

-- ZK-eSIM Algorithm 3: CertInit, leg 1.
-- The eUICC derives a fresh user keypair and proves possession/binding.

ZkCertInitRequest ::= [70] SEQUENCE { -- Tag 'BF46'
    sessionKeySeed Octet32
        -- r_seed from Algorithm 3.  The prototype passes it from lpac.
}

ZkCertInitResponse ::= [70] CHOICE { -- Tag 'BF46'
    zkCertInitOk    ZkCertInitOk,
    zkCertInitError ZkRegisterError
}

ZkCertInitOk ::= SEQUENCE {
    userPublicKey OCTET STRING (SIZE(65)),
        -- pk_U, uncompressed P-256 point.
    bindingSignature OCTET STRING,
        -- Prototype pi_bind = ECDSA-SHA256(sk_U, pk_U || EID), DER encoded.
    credentialBindingHash Octet32
        -- SHA-256(sigma_EID), embedded into PCert_U by the PCA.
}

-- ZK-eSIM Algorithm 3: CertInit, leg 2.
-- The PCA-issued certificate is installed into the eUICC for later BF42/BF38.

ZkCertInstallRequest ::= [71] SEQUENCE { -- Tag 'BF47'
    pseudonymCertificate Certificate
        -- PCert_U, DER certificate signed by the PCA.
}

ZkCertInstallResponse ::= [71] CHOICE { -- Tag 'BF47'
    zkCertInstallOk    SEQUENCE {},
    zkCertInstallError ZkRegisterError
}

ZkRegisterError ::= INTEGER {
    invalidFormat(1),
    cryptoError(2),
    registrationRequired(3),
    undefinedError(127)
}
```

Implementation note: renaming ASN.1 fields requires updating Python dict
accesses in `mno-server.py`, `osmo-smdpp.py`, tests, and any `asn1.encode` /
`asn1.decode` callsites that reference the old names.

### 2. Restore and centralize ZK utility helpers

File: `pysim/pySim/esim/zk_utils.py`.

Add:

- `extract_pcert_from_bf(bf_blob: bytes, expected_outer_tag: int) -> bytes`
  - Parses `BF42` or `BF38`, enters the success `A0`, skips the statement or
    signed block, and returns the raw certificate DER bytes exactly as they
    appeared on wire.
  - Used by MNO and SM-DP+ so both compute `h_cert` over identical bytes.
- `ecdsa_der_to_tr03111(der: bytes) -> bytes`
  - Parses DER ECDSA and returns raw 64-byte `r || s`.
  - Inverse of existing `ecdsa_tr03111_to_dss`.
- `_build_pcert_u(pk_u_bytes: bytes, sk_pca, eid_ascii: str,
  credential_binding_hash: bytes) -> bytes`
  - Move from `osmo-smdpp.py`.
  - Adds X.509 extension `2.23.146.1.2.1.8` containing the
    credential-binding hash.

### 3. Add PCA server

New file: `pysim/pca-server.py`.

Model it on `mno-server.py` for Klein/Twisted setup and TLS launching.

Constants:

- `FIXED_PCA_PRIVATE_SCALAR`, distinct from the MNO scalar.
- `FIXED_TEST_EID = b'89001234567891234567891234567891'`.

Routes:

- `GET /health` returns `{"ok": true}`.
- `POST /zk-esim/v1/certInitRequest` accepts:
  - `userPublicKey` preferred, with `pkU` accepted as a temporary legacy alias.
  - `bindingSignature` preferred, with `piBind` accepted as a temporary legacy
    alias.
  - `credentialBindingHash` preferred, with `hSigmaEid` accepted as a
    temporary legacy alias.

Behavior:

1. Decode and validate `userPublicKey` is a 65-byte P-256 point.
2. Decode and validate `credentialBindingHash` is 32 bytes.
3. Verify `bindingSignature` over `userPublicKey || EID_BIN` using
   `userPublicKey`.
4. Build `PCert_U` with `_build_pcert_u(..., sk_PCA, ..., credentialBindingHash)`.
5. Return `{"pseudonymCertificate": <base64 DER>}` and also `pCertU` as a
   temporary compatibility alias until lpac/Python callers are migrated.

### 4. Move Phase 0.a to MNO server

File: `pysim/mno-server.py`.

Add:

- `FIXED_DEVICE_W`: the 65-byte `pk_b` matching the applet's fixed device key.
- `self.phase0_sessions = {}`.
- `POST /zk-esim/v1/registerChallenge`
  - Generate `r_mno`.
  - Return `requestId` and `mnoNonceCommitment` (base64 `R_MNO`).
  - Also return `rMno` as a temporary alias if needed by existing tests.
- `POST /zk-esim/v1/registerCredential`
  - Accept `blindedEligibilityChallenge`/`deviceAuthSignature`, with legacy
    aliases `e`/`piAuth` during migration.
  - Verify `deviceAuthSignature = ECDSA(sk_b, blindedEligibilityChallenge)`.
  - Compute `mnoPartialSignature = r_mno - e * sk_MNO mod q`.
  - Return `mnoPartialSignature` and legacy alias `s`.

Also fix existing Phase 1/2 issues:

- Accept lpac's JSON key `zkProfileResponse`; do not require the non-existent
  `zkProfileResponse_b64`.
- Use renamed ASN.1 fields: `mnoPublicKey`, `leaPublicKey`, `userPublicKey`,
  `pseudonymId`, `encryptedEid`, `credentialBindingHash`,
  `pseudonymCertificate`, and `requestProof`.
- Keep `L_auth` as server state, not a fresh local accumulator per request.
- Reject replay if `hashedPseudonym` is already in `L_auth`.
- Call SM-DP+ ES2+ `downloadOrder` and `confirmOrder` over HTTP instead of
  using any in-process SM-DP+ helper.
- Return BF43 as `setEligibilityDataRequest` using the renamed
  `EligibilityData` fields.

### 5. Strip MNO/PCA protocol code from SM-DP+

File: `pysim/osmo-smdpp.py`.

Delete:

- `_build_pcert_u` after moving it to `zk_utils.py`.
- `FIXED_DEVICE_W` and `FIXED_LEA_PUBLIC_W` if no remaining SM-DP+ path uses
  them.
- `self._mno_sessions`, `self._phase0_sessions`, `self._zk_pending_orders`,
  and `self._L_auth`.
- Routes:
  - `/zk-esim/v1/registerChallenge`
  - `/zk-esim/v1/registerCredential`
  - `/zk-esim/v1/certInitRequest`
  - `/zk-esim/v1/getMNOChallenge`
  - `/zk-esim/v1/zkRequest`
  - `/zk-esim/v1/ack`
- Internal `_zk_download_order_internal` and `_zk_confirm_order_internal`.
- `self._sk_mno` and `self._pk_mno_bytes` if unused after the route removal.

Keep:

- ES2+ `downloadOrder`, `confirmOrder`, and `releaseProfile`.
- ES9+ SGP.22 flow.
- `--zk` Algorithm 6 verification logic.
- `setupMNOValues` only for public constants/session defaults that SM-DP+
  still needs to verify MNO-issued credentials; it must not generate fake
  credentials for the applet in the new flow.

Algorithm 6 replay fix:

- Move spent-token state to the SM-DP+ server object, for example
  `self.zk_spent_tokens = set()`.
- During `authenticateClient` in `--zk` mode, reject if
  `authorizationToken.hex()` is already present, and add it only after all
  signature, expiry, and accumulator checks pass.

### 6. Add PCA TLS certificate directory

Create `pysim/smdpp-data/certs/PCA/` mirroring the MNO directory:

- `CERT_PCA_TLS.csr.cnf`
- `CERT_PCA_TLS.ext.cnf`
- `gen_certs.sh`
- generated outputs:
  - `SK_PCA_TLS_NIST.pem`
  - `PK_PCA_TLS_NIST.pem`
  - `CERT_PCA_TLS_NIST.pem`
  - `CERT_PCA_TLS_NIST.der`

The cert subject should be `CN = testpca1.example.com`; SANs must include
`localhost` and `127.0.0.1`. Use the same local-development self-signed model
as the MNO TLS certs.

### 7. Add `lpac profile zk-register`, `zk-certinit`, and `zk-order`

Add separate lpac commands so the implementation mirrors the protocol roles
and the workflow can measure the four rows from the paper table:
Registration, Certificate Initialisation, Order Profile, and Profile Download.

`lpac profile zk-register` drives only Algorithm 2 / RegisterAndIssue:

Suggested CLI:

```bash
lpac profile zk-register -n localhost:4443
```

It performs:

1. POST `registerChallenge` to the MNO.
2. Send BF44 `ZkRegisterChallengeRequest` to the eUICC.
3. POST `registerCredential` to the MNO.
4. Send BF45 `ZkRegisterCredentialRequest` to the eUICC.

`lpac profile zk-certinit` drives only Algorithm 3 / CertInit:

```bash
lpac profile zk-certinit -p https://localhost:5443
```

It performs:

1. Generate or accept a 32-byte `sessionKeySeed`.
2. Send BF46 `ZkCertInitRequest` to the eUICC.
3. POST `certInitRequest` to the PCA with `userPublicKey`,
   `bindingSignature`, and `credentialBindingHash`.
4. Send BF47 `ZkCertInstallRequest` to the eUICC with the returned
   `pseudonymCertificate`.

Do not keep Phase 0 APDU construction in `zkesim_workflow.sh`. The workflow
should call these lpac commands; lpac should own ES10 APDUs and HTTP JSON.

`lpac profile zk-order` drives Algorithm 4 and Algorithm 5 up to delivery of
the MNO-issued eligibility bundle:

```bash
lpac profile zk-order -n https://localhost:4443 -s localhost
```

It performs:

1. POST `getMNOChallenge` to the MNO.
2. Send BF42 `ZKProfileRequest` to the eUICC.
3. POST `zkRequest` to the MNO.
4. Send BF43 `SetEligibilityDataRequest` to the eUICC.
5. POST `ack` to the MNO.
6. Print JSON containing `matchingId`, `smdpAddress`, and `iccid`.

The actual GSMA profile download must remain a separate measured step using
`lpac profile download -s <smdpAddress> -m <matchingId>`.

Implementation pieces:

- Add MNO client helpers for:
  - `registerChallenge`
  - `registerCredential`
- Add PCA client helpers for:
  - `certInitRequest`
- Add ES10b helpers shared by the two commands:
  - BF44 `ZkRegisterChallengeRequest`
  - BF45 `ZkRegisterCredentialRequest`
  - BF46 `ZkCertInitRequest`
  - BF47 `ZkCertInstallRequest`
- Add `lpac/src/applet/profile/zk-register.c` for BF44/BF45.
- Add `lpac/src/applet/profile/zk-certinit.c` for BF46/BF47.
- Add `lpac/src/applet/profile/zk-order.c` for BF42/BF43 plus MNO order.
- Wire the commands into the profile command table/build files next to
  `zk-download.c`.

Wire JSON field names should prefer the human-friendly names from the ASN.1
section. Accepting legacy response aliases during the transition is fine, but
new code should emit descriptive names.

### 8. Rebuild `zkesim_workflow.sh` for macOS and Linux

Use the known-good structure from `3f9573a`, then apply the ZK server and
registration flow cleanly. Do not forward-port the current raw-shell Phase 0
driver.

Required portability rules:

- Use `python3 -c "import time; ..."` for millisecond timestamps.
- Use `lsof -iTCP:"$port" -sTCP:LISTEN -t` for port PID detection when
  available.
- If `lsof` is unavailable, fall back to non-mutating readiness checks using
  `ss -tln` on Linux or `netstat -an` on macOS/Linux. Do not depend on
  Linux-only `netstat -p`.
- Use a small Python socket probe for readiness when possible:
  `socket.create_connection((host, port), timeout=0.25)`.
- Use `sysctl -n hw.ncpu` as the macOS fallback when `nproc` is unavailable.
- Avoid `readlink -f`, `timeout`, `date +%s%N`, GNU-only `sed -i`, and
  Bash features unavailable in the system Bash shipped by macOS.
- Track PIDs for SM-DP+, MNO, and PCA separately and clean them in the trap.
- Keep logs in `.zkesim-workflow/logs/`, not the repo root.

Workflow configuration:

```bash
SMDPP_HOST="${SMDPP_HOST:-localhost}"
SMDPP_PORT="${SMDPP_PORT:-443}"
MNO_HOST="${MNO_HOST:-localhost}"
MNO_PORT="${MNO_PORT:-4443}"
PCA_HOST="${PCA_HOST:-localhost}"
PCA_PORT="${PCA_PORT:-5443}"
ZK_DOWNLOAD="${ZK_DOWNLOAD:-0}"
LPAC_BUILD_DIR="${LPAC_BUILD_DIR:-${REPO_ROOT}/lpac/build}"
```

Workflow order:

1. Build lpac.
2. Build and inject the applet profile unless `SKIP_BUILD=1`.
3. Start SM-DP+ without `--zk`.
4. Run the normal bootstrap download against the default ISD-R AID so the
   ZK-eSIM applet is installed/enabled.
5. If `ZK_DOWNLOAD=0`, optionally run the existing applet smoke path and exit.
6. If `ZK_DOWNLOAD=1`:
   - Restart SM-DP+ with `--zk`.
   - Start MNO server on `${MNO_HOST}:${MNO_PORT}`.
   - Start PCA server on `${PCA_HOST}:${PCA_PORT}`.
   - Export `LPAC_CUSTOM_ISD_R_AID="${INSTANCE_AID}"`.
   - Run `lpac profile zk-register -n "${MNO_HOST}:${MNO_PORT}"`.
   - Run `lpac profile zk-certinit -p "${PCA_HOST}:${PCA_PORT}"`.
   - Run `lpac profile zk-order -n "${MNO_HOST}:${MNO_PORT}" -s "${SMDPP_HOST}"`.
   - Unset `LPAC_CUSTOM_ISD_R_AID`.
   - Run `lpac profile download -s "$smdpAddress" -m "$matchingId"`.
   - Keep `LPAC_CUSTOM_ISD_R_AID` set for `zk-register`, `zk-certinit`,
     and `zk-order`, because BF44-BF47 and BF42/BF43 must go to the ZK
     applet AID.

Timing summary:

- Track at least:
  - `T_REGISTER_MS`
  - `T_CERTINIT_MS`
  - `T_ORDER_PROFILE_MS`
  - `T_PROFILE_DOWNLOAD_MS`
- Measure `T_REGISTER_MS` around `lpac profile zk-register`.
- Measure `T_CERTINIT_MS` around `lpac profile zk-certinit`.
- Measure `T_ORDER_PROFILE_MS` around `lpac profile zk-order`.
- Measure `T_PROFILE_DOWNLOAD_MS` around `lpac profile download`.

Delete from the workflow:

- `phase0_apdu`
- `mno_post`
- shell parsers for BF44/BF46
- direct `curl --insecure` Phase 0 calls
- the old ZK ordering that runs `zk-download` before registration
- the co-located MNO defaults (`MNO_HOST=SMDPP_HOST`, `MNO_PORT=SMDPP_PORT`)

### 9. Documentation

Update `AGENT.md` and `ZKESIM_WORKFLOW.md`:

- Document the three role servers and ports.
- Document protocol order and which lpac command drives each phase.
- Mention that `LPAC_CUSTOM_ISD_R_AID` must remain set during
  `zk-register`, `zk-certinit`, and `zk-download`.
- Document macOS/Linux workflow assumptions and dependencies:
  `bash`, `python3`, `cmake`, `lsof` preferred, `openssl`, and a working
  pysim Python environment.

## Files touched

New:

- `pysim/pca-server.py`
- `pysim/smdpp-data/certs/PCA/*`
- `lpac/src/applet/profile/zk-register.c`
- `lpac/src/applet/profile/zk-certinit.c`
- `lpac/src/applet/profile/zk-order.c`
- lpac headers/build-table entries needed by `zk-register`, `zk-certinit`,
  and `zk-order`

Modified:

- `pysim/pySim/esim/asn1/rsp/rsp.asn`
- `pysim/pySim/esim/zk_utils.py`
- `pysim/mno-server.py`
- `pysim/osmo-smdpp.py`
- `lpac/euicc/es10b.*`
- `lpac/euicc/es12p.*` or a new registration-specific client module
- `lpac/src/applet/profile/zk-download.c` only if field names or `-s`
  behavior need compatibility fixes
- `zkesim_workflow.sh`
- `AGENT.md`
- `ZKESIM_WORKFLOW.md`

Avoid applet changes unless integration reveals that the existing BF44-BF47,
BF42/BF43, or BF38 wire shape does not match the ASN.1/protocol definitions.

## Verification

Static checks:

```bash
python3 -c "import pySim.esim.rsp as rsp; \
for t in ['ZkRegisterChallengeRequest','ZkRegisterCredentialRequest', \
'ZkCertInitRequest','ZkCertInstallRequest','ZKProfileRequest', \
'SetEligibilityDataRequest']: assert t in rsp.asn1.types, t; \
print('asn1 ok')"

python3 -c "from pySim.esim.zk_utils import hash_fn, serialize_proof, \
ecdsa_der_to_tr03111, extract_pcert_from_bf, _build_pcert_u; print('utils ok')"

bash -n zkesim_workflow.sh
```

Server smoke checks:

```bash
python3 pysim/mno-server.py --help
python3 pysim/pca-server.py --help
python3 pysim/osmo-smdpp.py --help

grep -nE "registerChallenge|registerCredential|certInitRequest|getMNOChallenge|zkRequest|zkAck|_phase0_sessions|_mno_sessions|FIXED_DEVICE_W|_build_pcert_u" pysim/osmo-smdpp.py
# expected: no matches, except comments only if kept deliberately
```

Build checks:

```bash
cd lpac
cmake -B build -DSTANDALONE_MODE=ON
cmake --build build -j "$(command -v nproc >/dev/null && nproc || sysctl -n hw.ncpu || echo 4)"
```

Workflow portability checks:

```bash
ZK_DOWNLOAD=0 SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh
```

This must run on Linux and macOS without `command not found`, GNU/BSD option
errors, or stale server cleanup failures.

End-to-end checks:

```bash
ZK_DOWNLOAD=0 bash zkesim_workflow.sh
ZK_DOWNLOAD=1 bash zkesim_workflow.sh
```

Expected ZK log signals:

- `mno.log`: `registerChallenge` issued and `registerCredential` signed.
- `pca.log`: `certInitRequest` verified `bindingSignature` and issued
  `PCert_U`.
- `mno.log`: `zkRequest` verified challenge/proof/cert binding, called
  `downloadOrder`/`confirmOrder`, and returned BF43 eligibility data.
- `smdpp.log`: ES2+ orders served; `authenticateClient --zk` verified
  credential signature, root signature, auth token, accumulator inclusion,
  expiry, and one-time token freshness.
- `lpac`: `zk-register` completes, `zk-certinit` installs `PCert_U`,
  `zk-order` stores eligibility data, then
  `zk-download` completes and installs the profile.

Replay checks:

- Reusing the same BF42/MNO requestId must fail at the MNO.
- Reusing the same `authorizationToken` in a second Algorithm 6 session must
  fail at the SM-DP+.

## Assumptions

- The implementation target is protocol-flow completeness for all provided
  algorithms, not production cryptographic fidelity.
- Existing prototype signatures/proofs are acceptable where the applet already
  uses them.
- During the migration, HTTP JSON may accept legacy aliases, but new ASN.1 and
  newly written code should use descriptive field names.
- The PCA signs `PCert_U`; the eUICC stores it, and SM-DP+ verifies the
  resulting credential bundle in `--zk` mode without adding a production PCA
  trust-chain requirement.
