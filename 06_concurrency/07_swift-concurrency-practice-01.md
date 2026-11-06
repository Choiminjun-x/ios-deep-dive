# Swift Concurrency 실전 1 — 중복 네트워크 요청 (Latest Wins)

> 작성일: 2026-11-06

## 1. 문제 상황

상품 목록 화면에서 사용자가 새로고침 버튼을 빠르게 여러 번 누르면 동일한 API 요청이 중복으로 발생할 수 있다.

```swift
func fetchProducts() {
    Task {
        let products = try await API.fetchProducts()
        self.products = products
    }
}
```

위 코드는 새로고침을 누를 때마다 새로운 Task를 생성한다.

기존 요청이 진행 중이더라도 별도의 요청이 시작되므로 다음과 같은 문제가 발생할 수 있다.

- 불필요한 네트워크 요청 발생
- 동일한 데이터를 여러 번 요청
- 이전 요청이 늦게 도착해 최신 결과를 덮어쓰는 문제
- 화면 상태와 실제 요청 상태가 일치하지 않는 문제

```
탭 1 → 요청 A 시작 ─────────────────────→ 응답 A 도착 → products = A  ← 오래된 값으로 덮어씀
탭 2 →        요청 B 시작 ──→ 응답 B 도착 → products = B
```

또한 이 코드는 `Task`가 오류를 그대로 삼킨다. 클로저가 throw하면 `Task<Void, Error>`가 되고, 아무도 `value`를 기다리지 않으므로 실패해도 아무 일도 일어나지 않는다.

이번 문제에서는 **Latest Wins** 정책을 적용한다.

새로운 요청이 들어오면 기존 요청을 취소하고, 가장 최근 요청의 결과만 반영한다.

## 2. Task Handle을 이용한 작업 관리

`Task {}`는 Unstructured Task를 생성한다.

Unstructured Task는 개발자가 직접 생명주기를 관리해야 하므로, 나중에 취소하거나 상태를 확인할 수 있도록 Task Handle을 보관할 수 있다.

```swift
private var fetchTask: Task<Void, Never>?
```

새로운 요청이 시작되면 기존 Task를 취소하고 새로운 Task를 생성한다.

```swift
func fetchProducts() {
    fetchTask?.cancel()

    fetchTask = Task {
        guard let products = try? await API.fetchProducts() else { return }
        self.products = products
    }
}
```

`fetchTask`의 타입이 `Task<Void, Never>`이므로, 클로저 안에서 오류를 밖으로 던지면 타입이 맞지 않아 컴파일되지 않는다. 오류는 클로저 안에서 처리해야 한다 (`try?` 또는 `do-catch`).

Task Handle은 실행 중인 Task를 참조하는 객체다.

`fetchTask = nil`로 설정하는 것은 참조를 정리하는 것이며, 해당 Task를 자동으로 취소하지 않는다.

따라서 작업을 중단하려면 명시적으로 `cancel()`을 호출해야 한다.

| 동작 | Task 실행 | 나중에 취소 | 결과 기다리기 |
|---|---|---|---|
| `fetchTask?.cancel()` | 취소 요청됨 (협력 필요) | — | 가능 |
| `fetchTask = nil` | 계속 실행됨 | 불가능 | 불가능 |

## 3. Cancellation의 동작 원리

Swift Concurrency의 취소는 **협력적 취소(Cooperative Cancellation)** 방식이다.

```swift
fetchTask?.cancel()
```

`cancel()`은 Task에 취소를 요청할 뿐, 실행 중인 코드를 강제로 종료하지 않는다.

```
cancel()
 → Task의 isCancelled 플래그만 true로 바뀜
 → 코드는 계속 실행됨
 → 취소를 확인하는 지점에서만 반응
      - Task.checkCancellation() / Task.isCancelled
      - 취소를 지원하는 API (Task.sleep, URLSession 등)
```

실제 작업이 취소에 반응하려면 다음과 같은 확인이 필요하다.

```swift
try Task.checkCancellation()
```

현재 Task가 취소된 상태라면 `CancellationError`를 발생시킨다.

단, 모든 비동기 API가 반드시 `CancellationError`를 반환하는 것은 아니다. 예를 들어 URLSession 기반 API에서는 상황에 따라 `URLError.cancelled` 등으로 나타날 수 있다.

따라서 취소를 요청했다는 사실만으로 작업이 즉시 종료되거나 결과 반영이 차단된다고 생각하면 안 된다.

### 실무에서

어떤 오류가 오는지는 "취소를 누가 먼저 알아챘느냐"에 따라 다르다.

| 취소를 알아챈 곳 | 던지는 오류 |
|---|---|
| `Task.checkCancellation()`, `Task.sleep` | `CancellationError` |
| `URLSession.data(for:)` 등 (요청 중 취소) | `URLError(.cancelled)` (NSURLErrorDomain -999) |
| 서드파티 SDK | SDK마다 다름 |

증상: `catch is CancellationError`로 취소를 걸렀는데, 새로고침을 연타하면 "요청 실패: … cancelled" 로그나 에러 토스트가 뜬다.

오류 타입으로 판단하지 말고, catch 안에서 `Task.isCancelled`로 판단하는 것이 안전하다.

```swift
} catch {
    if Task.isCancelled {
        // 취소 — 사용자에게 보여 주지 않음
    } else {
        // 진짜 실패
    }
}
```

## 4. Request ID를 이용한 최신 요청 검증

기존 요청이 취소에 협력하지 않거나, 취소 요청이 처리되기 전에 응답을 반환할 수도 있다.

이때 취소 여부만으로 최신 요청인지 판단하는 것은 충분하지 않다.

각 요청에 고유한 ID를 부여하고, 결과를 반영하기 전에 현재 요청 ID와 비교한다.

```swift
private var currentRequestID = UUID()
```

새로운 요청이 시작될 때마다 ID를 갱신한다.

```swift
let requestID = UUID()
currentRequestID = requestID
```

응답을 받은 뒤 현재 요청인지 확인한다.

```swift
guard currentRequestID == requestID else {
    return
}
```

이렇게 하면 이전 요청이 늦게 응답하더라도 최신 요청의 상태를 덮어쓰지 못한다.

```
요청 A: requestID = a, currentRequestID = a
요청 B: requestID = b, currentRequestID = b   (A는 cancel 요청됨)
응답 A 도착 → a != b → return (반영 안 함)
응답 B 도착 → b == b → products = B
```

### Cancellation과 Request ID의 역할

| 구분 | 역할 |
|---|---|
| Cancellation | 불필요한 작업의 중단을 요청 |
| Request ID | 오래된 요청이 최신 상태를 변경하지 못하도록 방어 |

두 기능은 서로 대체하는 관계가 아니다.

Cancellation은 불필요한 작업을 줄이기 위한 수단이고, Request ID는 결과의 유효성을 검증하기 위한 수단이다.

### ID 비교가 안전한 이유 — MainActor

이 비교가 경쟁 없이 동작하는 전제는 **`currentRequestID`를 읽고 쓰는 코드가 모두 같은 actor(MainActor)에서 실행된다는 것**이다.

```
@MainActor 클래스 안에서 Task { } 생성
 → Task 클로저는 MainActor 격리를 물려받음
 → ID 갱신, cancel(), 응답 후 ID 비교, products 반영이 모두 MainActor에서 하나씩 실행
 → "비교한 직후 다른 곳이 ID를 바꾸는" 끼어들기가 없음
```

`Task.detached`나 MainActor가 아닌 곳에서 이 패턴을 쓰면 `currentRequestID` 자체가 데이터 경쟁 대상이 된다. Swift 6 언어 모드나 Complete 검사에서는 컴파일러가 경고·오류로 알려 준다.

## 5. defer를 이용한 Task 정리

Task가 종료될 때 정리 작업을 수행하려면 `defer`를 사용할 수 있다.

```swift
defer {
    fetchTask = nil
}
```

다만 이전 Task가 늦게 종료되면 이미 새 Task가 저장된 `fetchTask`를 `nil`로 변경할 수 있다.

```
요청 A 시작 → fetchTask = A
요청 B 시작 → fetchTask = B
A 늦게 종료 → defer { fetchTask = nil }  ← B의 Handle이 지워짐
이후 새로고침 → fetchTask?.cancel()이 nil에 호출됨 → B가 취소되지 않음
```

따라서 자신의 요청 ID가 여전히 최신 요청인지 확인한 뒤 정리해야 한다.

```swift
defer {
    if currentRequestID == requestID {
        fetchTask = nil
    }
}
```

`defer`는 현재 스코프를 벗어나기 직전에 실행된다. 정상 종료, `return`, 오류 발생 등으로 스코프를 벗어나는 경우에도 실행된다.

## 6. 통합 코드

```swift
@MainActor
final class ProductViewModel {
    private(set) var products: [Product] = []

    private var fetchTask: Task<Void, Never>?
    private var currentRequestID = UUID()

    func fetchProducts() {
        // 기존 요청 취소
        fetchTask?.cancel()

        // 새로운 요청 ID 발급
        let requestID = UUID()
        currentRequestID = requestID

        fetchTask = Task {
            defer {
                // 최신 요청만 자신의 Task Handle 정리
                if self.currentRequestID == requestID {
                    self.fetchTask = nil
                }
            }

            do {
                let products = try await API.fetchProducts()

                // 취소 여부 확인
                try Task.checkCancellation()

                // 최신 요청인지 확인
                guard self.currentRequestID == requestID else {
                    return
                }

                // 결과 반영
                self.products = products

            } catch is CancellationError {
                print("요청 취소")

            } catch {
                print("요청 실패:", error)
            }
        }
    }

    func cancelFetch() {
        // 기존 요청 무효화
        currentRequestID = UUID()

        // Task 취소 요청
        fetchTask?.cancel()

        // Handle 참조 정리
        fetchTask = nil
    }
}
```

이 코드는 동시성 문제를 이해하기 위한 학습용 구현이다. 실제 프로젝트에서는 Task가 `self`를 강하게 캡처하면서 발생할 수 있는 순환 참조, API의 취소 협력 여부, 오류 처리 및 화면 생명주기 등을 추가로 고려해야 한다.

### 실무에서

- **URLSession 취소는 두 번째 catch로 간다.** 요청 도중 취소되면 `URLError(.cancelled)`가 오므로 `catch is CancellationError`에 걸리지 않고 "요청 실패"로 찍힌다. 3장처럼 `Task.isCancelled`로 판단한다
- **순환 참조는 "실행 중에만" 생긴다.** `self → fetchTask → 클로저 → self` 구조라 Task가 끝나기 전까지는 ViewModel이 해제되지 않는다. 한 번 응답하고 끝나는 요청이면 Task가 끝날 때 클로저를 놓으므로 문제가 작다. 끝나지 않는 작업(AsyncSequence 순회, 폴링)이면 실제 누수가 되므로 화면을 나갈 때 `cancelFetch()`를 호출한다
- **`[weak self]`만으로는 부족하다.** 클로저 시작에서 `guard let self`로 다시 강하게 잡으면 그 뒤 await 동안에는 결국 `self`를 붙잡는다. 수명은 취소로 관리하는 것이 핵심이다
- 디버깅 포인트: Network 탭(또는 Charles)에서 연타 시 이전 요청이 cancelled로 끊기는지, 화면을 나간 뒤 ViewModel의 `deinit`이 응답 도착 전에 찍히는지 확인한다

## 7. Task와 SwiftUI .task의 생명주기

`Task {}`와 SwiftUI의 `.task {}`는 작업의 생명주기를 관리하는 주체가 다르다.

| 구분 | Task {} | .task {} |
|---|---|---|
| 종류 | Unstructured Task | SwiftUI가 관리하는 View 관련 작업 |
| 생명주기 | 개발자가 직접 관리 | View 생명주기에 연결 |
| 취소 | 직접 cancel 호출 | View 생명주기 등에 따라 취소 요청 |
| 관리 주체 | 개발자 | SwiftUI |

화면에 종속된 데이터 조회 작업은 화면을 벗어날 때 취소하는 것이 일반적으로 적절하다.

반면 파일 다운로드, 결제, 메시지 전송처럼 화면을 벗어나도 완료되어야 하는 작업은 별도의 생명주기 정책이 필요하다.

특히 클라이언트 Task를 취소했다고 해서 서버에서 이미 진행 중인 작업까지 자동으로 취소되거나 되돌려지는 것은 아니다.

### .task(id:) — SwiftUI에 내장된 Latest Wins (iOS 15+)

`.task(id:)`는 `id` 값이 바뀌면 기존 작업을 취소하고 새로 시작한다. 이 문서의 "기존 취소 → 새로 시작"을 SwiftUI가 대신 해 주는 셈이다.

```swift
@State private var refreshToken = 0

var body: some View {
    List(viewModel.products) { … }
        .toolbar {
            Button("새로고침") { refreshToken += 1 }
        }
        .task(id: refreshToken) {
            await viewModel.loadProducts()   // async 함수
        }
}
```

```
버튼 탭 → refreshToken 변경
 → SwiftUI가 이전 .task 취소 요청
 → 새 .task 시작
화면 이탈 → SwiftUI가 .task 취소 요청
```

주의:

- 해 주는 것은 **취소 요청까지**다. 이전 작업이 취소에 협력하지 않으면 늦게 끝나서 상태를 덮어쓸 수 있으므로, 결과 반영 전 검증(Request ID 또는 `Task.isCancelled` 확인)은 여전히 필요하다
- 이 경우 ViewModel은 Task Handle을 들고 있지 않아도 되므로 `fetchTask`·`defer` 정리 코드가 사라진다
- UIKit에는 대응하는 기능이 없으므로 6장 패턴을 쓴다

## 핵심 정리

- `Task {}`로 생성한 Unstructured Task는 개발자가 직접 생명주기를 관리해야 한다.
- Task Handle을 프로퍼티에 보관하면 작업을 취소하거나 참조를 정리할 수 있다.
- `cancel()`은 강제 종료가 아닌 협력적 취소 요청이다.
- `Task.checkCancellation()`은 현재 Task의 취소 상태를 확인하고, 취소됐다면 `CancellationError`를 던진다.
- API가 취소에 협력하지 않을 수 있으므로 결과 반영 전 검증이 필요하다.
- 취소 시 던지는 오류는 API마다 다르다 (`CancellationError`, `URLError.cancelled`). 오류 타입보다 `Task.isCancelled`로 판단한다.
- Request ID를 이용하면 오래된 요청이 최신 상태를 변경하는 것을 방지할 수 있다.
- Request ID 비교는 관련 상태가 모두 같은 actor(MainActor)에서 다뤄질 때 안전하다.
- `defer`를 이용한 정리 작업도 최신 요청인지 확인해야 한다.
- Task Handle을 `nil`로 설정하는 것과 Task를 취소하는 것은 별개의 동작이다.
- `Task {}`와 SwiftUI `.task {}`는 작업 생명주기를 관리하는 주체가 다르다.
- SwiftUI에서는 `.task(id:)`가 "기존 취소 → 새로 시작"을 대신 해 준다. 단, 결과 검증은 여전히 필요하다.

## 참고 자료

**공식**

- [Swift — Task](https://developer.apple.com/documentation/swift/task) — Unstructured Task, cancel()
- [Swift — Task.checkCancellation()](https://developer.apple.com/documentation/swift/task/checkcancellation())
- [Swift — CancellationError](https://developer.apple.com/documentation/swift/cancellationerror)
- [SwiftUI — task(priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(priority:_:)) — 뷰가 사라진 뒤 자동 취소
- [SwiftUI — task(id:priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)) — id가 바뀌면 취소 후 재시작, iOS 15+
- [WWDC23 — Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170) — Unstructured Task는 명시적으로 취소
- [SE-0304 Structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) — 협력적 취소, Task 클로저의 암시적 self 캡처

**외부**

- [Ole Begemann — Cancellation can come in many forms (2022)](https://oleb.net/2022/cancellation-forms/) — URLSession은 URLError.cancelled를 던짐, Task.isCancelled로 판단
- [Swift Forums — CancellationError (2022)](https://forums.swift.org/t/cancellationerror/60009) — .task 취소 시 NSURLErrorDomain -999가 온 사례
- [Swift Forums — Task async retain cycles](https://forums.swift.org/t/task-async-retain-cycles/49585) — 실행 중 순환은 괜찮고 끝나지 않는 Task가 문제
- [Swift Forums — Is [weak self] actually necessary in a Task closure?](https://forums.swift.org/t/is-weak-self-actually-necessary-in-a-task-closure/88555) — weak self가 await 동안 순환을 막지 못하는 이유
- [Hacking with Swift — How to cancel a Task](https://www.hackingwithswift.com/quick-start/concurrency/how-to-cancel-a-task)
