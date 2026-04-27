# ZK-eSIM End-to-End Workflow

This document describes the current runnable workflow for building the ZK-eSIM
JavaCard applet, packaging it into an eSIM profile, downloading that profile to
a physical eUICC, and running the role-separated ZK protocol through lpac,
SM-DP+, MNO, and PCA services.

## Overview

```text
Setup
  lpac CMake build
  ZK-eSIM CAP build
  SAIP profile injection

Prerequisite install, default ISD-R
  osmo-smdpp.py
      ^
      | ES9+
    lpac  --ES10-->  eUICC ISD-R
                     installs profile containing ZkEsimApplet

ZK path, applet AID
  lpac profile zk-register  <->  MNO  <->  ZkEsimApplet BF44/BF45
  lpac profile zk-certinit  <->  PCA  <->  ZkEsimApplet BF46/BF47
  lpac profile zk-order     <->  MNO  <->  ZkEsimApplet BF42/BF43
  lpac profile zk-download  <->  SM-DP+ --zk / ZkEsimApplet ES10
```

The prerequisite download must use the default ISD-R AID. The ZK phases then set
`LPAC_CUSTOM_ISD_R_AID` to the applet instance AID:

```text
Default ISD-R:  A0000005591010FFFFFFFF8900000100
ZK applet AID: D07002CA44900101
```

## Prerequisites

| Requirement | Notes |
|---|---|
| Java 17+ | Used by Ant and the JavaCard build |
| Apache Ant | Runs applet tests and CAP build |
| Python 3 + pysim environment | Activate the intended environment before running the workflow |
| CMake + compiler | Builds lpac |
| OpenSSL | Certificate and TLS helpers |
| `curl` | Required by the workflow and lpac HTTP backend |
| `lsof` | Preferred for port checks; script has `ss`/`netstat` fallbacks |
| pcscd + pcsc-lite | Required for physical eUICC access |
| Git submodules | `git submodule update --init --recursive` |

TLS files for SM-DP+ are expected under:

```text
pysim/smdpp-data/certs/DPtls/CERT_S_SM_DP_TLS_NIST.der
pysim/smdpp-data/certs/DPtls/CERT_S_SM_DP_TLS_NIST.pem
pysim/smdpp-data/certs/DPtls/SK_S_SM_DP_TLS_NIST.pem
```

For local non-TLS development, run the workflow with an alternate port and
`SMDPP_EXTRA_ARGS="-s"`.

## Quick Start

```bash
# Full workflow: build, prerequisite install, ZK register/cert/order/download
bash zkesim_workflow.sh

# Reuse existing workflow build artifacts and profile
SKIP_BUILD=1 bash zkesim_workflow.sh

# Skip prerequisite normal install when the applet profile is already installed
SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh

# Only run the standard profile install path, not the ZK phases
bash zkesim_workflow.sh --standard-download

# Run the optional legacy applet smoke download after the main workflow
bash zkesim_workflow.sh --applet-smoke
```

Default logs:

```text
.zkesim-workflow/logs/smdpp.log
.zkesim-workflow/logs/mno.log
.zkesim-workflow/logs/pca.log
.zkesim-workflow/logs/zk-lpac.log.phase*
```

## Setup A - Build lpac

The workflow builds lpac out of tree and installs it into a workflow directory:

```text
LPAC_BUILD_DIR  default: /tmp/zkesim-workflow-$USER/lpac-build
LPAC_OUTPUT_DIR default: /tmp/zkesim-workflow-$USER/lpac-output
LPAC_BIN        default: /tmp/zkesim-workflow-$USER/lpac-output/executables/lpac
```

Manual equivalent:

```bash
WORKFLOW_DIR="${TMPDIR:-/tmp}/zkesim-workflow-${USER:-$(id -u)}"
LPAC_BUILD_DIR="$WORKFLOW_DIR/lpac-build"
LPAC_OUTPUT_DIR="$WORKFLOW_DIR/lpac-output"

cmake -S lpac -B "$LPAC_BUILD_DIR" -DSTANDALONE_MODE=ON
cmake --build "$LPAC_BUILD_DIR" -j "$(nproc 2>/dev/null || printf 4)"
DESTDIR="$LPAC_OUTPUT_DIR" cmake --install "$LPAC_BUILD_DIR"
```

The script exports `LD_LIBRARY_PATH` and `DYLD_LIBRARY_PATH` so this installed
binary can find the built libraries.

## Setup B - Build Applet and Create Profile

The workflow calls `ZK-eSIM_applet/build_and_inject_profile.sh` with
`INSTALL_TO_SMDPP_UPP=1`.

Manual equivalent:

```bash
cd ZK-eSIM_applet

MATCHING_ID=zkesimTest \
LOAD_PACKAGE_AID=D07002CA44 \
CLASS_AID=D07002CA44900101 \
INSTANCE_AID=D07002CA44900101 \
PYSIM_ROOT=../pysim \
INSTALL_TO_SMDPP_UPP=1 \
  bash build_and_inject_profile.sh
```

Expected outputs:

```text
ZK-eSIM_applet/dist/ZkEsimApplet.cap
ZK-eSIM_applet/output/zkesimTest.der
pysim/smdpp-data/upp/zkesimTest.der
```

## Prerequisite Standard Download

The applet lives inside the profile generated above, so the workflow first
downloads that profile through the eUICC's normal ISD-R. Do not set
`LPAC_CUSTOM_ISD_R_AID` for this step.

Manual equivalent:

```bash
unset LPAC_CUSTOM_ISD_R_AID
export LPAC_APDU=pcsc
export LPAC_HTTP=curl

python3 pysim/osmo-smdpp.py -H testsmdpplus1.example.com -p 443 -v

"$LPAC_BIN" profile download \
  -s testsmdpplus1.example.com \
  -m zkesimTest

"$LPAC_BIN" profile list
```

The script also does a best-effort memory reset/purge, removes existing
profiles, prints `EUICCInfo2.extCardResource` diagnostics, and enables the
newly downloaded profile if it is disabled.

## ZK Runtime Path

After the prerequisite profile is installed, the workflow restarts SM-DP+ in ZK
mode and starts the MNO/PCA role servers:

```bash
python3 pysim/osmo-smdpp.py -H testsmdpplus1.example.com -p 443 -v --zk
python3 pysim/mno-server.py --host localhost --port 4443 --smdp-url https://testsmdpplus1.example.com:443
python3 pysim/pca-server.py --host localhost --port 5443
```

Then lpac targets the applet AID:

```bash
export LPAC_APDU=pcsc
export LPAC_HTTP=curl
export LPAC_CUSTOM_ISD_R_AID=D07002CA44900101
```

### Phase 0 - RegisterAndIssue

```bash
"$LPAC_BIN" profile zk-register -n localhost:4443
```

Flow:

- lpac requests an MNO nonce commitment.
- Applet handles `BF44`, computes the blinded challenge and auth signature.
- MNO verifies the device auth signature and returns a partial blind signature.
- Applet handles `BF45`, unblinds and stores `sigma_EID`.

### Phase 1 - CertInit

```bash
"$LPAC_BIN" profile zk-certinit -p localhost:5443
```

Flow:

- lpac generates a random session seed.
- Applet handles `BF46`, derives `sk_U`, returns `pk_U`, binding signature, and
  `H(sigma_EID)`.
- PCA verifies the binding signature and issues `PCert_U`.
- Applet handles `BF47`, installs `PCert_U`, and activates the session key.

### Phase 2 - Order Profile / ZKRequest

```bash
"$LPAC_BIN" profile zk-order -n localhost:4443 -s testsmdpplus1.example.com
```

Flow:

- MNO returns a profile-order challenge.
- Applet handles `BF42` and emits a ZK profile response containing the statement,
  `PCert_U`, and proof.
- MNO verifies the proof and calls SM-DP+ ES2+ `downloadOrder` and
  `confirmOrder`.
- MNO returns a `BF43` SetEligibilityData request.
- Applet stores the eligibility bundle for later inclusion in BF38.
- lpac prints JSON containing the `matchingId` and `smdpAddress` for Phase 3.

### Phase 3 - ZK Profile Download

```bash
"$LPAC_BIN" profile zk-download \
  -s testsmdpplus1.example.com \
  -m zkesimTest
```

`zk-download` runs the ES9+/ES10 chain through the applet:

- `BF20` / `BF2E` for eUICC info and challenge
- `BF38` AuthenticateServer with `eligibilityData`
- `BF21` PrepareDownload
- `BF36` LoadBoundProfilePackage

In `--zk` mode, SM-DP+ still verifies `euiccSignature1`; it skips only the EUM
chain walk because the prototype uses a self-signed or PCA-issued pseudonym cert.
It validates credential/root/token signatures, token expiry, accumulator
inclusion proof, and token single-use before serving the bound profile package.

### Phase 4 - Verify Profile

```bash
"$LPAC_BIN" profile list
```

The workflow lists profiles through the applet AID and enables a disabled newly
installed profile when present.

## ES10 APDU Transport Notes

lpac delivers DER-encoded ES10 objects via `STORE DATA`:

```text
CLA = 0x80..0x83 or 0xC0..0xCF
INS = 0xE2
P1  = 0x11 for more command segments
P1  = 0x91 for the final command segment
P2  = incrementing block number
```

The applet stages outbound responses in chunks of up to 256 bytes. When more
data remains, it returns proprietary `91xx`; lpac treats both `61xx` and `91xx`
as "more data pending" and sends:

```text
00 C0 00 00 <SW2>
```

`91xx` is intentional for this prototype: on real cards, throwing `61xx` while
responding on transport CLA `0x81` can trigger the runtime's T=0 auto-chaining
path and produce `6F00`.

## Environment Variable Reference

| Variable | Default | Description |
|---|---|---|
| `MATCHING_ID` | `zkesimTest` | Profile matching ID and `.der` filename |
| `LOAD_PACKAGE_AID` | `D07002CA44` | JavaCard load package AID |
| `CLASS_AID` | `D07002CA44900101` | Applet class AID |
| `INSTANCE_AID` | `D07002CA44900101` | Applet instance AID |
| `SMDPP_HOST` / `SMDPP_PORT` | `testsmdpplus1.example.com` / `443` | SM-DP+ address |
| `SMDPP_EXTRA_ARGS` | empty | Extra args passed to `osmo-smdpp.py`, for example `-s` |
| `MNO_HOST` / `MNO_PORT` | `localhost` / `4443` | MNO role address |
| `PCA_HOST` / `PCA_PORT` | `localhost` / `5443` | PCA role address |
| `WORKFLOW_DIR` | `/tmp/zkesim-workflow-$USER` | lpac build/install base |
| `LPAC_BUILD_DIR` | `$WORKFLOW_DIR/lpac-build` | lpac CMake build dir |
| `LPAC_OUTPUT_DIR` | `$WORKFLOW_DIR/lpac-output` | lpac install dir |
| `LPAC_BIN` | `$LPAC_OUTPUT_DIR/executables/lpac` | lpac binary |
| `LPAC_APDU` | `pcsc` | lpac APDU backend |
| `LPAC_HTTP` | `curl` | lpac HTTP backend |
| `LPAC_CUSTOM_ISD_R_AID` | unset | Custom target AID; set only for applet/ZK phases |
| `LPAC_CUSTOM_ES10X_MSS` | lpac default | ES10 max command segment size |
| `LPAC_APDU_DEBUG` | false | Raw APDU logging |
| `LPAC_HTTP_DEBUG` | false | Raw HTTP logging |
| `ZK_APDU_DEBUG` | `1` | Workflow APDU tracing for ZK phases |
| `RUN_APPLET_SMOKE` | `0` | Run optional applet smoke path |
| `SKIP_BUILD` | `0` | Skip lpac and profile build setup |
| `SKIP_DOWNLOAD` | `0` | Skip prerequisite standard profile install |
| `ZK_DOWNLOAD` | `1` | Run role-separated ZK phases |
| `WORKFLOW_LOG_DIR` | `.zkesim-workflow/logs` | Server and lpac phase logs |

## Troubleshooting

### SM-DP+ server won't start

- Port 443 may require privileges or already be in use. Use
  `SMDPP_PORT=8080 SMDPP_EXTRA_ARGS="-s"` for local non-TLS testing.
- Check `.zkesim-workflow/logs/smdpp.log`.
- Ensure the pysim Python environment is active before running the workflow.

### lpac cannot find the eUICC

```bash
sudo systemctl start pcscd
"$LPAC_BIN" driver apdu list
```

Check that the reader is visible and the card is inserted.

### `LPAC_BIN` missing with `SKIP_BUILD=1`

The current default binary lives under `/tmp/zkesim-workflow-$USER/lpac-output`.
Either run without `SKIP_BUILD=1` once, or set `LPAC_BIN` to another built lpac
binary.

### Applet not selectable during ZK phases

- Confirm the prerequisite profile download completed.
- Confirm the profile is enabled.
- Confirm `LPAC_CUSTOM_ISD_R_AID` equals `D07002CA44900101`.
- Use `LPAC_APDU_DEBUG=1` to check whether SELECT reaches the expected AID.

### BF38 / eligibility verification fails

- BF38 eligibility signatures are raw 64-byte `r||s`, not DER signatures.
- `BF38` should contain real DER certificate TLVs for `euiccCertificate` and
  `eumCertificate`.
- SM-DP+ computes `h_cert` over the exact on-wire DER certificate bytes, so a
  stale CAP or rewritten certificate encoding can break verification.

### Response chaining fails

Make sure the host treats `91xx` as a chaining status and issues
`GET RESPONSE`. This support is in the patched lpac path; generic APDU tools may
need manual `00 C0 00 00 <SW2>` commands.

## Component Map

| Component | Path | Role |
|---|---|---|
| JavaCard applet | `ZK-eSIM_applet/` | ES10 applet and ZK protocol state |
| Applet build/inject script | `ZK-eSIM_applet/build_and_inject_profile.sh` | CAP build and SAIP profile generation |
| SAIP tool | `pysim/contrib/saip-tool.py` | Injects CAP into profile DER |
| SM-DP+ | `pysim/osmo-smdpp.py` | ES9+/ES2+ server and ZK eligibility validator |
| MNO role | `pysim/mno-server.py` | Register/order/eligibility role |
| PCA role | `pysim/pca-server.py` | Pseudonym certificate issuer |
| LPA client | `lpac/` | Profile download and ZK commands |
| Workflow script | `zkesim_workflow.sh` | End-to-end runner |
