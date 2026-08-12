# iOS Deep Dive

iOS 개발 학습 기록과 사이드 프로젝트를 관리하는 저장소입니다.
"동작하니까 됐다" 수준에서 멈추지 않고, 원리와 설계 의도까지 정리하는 것을 목표로 합니다.

## 구조

| 경로 | 설명 |
|---|---|
| `notes/` | 학습 주제별 노트 |
| `projects/` | 프로젝트 설명 · repo 링크 · 회고 |
| `assets/` | 이미지 등 첨부 파일 |
| `scripts/` | 저장소 관리 스크립트 |

## 진행 상태

| 주제 | 구분 | 상태 | 기간 | 노트 | Repo |
|---|---|---|---|---|---|
| iOS 빌드 파이프라인 | 스터디 | 🟡 진행 중 | 2026.08 ~ | — | — |

**상태 범례** · 🟡 진행 중 · ✅ 완료 · ⚪️ 예정 · 🔴 보류

## 작성 규칙

- 표준 마크다운만 사용 (위키링크 `[[ ]]` 사용하지 않음)
- 파일명은 영문 kebab-case, 문서 제목(H1)은 한글
- 다이어그램은 Mermaid, 첨부 이미지는 `assets/`에 상대 경로로 참조

## 새 환경 세팅

클론 후 pre-commit hook을 다시 걸어야 합니다.

```bash
chmod +x scripts/lint.sh
printf '#!/usr/bin/env bash\nexec ./scripts/lint.sh\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```
