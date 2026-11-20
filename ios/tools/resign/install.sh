#!/bin/zsh
# 自動の再署名を、この Mac に入れる（もう一度実行すると入れ直し）。外すときは ./install.sh --remove
set -e
HERE="${0:A:h}"
AGENT="$HOME/Library/LaunchAgents/com.fujiiyuuki.mytime.resign.plist"
DEST="$HOME/Library/Application Support/MyTimeResign"
mkdir -p "$DEST" "$HOME/Library/Logs/MyTime" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
if [[ "${1:-}" == "--remove" ]]; then rm -f "$AGENT"; echo "外しました"; exit 0; fi
cp "$HERE/mytime-resign.sh" "$DEST/mytime-resign.sh"; chmod +x "$DEST/mytime-resign.sh"
sed -e "s#__SCRIPT__#$DEST/mytime-resign.sh#" -e "s#__LOGDIR__#$HOME/Library/Logs/MyTime#g" "$HERE/com.fujiiyuuki.mytime.resign.plist" > "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "入れました：3時間ごとに署名の期限を見て、48時間を切ったら iPhone に入れ直します"
