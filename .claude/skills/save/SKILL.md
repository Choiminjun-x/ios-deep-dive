---
name: save
description: 이 볼트의 변경분을 lint 검사 → 주제별 분리 커밋 → 현재 브랜치 푸시까지 한 번에 처리하는 스킬. 사용자가 "저장해줘", "커밋하고 푸시해줘", "/save" 라고 하면 사용한다. lint 실패 시 커밋하지 않고 중단하며, force push·브랜치 전환·amend 는 하지 않는다.
---

## 역할

ios-deep-dive 볼트의 미커밋 변경분을 **lint 통과 → 주제별 커밋 → 푸시** 순으로 저장한다.

---

## Step 1. 변경분 점검

```bash
git status --porcelain
git diff
git diff --cached
git log --oneline -10
```

- 변경분이 없으면 즉시 종료:
  ```
  ℹ️ 커밋할 변경분이 없습니다.
  ```
- `git log` 는 이 저장소의 커밋 메시지 스타일을 학습하기 위해 본다.

---

## Step 2. lint 게이트

```bash
bash scripts/lint.sh
```

- **실패하면 커밋하지 않고 중단한다.** 출력 전문을 그대로 보여주고 무엇을 고쳐야 하는지 안내한다.
- 통과시키려고 `lint.sh` 자체를 수정하지 않는다.
- `scripts/lint.sh` 가 없으면 그 사실만 알리고 다음 단계로 진행.

---

## Step 3. 주제별 그룹핑

변경 파일을 성격별로 묶어 커밋 단위를 정한다.

| 분류 | 대상 | 메시지 타입 |
|---|---|---|
| 노트 | `notes/*.md` | `docs` |
| 다이어그램 | `assets/*.svg` | `docs` |
| 색인 | `README.md` | `docs` |
| 저장소 규칙·도구 | `CLAUDE.md`, `scripts/`, `.claude/` | `chore` |

그룹핑 규칙:

- **한 주제로 묶이는 건 한 커밋.** 노트와 그 노트가 참조하는 SVG, 그리고 그 노트를 추가한 `README.md` 표 행은 함께 커밋한다.
- 서로 다른 노트 주제는 분리한다.
- 저장소 규칙 변경(`CLAUDE.md`, `scripts/`)은 항상 노트 변경과 분리한다.
- 결과 그룹이 하나뿐이면 그냥 단일 커밋으로 처리한다.

메시지 형식은 `타입: 한 줄 요약` (한글). 최근 로그 스타일과 어긋나면 로그 쪽을 따른다.

---

## Step 4. 사용자 확인

그룹과 초안 메시지를 표로 제시한다.

```
📝 커밋 계획

[1] docs: Xcode 빌드 파이프라인 노트 추가
      A notes/Xcode-build-pipeline.md
      A assets/build-pipeline.svg

[2] chore: 저장소 규칙에 SVG 스타일 가이드 추가
      M CLAUDE.md

진행할까요? (y / 수정 / 병합 / 취소) →
```

- `y` → 그대로 진행
- `수정` → 특정 그룹의 메시지 교체
- `병합` → 전부 한 커밋으로 합침
- `취소` → 종료

추적되지 않은 파일(`??`)은 **포함 여부를 반드시 확인**한다. 임시 파일·로컬 설정은 제외를 권고.

---

## Step 5. 커밋

그룹마다 순서대로:

```bash
git add <해당 그룹의 파일들을 명시적으로 나열>
git commit -m "<메시지>"
```

- `git add -A` / `git add .` 금지. 파일을 명시적으로 나열한다.
- 커밋 실패(pre-commit hook 등) 시 출력을 보여주고 **거기서 중단**. 이미 만든 커밋은 그대로 둔다.
- `--amend` 금지.

---

## Step 6. 푸시

```bash
BR=$(git rev-parse --abbrev-ref HEAD)
git push origin "$BR"
```

- upstream 이 없으면 `git push -u origin "$BR"`.
- **non-fast-forward 로 거절되면 force push 하지 않는다.** 아래를 안내하고 중단:
  ```
  ⚠️ 원격이 앞서 있습니다. 커밋은 로컬에 남아 있습니다.
     git pull --rebase origin <브랜치> 후 다시 /save 하세요.
  ```
- 네트워크/인증 실패 시 원인을 그대로 보여주고, 커밋은 보존된 상태임을 알린다.

### 보호 브랜치 훅 (기기마다 1회)

`pre-commit-gate.sh` 가 `🚫 보호 브랜치(main/master) 직접 push 차단` 을 내면, **브랜치를 만들지 말 것.**
이 볼트는 혼자 쓰는 문서 저장소라 main 직접 push 가 정상이다.

훅의 예외 마커는 저장소가 아니라 사용자 홈에 있어 기기 간 동기화되지 않는다. 새 기기에서는 없는 것이 정상이므로,
막히면 마커를 만들고 push 를 **한 번만** 재시도한다.

```bash
CFG=$(bash ~/.claude/bin/project-config-dir.sh)
touch "$CFG/allow-push-main"
```

- 마커는 이 볼트에만 적용된다. 다른 프로젝트의 브랜치 보호는 그대로다.
- 재시도해도 막히면 원인을 그대로 보고하고 중단. 훅 파일 자체는 수정하지 않는다.

### SSH 인증

remote 는 `git@github.com:Choiminjun-x/ios-deep-dive.git` (SSH). 인증은 `~/.ssh/config` 와 ssh-agent 에
등록된 키(`id_ed25519_github_choiminjun`)로 git 이 처리한다. **스킬이 키 경로를 지정하거나 자격증명을 저장하지 않는다.**

`Permission denied (publickey)` 로 푸시가 실패하면 진단만 안내하고 중단:

```bash
ssh-add -l                                  # 키가 agent 에 있는지
ssh -o BatchMode=yes -T git@github.com      # 인증 자체가 되는지
```

- `The agent has no identities` → `ssh-add ~/.ssh/id_ed25519_github_choiminjun` 실행 안내
- 그 외 → 출력을 그대로 보여주고 사용자 판단에 맡긴다. 키 생성·config 수정은 하지 않는다.

---

## Step 7. 결과 요약

```
✅ 저장 완료

  lint: 통과
  커밋:
    a1b2c3d docs: Xcode 빌드 파이프라인 노트 추가
    e4f5g6h chore: 저장소 규칙에 SVG 스타일 가이드 추가
  푸시: main → origin/main
```

lint 실패·푸시 실패 등으로 일부만 끝났다면 "완료" 라고 쓰지 않고 **단계별 상태로만** 보고한다.

---

## 하지 않는 것

- force push (`-f`, `--force-with-lease`)
- 브랜치 생성·전환
- `git commit --amend`, `git reset`, `git rebase`
- lint 를 통과시키기 위한 `scripts/lint.sh` 수정
- 요청 범위 밖 파일의 수정
