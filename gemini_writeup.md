# Fixing MT6789 (Helio G99) Headphone Jack Audio Hiss on GSIs and Custom ROMs: A Technical Case Study

## 1. Executive Summary

On many MediaTek MT6789 (Helio G99) devices utilizing the integrated MT6366 PMIC/audio codec, flashing a Generic System Image (GSI) or any non-stock custom ROM introduces severe background hiss (noise floor) and low-volume audio distortion through the 3.5mm analog headphone jack. This document details the step-by-step diagnostic process that successfully traced the problem from userspace system libraries to hardware power-gating, culminating in the creation of a zero-overhead, event-driven Magisk module that restores factory-calibrated, crystal-clear analog audio.

## 2. The Diagnosis: Digital vs. Analog Gain Staging

Initially, it was assumed that non-stock ROMs lacked userspace audio components from the stock firmware (such as MediaTek's `system_ext` libraries, its `bessound` DSP effects engine, or specialized XML configs). However, systematic static file diffing, runtime `logcat` analysis, and a critical physical diagnostic test disproved this:

-   **The** $15\text{ dB}$ **Gain Test:** System volume was raised significantly while the source track's software gain was cut by $15\text{ dB}$ (keeping perceived output loudness constant). The persistent background hiss and distortion remained completely unchanged.
    
-   **The Verdict:** If the hiss were a digital resolution or quantization curve scaling issue, raising the OS volume slider would have pushed the signal away from the bottom of the digital curve, attenuating the hiss. Because it remained constant, the noise was proved to be an **analog noise floor issue** in the hardware amplifier stage. The headphone amplifier was running wide open ("hot") because it lacked the calibrated analog attenuation command.
    

## 3. Pinpointing the Register: `Headset Volume`



By comparing active hardware registers using `tinymix` between the stock ROM and a GSI/custom ROM while actively playing audio, a singular hardware difference was uncovered:


| Partition | Control ID | Control Type | Parameter Name | Value | Description |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Non-Stock (GSI/ROM)** | 284 | `INT 2` | `Headset Volume` | `0 0` | Hardware default (uncalibrated, raw high-gain state) |
| **Stock** | 284 | `INT 2` | `Headset Volume` | `9 9` | Calibrated midpoint (0 dB reference, clean noise floor) |

Every other hardware control (digital PGA volumes, ADDA dynamic gain controls, and DC offsets) was byte-identical. Custom ROMs completely fail to set the analog stage's post-DAC volume register, leaving it sitting at a power-on default of `0 0` (uncalibrated and noisy).

## 4. The Obstacle: Audio Codec Power-Gating

Writing `tinymix "Headset Volume" 9 9` while the phone was idle resulted in the setting being silently dropped. Further testing revealed that:

1.  The physical analog audio rail is **power-gated** (shut down) by the MT6366 kernel driver when no audio is playing to preserve battery.
    
2.  When an audio stream initializes, the hardware spins up and applies its power-on driver default, resetting the register back to `0 0`.
    
3.  The register can **only** be modified while the analog output stage is actively powered and driving audio. If you pause music for more than a couple of seconds, the amp falls asleep, and resuming resets the register back to `0 0` (and the hiss returns).
    

## 5. Script Evolution & Engineering Solutions

### Attempt 1: Constant Polling (Discarded)

A script that polled `tinymix "Headphone Plugged In"` every 1 second was proposed. This was discarded because:

-   It introduced up to 1 second of hiss upon resuming a track before correcting.
    
-   It woke the CPU continuously from deep sleep, causing parasitic battery drain.
    

### Attempt 2: GNU Grep Pipelines (Failed)

```
logcat -s AudioALSAStreamManager | grep --line-buffered "+createPlaybackHandler" ...

```

This failed immediately on Android for two distinct reasons:

1.  Android utilizes **Toybox**, not GNU utilities. The `--line-buffered` flag is an unknown option to Toybox `grep` and silently killed the process.
    
2.  Chaining pipes together when outputting to a non-TTY forces the Linux kernel into **4KB block-buffering**. Logcat lines were trapped in RAM buffering, causing the script to lag and never execute in real time.
    

### Attempt 3: The Optimized, Event-Driven Solution (Success)

By parsing `logcat` directly through the shell's built-in `case` string matching, the pipeline buffer was bypassed entirely. The script monitors for the exact millisecond the MediaTek HAL prints `+createPlaybackHandler` for a headphone jack device mask (`output_devices = 0x8`), then fires a fast, bounded verification-and-retry sequence to lock in the hardware gain state.

## 6. The Production-Ready Daemon (`service.sh`)

This optimized script acts as a highly efficient background data pipe. It relies entirely on standard shell pattern matching (which incurs zero process-forking overhead) and implements a self-healing restart supervisor.

```
#!/system/bin/sh
TARGET="9 9"
CTRL="Headset Volume"

until logcat -g >/dev/null 2>&1; do
    sleep 0.5
done

apply_fix() {
    usleep 50000
    i=0
    while [ "$i" -lt 5 ]; do
        current=$(tinymix "$CTRL" 2>/dev/null | tail -1)
        case "$current" in
            *"$TARGET"*) return 0 ;;
        esac
        tinymix "$CTRL" $TARGET 2>/dev/null
        usleep 100000
        i=$((i + 1))
    done
}

watch_loop() {
    logcat -v brief AudioALSAStreamManager:D *:S | while read -r line; do
        case "$line" in
            *"+createPlaybackHandler"*"output_devices = 0x8"*)
                apply_fix
                ;;
        esac
    done
}

(
    while true; do
        watch_loop
        sleep 1
    done
) &

```

## 7. Magisk Module Structure

To deploy this fix permanently, package it into a flashable ZIP file with the following layout:

```
mtk_analog_audio_fix.zip
├── module.prop
└── service.sh

```

### `module.prop`

```
id=mtk_analog_audio_fix
name=MTK Analog Audio Fix
version=v1.0
versionCode=1
author=invalidsudo
description=Eliminates headphone jack hiss and distortion on MediaTek G99 devices (and likely others) running non-stock ROMs/GSIs. Dynamically restores calibrated stock analog gain settings via event-driven tinymix triggers.

```

Ensure `service.sh` has executable permissions (`chmod +x service.sh`) before zipping:

```
zip -r ../mtk_analog_audio_fix.zip ./*

```

## 8. Key Engineering Lessons

1.  **Gain Staging Over Digital Volume:** Always inspect the actual analog register values before assuming an open-source ROM's audio engine is "missing" files. A mismatched analog output gain is far more detrimental to IEMs than digital DSP alterations.
    
2.  **Android Shell Limitations:** Do not use GNU-specific flags (`--line-buffered`) in Android scripts due to Toybox limitations, and bypass multi-hop piping to prevent kernel-level 4KB block-buffering.
    
3.  **The Unquoted Variable Trick:** Leaving `$TARGET` unquoted (`tinymix "$CTRL" $TARGET`) is a valid and useful pattern when you specifically want the shell's native word-splitting to separate space-delimited options into distinct command-line arguments.
