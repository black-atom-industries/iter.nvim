# Run from an empty directory: REPO=<iter.nvim> vhs "$REPO/docs/assets/tapes/review.tape"
# Then overlay frames/frame-text-* with frames/frame-cursor-*, pad 40px with the background, and encode:
# magick -delay 1x50 -loop 0 'composed/f*.png' -define webp:lossless=true -define webp:method=4 review.webp
Output frames/
Set Shell bash
Set FontFamily "FiraCode Nerd Font Mono"
Set FontSize 18
Set Width 1400
Set Height 800
Set Padding 0
Set Framerate 50
Set TypingSpeed 80ms

Hide
Type@1ms 'export PS1="$ " XDG_CONFIG_HOME=$PWD/xdg/config XDG_DATA_HOME=$PWD/xdg/data XDG_STATE_HOME=$PWD/xdg/state XDG_CACHE_HOME=$PWD/xdg/cache GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1'
Enter
Type@1ms '"$REPO/docs/assets/tapes/demo.sh" "$PWD/demo" && cd demo && clear'
Enter
Sleep 500ms
Type@1ms 'nvim --clean -u "$REPO/docs/assets/tapes/init.lua" lua/kettle/init.lua'
Enter
Sleep 1.5s
Show

Sleep 800ms
Type ":Iter review"
Sleep 400ms
Enter
Sleep 1.5s
Type "j"
Sleep 1.2s
Type "k"
Sleep 1s
Enter
Sleep 1s
Type "]c"
Sleep 1s
Type "j"
Sleep 600ms
Type "a"
Sleep 800ms
Type "Notify only once the timer is done?"
Sleep 600ms
Ctrl+S
Sleep 1.5s
Type "r"
Sleep 1.5s
Ctrl+J
Sleep 1s
Type "l"
Sleep 2s
Type "h"
Sleep 600ms
Type "j"
Sleep 1.5s
