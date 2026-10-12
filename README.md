# iOS Deep Dive

기초부터 다시 공부하고, 모르는 게 생기면 계속 파고든다.

앱이 만들어지는 과정부터 시작해, 기기에서 켜지고 → 돌아가고 → 화면에 그려지고 → 데이터를 주고받는 순서로 올라간다.

## 1. 빌드

코드가 `.app`이 되기까지

- [Xcode 프로젝트 구조와 빌드 설정](01_build/01_xcode-project-settings.md)
- [iOS 빌드 과정](01_build/02_build-process.md)
- [iOS 코드 서명](01_build/03_code-signing.md)
- [심볼과 링킹](01_build/04_symbol-linking.md)
- [SPM과 의존성 빌드](01_build/05_spm-dependency-build.md)
- [Swift 컴파일러 내부와 모듈](01_build/06_swift-compiler-module.md)
- [Archive와 배포](01_build/07_archive-distribution.md)

## 2. 실행 시작

탭 → dyld → `main` → 앱 생명주기

- [AppDelegate와 SceneDelegate](02_app-lifecycle/01_app-scene-delegate.md)
- [iOS 27 UIScene 라이프사이클 필수화](02_app-lifecycle/02_uiscene-ios27.md)
- [Launch, Prewarming, Watchdog, Jetsam](02_app-lifecycle/03_launch-watchdog-jetsam.md)

## 3. 메모리·언어

객체가 메모리에 놓이고 호출되는 방식

## 4. 스레드·동시성

코드가 어느 스레드에서 도는가

## 5. 이벤트·렌더링

터치 → 처리 → 레이아웃 → 화면 그리기 (UIKit, SwiftUI 포함)

- [RunLoop, Hit-Testing, Responder Chain](03_event-handling/01_runloop-hittest-responder.md)

## 6. 데이터·네트워크

저장하고 주고받기

- [iCloud 백업/복원](04_data-storage/01_icloud-backup-restore.md)

## 7. 보안

데이터와 통신을 안전하게

- [iOS Secure Enclave](05_security/01_secure-enclave.md)

## 8. 아키텍처

앱 전체를 어떻게 나누는가
