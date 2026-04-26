# ZK-eSIM End-to-End Workflow

This document describes how to compile the ZK-eSIM JavaCard applet, install it inside an eSIM profile, download that profile to a physical eUICC chip, and run the role-separated ZK-eSIM protocol with lpac, SM-DP+, MNO, and PCA services.

---

## Overview

```
┌──────────────────────────────────────────────────────────────┐
│  Phase 1 — Install Profile (Default ISD-R AID)               │
│                                                               │
│  JavaCard CAP  ──saip-tool──►  DER profile                   │
│                                    │                          │
│                               osmo-smdpp.py                  │
│                                    │  ES9+ HTTPS              │
│                                 lpac  ◄──────► eUICC         │
│                               (default ISD-R)                 │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  ZK Phases — ZK-eSIM Applet AID                              │
│                                                               │
│   lpac zk-register  ◄──► MNO 4443 ◄──► ZkEsimApplet BF44/45  │
│   lpac zk-certinit  ◄──► PCA 5443 ◄──► ZkEsimApplet BF46/47  │
│   lpac zk-order     ◄──► MNO 4443 ◄──► ZkEsimApplet BF42/43  │
│   lpac zk-download  ◄──► SM-DP+ 443 ◄──► ZkEsimApplet ES10   │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Java 17 | `/usr/lib/jvm/java-17-openjdk-amd64` on Linux |
| Apache Ant | `sudo apt install ant` |
| Python 3 + pysim environment | Activate the project Python environment before running the workflow |
| CMake + compiler | Build lpac on Linux or macOS |
| OpenSSL | Certificate generation and TLS helpers |
| `lsof` | Preferred for portable port checks; workflow has fallbacks |
| pcscd + pcsc-lite | `sudo apt install pcscd libpcsclite-dev` |
| libcurl | `sudo apt install libcurl4-openssl-dev` |
| lpac built | `cd lpac && cmake -B build && cmake --build build` |
| Git submodules initialised | `git submodule update --init --recursive` |

On macOS, install the equivalent tools with Homebrew, for example `bash`,
`python3`, `cmake`, `openssl`, `lsof`, and the PC/SC dependencies required by
your reader.

TLS certificates for osmo-smdpp must be present at:
```
pysim/smdpp-data/certs/DPtls/CERT_S_SM_DP_TLS_NIST.{der,pem}
pysim/smdpp-data/certs/DPtls/SK_S_SM_DP_TLS_NIST.pem
```
(Use `-s` flag on osmo-smdpp.py to disable SSL during local development.)

---

## Quick start

```bash
# Run the full automated workflow
bash zkesim_workflow.sh

# Skip the build step if the CAP + profile already exist
SKIP_BUILD=1 bash zkesim_workflow.sh

# Skip both build and download (applet testing only)
SKIP_BUILD=1 SKIP_DOWNLOAD=1 bash zkesim_workflow.sh
```

---

## Phase 1a — Build Applet & Create eSIM Profile

### What it does

1. Compiles `ZK-eSIM_applet/src/` into a JavaCard CAP file using Ant.
2. Creates a SAIP profile (`.der`) from a base profile template.
3. Injects the CAP as a load package and instantiates the applet inside the profile.
4. Validates the profile structure.
5. Copies the final `.der` to `pysim/smdpp-data/upp/` so osmo-smdpp can serve it.

### Manual steps

```bash
cd ZK-eSIM_applet

# Build CAP + inject into profile + install for osmo-smdpp
MATCHING_ID=zkesimTest \
LOAD_PACKAGE_AID=D07002CA44 \
CLASS_AID=D07002CA44900101 \
INSTANCE_AID=D07002CA44900101 \
PYSIM_ROOT=../pysim \
INSTALL_TO_SMDPP_UPP=1 \
  bash build_and_inject_profile.sh
```

Expected output files:
- `ZK-eSIM_applet/output/zkesimTest.der` — generated profile
- `pysim/smdpp-data/upp/zkesimTest.der` — installed for SM-DP+ lookup

### Key environment variables

| Variable | Default | Description |
|---|---|---|
| `MATCHING_ID` | `zkesimTest` | Profile activation code / filename |
| `LOAD_PACKAGE_AID` | `D07002CA44` | JavaCard package AID (hex) |
| `CLASS_AID` | `D07002CA44900101` | Applet class AID (hex) |
| `INSTANCE_AID` | `D07002CA44900101` | Applet instance AID (hex) |
| `BASE_PROFILE` | `pysim/smdpp-data/upp/TS48V1-A-UNIQUE.der` | Base SAIP profile |
| `PYSIM_ROOT` | `../pysim` (relative to applet dir) | Path to pysim repo |
| `INSTALL_TO_SMDPP_UPP` | `0` | Set to `1` to copy profile to SM-DP+ directory |

---

## Phase 1b — Start the SM-DP+ Server

### What it does

`pysim/osmo-smdpp.py` implements a proof-of-concept SGP.22 SM-DP+ server. It serves the `.der` profile over HTTPS ES9+ endpoints when lpac connects.

### Manual steps

```bash
cd pysim

# With SSL (production-like, requires certs in smdpp-data/certs/)
python3 osmo-smdpp.py -H localhost -p 443 -v

# Without SSL (local development)
python3 osmo-smdpp.py -H localhost -p 8080 -s -v
```

| Flag | Meaning |
|---|---|
| `-H` | Bind host (default: `localhost`) |
| `-p` | Bind port (default: `443`) |
| `-s` | Disable TLS |
| `-v` | Verbose / debug logging |
| `-m` | Ephemeral in-memory session storage |
| `-b` | Use Brainpool curves instead of NIST |

The server resolves download requests by matching the `matchingId` in the request to a file in `smdpp-data/upp/<matchingId>.der`.

---

## Phase 1c — Download Profile to eUICC (Default ISD-R AID)

### Why the default AID

During a standard SGP.22 profile download, lpac opens a logical channel to the **ISD-R** (Issuer Security Domain Root), which manages profile installation. The default ISD-R AID is:

```
A0000005591010FFFFFFFF8900000100
```

This is the standard AID used by all compliant eUICC chips. **Do not override it during profile download.**

### Message flow

```
lpac                        SM-DP+ (osmo-smdpp.py)        eUICC (ISD-R)
  │                               │                             │
  │── ES9+ InitiateAuthentication ──►                          │
  │                               │                             │
  │◄── serverSigned1 + cert ──────│                             │
  │                               │                             │
  │─── ES10b GetEuiccChallenge ─────────────────────────────►  │
  │◄── euiccChallenge (BF2E) ───────────────────────────────── │
  │                               │                             │
  │── ES9+ AuthenticateClient ──►  │                            │
  │      (euiccSigned1 + cert)    │                             │
  │                               │                             │
  │◄── ES9+ GetBoundProfilePackage│                             │
  │                               │                             │
  │─── ES10b PrepareDownload ────────────────────────────────►  │
  │◄── deviceSigned1 (BF21) ────────────────────────────────── │
  │                               │                             │
  │── ES9+ GetBoundProfilePackage ──►                           │
  │◄── boundProfilePackage ───────│                             │
  │                               │                             │
  │─── ES10b LoadBoundProfilePackage ───────────────────────►   │
  │◄── loadResult (BF36) ───────────────────────────────────── │
```

### Manual steps

```bash
# No LPAC_CUSTOM_ISD_R_AID — uses default ISD-R
export LPAC_APDU=pcsc
export LPAC_HTTP=curl

./lpac/build/src/lpac profile download \
  -s "testsmdpplus1.example.com" \
  -m "zkesimTest"

# Verify installation
./lpac/build/src/lpac profile list
```

---

## ZK Phases — Role-Separated Protocol

### Why a different AID

The ZK-eSIM applet (`ZkEsimApplet`) is installed **inside the profile** that was just downloaded. It has its own AID:

```
D07002CA44900101
```

To send ES10 APDUs directly to the applet (rather than to the chip's ISD-R), lpac must open a logical channel to this AID. This is done via the `LPAC_CUSTOM_ISD_R_AID` environment variable.

```
Default ISD-R:  A0000005591010FFFFFFFF8900000100  ← used for prerequisite download
ZK-eSIM applet: D07002CA44900101                  ← used for phases 0-4
```

### APDU construction by lpac

lpac uses `STORE DATA (CLA=0x80, INS=0xE2)` APDUs to deliver DER-encoded ES10 messages to the selected applet. Large payloads are segmented using P1=`0x11` (continue) or `0x91` (last segment), with P2 as a sequence counter.

```
80 E2 91 00 <Lc> <DER-payload>   ← last segment
```

The applet responds with `61 XX` if more data follows; lpac then issues `GET RESPONSE (00 C0 00 00 Le)` to retrieve the full response.

### Role servers

| Role | Script | Default |
|---|---|---|
| SM-DP+ | `pysim/osmo-smdpp.py --zk` | `testsmdpplus1.example.com:443` |
| MNO | `pysim/mno-server.py` | `localhost:4443` |
| PCA | `pysim/pca-server.py` | `localhost:5443` |

### Manual steps

```bash
export LPAC_APDU=pcsc
export LPAC_HTTP=curl
export LPAC_CUSTOM_ISD_R_AID=D07002CA44900101   # ← ZK-eSIM applet AID

# Phase 0: RegisterAndIssue with the MNO
./lpac/build/src/lpac profile zk-register -n localhost:4443

# Phase 1: CertInit with the PCA
./lpac/build/src/lpac profile zk-certinit -p localhost:5443

# Phase 2: ZKRequest + OrderProfile with the MNO
./lpac/build/src/lpac profile zk-order -n localhost:4443

# Phase 3: Profile download with SM-DP+
./lpac/build/src/lpac profile zk-download \
  -s testsmdpplus1.example.com \
  -m zkesimTest

# Phase 4: verify installation
./lpac/build/src/lpac profile list
```

The automated workflow runs these steps after the prerequisite normal profile
download unless `SKIP_DOWNLOAD=1`. Logs are written under
`.zkesim-workflow/logs/` by default.

---

## Environment Variable Reference

| Variable | Default | Phase | Description |
|---|---|---|---|
| `MATCHING_ID` | `zkesimTest` | 1 | Profile matching ID and .der filename |
| `LOAD_PACKAGE_AID` | `D07002CA44` | 1 | JavaCard package AID |
| `CLASS_AID` | `D07002CA44900101` | 1 | Applet class AID |
| `INSTANCE_AID` | `D07002CA44900101` | 1, 2 | Applet instance AID |
| `PYSIM_ROOT` | `../pysim` | 1 | Path to pysim repository |
| `INSTALL_TO_SMDPP_UPP` | `0` | 1 | Copy profile to SM-DP+ UPP directory |
| `SMDPP_HOST` / `SMDPP_PORT` | `testsmdpplus1.example.com` / `443` | all | SM-DP+ role address |
| `MNO_HOST` / `MNO_PORT` | `localhost` / `4443` | 0, 2 | MNO role address |
| `PCA_HOST` / `PCA_PORT` | `localhost` / `5443` | 1 | PCA role address |
| `WORKFLOW_LOG_DIR` | `.zkesim-workflow/logs` | all | Default directory for SM-DP+, MNO, PCA, and lpac logs |
| `LPAC_APDU` | `pcsc` | all | lpac APDU backend |
| `LPAC_HTTP` | `curl` | all | lpac HTTP backend |
| `LPAC_CUSTOM_ISD_R_AID` | *(unset = default ISD-R)* | ZK phases | Override ISD-R AID for applet testing |
| `LPAC_CUSTOM_ES10X_MSS` | `120` | all | ES10 max APDU segment size (6–256) |
| `LPAC_APDU_DEBUG` | `false` | all | Log raw APDU bytes |
| `LPAC_HTTP_DEBUG` | `false` | all | Log raw HTTP traffic |

---

## Troubleshooting

### SM-DP+ server won't start

- **Port 443 in use**: use `SMDPP_PORT=8080` and add `SMDPP_EXTRA_ARGS="-s"` for no-SSL, or run with `sudo`.
- **TLS certificate missing**: check `pysim/smdpp-data/certs/DPtls/` or pass `-s` to disable TLS.
- **Python import errors**: ensure `PYTHONPATH` includes the pysim root or run from within the `pysim/` directory.

### lpac cannot find eUICC

- Confirm `pcscd` is running: `sudo systemctl start pcscd`
- List readers: `sudo ./lpac/build/src/lpac driver apdu list`
- Check the card is inserted and the reader is recognised.

### Profile download fails with "matching ID not found"

- Confirm `pysim/smdpp-data/upp/${MATCHING_ID}.der` exists.
- Check the SM-DP+ server logs for `matchingId` resolution messages.

### Applet not selectable in Phase 2

- Confirm Phase 1 download succeeded and the profile is **enabled**.
- Enable the profile: `sudo LPAC_APDU=pcsc LPAC_HTTP=curl ./lpac/build/src/lpac profile enable <ICCID>`
- Verify `LPAC_CUSTOM_ISD_R_AID` matches the installed instance AID exactly.

### ZK proof verification fails

- Enable APDU debug logging: `LPAC_APDU_DEBUG=true`
- Check `AuthenticateServer` (BF38) response contains both the commitment `T` and response scalar `s`.
- Run unit tests in `ZK-eSIM_applet/test/` with jCardSim for isolated applet testing.

---

## Component Map

| Component | Path | Role |
|---|---|---|
| ZK-eSIM Applet | `ZK-eSIM_applet/` | JavaCard applet with ZK proof logic |
| Build script | `ZK-eSIM_applet/build_and_inject_profile.sh` | Compile CAP + create SAIP profile |
| Profile tool | `pysim/contrib/saip-tool.py` | Inject applet into `.der` profile |
| SM-DP+ server | `pysim/osmo-smdpp.py` | Serve profiles via SGP.22 ES9+ |
| LPA client | `lpac/build/src/lpac` | Download profiles, send ES10 APDUs |
| Base profiles | `pysim/smdpp-data/upp/` | Template `.der` profiles |
| Workflow script | `zkesim_workflow.sh` | Automated end-to-end runner |
