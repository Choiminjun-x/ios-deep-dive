# 백그라운드 실행 · 종료 · 복원

> 작성일: 2026-10-15

## 큰 그림

```
홈으로 나감 → Background (잠깐 실행) → Suspended (멈춤) → (Jetsam 등으로 죽음) → 다시 열면 복원
   1. 나가기: 이 "잠깐"을 늘리거나 미루는 방법
   2. 죽기: 죽기 직전 콜백, 죽은 뒤 이유 구분
   3. 돌아오기: 죽은 뒤 보던 화면 되살리기
```

## 1. 나가기: 백그라운드 실행 4가지

Background에 들어가면 곧 Suspended가 된다. 더 실행하려면 시스템에 요청해야 하고, 방법은 "그 작업을 언제 하고 싶은가"로 고른다.

| 상황 | 쓰는 것 | 한 줄 |
|---|---|---|
| 하던 걸 마저 끝내고 싶다 (저장, 메시지 전송) | `beginBackgroundTask` | "잠깐만, 이것만 끝내고 멈출게" |
| 파일 업로드·다운로드 | 백그라운드 `URLSession` | 전송을 시스템에 맡김 |
| 나중에 해도 된다 (새로고침, DB 정리) | `BGTaskScheduler` | 시스템이 좋은 때 깨워 줌 |
| 사용자가 버튼 눌러 시작한 긴 작업 (영상 내보내기) | `BGContinuedProcessingTask` (iOS 26+) | 진행률을 보여 주며 계속 |

```
마저 끝내기   → beginBackgroundTask      (잠깐만!)
전송          → 백그라운드 URLSession     (택배에 맡기기)
나중에        → BGTaskScheduler          (시스템이 알아서 깨워 줌)
긴 작업 계속  → BGContinuedProcessingTask (진행률 보여 주며 계속)
```

### `beginBackgroundTask`: 마저 끝내기

```
begin → 작업 → end   (짝이 안 맞으면 앱이 죽음)
```

- 시간이 다 되기 전에 `endBackgroundTask`를 부르지 않으면 시스템이 앱을 종료한다. 시간이 거의 다 됐을 때 불리는 expiration handler에서도 정리하고 end를 부른다
- 요청이 비동기로 처리되므로 미리 부른다. `applicationDidEnterBackground` 맨 끝에서 부르면 승인 전에 멈출 수 있다
- 주는 시간은 문서에 수치가 없다. `backgroundTimeRemaining`으로 확인한다

### 백그라운드 `URLSession`: 전송을 맡기기

전송을 내 앱이 아니라 별도 프로세스가 한다. 그래서 앱이 Suspended가 되거나 시스템에 의해 종료돼도 전송은 계속된다.

```
앱: "이 파일 올려 줘" → 시스템 프로세스가 전송
앱은 Suspended, 또는 시스템에 의해 종료 → 전송 계속
끝나면 → 시스템이 앱을 깨우거나 백그라운드로 다시 실행
       → application(_:handleEventsForBackgroundURLSession:completionHandler:)
       → 같은 identifier로 세션을 다시 만들어야 결과를 받음
```

- 업로드는 파일에서 올리는 것만 지원한다. `Data`에서 올린 업로드는 앱이 종료되면 실패한다

### `BGTaskScheduler`: 나중에 하기

| 종류 | 용도 | 시간 |
|---|---|---|
| `BGAppRefreshTask` | 짧은 새로고침 | 최대 30초 |
| `BGProcessingTask` | 무거운 작업 (DB 정리, ML) | 충전 중 밤 같은 한가한 때 |

둘 다 언제 실행될지는 시스템이 정한다. "매일 9시에 실행"은 안 된다.

### `BGContinuedProcessingTask` (iOS 26+): 긴 작업 이어가기

- 다른 BGTask와 달리 포그라운드에서 시작하고, 버튼 탭 같은 사용자 동작에 대한 응답으로만 실행한다
- 진행률은 Live Activity로 보이고, 사용자가 거기서 취소할 수 있다
- 자원이 부족하면 진행이 거의 없는 작업부터 종료되므로 진행률을 꾸준히 보고한다

### Swift 5 / 6 차이

`beginBackgroundTask`의 expiration handler는 `@MainActor @Sendable`로 선언돼 있다. Swift 6 모드에서는 이 클로저가 Sendable이 아닌 값을 캡처하면 에러가 나고, Swift 5 모드에서는 동시성 검사 설정에 따라 경고로 끝나거나 진단 없이 통과한다 (세부 진단은 확인 필요).

### 실무에서

- 백그라운드 작업 중 앱이 죽고 크래시 로그에 앱 코드가 없다 → `endBackgroundTask` 누락
- 홈으로 나가면 업로드가 끊긴다 → 일반 `URLSession`이거나 `Data`에서 업로드
- 개발 중 `BGAppRefreshTask`가 안 불린다 → 실행 시점을 시스템이 정하므로 정상
- 앱 스위처에서 쓸어 올려 종료하면 continued processing task는 모두 취소되고, 앱은 취소 알림도 받지 못한다

## 2. 죽기: 종료 콜백과 죽은 이유 구분

### `applicationWillTerminate`

- 이름만 보면 종료 직전에 항상 불리는 것 같다 (오해)
- 사실상 "운 좋으면 불리는 곳"

```
사용자가 홈으로 나감 → Background → Suspended
 → 이 상태에서 죽으면 (Jetsam, 앱 스위처 종료 등) → 아무 콜백 없음
```

앱이 Suspended가 아니라 백그라운드에서 실행 중일 때 시스템이 종료하는 경우에만 불릴 수 있고, 불려도 약 5초 안에 리턴해야 한다. 그래서 저장은 `sceneDidEnterBackground`에서 한다.

### 크래시: Exception Type으로 종류를 본다

- `EXC_BREAKPOINT (SIGTRAP)` → Swift 런타임 에러 (강제 언래핑 nil, 배열 범위 초과 등). 런타임이 오류를 잡고 일부러 앱을 종료한 것
- `EXC_BAD_ACCESS (SIGSEGV)` → 잘못된 메모리 접근
- `EXC_CRASH (SIGABRT)` + `Last Exception Backtrace` → ObjC 예외 (시스템 프레임워크가 던짐)

### Watchdog: `0x8badf00d`

- 시스템이 "너무 오래 응답 없네" 하고 죽임
- 응답 없는 앱 종료 → Termination Reason에 `0x8badf00d` 찍힌 크래시 리포트 남음
- Watchdog이 감시하는 건 런치, 포그라운드·백그라운드 전환 같은 순간
- Termination Description에 어느 전환(예: `scene-create`)에서 몇 초를 넘겼는지 적힌다

### Jetsam: 크래시처럼 보이지만 크래시 리포트가 아니다

- 시스템(커널)이 "메모리 모자라" 하고 죽임
- 리포트는 JSON이고, 기기 전체 프로세스의 메모리 사용량이 담기며, 앱 스레드의 백트레이스가 없다
- `processes` 배열에서 `reason` 키를 찾는다. 종료된 프로세스에만 있다
- `per-process-limit` → 내 앱이 메모리 한도를 넘음
- `vm-pageshortage` → 포그라운드 앱에 메모리를 주려고 백그라운드 앱을 정리
- 열린 파일 수(`vnode-limit`)나 파일 캐시(`fc-thrashing`) 때문에도 백그라운드 앱이 정리될 수 있다. 내 잘못인지는 `reason`을 봐야 안다

| | 크래시 | Watchdog | Jetsam |
|---|---|---|---|
| 누가 죽였나 | 내 코드 버그 | 시스템 (전환 중 응답 없음) | 시스템 (자원 부족) |
| 남는 것 | 크래시 리포트 | 크래시 리포트 | Jetsam 이벤트 리포트 |
| 알아보는 표시 | Exception Type | `0x8badf00d` | `reason` 키 |
| 백트레이스 | 있음 | 있음 | 없음 |

```
"앱이 갑자기 꺼졌어요" 제보
 → 크래시 리포트가 있나?
     있음 → 0x8badf00d면 Watchdog, 아니면 Exception Type 보고 크래시 종류
     없음 → Jetsam 리포트에서 내 앱에 reason이 있나?
              있음 → 메모리 (per-process-limit이면 내 앱이 과다 사용)
              없음 → 확인 필요 (사용자가 직접 종료했을 수도)
```

### 실무에서

- Organizer나 Crashlytics에 아무것도 없는데 "앱이 꺼진다" 제보 → Jetsam 의심. 크래시 수집 도구에 안 잡힌다
- `0x8badf00d`인데 개발 중엔 재현이 안 된다 → 디버거가 연결되면 Watchdog이 꺼진다
- `applicationWillTerminate`에 저장 코드가 있는데 데이터가 날아간다 → 거기가 안 불린 것. `sceneDidEnterBackground`로 옮긴다

## 3. 돌아오기: 상태 복원

화면은 저절로 돌아오지 않는다.

```
Jetsam으로 죽음 → 앱 실행 → 프로세스가 새로 뜸 (cold launch)
```

복원은 "죽기 전에 메모 남기기 → 다시 뜰 때 메모 읽기"다.

```
나갈 때    "지금 상품 123 상세 화면 보는 중" 메모 → 시스템이 디스크에 보관
죽음       (Jetsam 등)
다시 뜰 때  메모 꺼내기 → 상품 123 상세 화면을 다시 만들어 보여 줌
```

메모에는 화면 자체가 아니라 다시 만들 단서만 넣는다 ("상품 ID 123, 탭 2번" 정도).

| | UIKit | SwiftUI |
|---|---|---|
| 메모 남기기 | `stateRestorationActivity(for:)`에서 `NSUserActivity` 반환 | `@SceneStorage`에 값 넣기 |
| 메모 읽기 | `willConnectTo`에서 `session.stateRestorationActivity` 확인 | 자동 (초깃값이 복원됨) |
| 단위 | 씬마다 | 씬마다 |
| iOS | 13+ | 14+ |

### UIKit

```
나갈 때: UIKit → stateRestorationActivity(for:) 호출 → NSUserActivity 반환
다시 뜰 때: willConnectTo → session.stateRestorationActivity에 그 activity가 들어 있음
           → 있으면 그 화면으로, 없으면 기본 첫 화면
```

### SwiftUI: `@SceneStorage`

- 이전에 저장된 값이 있으면 시스템이 초깃값을 복원해 주고, 씬마다 따로 저장되어 다른 씬과 공유되지 않는다
- 모델 데이터처럼 큰 값은 넣지 말고, 가벼운 데이터만 넣기
- 민감한 데이터를 넣지 말기

### 실무에서

테스트 시 Jetsam 상황 만드는 법:

```
홈으로 나가 Suspended 만들기 → Xcode에서 정지 버튼 → Xcode로 다시 실행
(앱 스위처로 죽이면 복원 데이터가 지워져서 "안 되는 것처럼" 보임)
```

런치 중 크래시가 나도 보존된 상태가 삭제된다.

## 핵심 정리

1. 백그라운드 실행은 "언제 할 작업인가"로 고른다. 마저 끝내기는 `beginBackgroundTask`, 전송은 백그라운드 `URLSession`, 나중에는 `BGTaskScheduler`, 사용자가 시작한 긴 작업은 `BGContinuedProcessingTask`
2. `applicationWillTerminate`는 Suspended 상태에서 죽으면 불리지 않는다. 저장은 `sceneDidEnterBackground`에서
3. 크래시는 내 코드가, Watchdog(전환 중 응답 없음)과 Jetsam(자원 부족)은 시스템이 죽인다. 리포트의 Exception Type, `0x8badf00d`, `reason`으로 구분한다
4. 화면 복원은 직접 구현해야 한다. UIKit은 `stateRestorationActivity`, SwiftUI는 `@SceneStorage`
5. 앱 스위처로 종료하면 복원 데이터가 지워진다. 테스트는 Xcode 정지 버튼으로

## 셀프 체크

**Q0. 홈으로 나갈 때 하던 작업을 계속하려면 무엇을 쓰나?**

- "그 작업을 언제 하고 싶은가"로 고른다. 하던 걸 마저 끝내려면 `beginBackgroundTask`, 파일 전송은 백그라운드 `URLSession`, 나중에 해도 되는 일은 `BGTaskScheduler`, 사용자가 시작한 긴 작업은 `BGContinuedProcessingTask`(iOS 26+)

**Q1. 업로드 중 홈으로 나갔다가 Jetsam으로 죽으면, 업로드와 화면은 각각 어떻게 되나?**

- 업로드: 일반 `URLSession`은 앱과 함께 실패하고, 다음에 처음부터 다시 올려야 한다. 백그라운드 `URLSession`(파일 업로드)은 별도 프로세스가 전송하므로 계속 진행되고, 끝나면 시스템이 앱을 백그라운드로 다시 띄워 결과를 전달한다
- 화면: `stateRestorationActivity`를 구현해 뒀다면 재실행 시 보던 화면으로 돌아올 수 있다. 구현하지 않았다면 첫 화면부터 시작한다

**Q2. 응답 없음은 Watchdog, 메모리 이슈는 Jetsam이고, 둘 다 시스템이 죽이는 게 맞나?**

- 맞다. 다만 Watchdog은 항상이 아니라 런치·전환 같은 순간의 응답 없음을 감시한다. Jetsam은 메모리 외에 열린 파일 수 같은 자원 부족으로도 일어나고, 다른 앱 때문에 백그라운드의 내 앱이 정리될 수도 있다. 내 책임인지는 `reason`으로 판단한다

## 참고 자료

**공식**

- [beginBackgroundTask(withName:expirationHandler:)](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:))
- [Choosing Background Strategies for Your App](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [applicationWillTerminate(_:)](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationwillterminate(_:))
- [Identifying the cause of common crashes](https://developer.apple.com/documentation/xcode/identifying-the-cause-of-common-crashes)
- [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)
- [stateRestorationActivity(for:)](https://developer.apple.com/documentation/uikit/uiscenedelegate/staterestorationactivity(for:))
- [SceneStorage](https://developer.apple.com/documentation/swiftui/scenestorage)
- [Restoring your app's state](https://developer.apple.com/documentation/uikit/restoring-your-app-s-state)
