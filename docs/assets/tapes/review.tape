# Run from an empty directory: REPO=<iter.nvim> BLACK_ATOM=<black-atom/adapters/nvim> vhs "$REPO/docs/assets/tapes/review.tape"
# Then overlay frames/frame-text-* with frames/frame-cursor-*, pad 40px with the background, and encode:
# magick -delay 1x50 -loop 0 'composed/f*.png' -define webp:lossless=true -define webp:method=4 review.webp
Output frames/
Set Shell bash
Set FontFamily "TX-02, FiraCode Nerd Font Mono"
Set LineHeight 1.15
Set Theme {"name":"Black Atom Minium Sienna Light","background":"#ece3da","foreground":"#3d393a","selection":"#d2c9c1","cursor":"#ff7b26","black":"#585455","red":"#f14d4c","green":"#819e00","yellow":"#cd7b00","blue":"#00a3e9","magenta":"#a49c9a","cyan":"#c4bcb9","white":"#c4bcb9","brightBlack":"#676261","brightRed":"#f14d4c","brightGreen":"#819e00","brightYellow":"#cd7b00","brightBlue":"#00a3e9","brightMagenta":"#a49c9a","brightCyan":"#c4bcb9","brightWhite":"#c4bcb9"}
Set FontSize 18
Set Width 1600
Set Height 1000
Set Padding 0
Set Framerate 50
Set TypingSpeed 80ms

Hide
Type@1ms 'export PS1="$ " XDG_CONFIG_HOME=$PWD/xdg/config XDG_DATA_HOME=$PWD/xdg/data XDG_STATE_HOME=$PWD/xdg/state XDG_CACHE_HOME=$PWD/xdg/cache GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 BLACK_ATOM="$BLACK_ATOM"'
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
