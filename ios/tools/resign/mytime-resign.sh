#!/bin/zsh
# My Time を iPhone に入れ直して、7日で切れる署名を自動で更新する（Mac の LaunchAgent から3時間ごとに呼ばれる）。
# - 入っている版の署名の期限が48時間より先なら何もしない
# - 近ければ、期限の近い署名ファイルを退けて新しい署名を取り直し、main の最新でビルドして iPhone に入れる
# - iPhone が見つからないときは通知で知らせ、次の回にもう一度ためす
# 記録：~/Library/Logs/MyTime/resign.log
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

REPO="${MYTIME_REPO:-$HOME/MyTime/My-Time}"
DEVICE="${MYTIME_DEVICE:-00008130-001E692914D2001C}"
BUNDLE="com.fujiiyuuki.mytime"
WORK="$HOME/Library/Application Support/MyTimeResign"
SRC="$WORK/src"
DD="$WORK/DerivedData"
LOG_DIR="$HOME/Library/Logs/MyTime"
LOG="$LOG_DIR/resign.log"
STATE="$WORK/last-success"
MARGIN_HOURS="${MYTIME_MARGIN_HOURS:-48}"
mkdir -p "$WORK" "$LOG_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"My Time\" subtitle \"$1\"" >/dev/null 2>&1 || true; }

# 同時に2つ動かない
LOCK="$WORK/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 6時間より古い錠は消す（途中で落ちたとき）
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +360 2>/dev/null)" ]]; then rmdir "$LOCK"; mkdir "$LOCK"; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

expiry_of() { # .app か .mobileprovision の期限（UNIX 秒）
  local f="$1"; [[ -d "$f" ]] && f="$f/embedded.mobileprovision"
  [[ -f "$f" ]] || { print 0; return; }
  local d; d=$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || { print 0; return; }
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null || print 0
}

NOW=$(date +%s)
APP="$DD/Build/Products/Debug-iphoneos/My Time.app"
EXP=$(expiry_of "$APP")
LEFT=$(( (EXP - NOW) / 3600 ))
if [[ "${1:-}" != "--force" && $EXP -gt 0 && $LEFT -gt $MARGIN_HOURS ]]; then
  log "まだ大丈夫（署名の残り ${LEFT} 時間）"
  exit 0
fi
log "入れ直しを始める（署名の残り ${LEFT} 時間）"

# iPhone がつながっているか（ケーブルか、同じ Wi‑Fi）
if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -qE "available|connected"; then
  log "iPhone が見つからない（次の回にもう一度）"
  if (( LEFT < 24 )); then notify "署名の更新を待っています" "iPhone を Mac につなぐか、同じ Wi‑Fi にしてください（残り ${LEFT} 時間）"; fi
  exit 0
fi

# main の最新を作業用の場所へ（作業中の手元の変更とは分ける）
if [[ ! -d "$SRC/.git" ]]; then
  git clone --quiet "$(git -C "$REPO" remote get-url origin)" "$SRC" >> "$LOG" 2>&1 || { log "取得に失敗"; notify "署名の更新に失敗" "ソースを取得できませんでした"; exit 1; }
fi
git -C "$SRC" fetch --quiet origin main >> "$LOG" 2>&1 && git -C "$SRC" checkout --quiet -B main origin/main >> "$LOG" 2>&1 \
  || log "最新の取得に失敗（手元にある版でビルドする）"

# 署名の設定（チームとバンドルID）は手元だけのファイル。作業用の場所へ写す
if [[ -f "$REPO/ios/Config/Local.xcconfig" ]]; then
  cp "$REPO/ios/Config/Local.xcconfig" "$SRC/ios/Config/Local.xcconfig"
else
  log "署名の設定（ios/Config/Local.xcconfig）が見つからない"
  notify "署名の更新に失敗" "署名の設定ファイルが見つかりません"; exit 1
fi

# 期限の近い署名ファイルを退ける（Xcode が新しい7日の署名を取り直す）
BACKUP="$WORK/old-profiles"; mkdir -p "$BACKUP"
MOVED=()
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [[ -d "$dir" ]] || continue
  for f in "$dir"/*.mobileprovision(N); do
    if security cms -D -i "$f" 2>/dev/null | grep -q "$BUNDLE"; then
      e=$(expiry_of "$f")
      if (( (e - NOW) / 3600 <= MARGIN_HOURS )); then mv "$f" "$BACKUP/" && MOVED+=("$dir/${f:t}") && log "古い署名を退けた：${f:t}"; fi
    fi
  done
done

if ! xcodebuild -project "$SRC/ios/MyTime.xcodeproj" -scheme MyTime -destination "id=$DEVICE" \
      -derivedDataPath "$DD" -allowProvisioningUpdates build >> "$LOG" 2>&1; then
  log "ビルドに失敗"
  # 退けた署名を元に戻す（取り直せなかったときに、今の署名でのビルドまでできなくならないように）
  for f in "${MOVED[@]}"; do mv "$BACKUP/${f:t}" "$f" 2>/dev/null && log "署名を元に戻した：${f:t}"; done
  if tail -n 400 "$LOG" | grep -q "No Accounts"; then
    notify "署名を更新できません" "Xcode の設定の「Apple Accounts」で Apple ID にサインインしてください（残り ${LEFT} 時間）"
  else
    notify "署名の更新に失敗" "ビルドできませんでした。記録：~/Library/Logs/MyTime/resign.log"
  fi
  exit 1
fi
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  log "インストールに失敗"
  notify "署名の更新に失敗" "iPhone に入れられませんでした（ロックを外してもう一度）"
  exit 1
fi
NEW=$(expiry_of "$APP")
print "$NOW" > "$STATE"
log "入れ直した（新しい署名の期限：$(date -r $NEW '+%m/%d %H:%M')）"
notify "署名を更新しました" "次の期限：$(date -r $NEW '+%m月%d日 %H:%M')"
