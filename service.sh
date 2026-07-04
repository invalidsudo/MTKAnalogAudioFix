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
