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
- [pysim/osmo-smdpp.py](pysim/osmo-smdpp.py) adds -z/--zk CLI flag and carries zk_mode into the server instance.

### 2) Chain-skip for self-signed applet certificates
- In zk mode, the SM-DP+ skips EUM/CI certificate-chain validation since the applet emits a self-signed eUICC cert without an EUM issuer.
- The standard SGP.22 euiccSignature1-over-euiccSigned1 verification still runs in both modes.

### 3) ECDH-derived BSP session keys
- In getBoundProfilePackage, zk mode derives BSP session keys (s_enc, s_mac, initial_mcv) from the ECDH shared secret using `bsp_key_derivation`, instead of static placeholders.

## What is implemented in ZK-eSIM applet

### Command decode and dispatch
- [ZK-eSIM_applet/src/zk/esim/applet/Asn1.java](ZK-eSIM_applet/src/zk/esim/applet/Asn1.java#L18) defines TYPE_GET_EUICC_INFO1_REQUEST for BF20.
- [ZK-eSIM_applet/src/zk/esim/applet/Asn1.java](ZK-eSIM_applet/src/zk/esim/applet/Asn1.java#L141) decodes BF20 requests.
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L253) dispatches BF20/BF2E/BF21/BF36/BF38/BF41 handlers.

### GetEuiccInfo1 (BF20)
- [ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java](ZK-eSIM_applet/src/zk/esim/applet/ZkEsimApplet.java#L426) builds BF20 response.
- Returns SVN and CI PKID lists for verification/signing (A9 and AA lists).

### AuthenticateServer (BF38)
- BF38 response is a stock SGP.22 EuiccSigned1 (transactionId / serverAddress / serverChallenge / euiccInfo2 / ctxParams1) plus the application-tag-55 ECDSA signature.
- The applet's self-signed eUICC and EUM certificate slots are emitted after the signature so the standard ASN.1 decoder accepts the response.

### Session/state handling and response staging
- Tracks challenge + transaction state for request coherence and cancel/load behaviors.
- Handles APDU segmentation ingest and staged response emission through internal handlers.
- Supports profile installation result generation and session cleanup.

## Key scripts
- [zkesim_workflow.sh](zkesim_workflow.sh): Main end-to-end flow.
- [algtest_workflow.sh](algtest_workflow.sh): Alternate workflow for AlgTest CAP packaging/download and smoke testing.
- [ZKESIM_WORKFLOW.md](ZKESIM_WORKFLOW.md): Detailed narrative workflow doc.

## Typical run

```bash
bash zkesim_workflow.sh
```

Useful toggles:
- SKIP_BUILD=1 bash zkesim_workflow.sh
- SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh
