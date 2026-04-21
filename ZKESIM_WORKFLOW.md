# ZK-eSIM End-to-End Workflow

This document describes how to compile the ZK-eSIM JavaCard applet, install it inside an eSIM profile, download that profile to a physical eUICC chip, and verify the applet's ZK-proof message flow using lpac.

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
│  Phase 2 — Test Applet (ZK-eSIM Applet AID)                  │
│                                                               │
│   lpac  ──LPAC_CUSTOM_ISD_R_AID──►  ZkEsimApplet             │
│  (ES10 APDUs via STORE DATA 80 E2)                            │
│   BF2E GetEuiccChallenge                                      │
│   BF38 AuthenticateServer  (includes ZK proof)                │
│   BF21 PrepareDownload                                        │
│   BF36 LoadBoundProfilePackage                                │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Java 17 | `/usr/lib/jvm/java-17-openjdk-amd64` on Linux |
| Apache Ant | `sudo apt install ant` |
| Python 3 | `sudo apt install python3` |
| pcscd + pcsc-lite | `sudo apt install pcscd libpcsclite-dev` |
| libcurl | `sudo apt install libcurl4-openssl-dev` |
| lpac built | `cd lpac && cmake -B build && cmake --build build` |
| Git submodules initialised | `git submodule update --init --recursive` |

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

## Phase 2 — Test ZK-eSIM Applet (ZK-eSIM Applet AID)

### Why a different AID

The ZK-eSIM applet (`ZkEsimApplet`) is installed **inside the profile** that was just downloaded. It has its own AID:

```
D07002CA44900101
```

To send ES10 APDUs directly to the applet (rather than to the chip's ISD-R), lpac must open a logical channel to this AID. This is done via the `LPAC_CUSTOM_ISD_R_AID` environment variable.

```
Default ISD-R:  A0000005591010FFFFFFFF8900000100  ← used in Phase 1
ZK-eSIM applet: D07002CA44900101                  ← used in Phase 2
```

### APDU construction by lpac

lpac uses `STORE DATA (CLA=0x80, INS=0xE2)` APDUs to deliver DER-encoded ES10 messages to the selected applet. Large payloads are segmented using P1=`0x11` (continue) or `0x91` (last segment), with P2 as a sequence counter.

```
80 E2 91 00 <Lc> <DER-payload>   ← last segment
```

The applet responds with `61 XX` if more data follows; lpac then issues `GET RESPONSE (00 C0 00 00 Le)` to retrieve the full response.

### ZK-proof in AuthenticateServer (BF38)

The `AuthenticateServer` response from `ZkEsimApplet` includes a Schnorr-style zero-knowledge proof:

- **Commitment** `T = r·G` (random EC point)
- **Response** `s = r + c·w mod n`

This proves the applet holds the witness `w` (derived from the device key + EID) without revealing it.

### Manual steps

```bash
export LPAC_APDU=pcsc
export LPAC_HTTP=curl
export LPAC_CUSTOM_ISD_R_AID=D07002CA44900101   # ← ZK-eSIM applet AID

# Step 1: verify the applet is selectable
./lpac/build/src/lpac chip info

# Step 2: exercise the full ES10 message flow through the applet
./lpac/build/src/lpac profile download \
  -s "testsmdpplus1.example.com" \
  -m "zkesimTest"

# Step 3: list profiles as seen through the applet
./lpac/build/src/lpac profile list
```

lpac internally calls, in order:

| lpac function | APDU tag | Description |
|---|---|---|
| `es10b_get_euicc_challenge` | BF2E | Request 16-byte random challenge |
| `es9p_initiate_authentication` | — | ES9+ HTTP to SM-DP+ |
| `es10b_authenticate_server` | BF38 | Verify server cert; generate ZK proof |
| `es9p_authenticate_client` | — | ES9+ HTTP |
| `es10b_prepare_download` | BF21 | Negotiate session keys |
| `es9p_get_bound_profile_package` | — | ES9+ HTTP — fetch encrypted profile |
| `es10b_load_bound_profile_package` | BF36 | Install profile elements |

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
| `LPAC_APDU` | `pcsc` | 1, 2 | lpac APDU backend |
| `LPAC_HTTP` | `curl` | 1, 2 | lpac HTTP backend |
| `LPAC_CUSTOM_ISD_R_AID` | *(unset = default ISD-R)* | 2 | Override ISD-R AID for applet testing |
| `LPAC_CUSTOM_ES10X_MSS` | `120` | 1, 2 | ES10 max APDU segment size (6–256) |
| `LPAC_APDU_DEBUG` | `false` | 1, 2 | Log raw APDU bytes |
| `LPAC_HTTP_DEBUG` | `false` | 1, 2 | Log raw HTTP traffic |

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
