# iOS 공부 노트

기초부터 다시 공부하고, 모르는 게 생기면 계속 파고든다.

## 노트

주제 폴더와 노트의 번호는 학습 순서.

| 주제 | 노트 |
|---|---|
| 빌드 | [iOS 빌드 과정](01_build/01_build-process.md) · [iOS 코드 서명](01_build/02_code-signing.md) |
| 앱 생명주기 | [AppDelegate와 SceneDelegate](02_app-lifecycle/01_app-scene-delegate.md) · [iOS 27 UIScene 라이프사이클 필수화](02_app-lifecycle/02_uiscene-ios27.md) · [Launch, Prewarming, Watchdog, Jetsam](02_app-lifecycle/03_launch-watchdog-jetsam.md) |
| 이벤트 처리 | [RunLoop, Hit-Testing, Responder Chain](03_event-handling/01_runloop-hittest-responder.md) |
| 데이터 저장 | [iCloud 백업/복원](04_data-storage/01_icloud-backup-restore.md) |

## 작성 규칙

노트 골격은 [_template.md](_template.md).

- **필수:** 제목 · 작성일 · 본문. 큰 그림 · 실무에서 · 핵심 정리 · 셀프 체크는 내용이 있을 때만 넣는다
- **순서:** 제목 → 작성일 → 큰 그림 → 본문 → 핵심 정리 → 셀프 체크 → 참고 자료
- **제목:** 공부한 주제만, 간결하게
- **본문:** 큰 섹션은 `## 1.` 번호. 실무 내용은 해당 섹션 안 `### 실무에서`
- **셀프 체크:** 질문을 주고받았으면 `**Q1. 질문**` + 빈 줄 + `- 답`
- **참고 자료:** 참고한 자료가 있으면 넣는다
- **이름:** 폴더·파일은 `NN_영문-소문자-kebab` (한글은 제목에). 이미지는 주제 폴더 `images/<문서>-<설명>.png`
- **표기:** 섹션 사이 `---` 안 씀. 다이어그램은 텍스트 코드 블록, 안 되면 PNG. Mermaid · HTML 태그 · 줄끝 `\` 안 씀
- **줄바꿈:** 줄을 나눠 보여야 하면 빈 줄로 문단을 나눈다 (GitHub은 줄바꿈 하나를 무시)
- **굵게 + 조사:** 문장부호는 굵게 바깥으로 — `"**…**"는`, `` **`codesign`이** ``

## 커밋 규칙

| prefix | 언제 |
|---|---|
| `docs:` | 문서 내용 추가·수정 |
| `chore:` | README · 설정 |
| `refactor:` | 폴더·파일 이동, 구조 정리 |
| `fix:` | 표기 깨짐 수정 |
