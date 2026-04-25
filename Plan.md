# Implement ZK-eSIM Phase 1 (ZKProfileRequest) and Phase 2 (OrderProfile)

## Context

Phases 3 and 4 (`MutualAuthAndProvision`) are already working end-to-end: the
applet currently pre-signs eligibility data (`hpid`, `sigCred`, `authToken`,
`accRoot`, `sigRoot`) at install time using `FIXED_MNO_PRIVATE_SCALAR`, the
SM-DP+ in `--zk` mode verifies it inside `BF38` AuthenticateClient, and the
profile download completes.

What's missing is the **runtime** Phase 1 (UE↔MNO `ZKProfileRequest`, Alg. 4)
and Phase 2 (MNO↔SM-DP+ `OrderProfile`, Alg. 5). The user wants:

- A new **MNO server** in `pysim/` that talks to lpac and the SM-DP+.
- Phase 1 and Phase 2 to run as real message exchanges, reusing SGP.22 ES2+
  `DownloadOrder` / `ConfirmOrder` (already defined in
  [pysim/pySim/esim/es2p.py:128-192](pysim/pySim/esim/es2p.py#L128-L192),
  but with no server handler).
- **Phase 0** (Registration, CertInit) stays hardcoded (pre-provisioned
  `sk_b`, `r_seed`, `σ_EID`, `PCert_U`, MNO long-term keys).
- **The applet computes the real cryptographic content** of
  `ZKProfileRequest`: `K_pid`, `pid`, `EncEid`, and `π_req` are produced
  on-card from the MNO challenge using existing `Crypto.java`
  primitives. The MNO verifies `π_req` in Python.

### Protocol flow (per Figure 8)

**Phase 1 — ZKProfileRequest (UE ↔ MNO via LPA):**

1. `LPA → MNO`  request MNO challenge
2. `MNO → LPA`  `mnoChallenge = N_S` (+ stored `nonce_MNO ← mnoChallenge`)
3. `LPA → eUICC`  **`ZKProfileRequest`** APDU carrying only the
   ASN.1-encoded `mnoChallenge`. `pk_MNO`, `pk_LEA`, and `mnoid` are
   Phase-0 hardcoded constants inside the applet and are not sent over
   the wire.
4. Inside the eUICC: `K_pid ← KDF(sk_b, mnoChallenge)`,
   `pid ← PRF_{K_pid}(EID)`, `r ←$ {0,1}^λ`,
   `EncEid ← PKE.Enc_{pk_LEA}(EID; r)`,
   `x = (pk_MNO, pk_LEA, pk_U, mnoChallenge, pid, EncEid)`,
   `w = (EID, sk_b, r_seed, σ_EID, r)`, `π_req ← ZK.Prove(x; w)`.
5. `eUICC → LPA`  **`ZKProfileResponse`** carrying `(x, PCert_U, π_req)`.
6. `LPA → MNO`  HTTP POST with `(x, PCert_U, π_req)`.

**Phase 2 — OrderProfile (MNO ↔ SM-DP+, MNO → eUICC):**

7. MNO checks `x.mnoChallenge == stored nonce_MNO`, verifies `PCert_U`
   chain / expiry, parses `pk_U`, runs `ZK.Verify(x, π_req)`.
8. MNO computes `Hpid ← H'(pid)`, `h_cert ← H''(PCert_U)`, aborts if
   `Hpid ∈ L_auth`, stores `Hpid ↔ EncEid`.
9. `MNO → SM-DP+`  ES2+ `DownloadOrder(Hpid, mnoid, profileType)` [RSP*].
10. `SM-DP+ → MNO`  ICCID [RSP*].
11. `MNO → SM-DP+`  ES2+ `ConfirmOrder(ICCID, Hpid, releaseFlag=true)` [RSP*].
12. `SM-DP+`  maps `ICCID ↔ Hpid` [RSP*].
13. MNO: `L_auth ← Acc.add(L_auth, Hpid)`,
    `π_inc ← Acc.prove`, `root_auth ← Acc.digest`,
    `σ^root_MNO ← Sig.sign_{sk_MNO}(root_auth)`,
    `σ_cred ← Sig.sign_{sk_MNO}(Hpid, h_cert, mnoid)`,
    `T_i ← Sig.sign_{sk_MNO}(Hpid, h_cert, mnoid, expiry)`.
14. `MNO → LPA`  **`SetEligibilityDataRequest`** carrying the six
    `EligibilityData` fields
    `(Hpid, σ_cred, T_i, root_auth, σ^root_MNO, π_inc)`; `mnoid` and
    `expiry` are Phase-0 hardcoded on both sides. The HTTP body also
    carries `matchingId` / `smdpAddress` / `iccid` for Phases 3-4
    (outside the TLV).
15. `LPA → eUICC`  forwards the `SetEligibilityDataRequest` APDU.
16. `eUICC → LPA`  **`SetEligibilityDataResponse`** (ok / error).
17. `LPA → MNO`  relays the ack (HTTP response body).

Phase 1 ends after step 6. Phase 2 ends after step 17. Phases 3-4 then run
unchanged against the SM-DP+ using the `matchingId` returned by the MNO.

### User-confirmed design decisions

- New applet APDUs `BF42 ZKProfileRequest/Response` and
  `BF43 SetEligibilityDataRequest/Response` — the LPA is a pass-through
  for both.
- Extend `rsp.asn` in place; follow the existing style (numeric class tags
  `[n]` with a `-- Tag 'BFnn'` comment, `AUTOMATIC TAGS`).
- New lpac command `lpac profile zk-download -m <mno> -d <smdp> -i <matchingId>`
- MNO server runs on a separate HTTPS port with a new self-signed cert under
  `smdpp-data/certs/MNO/`.

---

## Architecture

```
   lpac (UE)                    mno-server.py                 osmo-smdpp.py
 ───────────                   ──────────────                ──────────────
  zk-download                                                (existing --zk)
      │
      │  1)  POST /zk-esim/v1/getMNOChallenge  ──────────▶
      │                                      mnoChallenge, requestId
      │  ◀────────────────────────────────────────────────────
      │
      │  2)  BF42 ZKProfileRequest(mnoChallenge)       ── local APDU
      │      (applet runs KDF / PRF / PKE.Enc / ZK.Prove)
      │      BF42 ZKProfileResponse(x, PCert_U, π_req) ── local APDU
      │
      │  3)  POST /zk-esim/v1/zkRequest                ────▶
      │       { x, PCert_U, π_req, requestId }
      │                                      4) ZK.Verify (ECDSA over
      │                                         ZKStatement DER, pk_U)
      │                                      5) Hpid/h_cert, replay check
      │                                      6) POST /gsma/rsp2/es2plus/downloadOrder
      │                                      ├────────────────────────────────▶
      │                                      │                          ICCID
      │                                      │◀────────────────────────────────
      │                                      7) POST /gsma/rsp2/es2plus/confirmOrder
      │                                      ├────────────────────────────────▶
      │                                      │                    matchingId, smdpAddr
      │                                      │◀────────────────────────────────
      │                                      8) build SetEligibilityDataRequest
      │      ZKProfileResult: base64(BF43 SetEligibilityDataRequest TLV)
      │      + { iccid, matchingId, smdpAddress }
      │  ◀──────────────────────────────────────────────────
      │
      │  9)  BF43 SetEligibilityDataRequest            ── local APDU
      │      (applet overwrites hpidBuf/sigCredBuf/etc.)
      │      BF43 SetEligibilityDataResponse(ok)       ── local APDU
      │
      │  10) POST /zk-esim/v1/ack  { requestId, ok }   ────▶   (optional)
      │
      │  11) Existing Phase 3-4 flow against SM-DP+    ───────────────────▶ osmo-smdpp.py
      │      (already implemented — unchanged)
```

Phase 3-4 code paths (both in the applet and in `osmo-smdpp.py`) stay
unchanged. The only APDUs added are `BF42` and `BF43`; the existing
`BF38` emitter now simply reads whatever `hpidBuf / sigCredBuf / ...` were
written by the most recent `BF43`.

---

## Work breakdown

### 1. ASN.1 — extend `rsp.asn` in place

File: [pysim/pySim/esim/asn1/rsp/rsp.asn](pysim/pySim/esim/asn1/rsp/rsp.asn)

Append a new section after `EligibilityData` (after line 300), mimicking
the formatting/commenting style used by `AuthenticateServerRequest` /
`AuthenticateServerResponse` (lines 255-291):

```asn1
-- Definition of data objects for ZK-eSIM Phase 1 ZKProfileRequest ------------
-- Alg. 4 in the ZK-eSIM spec.  The LPA passes the MNO's challenge
-- (N_S) into the eUICC; the eUICC returns the ZK statement x, the
-- pseudonym certificate PCert_U, and the proof π_req.

ZKProfileRequest ::= [66] SEQUENCE { -- Tag 'BF42'
    mnoChallenge Octet16           -- N_S: MNO challenge
    -- pk_MNO, pk_LEA and mnoid are Phase-0 hardcoded in the applet and
    -- do not travel over the wire.
}

ZKProfileResponse ::= [66] CHOICE { -- Tag 'BF42'
    zkProfileResponseOk ZKProfileResponseOk,
    zkProfileResponseError ZKProfileResponseError
}

ZKProfileResponseOk ::= SEQUENCE {
    zkStatement ZKStatement,                          -- x
    pcertU Certificate,                               -- PCert_U
    zkProof [APPLICATION 55] OCTET STRING             -- π_req, tag '5F37'
}

ZKStatement ::= SEQUENCE {
    pkMno        [0] OCTET STRING,    -- pk_MNO
    pkLea        [1] OCTET STRING,    -- pk_LEA
    pkU          [2] OCTET STRING,    -- pk_U (eUICC pubkey)
    mnoChallenge [3] Octet16,         -- N_S
    pid          [4] Octet32,         -- PRF_{K_pid}(EID)
    encEid       [5] OCTET STRING     -- PKE.Enc_{pk_LEA}(EID; r)
}

ZKProfileResponseError ::= SEQUENCE {
    errorCode ZKProfileErrorCode
}

ZKProfileErrorCode ::= INTEGER {
    invalidChallenge(1),
    cryptoError(2),
    undefinedError(127)
}

-- Definition of data objects for ZK-eSIM Phase 2 SetEligibilityData ----------
-- Alg. 5 step 21 (re-direction): the MNO delivers the issued credentials
-- to the eUICC so that the subsequent SGP.22 AuthenticateServer flow can
-- carry them verbatim in BF38.EuiccSigned1.eligibilityData.

SetEligibilityDataRequest ::= [67] SEQUENCE { -- Tag 'BF43'
    eligibilityData EligibilityData     -- reuses the SEQUENCE at line 293
    -- mnoid and expiry are Phase-0 hardcoded constants agreed between
    -- applet and MNO, so they are not carried here.
}

SetEligibilityDataResponse ::= [67] CHOICE { -- Tag 'BF43'
    setEligibilityOk SetEligibilityOk,
    setEligibilityError SetEligibilityErrorCode
}

SetEligibilityOk ::= SEQUENCE {
}

SetEligibilityErrorCode ::= INTEGER {
    invalidFormat(1),
    lengthMismatch(2),
    notAllowed(3),
    undefinedError(127)
}
```

No changes to `EuiccSigned1` or to the existing `EligibilityData` SEQUENCE —
we reuse them as-is.

### 2. Applet — add `BF42` and `BF43` dispatch

Files:
- [ZK-eSIM_applet/src/zk/esim/applet/Asn1.java](ZK-eSIM_applet/src/zk/esim/applet/Asn1.java)
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java)
- [ZK-eSIM_applet/src/zk/esim/applet/Crypto.java](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java)

`Asn1.java` changes (pattern in lines 17-38 + decode switch at ~line 172):
- `TYPE_ZK_PROFILE_REQUEST = 0x42;` / `TAG_BF42 = (short) 0xBF42;`
- `TYPE_SET_ELIGIBILITY_DATA_REQUEST = 0x43;` / `TAG_BF43 = (short) 0xBF43;`
- Extend `decodeRequest` to recognise both tags.

`ZkEsimApplet.java` — extend the dispatch switch near lines 423-435:

- `TYPE_ZK_PROFILE_REQUEST → buildZKProfileResponse()`.
  - Parse the inbound `mnoChallenge` (length 16); reject malformed
    lengths with `BF42 { A1 INT invalidChallenge }`.
  - `pk_MNO`, `pk_LEA`, and `mnoid` are hardcoded constants in the
    applet — added next to `DEFAULT_RANDOM_SEED` at
    [Crypto.java:134-135](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L134-L135)
    as `MNO_PUBLIC_KEY` (65 B), `LEA_PUBLIC_KEY` (65 B), and
    `MNO_ID` (bytes). Derive them once offline from
    `FIXED_MNO_PRIVATE_SCALAR` and a test LEA scalar; both the MNO
    server and the applet use the same constants so no wire exchange
    is needed.
  - **Real `pid` (Alg. 4 step 3)** — surrogate KDF/PRF chain built from
    the SHA-256 primitive already at
    [Crypto.java:205](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L205):
    1. `K_pid = SHA256(sk_b || mnoChallenge)` — 32 bytes.  `sk_b` is a
       new 32-byte persisted constant `SK_B_SEED` initialised once in
       the applet constructor next to `rSeedBuf`
       ([Crypto.java:134-135](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L134-L135));
       this is the "Phase 0 hardcoded" registration seed.
    2. `pid = SHA256(K_pid || EID)` — 32 bytes.
    Implement as
    `Crypto.computePid(mnoChallenge, mcOff, pidOut, pidOutOff)`.
    Reuses `scratchScalar1` for the intermediate `K_pid` to stay
    allocation-free on card.
  - **Real `EncEid` (Alg. 4 step 4)** — ECIES against `pk_LEA`:
    1. Import `pk_LEA` into a transient `ECPublicKey` (same pattern as
       `setSmdpPbPublicKey` at line 738).
    2. Generate an ephemeral keypair; compute
       `shared = ECDH(eSK, pk_LEA)` and `K_enc = SHA256(shared_x)`;
       reuse the ECDH machinery that backs
       `Crypto.deriveSessionKey()` at
       [Crypto.java:325](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L325).
    3. `ct = AES-128-CBC(K_enc[0:16], IV = 0, EID)` — reuse the
       `encryptEid()` pattern at
       [Crypto.java:308](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L308),
       but taking the AES key from the KDF instead of random bytes.
    4. `EncEid = ePK(65 B) || ct(16 B)` — 81 bytes total.
    Implement as
    `Crypto.encryptEidEcies(pkLea, pkLeaOff, encEidOut, encEidOutOff)`.
  - **Real `π_req` (Alg. 4 step 6)** — pragmatic choice: use an ECDSA
    signature by `sk_U` over the canonical DER encoding of the
    `ZKStatement` SEQUENCE.  In the random-oracle model this is a
    signature of knowledge of `sk_U` bound to `x`, which is exactly the
    binding property we need for Phase 1, and (critically) it is
    verifiable on the MNO side using the existing `pk_U` inside
    `PCert_U` with no custom Python crypto — standard
    `ec.ECDSA(hashes.SHA256())` (the same library already used at
    [pysim/osmo-smdpp.py:844-865](pysim/osmo-smdpp.py#L844-L865)).
    Implementation:
    1. Assemble the `ZKStatement` DER via the existing `TlvWriter`
       helpers (same style as the BF38 builder at
       [ZkEsimApplet.java:1627-1710](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L1627-L1710)).
       Fields and tag numbers match the ASN.1 above (implicit `[0]..[5]`).
    2. Sign those bytes with `Crypto.sign()`
       ([Crypto.java:176](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L176)),
       which is `ECDSA-SHA256 { sk_U }` in DER form. This is `π_req`.
    Note: the existing `Crypto.generateZkp()` at
    [Crypto.java:706](ZK-eSIM_applet/src/zk/esim/applet/Crypto.java#L706)
    uses a witness `w = H(SK || EID)` whose commitment `W = w·G` is not
    known to the MNO, so it can't verify it off-card.  We keep
    `generateZkp()` untouched for future use but do not call it here.
  - Assemble the response:
    - `pcertU` = bytes of the applet's self-signed eUICC cert — the
      same DER emitted as `euiccCertificate` in BF38 today
      ([ZkEsimApplet.java:1627-1710](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L1627-L1710)).
    - Emit `BF42 { A0 { 30 …zkStatement, 30 …pcertU, 5F37 …π_req } }`.

- `TYPE_SET_ELIGIBILITY_DATA_REQUEST → buildSetEligibilityDataResponse()`.
  - Parse the inbound `EligibilityData` (same TLV shape the applet
    already encodes at lines 1706-1710: `80` hpid / `81` sigCred /
    `82` authToken / `83` accRoot / `84` sigRoot / `85` accProof).
  - Validate lengths (`32/64/64/32/64/any`) and copy into
    `hpidBuf / sigCredBuf / authTokenBuf / accRootBuf / sigRootBuf`
    (already declared at lines 161-165). Add a new `accProofBuf` field
    if one isn't already present; allocate once in the constructor
    next to the other buffers (lines 225-229).
  - Emit `BF43 { A0 { 30 {} } }` (empty `SetEligibilityOk`) on success;
    `BF43 { A1 <INT> }` on error.

No state is cleared on applet-deselect for either buffer — the host is
expected to call `BF43` shortly before each `BF38`.

New test files:
- `ZK-eSIM_applet/test/ZkEsimAppletZKProfileRequestTest.java`
- `ZK-eSIM_applet/test/ZkEsimAppletSetEligibilityDataTest.java`

covering happy path + malformed TLV + length overruns. They should follow
the same style as the existing `ZkEsimAppletAuthenticateServerTest.java`
and are picked up automatically by the `ant test` glob.

### 3. New MNO server — `pysim/mno-server.py`

Model after [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py) (Klein + Twisted).
Single file.

- Argparse: `--host`, `--port` (default `8443`), `--smdp-url`
  (default `https://testsmdpplus1.example.com:8000`),
  `--data-dir` (default `./mno-data`), `--nossl` for dev.
- Loads `CERT_MNO_TLS_NIST.pem` + `SK_MNO_TLS_NIST.pem` from the new
  `smdpp-data/certs/MNO/` directory (see §6).
- Holds `FIXED_MNO_PRIVATE_SCALAR` — moved from
  [pysim/osmo-smdpp.py:176](pysim/osmo-smdpp.py#L176).  SM-DP+ keeps only
  the pubkey for verification.
- Holds the Phase-0 hardcoded `pk_MNO` (= `sk_MNO.public_key()`) and
  `pk_LEA` for integrity-checking the applet's `ZKStatement` — the MNO
  must reject a request whose `x.pkMno` / `x.pkLea` don't match its own
  copies, otherwise an attacker could coerce the applet into encrypting
  `EncEid` under a pubkey it controls.
- In-memory request store keyed by `requestId` (uuid): tracks the
  issued `mnoChallenge` (`nonce_MNO`), `EncEid`, pending orders, and
  spent tokens. Optional shelve persistence.
- `MerkleAccumulator` reused from
  [pysim/pySim/esim/rsp.py:226](pysim/pySim/esim/rsp.py#L226).  MNO owns
  `L_auth` and `L_spent`.
- ES2+ client — call
  `pySim.esim.es2p.Es2pApiClient(url_prefix=smdp_url,
  func_req_id="mno-test", server_cert_verify=<path>)`
  (see [pysim/pySim/esim/es2p.py:210-249](pysim/pySim/esim/es2p.py#L210-L249)).

Routes:

| Method | Path | Purpose |
|---|---|---|
| POST | `/zk-esim/v1/getMNOChallenge` | Generate 16-byte challenge, return `{mnoChallenge, requestId, expiry}`. Alg. 4 step 2. |
| POST | `/zk-esim/v1/zkRequest`       | Accept `ZKProfileResponseOk` body, drive Phase 2, return a `ZKProfileResult` (see below). Alg. 5. |
| POST | `/zk-esim/v1/ack`             | Record the `SetEligibilityDataResponse` outcome from the LPA (closes the session). Optional for v1. |
| GET  | `/health`                     | Liveness. |

**`zkRequest` handler body (Alg. 5 mapped to code):**

1. Request body JSON: `{requestId, zkProfileResponse_b64}`.
   Base64-decode + `asn1.decode('ZKProfileResponse', ...)`; abort on
   `zkProfileResponseError` or if `requestId` not in store.
2. Extract `x = zkStatement`, `pcertU`, `zkProof`. Check
   `x.mnoChallenge == store[requestId].mnoChallenge`, else 400.
   Also check `x.pkMno == MNO.pk_self_der` and
   `x.pkLea == MNO.pk_lea_der` — the MNO must refuse if the applet's
   statement uses different `pk_MNO` / `pk_LEA` values than the
   Phase-0 constants it shares with the applet.
3. Parse `pcertU` as X.509; extract subject serial number → `EID`;
   load `pk_U` from the cert (`pcertU.public_key()`). Verify chain
   against the Test CI cert via
   [pySim.esim.x509_cert.CertificateSet](pysim/pySim/esim/x509_cert.py).
4. **`ZK.Verify(x, π_req)`** — re-encode `ZKStatement` with
   `asn1.encode('ZKStatement', x)` and verify
   `pk_U.verify(zkProof, zkStatement_der, ec.ECDSA(hashes.SHA256()))`.
   Abort on `InvalidSignature` (Alg. 5 step 9). Same API used today at
   [pysim/osmo-smdpp.py:844-865](pysim/osmo-smdpp.py#L844-L865).
5. `pid = x.pid`; `h_pid = hash_fn(pid)`;
   `h_cert = hash_fn(asn1.encode('Certificate', pcertU))`.
   (`hash_fn` and `serialize_proof` lifted into
   `pySim/esim/zk_utils.py` so both `osmo-smdpp.py` and `mno-server.py`
   import from one place; current definitions live at
   [pysim/osmo-smdpp.py:236-256](pysim/osmo-smdpp.py#L236-L256).)
6. Replay check — abort if `h_pid.hex() in self.L_auth.leaves`.
7. Call `es2p.downloadOrder({eid: b2h(EID), iccid: None, profileType: "ZK_TEST"})`.
8. Call `es2p.confirmOrder({iccid, eid, matchingId, releaseFlag: true})`.
9. Accumulator update: `L_auth.add(h_pid.hex())`,
   `root_auth = L_auth.get_root()`,
   `pi_inc_bytes = serialize_proof(L_auth.generateProof(h_pid.hex()))`.
10. Sign with `sk_MNO` (P-256 ECDSA-SHA256 → DER; convert to TR-03111
    `r||s` to match the applet/osmo-smdpp.py verification path at
    [pysim/osmo-smdpp.py:844-865](pysim/osmo-smdpp.py#L844-L865)):
    - `σ_cred` over `h_pid || h_cert || mnoid`
    - `σ_root` over `root_auth`
    - `authToken` over `h_pid || h_cert || mnoid || expiry`
    Expiry constant = `b"4102444800"` (matches
    [pysim/osmo-smdpp.py:173](pysim/osmo-smdpp.py#L173)).
11. Build `EligibilityData` dict and encode a
    `SetEligibilityDataRequest` TLV via
    `asn1.encode('SetEligibilityDataRequest', ...)`.
12. Reply JSON:

```json
{
  "setEligibilityDataRequest": "<base64 of BF43 TLV>",
  "iccid":       "89049032...",
  "matchingId":  "TS48V1-A-UNIQUE",
  "smdpAddress": "testsmdpplus1.example.com"
}
```

No response ASN.1 wrapper is needed — the TLV is a payload meant to be
forwarded verbatim to the eUICC.

### 4. ES2+ handlers in `osmo-smdpp.py`

File: [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py).  Add handlers just above
`getBoundProfilePackage` (around line 909).  Use the existing
`@app.route + @rsp_api_wrapper` pattern from line 574.

```python
@app.route('/gsma/rsp2/es2plus/downloadOrder', methods=['POST'])
@rsp_api_wrapper
def downloadOrder(self, request, content):
    eid = content.get('eid')
    iccid = content.get('iccid') or self._allocate_zk_iccid(eid)
    self._pending_orders[iccid] = {'eid': eid, 'state': 'ordered',
                                   'profileType': content.get('profileType')}
    return {'header': _ok_header(), 'iccid': iccid}

@app.route('/gsma/rsp2/es2plus/confirmOrder', methods=['POST'])
@rsp_api_wrapper
def confirmOrder(self, request, content):
    iccid = content['iccid']
    order = self._pending_orders.get(iccid)
    if order is None:
        raise ApiError('8.2.6', '3.8', 'Refused')
    matchingId = content.get('matchingId') or self._allocate_matching_id(iccid)
    order['matchingId'] = matchingId; order['state'] = 'confirmed'
    self._ensure_upp_for_matching_id(matchingId)  # symlink test UPP
    return {'header': _ok_header(), 'matchingId': matchingId,
            'smdpAddress': self.server_hostname}

@app.route('/gsma/rsp2/es2plus/releaseProfile', methods=['POST'])
@rsp_api_wrapper
def releaseProfile(self, request, content):
    iccid = content['iccid']
    if iccid in self._pending_orders:
        self._pending_orders[iccid]['state'] = 'released'
    return {'header': _ok_header()}
```

`self._pending_orders` is a dict on `SmDppHttpServer.__init__`.  Allocators:
`_allocate_zk_iccid(eid)` derives an ICCID deterministically from the EID
hash for reproducibility; `_allocate_matching_id` hashes
`(iccid, hpid)` into an alphanumeric token. `_ensure_upp_for_matching_id`
symlinks an existing `smdpp-data/upp/*.der` so the standard
`getBoundProfilePackage` path later finds the UPP.

### 5. Key ownership split

- **MNO server**: sole holder of `FIXED_MNO_PRIVATE_SCALAR`.
- **SM-DP+**: keeps only the derived public key for verification in
  `authenticateClient` (lines 844-865). Remove the `sk_mno` local in
  `setupMNOValues`.
- **Applet**: the existing install-time MNO signing path is left intact
  (still useful for the non-Phase-1/2 test workflow). When `BF43` has
  been invoked, its values overwrite the pre-signed buffers, so
  subsequent `BF38` reflects the MNO-issued credentials.

No new cert provisioning beyond the MNO TLS cert (§6).

### 6. TLS cert for the MNO server

Create `pysim/smdpp-data/certs/MNO/` following the DPtls pattern at
[pysim/smdpp-data/certs/DPtls/](pysim/smdpp-data/certs/DPtls/):
- `SK_MNO_TLS_NIST.pem`, `PK_MNO_TLS_NIST.pem`
- `CERT_MNO_TLS_NIST.pem` + `.der`
- `CERT_MNO_TLS.csr.cnf`, `CERT_MNO_TLS.ext.cnf`

`CN = testmno1.example.com`, SAN includes `localhost`.

Add `pysim/smdpp-data/certs/MNO/gen_certs.sh` so the cert can be rebuilt
in one step.

Configure lpac to trust the MNO cert either via curl's `CURLOPT_CAINFO`
(new `--mno-cacert` flag on `lpac profile zk-download`) or by dropping
the cert into the system trust store in the dev workflow script.

### 7. lpac — `es12p.c` + `zk-download` applet + ES10 helpers

New files:
- `lpac/euicc/es12p.c` + `lpac/euicc/es12p.h` — MNO HTTPS helpers.
- `lpac/src/applet/profile/zk-download.c` — new
  `lpac profile zk-download` subcommand.

Modified:
- `lpac/euicc/es10b.c` + `.h` — add `es10b_zk_profile_request()` and
  `es10b_set_eligibility_data()`.
- `lpac/euicc/CMakeLists.txt`, `lpac/src/applet/profile/CMakeLists.txt`.
- `lpac/src/applet/profile/profile.c` — register `zk-download` the
  same way `download` is registered at
  [lpac/src/applet/profile/download.c:345](lpac/src/applet/profile/download.c#L345).

**`es12p.c` — follow
[lpac/euicc/es9p.c:29-251](lpac/euicc/es9p.c#L29-L251):**

```c
int es12p_get_mno_challenge(struct euicc_ctx *ctx, const char *mno_url,
                            char **out_b64_mno_challenge,
                            char **out_request_id);

int es12p_zk_request(struct euicc_ctx *ctx, const char *mno_url,
                     const char *request_id,
                     const char *b64_zk_profile_response,
                     /* out */ char **out_b64_set_eligibility_req,
                     /* out */ char **out_iccid,
                     /* out */ char **out_matching_id,
                     /* out */ char **out_smdp_address);

int es12p_ack(struct euicc_ctx *ctx, const char *mno_url,
              const char *request_id, bool ok);
```

Each one sets `ctx->http.server_address = mno_url` around the call and
reuses the generic `ctx->http.interface->transmit` callback
(see [lpac/euicc/interface.h:16](lpac/euicc/interface.h#L16)).

**`es10b.c` additions** — plain APDU wrappers (the existing ES10
functions already chunk + reassemble via `interface.c`):

```c
int es10b_zk_profile_request(struct euicc_ctx *ctx,
                             const uint8_t *b64_mno_challenge,
                             /* out */ char **b64_zk_profile_response);

int es10b_set_eligibility_data(struct euicc_ctx *ctx,
                               const uint8_t *set_eligibility_req_der,
                               uint32_t der_len,
                               /* out */ int *result_code);
```

`zk_profile_request` builds a `BF42` TLV on the host (short enough to fit
within `MAX_REASSEMBLED_APDU = 1536`) via the existing `derutil` helpers
in [lpac/euicc/derutil.c](lpac/euicc/derutil.c), sends it, parses the
`BF42` response back into a base64-encoded opaque blob (lpac does not
need to look inside — it just forwards it to the MNO).

`set_eligibility_data` accepts the DER bytes exactly as returned by the
MNO (already a complete `BF43` TLV) and pushes them via `es10x_transmit`,
reading the single-tag response.

**`zk-download.c` flow:**

```c
1. Parse flags: -m mno, -d smdp, -i matchingId[-c cc] [--mno-cacert path]
2. es12p_get_mno_challenge(ctx, mno) -> b64_mno_challenge, request_id
3. es10b_zk_profile_request(ctx, b64_mno_challenge)
       -> b64_zk_profile_response
4. es12p_zk_request(ctx, mno, request_id, b64_zk_profile_response)
       -> b64_set_eligibility_req, iccid, matchingId, smdpAddress
5. Decode b64_set_eligibility_req -> DER bytes
   es10b_set_eligibility_data(ctx, der_bytes, der_len) -> ok
6. [optional] es12p_ack(ctx, mno, request_id, ok)
7. ctx->http.server_address = smdpAddress
   // from here down, verbatim copy of download.c lines 222-325:
   es10b_get_euicc_challenge_and_info(ctx)
   es9p_initiate_authentication(ctx)
   es10b_authenticate_server(ctx, ...)
   es9p_authenticate_client(ctx, ...)
   es10b_prepare_download(ctx, confirmation_code, ...)
   es9p_get_bound_profile_package(ctx, ...)
   es10b_load_bound_profile_package(ctx, ...)
```

Emit `jprint_progress`/`jprint_error` at each step so the host-side
wrapper (workflow scripts) can follow the flow just like it does for the
standard `download`.

---

## Files touched

**New:**
- `pysim/mno-server.py`
- `pysim/pySim/esim/zk_utils.py` (moves `hash_fn`, `serialize_proof`,
  `deserialize_proof`, `ecdsa_tr03111_to_dss` out of `osmo-smdpp.py`)
- `pysim/smdpp-data/certs/MNO/*` (cert material + configs + `gen_certs.sh`)
- `lpac/euicc/es12p.c`, `lpac/euicc/es12p.h`
- `lpac/src/applet/profile/zk-download.c`
- `ZK-eSIM_applet/test/ZkEsimAppletZKProfileRequestTest.java`
- `ZK-eSIM_applet/test/ZkEsimAppletSetEligibilityDataTest.java`

**Modified:**
- `pysim/pySim/esim/asn1/rsp/rsp.asn` — add the eight new types above
- `pysim/osmo-smdpp.py` — ES2+ routes, drop `sk_mno`, import from
  `zk_utils.py`
- `ZK-eSIM_applet/src/zk/esim/applet/Asn1.java` — add `TAG_BF42`,
  `TAG_BF43`, and `TYPE_*` constants + decode branches
- `ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java` — dispatch cases,
  `buildZKProfileResponse()`, `buildSetEligibilityDataResponse()`,
  possibly `accProofBuf` field
- `ZK-eSIM_applet/src/zk/esim/applet/Crypto.java` — add persisted
  constants `SK_B_SEED`, `MNO_PUBLIC_KEY`, `LEA_PUBLIC_KEY`, `MNO_ID`
  (and reuse the existing `FIXED_EXPIRY`); new methods `computePid()`
  and `encryptEidEcies()`
- `lpac/euicc/es10b.c` + `.h` — `es10b_zk_profile_request()`,
  `es10b_set_eligibility_data()`
- `lpac/euicc/CMakeLists.txt`, `lpac/src/applet/profile/CMakeLists.txt`
- `lpac/src/applet/profile/profile.c` — register the new subcommand
- `zkesim_workflow.sh` — add `phase1_start_mno`, switch
  `phase1_download` to `lpac profile zk-download`, add `MNO_*`
  configuration knobs, extend cleanup
- `AGENT.md` — append a `Phase 1/2 MNO server` section under Recent Notes

---

## Verification

End-to-end via the updated workflow script (requires a new applet CAP
install):

```bash
# One-shot: builds applet, installs CAP, starts SM-DP+ and MNO, runs
# lpac profile zk-download, then phase2_test_applet.
bash zkesim_workflow.sh

# Same thing, skipping the CAP rebuild:
SKIP_BUILD=1 bash zkesim_workflow.sh

# Legacy non-ZK download path (regression):
ZK_DOWNLOAD=0 bash zkesim_workflow.sh
```

Manual version (for debugging individual pieces):

```bash
# 1. Regenerate MNO TLS cert (once).
bash pysim/smdpp-data/certs/MNO/gen_certs.sh

# 2. Terminal A — SM-DP+.
cd pysim && python3 osmo-smdpp.py --zk --host 0.0.0.0 --port 443

# 3. Terminal B — MNO.
python3 mno-server.py --host 0.0.0.0 --port 8443 \
    --smdp-url https://testsmdpplus1.example.com:443

# 4. Terminal C — lpac.
lpac profile zk-download \
    -m https://testmno1.example.com:8443 \
    -d https://testsmdpplus1.example.com \
    -i TS48V1-A-UNIQUE \
    --mno-cacert pysim/smdpp-data/certs/MNO/CERT_MNO_TLS_NIST.pem
```

Expected signals:
- **MNO** logs: challenge issued, `ZKProfileResponse` decoded, `ZK.Verify`
  passes (ECDSA over `ZKStatement` DER), `downloadOrder` + `confirmOrder`
  round-trip with SM-DP+, `SetEligibilityDataRequest` TLV returned.
- **SM-DP+** logs: ES2+ `downloadOrder` + `confirmOrder` served; then
  `initiateAuthentication` + `authenticateClient` succeed, passing all
  three MNO signature checks and the accumulator inclusion check at
  [pysim/osmo-smdpp.py:844-875](pysim/osmo-smdpp.py#L844-L875) using the
  values the MNO just issued via BF43.
- **lpac**: completes `zk-download` with `seqNumber` ok and the ICCID
  issued by the MNO during Phase 2.

Unit / integration:
- `ant -f ZK-eSIM_applet/build.xml test` — 10 existing `CryptoTest`s plus
  the two new `*Test` files must pass.
- `python3 -m pytest pysim/tests/` — add a test that boots
  `mno-server.py` + `osmo-smdpp.py` on in-memory reactors (Klein test
  client), POSTs a canned `ZKProfileResponse`, and asserts the response
  shape + ES2+ calls happened. Also a decoder-level test that round-trips
  `ZKProfileRequest`, `ZKProfileResponse`, `SetEligibilityDataRequest`
  through `asn1tools`.

### Workflow script

Modify [zkesim_workflow.sh](zkesim_workflow.sh) so the happy path drives
all four protocol phases (Phase 1-2 via MNO, Phase 3-4 via SM-DP+):

- Add config variables mirroring the SMDPP ones:
  `MNO_HOST` (default `testmno1.example.com`), `MNO_PORT` (default `8443`),
  `MNO_EXTRA_ARGS`, `MNO_CACERT` (default
  `pysim/smdpp-data/certs/MNO/CERT_MNO_TLS_NIST.pem`), `MNO_SKIP=0/1`.
- Generate MNO TLS cert once (call `pysim/smdpp-data/certs/MNO/gen_certs.sh`
  if it exists; otherwise warn + skip).
- Add a `phase1_start_mno` function next to
  `phase1_start_smdpp` — spawns `python3 mno-server.py` with
  `--smdp-url https://${SMDPP_HOST}:${SMDPP_PORT}`, logs to
  `workdir/mno.log`, captures PID in `workdir/mno.pid`. Arrange teardown
  in the existing `cleanup` trap.
- Replace the current `phase1_download` invocation
  (`lpac profile download -s ${SMDPP_HOST} -m ${MATCHING_ID}`) with
  `lpac profile zk-download -m https://${MNO_HOST}:${MNO_PORT}
  -d https://${SMDPP_HOST}:${SMDPP_PORT} --mno-cacert ${MNO_CACERT}`
- Keep `phase2_test_applet` as-is — it still exercises the ES10 flow
  through the applet AID and is useful after the profile is loaded.
- Leave an opt-out: `ZK_DOWNLOAD=0` falls back to the legacy
  `lpac profile download` path so the old workflow is still runnable
  for debugging.

---

## Scope boundaries (what this plan does NOT do)

- Phase 5 Deanonymisation path is not implemented.
- No SM-DP+-side UPP inventory / billing — `downloadOrder` just allocates
  a placeholder ICCID and a symlink to an existing test UPP.
- No OTA re-provisioning of applet MNO pubkey — it stays baked in at
  install time.
- No multi-MNO support.
- `π_req` uses an ECDSA signature of knowledge of `sk_U` bound to `x`,
  not a "zero-knowledge in the cryptographic sense" proof that also
  hides `pk_U`. Since `pk_U` is already revealed by `PCert_U`, this is
  adequate for the current threat model.
- `sk_b` / `r_seed` are persisted constants in the applet
  (Phase 0 hardcoded); no support for re-issuance.
