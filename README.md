# ZK eSIM Workflow and Component Changes

This repository orchestrates a two-stage ZK eSIM prototype across four active
components:

- `ZK-eSIM_applet/` - JavaCard applet, jCardSim tests, CAP/profile builder
- `lpac/` - LPA client with custom ES10 routing and ZK profile commands
- `pysim/` - `osmo-smdpp.py`, MNO server, PCA server, and SAIP tooling
- `OpenEUICC/` - Android LPA app wired to the custom lpac JNI path for
  privileged ZK profile downloads

The main automation entry point is [zkesim_workflow.sh](zkesim_workflow.sh).

## Anonymized Submodules

This repository uses anonymized submodule remotes:

| Path | Anonymized remote | Description |
| --- | --- | --- |
| `ZK-eSIM_applet/` | `https://anonymous.4open.science/r/ZK-eSIM_applet-BB53` | JavaCard ZK-eSIM applet and profile injection tooling |
| `lpac/` | `https://anonymous.4open.science/r/lpac_ZK-B783` | Patched lpac client with custom ES10 routing and ZK profile commands |
| `pysim/` | `https://anonymous.4open.science/r/ZK-eSIM-SMDP-02F2` | SM-DP+, MNO, PCA, and SAIP support code |
| `OpenEUICC/` | `https://anonymous.4open.science/r/OpenEUICC_ZK-3F83` | Android privileged LPA integration using the ZK-enabled lpac JNI layer |

## End-to-End Flow

The current workflow first installs the profile that contains the applet through
the card's normal ISD-R, then talks directly to the applet AID for the ZK
protocol and final profile download.

1. **Setup A: build lpac**
   - Configures and builds `lpac` with CMake.
   - Default build/output directories are under `/tmp/zkesim-workflow-$USER/`.
   - Exports `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` for the installed lpac
     libraries.

2. **Setup B: build applet and create profile**
   - Runs [ZK-eSIM_applet/build_and_inject_profile.sh](ZK-eSIM_applet/build_and_inject_profile.sh).
   - Builds `dist/ZkEsimApplet.cap`.
   - Injects the load package and applet instance into a SAIP profile DER.
   - Copies the generated DER into `pysim/smdpp-data/upp/${MATCHING_ID}.der`.

3. **Prerequisite standard download**
   - Starts `pysim/osmo-smdpp.py` in normal mode.
   - Uses the default ISD-R AID `A0000005591010FFFFFFFF8900000100`.
   - Downloads/enables the profile so the ZK-eSIM applet becomes selectable.

4. **Role-separated ZK phases**
   - Restarts SM-DP+ with `--zk`.
   - Starts `pysim/mno-server.py` and `pysim/pca-server.py`.
   - Sets `LPAC_CUSTOM_ISD_R_AID` to the applet instance AID
     `D07002CA44900101`.
   - Runs:
     - `lpac profile zk-register` for RegisterAndIssue (`BF44` / `BF45`)
     - `lpac profile zk-certinit` for pseudonym certificate issuance (`BF46` / `BF47`)
     - `lpac profile zk-order` for ZKRequest and MNO order/confirm (`BF42` / `BF43`)
     - `lpac profile zk-download` for the final ES9+/ES10 profile download

## Current Applet Surface

`ZkEsimApplet` dispatches ES10 transport APDUs (`STORE DATA`, `INS=E2`) for:

- `BF20` GetEuiccInfo1
- `BF2E` GetEuiccChallenge
- `BF38` AuthenticateServer
- `BF21` PrepareDownload
- `BF36` LoadBoundProfilePackage
- `BF41` CancelSession
- `BF42` ZKProfileRequest
- `BF43` SetEligibilityData
- `BF44` / `BF45` RegisterAndIssue
- `BF46` / `BF47` CertInit

Large outbound responses use proprietary `91xx` response chaining. Hosts should
treat `91xx` like `61xx`: issue `GET RESPONSE (00 C0 00 00 Le)` using `SW2` as
the next length hint. This avoids a real-card T=0 runtime issue seen with `61xx`
on transport CLA `0x81`.

## lpac Changes

- `LPAC_CUSTOM_ISD_R_AID` selects the logical-channel target AID. Leave it unset
  for the prerequisite ISD-R download; set it to `D07002CA44900101` for ZK applet
  phases.
- `LPAC_CUSTOM_ES10X_MSS` overrides the ES10 segment size.
- `LPAC_APDU_DEBUG` and `LPAC_HTTP_DEBUG` enable APDU/HTTP traces.
- `euicc.c` handles both standard `61xx` and proprietary `91xx` response
  chaining.
- Four profile subcommands implement the ZK path:
  `zk-register`, `zk-certinit`, `zk-order`, and `zk-download`.

## pysim Changes

- `osmo-smdpp.py --zk` enables eligibility validation during
  `authenticateClient`.
- In ZK mode, SM-DP+ verifies `euiccSignature1`, validates raw 64-byte MNO
  signatures (`r||s`) over the credential/root/token payloads, checks token
  expiry, verifies the accumulator inclusion proof, and spends each auth token
  once.
- SM-DP+ exposes ES2+ `downloadOrder`, `confirmOrder`, and `releaseProfile`
  routes used by the MNO role.
- `mno-server.py` handles MNO challenge, blind credential issuance, BF42 proof
  verification, ES2+ order/confirm, and BF43 eligibility-data generation.
- `pca-server.py` handles CertInit, verifies the binding signature, and issues
  `PCert_U`.

## Typical Run

```bash
bash zkesim_workflow.sh
```

Useful variants:

```bash
SKIP_BUILD=1 bash zkesim_workflow.sh
SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh
bash zkesim_workflow.sh --standard-download
bash zkesim_workflow.sh --applet-smoke
```

Workflow logs are written to `.zkesim-workflow/logs/` by default.

For the detailed phase-by-phase runbook, see
[ZKESIM_WORKFLOW.md](ZKESIM_WORKFLOW.md).
