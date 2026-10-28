# ios-deep-dive

기초부터 다시 공부하고, 모르는 게 생기면 계속 파고든다.

## 빌드 `01_build`

- [Xcode 프로젝트 구조와 빌드 설정](01_build/01_xcode-project-settings.md)
- [iOS 빌드 과정](01_build/02_build-process.md)
- [iOS 코드 서명](01_build/03_code-signing.md)
- [심볼과 링킹](01_build/04_symbol-linking.md)
- [SPM과 의존성 빌드](01_build/05_spm-dependency-build.md)
- [Swift 컴파일러와 모듈](01_build/06_swift-compiler-module.md)
- [Archive와 배포](01_build/07_archive-distribution.md)

## 앱 생명주기 `02_app-lifecycle`

- [AppDelegate와 SceneDelegate](02_app-lifecycle/01_app-scene-delegate.md)
- [iOS 27 UIScene 라이프사이클 필수화](02_app-lifecycle/02_uiscene-ios27.md)
- [Launch, Prewarming, Watchdog, Jetsam](02_app-lifecycle/03_launch-watchdog-jetsam.md)
- [런치: 탭부터 첫 프레임까지](02_app-lifecycle/04_launch-tap-to-first-frame.md)
- [백그라운드 실행 · 종료 · 복원](02_app-lifecycle/05_background-termination-restoration.md)
- [렌더 루프와 첫 프레임](02_app-lifecycle/06_render-loop-first-frame.md)

## 이벤트 처리 `03_event-handling`

- [RunLoop, Hit-Testing, Responder Chain](03_event-handling/01_runloop-hittest-responder.md)
- [런루프 (Run Loop)](03_event-handling/02_run-loop.md)
- [UIGestureRecognizer](03_event-handling/03_gesture-recognizer.md)

## 데이터 저장 `04_data-storage`

- [iCloud 백업/복원](04_data-storage/01_icloud-backup-restore.md)

## 보안 `05_security`

- [iOS Secure Enclave](05_security/01_secure-enclave.md)
- [App Attest 기술 검토](05_security/02_app-attest.md)

## 동시성 `06_concurrency`

- [Swift Concurrency 선수 개념](06_concurrency/01_concurrency-prerequisites.md)
