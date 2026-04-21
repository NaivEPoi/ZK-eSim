# ZK eSIM Workflow and Component Changes

This repository orchestrates a two-phase ZK eSIM flow across three key components:
- ZK-eSIM_applet (JavaCard applet)
- lpac (LPA client / ES10 transport)
- pysim osmo-smdpp.py (SM-DP+ server)

The automation entry point is [zkesim_workflow.sh](zkesim_workflow.sh).

## End-to-end workflow

### Phase 0: Build lpac
- [zkesim_workflow.sh](zkesim_workflow.sh) configures and builds lpac using CMake.
- It exports LD_LIBRARY_PATH so lpac runtime libraries are found.

### Phase 1a: Build applet and create profile
- Runs [ZK-eSIM_applet/build_and_inject_profile.sh](ZK-eSIM_applet/build_and_inject_profile.sh).
- Builds CAP from ZK-eSIM_applet sources.
- Injects applet load package + applet instance into a SAIP profile DER.
- Installs resulting DER into pysim UPP directory so SM-DP+ can serve it.

### Phase 1b: Start SM-DP+
- Starts [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py).
- Normal mode for standard download in phase 1.
- ZK mode in phase 2 (started with --zk).

### Phase 1c: Standard profile download to eUICC (default ISD-R)
- Uses default ISD-R AID A0000005591010FFFFFFFF8900000100.
- Performs standard SGP.22 profile download via lpac + ES9+.
- Includes card resource diagnostics and optional profile cleanup/reset flow from script.

### Phase 2: ZK applet routing and validation
- Sets LPAC_CUSTOM_ISD_R_AID to the applet instance AID.
- Replays the ES10 message path through ZkEsimApplet:
  - BF2E GetEuiccChallenge
  - BF38 AuthenticateServer
  - BF21 PrepareDownload
  - BF36 LoadBoundProfilePackage
- In this phase, the workflow restarts osmo-smdpp.py in ZK mode.

## What changed in lpac

### 1) Proprietary response chaining support (91xx)
- [lpac/euicc/interface.private.h](lpac/euicc/interface.private.h#L11) adds SW1_LAST_PROP = 0x91.
- [lpac/euicc/euicc.c](lpac/euicc/euicc.c#L36) treats both 61xx and 91xx as "more response data", issuing GET RESPONSE until complete.
- This is needed because the applet uses proprietary 91xx chaining behavior.

### 2) Selectable target AID via env var
- [lpac/src/main.c](lpac/src/main.c#L34) and [lpac/src/main.c](lpac/src/main.c#L77) support LPAC_CUSTOM_ISD_R_AID with default fallback to the standard ISD-R AID.
- This enables switching between:
  - standard ISD-R for normal profile install
  - ZK applet AID for direct applet routing tests

### 3) Custom ES10 segment size and debug hooks
- [lpac/src/main.c](lpac/src/main.c#L38) supports LPAC_CUSTOM_ES10X_MSS.
- [lpac/src/main.c](lpac/src/main.c#L32) and [lpac/docs/ENVVARS.md](lpac/docs/ENVVARS.md#L5) expose APDU/HTTP debug and custom env knobs.

## What changed in SM-DP+ (osmo-smdpp.py)

### 1) ZK mode flag and server wiring
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L1136) adds -z/--zk CLI flag.
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L526) carries zk_mode into server instance.

### 2) ZK-specific BF38 parsing path
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L572) adds _parse_authenticate_server_response_zk.
- It parses AuthenticateServerResponse in a way that avoids strict embedded cert decoding issues and retains euiccSigned1_bin for signature verification.

### 3) Eligibility bundle validation in authenticateClient
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L829) requires eligibilityData in zk mode.
- Enforces token expiry checks using decode_expiry.
- Verifies:
  - sigCred over (hpid, h_cert, mnoid)
  - sigRoot over accumulator root
  - inclusion proof against accumulator root
- Consumes/records authorization token state after validation.

### 4) Session and output extensions in zk mode
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L190) uses setupMNOValues for session initialization.
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py#L731) returns zkAuthTokenExpiry when present.
- In getBoundProfilePackage, zk mode derives BSP session keys from ECDH shared secret instead of static placeholders.

## What is implemented in ZK-eSIM applet

### Command decode and dispatch
- [ZK-eSIM_applet/src/zk/esim/applet/Asn1.java](ZK-eSIM_applet/src/zk/esim/applet/Asn1.java#L18) defines TYPE_GET_EUICC_INFO1_REQUEST for BF20.
- [ZK-eSIM_applet/src/zk/esim/applet/Asn1.java](ZK-eSIM_applet/src/zk/esim/applet/Asn1.java#L141) decodes BF20 requests.
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L253) dispatches BF20/BF2E/BF21/BF36/BF38/BF41 handlers.

### GetEuiccInfo1 (BF20)
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L426) builds BF20 response.
- Returns SVN and CI PKID lists for verification/signing (A9 and AA lists).

### AuthenticateServer response with ZK extension (BF38)
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L570) includes eligibilityData as A5 with fields 80..85:
  - hpid
  - sigCred
  - authToken
  - accRoot
  - sigRoot
  - accProof
- BF38 response includes EuiccSigned1 plus signature in application tag 55.
- Current implementation emits empty placeholder cert sequences after signature.

### Session/state handling and response staging
- Tracks challenge + transaction state for request coherence and cancel/load behaviors.
- Handles APDU segmentation ingest and staged response emission through internal handlers.
- Supports profile installation result generation and session cleanup.

## Key scripts
- [zkesim_workflow.sh](zkesim_workflow.sh): Main end-to-end flow.
- [algtest_workflow.sh](algtest_workflow.sh): Alternate workflow for AlgTest CAP packaging/download and smoke testing.
- [generate_test_values.py](generate_test_values.py): Generates deterministic ZK-related test constants.
- [ZKESIM_WORKFLOW.md](ZKESIM_WORKFLOW.md): Detailed narrative workflow doc.

## Typical run

```bash
bash zkesim_workflow.sh
```

Useful toggles:
- SKIP_BUILD=1 bash zkesim_workflow.sh
- SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh
