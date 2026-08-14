#!/usr/bin/env bash
# 볼트 마크다운 규칙 검사
# 인라인 코드(`...`)와 코드 블록(```)은 검사 대상에서 제외
set -u
fail=0

# 코드 블록·인라인 코드를 제거한 내용을 파일명:줄번호와 함께 출력
strip_code() {
  find . -name '*.md' -not -path './.git/*' | sort | while read -r f; do
    awk -v fn="$f" '
      /^[[:space:]]*```/ { inblock = !inblock; next }
      inblock { next }
      { gsub(/`[^`]*`/, ""); print fn ":" NR ":" $0 }
    ' "$f"
  done
}

CONTENT=$(strip_code)

# 위키링크 검출
if echo "$CONTENT" | grep -E '\[\[[^]]+\]\]' ; then
  echo "위키링크 발견 — 표준 마크다운 링크로 변경 필요"
  fail=1
fi

# 볼트 절대 경로 링크 검출 (GitHub에서 깨짐)
if echo "$CONTENT" | grep -E '\]\(/[^)]+\.md\)' ; then
  echo "절대 경로 링크 발견 — 상대 경로로 변경 필요"
  fail=1
fi

# 깨진 상대 링크 검출 (링크를 담은 파일의 디렉토리 기준으로 해석)
while IFS=$'\t' read -r fn p; do
  [ -z "$p" ] && continue
  [ -f "$(dirname "$fn")/$p" ] || { echo "깨진 링크: $fn → $p"; fail=1; }
done < <(echo "$CONTENT" | awk '{
    fn = $0; sub(/:.*/, "", fn)
    s = $0
    while (match(s, /\]\([^):]+\.md\)/)) {
      print fn "\t" substr(s, RSTART + 2, RLENGTH - 3)
      s = substr(s, RSTART + RLENGTH)
    }
  }' | sort -u)

[ $fail -eq 0 ] && echo "lint OK"
exit $fail
