# iOS 27 UIScene 라이프사이클 필수화

> 작성일: 2026-09-29

## 1. 무엇이 바뀌었나
- iOS 27 SDK(Xcode 27)로 빌드한 앱은 UIScene 라이프사이클 필수. 미채택 시 실행 즉시 종료
- 기준은 **빌드 SDK**. 기기 OS 버전, Deployment Target과 무관
  - Xcode 26으로 빌드한 앱은 iOS 27 기기에서도 정상 실행
- 필수는 "씬 라이프사이클 채택"뿐. 멀티 씬은 권장 사항
  - `UIApplicationSupportsMultipleScenes = false`로 싱글 윈도우 유지 가능

## 2. 단계적 예고
- iOS 18.4: 미채택 시 경고 로그
- iOS 26: "곧 필수가 된다" 경고로 강화 (WWDC25 공식 예고)
- iOS 27: 강제 (실행 불가)

## 3. 왜 강제하나
**AppDelegate 모델의 전제가 더 이상 성립하지 않기 때문**

| AppDelegate 모델의 전제 | 현재 플랫폼의 현실 |
|---|---|
| 앱 = 창 1개 | iPad 멀티 윈도우, visionOS 다중 창 |
| 화면 = UIScreen.main 하나 | iPhone Mirroring, 외부 디스플레이 |
| 앱 전체가 하나의 상태 | 창 A는 활성, 창 B는 백그라운드 공존 |
| 크기 고정 | iPadOS 26 창 크기 조절, iOS 27 iPhone 앱 리사이즈 |

- 씬 = "UI 인스턴스 하나"를 단위로 상태·화면·크기·라이프사이클을 독립 관리
- Apple 공식 설명
  - WWDC25: 씬이 유연성(flexibility)에 필수적이므로 의무화
  - WWDC26 "Modernize your UIKit app": 씬 라이프사이클은 적응형 앱의 기반이자 이후 기능들의 전제
- (해석) iOS 13부터 두 모델을 병행 지원해온 비용을 정리하고,
  새 기능(리사이즈, 미러링 등)을 씬 전제로만 설계하려는 방향

## 4. 최소 마이그레이션
1. Info.plist에 `UIApplicationSceneManifest` 추가
   - `UISceneDelegateClassName`에 `$(PRODUCT_MODULE_NAME).SceneDelegate` 반드시 지정
2. SceneDelegate 작성: window 생성을 `scene(_:willConnectTo:options:)`로 이동

## 5. 주의사항
- 씬 채택 후 AppDelegate의 UI 콜백(`applicationDidBecomeActive` 등)은 **호출되지 않음**
  → SceneDelegate의 대응 메서드로 이동
- 딥링크 처리도 SceneDelegate로 이동 (콜드 스타트 / 실행 중 두 경로)
- 푸시 토큰 콜백은 AppDelegate에 그대로 유지
- `UIScreen.main`, `keyWindow` 등 "창이 하나"라고 가정한 코드는 windowScene 기반으로 교체

## 참고 자료
- [TN3187: Migrating to the UIKit scene-based life cycle](https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle)
- [WWDC25 - Make your UIKit app more flexible](https://developer.apple.com/videos/play/wwdc2025/282/)
- [WWDC25 - What's new in UIKit](https://developer.apple.com/videos/play/wwdc2025/243/)
- [WWDC26 - Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/)
