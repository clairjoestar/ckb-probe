# CKB-Probe Stability Test Report

> **Scope: CKB testnet only**

## 1. Test Summary

| Field | Value |
|-------|-------|
| Start time | 2026-04-20T15:28:01+00:00 |
| End time | 2026-04-22T15:28:10+00:00 |
| Duration | 48h |
| Kernel | 6.8.0-106-generic |
| CKB version | ckb 0.204.0 (e863939 2026-02-12) |
| CPU | Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz (24 cores) |
| RAM | 15964 MB |
| Data points (timeseries) | 16693 |
| Data points (events) | 8642 (from JSON) |

## 2. S-1 through S-4 Verdict

| # | Metric | Criterion | Result |
|---|--------|-----------|--------|
| S-1 | No crash | ckb-probe runs full duration without crash/panic | **PASS** |
| S-2 | Memory stability | RSS growth <= 5 MB (last hour avg - first hour avg) | **PASS** |
| S-3 | No BPF errors | Zero new BPF-related dmesg messages | **FAIL** |
| S-4 | Restart recovery | ckb-probe reattaches after CKB restart within 60s | **PASS** |

<details>
<summary>S-4 Restart Test Details</summary>

```
=== S-4 CKB Restart Test ===
Trigger time: 2026-04-21T15:28:11+00:00
Elapsed: 86409s

Step 1: Sending SIGTERM to CKB (PID 1517688)...
SIGTERM sent at 2026-04-21T15:28:11+00:00
Step 2: Waiting 10s...
CKB stopped at 2026-04-21T15:28:21+00:00
Step 3: Restarting CKB...
New CKB PID: 1110470
Step 4: Waiting for ckb-probe to detect restart (up to 60s)...
Reconnection detected at T+1s

RESULT: PASS - ckb-probe reattached in 1s
Time-to-reconnect: 1s

=== End S-4 Test ===
0a1
> [2830869.249880] systemd[1]: systemd 255.4-1ubuntu8.14 running in system mode (+PAM +AUDIT +SELINUX +APPARMOR +IMA +SMACK +SECCOMP +GCRYPT -GNUTLS +OPENSSL +ACL +BLKID +CURL +ELFUTILS +FIDO2 +IDN2 -IDN +IPTC +KMOD +LIBCRYPTSETUP +LIBFDISK +PCRE2 -PWQUALITY +P11KIT +QRENCODE +TPM2 +BZIP2 +LZ4 +XZ +ZLIB +ZSTD -BPF_FRAMEWORK -XKBCOMMON +UTMP +SYSVINIT default-hierarchy=unified)
```
</details>

## 3. Time-Series Charts

### ckb-probe CPU%
```
probe CPU%

     0.4 |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
     0.2 |                                                            
         |                                  #                         
         |                                ####            ############
         |                              ##############################
         |                              ##############################
         |                              ##############################
         |##  #  ## #       ###### #  # ##############################
     0.0 |############################################################
         +------------------------------------------------------------
```

### ckb-probe RSS (KB)
```
probe RSS (KB)

 21952.0 | ###########################################################
         | ###########################################################
         |############################################################
         |############################################################
         |############################################################
         |############################################################
         |############################################################
 21950.0 |############################################################
         |############################################################
         |############################################################
         |############################################################
         |############################################################
         |############################################################
         |############################################################
 21948.0 |############################################################
         +------------------------------------------------------------
```

### CKB node CPU%
```
CKB CPU%

   178.9 |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
    90.2 |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
         |                                                            
     1.6 |                                      #                     
         +------------------------------------------------------------
```

### CKB Sync Speed (blocks/min)

```
      3364 |                                                            
           |                                                            
           |                                                            
           |                                                            
           |                                                            
      1682 |                                                            
           |                                                            
           |                                                            
           |                                                            
           |                                                            
           |                                                            
         0 |                                      #                     
           +------------------------------------------------------------
```

## 4. Resource Summary

| Metric | Min | Max | Avg | P99 | Budget | Verdict |
|--------|-----|-----|-----|-----|--------|---------|
| Probe CPU% | 0.00 | 0.38 | 0.09 | 0.29 | - | - |
| Probe RSS (MB) | 21.4 | 21.4 | 21.4 | 21.4 | 100 | PASS |
| CKB CPU% | 1.55 | 178.94 | 2.96 | 4.95 | - | - |
| CKB RSS (MB) | 378 | 756 | 646 | 747 | - | - |

## 5. Event Fidelity Report

### Per-Operation Event Counts

| Operation | Total Samples | Avg QPS | Avg Latency (us) | Avg P99 (us) |
|-----------|--------------|---------|------------------|--------------|
| GET | 8642 | 66.0 | 178.6 | 4306.3 |
| PUT | 8642 | 3.4 | 3.8 | 18.5 |
| WRITE | 8642 | 0.0 | 27.4 | 28.2 |
| ITER_NEW | 8642 | 0.3 | 56.4 | 294.3 |
| TXN_COMMIT | 8642 | 0.2 | 544.4 | 1771.6 |

### BPF Event Loss

| Metric | Value |
|--------|-------|
| Total events attempted | 126934 |
| Events lost | 0 |
| Loss rate | 0.0000% |

### CKB Sync Speed

| Metric | Value |
|--------|-------|
| Samples | 1401 |
| Start height | 20830114 |
| End height | 20840832 |
| Total blocks synced | 10718 |
| Avg blocks/min | 7.4 |
| Max blocks/min | 3363.9 |
| Min blocks/min | 0.0 |

## 6. Latency Distribution Histograms

Latency is binned into log2 buckets (powers of 2 in microseconds).

### GET

```
  (from ckb-probe --histogram, last snapshot)

  GET latency distribution:
          2s |######                                      232
          4s |########################################   1528
          8s |###########                                 421
         16s |###################                         727
         32s |###                                         125
         65s |                                             22
        131s |                                              1
        262s |                                              6
         1ms |                                              2
         2ms |                                              6
         4ms |                                             28
         8ms |                                             36
        16ms |                                              2
```

### PUT

```
  (from ckb-probe --histogram, last snapshot)

  PUT latency distribution:
          4s |########################################     51
          8s |########                                     11
         16s |####                                          6
```

### WRITE

```
  (from ckb-probe --histogram, last snapshot)

  WRITE latency distribution:
         32s |########################################      3
```

### ITER_NEW

```
  (from ckb-probe --histogram, last snapshot)

  ITER_NEW latency distribution:
         16s |########################################      9
         32s |#############                                 3
```

### TXN_COMMIT

```
  (from ckb-probe --histogram, last snapshot)

  TXN_COMMIT latency distribution:
         65s |##############################                3
        131s |########################################      4
        262s |####################                          2
```

## 7. Case Study 1 -- IBD Write Pattern

First 2 hours of data (potential IBD phase, from probe JSON):

| Time Window | Op | Avg QPS | Avg Latency (us) | Avg P99 (us) |
|-------------|-----|---------|------------------|--------------|
| 0-2h | PUT | 3.1 | 6.4 | 39.0 |
| 0-2h | WRITE | 0.0 | 45.7 | 47.2 |
| 0-2h | GET | 108.1 | 370.5 | 11614.5 |
| 0-2h | ITER_NEW | 0.1 | 512.5 | 3038.9 |
| 0-2h | TXN_COMMIT | 0.0 | 4355.4 | 14014.1 |

### Slow Events Summary

Captured by ckb-probe `--slow --threshold 1000us` running in parallel.

| Metric | Value |
|--------|-------|
| Total slow operations | 69120 |
|   BPF event loss: 0 / 126934 attempted  (0.0000%) |

| Operation | Count |
|-----------|-------|
| GET | 68014 |
| PUT | 6 |
| WRITE | 0
0 |
| ITER_NEW | 203 |
| TXN_COMMIT | 897 |


## 8. Case Study 2 -- Compaction / Anomaly Spikes

Detected **13411** anomaly events in probe output.

Sample anomaly events:

```
  [15:33:03] ITER_NEW: avg=1540.83us (baseline=666.53us, 2.31x) p99=25165.82us trigger=P99+CAP
  [15:33:03] TXN_COMMIT: avg=24250.45us (baseline=15615.26us, 1.55x) p99=201326.59us trigger=CAP
  [15:33:13] ITER_NEW: avg=1426.76us (baseline=666.53us, 2.14x) p99=25165.82us trigger=P99+CAP
  [15:33:13] TXN_COMMIT: avg=22767.23us (baseline=15615.26us, 1.46x) p99=201326.59us trigger=CAP
  [15:33:23] ITER_NEW: avg=1208.45us (baseline=666.53us, 1.81x) p99=25165.82us trigger=P99+CAP
  [15:33:23] TXN_COMMIT: avg=22186.88us (baseline=15615.26us, 1.42x) p99=201326.59us trigger=CAP
  [15:33:33] ITER_NEW: avg=1440.73us (baseline=666.53us, 2.16x) p99=25165.82us trigger=P99+CAP
  [15:33:33] TXN_COMMIT: avg=22421.72us (baseline=15615.26us, 1.44x) p99=201326.59us trigger=CAP
  [15:33:43] GET: avg=1751.38us (baseline=490.49us, 3.57x) p99=50331.65us trigger=P99+CAP
  [15:33:43] ITER_NEW: avg=1262.08us (baseline=666.53us, 1.89x) p99=25165.82us trigger=P99+CAP
```

## 9. Reproduction Instructions

To reproduce this stability test:

```bash
# System requirements
# Kernel: 6.8.0-106-generic
# CPU:    Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz (24 cores)
# RAM:    15964 MB
# CKB:   ckb 0.204.0 (e863939 2026-02-12) (testnet only)

# 1. Start CKB testnet node
cd /root && ./ckb run &

# 2. Run stability test
cd /root/ckb-probe
DURATION_HOURS=48h \
SAMPLE_SECS=10 \
  bash scripts/stability/stability-48h.sh

# 3. Generate report
bash scripts/stability/generate-report.sh /path/to/stability-<timestamp>/
```

---
*Generated by generate-report.sh on 2026-04-22T15:50:46+00:00*
