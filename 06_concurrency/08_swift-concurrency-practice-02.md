# Swift Concurrency 실전 2 — 검색어 자동 완성 (Debounce)

> 작성일: 2026-11-06

## 1. 문제 상황

검색 화면에서 사용자가 검색어를 입력할 때마다 API를 호출하면 불필요한 네트워크 요청이 많이 발생한다.

예를 들어 사용자가 `Swift`를 입력하면 다음과 같이 여러 요청이 발생할 수 있다.

```text
S → Sw → Swi → Swif → Swift
```

각 입력마다 API를 호출하는 대신, **일정 시간 동안 추가 입력이 없을 때 검색을 실행**하도록 개선할 수 있다.

이러한 방식을 Debounce라고 한다.

```
입력:   S   Sw  Swi  Swif  Swift ·········(300ms 조용)
        │   │   │    │     │
Task:   ✕   ✕   ✕    ✕     └─ sleep 300ms → API 호출 → 결과 반영
        (다음 입력이 들어오면 sleep 중에 취소됨)
```

이번 문제에서는 다음 정책을 적용한다.

- 새로운 검색어가 입력되면 기존 검색 Task 취소
- 마지막 입력 이후 300ms 동안 추가 입력이 없으면 API 호출
- 최신 검색 요청의 결과만 화면에 반영
- 이전 요청이 늦게 종료되더라도 최신 상태를 변경하지 못하도록 방어

### 실전 1과 달라진 점

| 구분 | 실전 1 (새로고침) | 실전 2 (자동 완성) |
|---|---|---|
| 요청 발생 | 버튼 연타 | 글자 입력마다 |
| 요청 전 대기 | 없음 | 300ms Debounce |
| 화면 상태 | `products` | `products`, `isLoading`, `errorMessage` |
| 특수 입력 | 없음 | 빈 검색어 |
| 공통 | 기존 Task 취소 + Request ID 검증 + `defer` 정리 | |

## 2. Debounce 구현

Swift Concurrency에서는 `Task.sleep()`을 이용해 일정 시간 대기하는 방식으로 Debounce를 구현할 수 있다.

```swift
try await Task.sleep(
    nanoseconds: 300_000_000
)
```

300ms 동안 Task를 중단한다.

이 시간 동안 새로운 검색어가 입력되면 기존 Task를 취소하고 새로운 Task를 생성한다.

```swift
func search(keyword: String) {
    searchTask?.cancel()

    searchTask = Task {
        try await Task.sleep(
            nanoseconds: 300_000_000
        )

        let products = try await API.searchProducts(
            keyword: keyword
        )

        self.products = products
    }
}
```

이 단계의 코드는 클로저가 오류를 밖으로 던지므로 `searchTask`의 타입이 `Task<Void, Error>?`여야 한다. 7장 통합 코드처럼 `Task<Void, Never>?`로 선언하려면 클로저 안에서 `do-catch`로 오류를 처리해야 한다.

`Task.sleep()`은 cancellation-aware API다.

Task가 취소되면 대기 중인 `Task.sleep()`은 `CancellationError`를 발생시키므로, 기존 Task가 불필요한 API 요청을 시작하지 않도록 할 수 있다.

sleep을 시작하기 전에 이미 취소된 상태여도 곧바로 `CancellationError`를 던진다.

### Task.sleep 종류

| API | 최소 버전 | 비고 |
|---|---|---|
| `Task.sleep(nanoseconds:)` | iOS 13 | 실무 프로젝트(iOS 15 타깃)에서 사용 가능 |
| `Task.sleep(for:)` | iOS 16 | `.milliseconds(300)`처럼 `Duration`으로 표현 |
| `Task.sleep(until:clock:)` | iOS 16 | 특정 시각까지 대기 |

모두 스레드를 막지 않고 Task만 중단한다. 취소되면 `CancellationError`를 던지는 점도 같다.

## 3. Cancellation과 결과 반영 전 검증

`Task.cancel()`은 취소 요청일 뿐 강제 종료가 아니다.

특히 API 호출이 이미 시작된 경우 API가 취소에 협력하지 않거나, 취소 요청보다 먼저 응답을 반환할 수 있다.

따라서 API 응답을 받은 뒤 결과를 반영하기 전에 취소 여부를 확인한다.

```swift
let products = try await API.searchProducts(
    keyword: keyword
)

try Task.checkCancellation()

self.products = products
```

`Task.checkCancellation()`은 현재 Task가 취소된 상태라면 `CancellationError`를 발생시킨다.

이를 통해 취소된 요청의 결과가 반영되는 것을 방지할 수 있다.

### 실무에서

취소가 어느 시점에 걸리느냐에 따라 들어가는 `catch`가 다르다.

| 취소 시점 | 던지는 곳 | 오류 | 들어가는 catch |
|---|---|---|---|
| Debounce 대기 중 | `Task.sleep` | `CancellationError` | `catch is CancellationError` |
| API 요청 중 | URLSession | `URLError(.cancelled)` | 두 번째 `catch` |
| 응답 받은 직후 | `Task.checkCancellation()` | `CancellationError` | `catch is CancellationError` |

API 요청 중에 취소되면 두 번째 `catch`로 간다. 그래도 7장 코드에서 오류 메시지가 뜨지 않는 이유는 그 `catch`에도 Request ID 검사가 있기 때문이다.

이 코드에서는 취소가 항상 새 `search()` 호출과 함께 일어나고, 그때 ID도 바뀐다. 그래서 "취소된 요청 = ID가 바뀐 요청"이 되어, ID 검사가 `URLError.cancelled`까지 걸러 준다.

증상: 두 번째 `catch`의 ID 검사를 빼면, 빠르게 타이핑할 때 "취소됨(cancelled)" 에러 문구가 잠깐 깜박인다.

## 4. Request ID를 이용한 최신 요청 검증

취소 여부 확인과 별개로, 요청의 최신 여부도 검증할 필요가 있다.

각 요청에 고유한 ID를 부여한다.

```swift
private var currentRequestID = UUID()
```

새로운 검색 요청이 시작되면 ID를 갱신한다.

```swift
let requestID = UUID()
currentRequestID = requestID
```

API 응답을 받은 뒤 현재 요청 ID와 비교한다.

```swift
guard currentRequestID == requestID else {
    return
}
```

### Cancellation과 Request ID의 역할

| 구분 | 역할 |
|---|---|
| Cancellation | 불필요한 작업의 중단을 요청 |
| Request ID | 오래된 요청이 최신 상태를 변경하지 못하도록 방어 |

Cancellation은 작업을 중단시키기 위한 수단이고, Request ID는 결과가 현재 유효한 요청에서 왔는지 확인하기 위한 수단이다.

두 가지를 함께 사용하면 더욱 안전하게 최신 요청만 반영할 수 있다.

## 5. defer를 이용한 Task 정리

Task가 종료될 때 `defer`를 이용해 상태를 정리할 수 있다.

다만 이전 Task가 늦게 종료되어 최신 Task의 상태를 변경하지 않도록 요청 ID를 확인해야 한다.

```swift
defer {
    if currentRequestID == requestID {
        isLoading = false
        searchTask = nil
    }
}
```

`defer`는 현재 스코프를 벗어나기 직전에 실행된다.

이때 최신 요청만 자신의 `isLoading`과 `searchTask`를 정리하도록 해야 한다.

```
"Sw" Task 진행 중 → "Swi" 입력 → isLoading = true, 새 Task 시작
"Sw" Task 늦게 종료 → defer
   ID 검사 없음: isLoading = false  ← "Swi"가 아직 로딩 중인데 스피너가 꺼짐
   ID 검사 있음: 아무것도 안 함
```

## 6. 검색어가 비어 있는 경우

검색어가 비어 있다면 API를 호출할 필요가 없다.

이때 기존 Task를 취소하고 기존 요청 ID를 무효화한 다음 화면 상태를 정리한다.

```swift
func search(keyword: String) {
    searchTask?.cancel()

    let requestID = UUID()
    currentRequestID = requestID

    guard !keyword.isEmpty else {
        products = []
        isLoading = false
        errorMessage = nil
        searchTask = nil
        return
    }

    // 새로운 검색 Task 실행
}
```

요청 ID를 먼저 갱신하는 이유는 기존 Task가 취소에 협력하지 않고 늦게 종료되더라도 이전 요청의 결과나 정리 로직이 현재 상태에 영향을 주지 못하도록 하기 위해서다.

```
"S" 검색 중 → 전부 지움("")
 → ID 갱신 → products = []
 → "S" 응답 늦게 도착 → ID 불일치 → 반영 안 함 (빈 화면 유지)
```

### 실무에서

- 공백만 입력한 경우도 빈 검색어로 볼지 정한다. 보통 `keyword.trimmingCharacters(in: .whitespacesAndNewlines)`로 정리한 뒤 비교한다
- 같은 검색어가 연달아 들어오는 경우(예: "Swift" → "Swif" → "Swift"가 300ms 안에 일어남)는 Debounce 덕분에 한 번만 호출된다. 하지만 이미 표시 중인 결과와 같은 검색어로 다시 호출되는 것까지 막으려면 마지막으로 검색한 키워드를 저장해 비교해야 한다

## 7. 통합 코드

```swift
import Foundation

@MainActor
final class SearchViewModel {

    private var searchTask: Task<Void, Never>?

    private(set) var isLoading = false
    private(set) var products: [Product] = []
    private(set) var errorMessage: String?

    private var currentRequestID = UUID()

    func search(keyword: String) {
        // 1. 기존 작업 취소
        searchTask?.cancel()

        // 2. 새로운 요청 ID 발급
        let requestID = UUID()
        currentRequestID = requestID

        // 3. 빈 검색어 처리
        guard !keyword.isEmpty else {
            products = []
            isLoading = false
            errorMessage = nil
            searchTask = nil
            return
        }

        // 4. 새로운 요청 상태 설정
        errorMessage = nil
        isLoading = true

        // 5. 새로운 Task 시작
        searchTask = Task {
            defer {
                // 최신 요청만 상태 정리
                if self.currentRequestID == requestID {
                    self.isLoading = false
                    self.searchTask = nil
                }
            }

            do {
                // 6. Debounce
                try await Task.sleep(
                    nanoseconds: 300_000_000
                )

                // 7. API 호출
                let products = try await API.searchProducts(
                    keyword: keyword
                )

                // 8. 취소 여부 확인
                try Task.checkCancellation()

                // 9. 최신 요청인지 확인
                guard self.currentRequestID == requestID else {
                    return
                }

                // 10. 결과 반영
                self.products = products

            } catch is CancellationError {
                // 새로운 입력으로 기존 작업 취소

            } catch {
                // 최신 요청의 오류만 반영
                guard self.currentRequestID == requestID else {
                    return
                }

                self.errorMessage = error.localizedDescription
            }
        }
    }
}
```

이 코드는 동시성 문제를 이해하기 위한 학습용 구현이다. 실제 프로젝트에서는 API의 취소 협력 여부, Task의 생명주기, `self`의 강한 캡처로 인한 순환 참조 가능성 등을 추가로 검토해야 한다.

### 실무에서

- **로딩 표시 시점.** `isLoading = true`가 Debounce 전에 설정되므로, 실제 요청이 나가기 전 300ms 동안에도 스피너가 돈다. 타이핑하는 내내 스피너가 보이는 게 싫다면 sleep 이후(API 호출 직전)에 `isLoading = true`를 두는 방법도 있다. 이건 UX 정책이다
- **순환 참조.** 이 Task는 sleep + 요청 한 번으로 끝나므로, 실행이 끝나면 클로저를 놓아 순환이 풀린다. 다만 화면을 나간 뒤에도 300ms + 응답 시간 동안은 ViewModel이 살아 있다. 즉시 정리하려면 화면 이탈 시 `searchTask?.cancel()`을 호출한다
- 디버깅 포인트: `search()`와 API 호출 직전에 로그를 찍고 "Swift"를 빠르게 입력해 본다. `search()`는 5번, API는 1번 찍혀야 정상이다

## 8. 추가로 이해해야 할 개념

### Task Handle 정리와 Task 종료

```swift
searchTask = nil
```

Task Handle을 `nil`로 변경하는 것은 참조를 정리하는 동작이다.

실행 중인 Task를 취소하는 동작은 아니므로, 취소가 필요하다면 먼저 `cancel()`을 호출해야 한다.

또한 Task가 종료되었다고 해서 프로퍼티에 저장된 Task Handle이 자동으로 `nil`이 되지는 않는다.

### @MainActor와 await

`@MainActor`로 격리된 ViewModel에서 `Task {}`를 생성하면 생성 문맥의 MainActor 격리를 상속한다.

네트워크 요청을 `await`하는 동안 MainActor가 차단되는 것은 아니다.

다만 `await` 이후에는 다른 MainActor 작업이 실행되었을 수 있으므로, 최신 요청인지 다시 확인하는 것이 중요하다.

반대로 `await`가 없는 동기 코드 구간에서는 다른 MainActor 작업이 중간에 끼어들지 않는다.

```
MainActor 위에서의 실행 순서

[search("Sw")]  cancel → ID = b → isLoading = true → Task 생성
[Task "S"]      ... await API (중단, MainActor 놓음)
[search("Swi")] cancel → ID = c → ...              ← await 사이에 끼어든 작업
[Task "S"]      재개 → checkCancellation / ID 검사 → 반영 안 함
```

`search()` 본문과 "응답 후 검사 → 반영" 구간에는 `await`가 없다. 그래서 각각 한 덩어리로 실행되고, 검사와 반영 사이에 ID가 바뀌는 일이 없다.

### UI 상태 관리

- 새 검색이 시작되면 `isLoading = true`
- 새로운 요청이 시작되면 `errorMessage = nil`
- 이전 검색 결과를 유지할지 지울지는 UX 정책에 따라 결정
- 최신 요청이 종료되면 `isLoading = false`
- 오류가 발생하면 최신 요청의 오류만 `errorMessage`에 반영

실제 SwiftUI 화면에서 상태 변경을 관찰하려면 `@Observable` 또는 `ObservableObject` 등 적절한 관찰 구조가 필요하다.

`@Observable`은 iOS 17+이다. iOS 15 타깃이면 `ObservableObject` + `@Published`를 쓴다.

### Debounce를 구현하는 다른 방법

| 방법 | 최소 버전 | 특징 |
|---|---|---|
| `Task` + `Task.sleep` (이 문서) | iOS 13 | 의존성 없음. 취소·검증을 직접 관리 |
| SwiftUI `.task(id:)` + `Task.sleep` | iOS 15 | 검색어가 바뀌면 SwiftUI가 이전 작업을 취소. Handle 관리 불필요 |
| Combine `debounce(for:scheduler:)` | iOS 13 | 기존 Combine 코드베이스에 자연스러움 |
| Swift Async Algorithms `debounce(for:)` | iOS 16 (`Clock` 사용) | AsyncSequence 연산자. 별도 패키지 |

SwiftUI에서는 `.task(id:)`를 쓰면 코드가 짧아진다.

```swift
.task(id: keyword) {
    do {
        try await Task.sleep(nanoseconds: 300_000_000)  // 입력이 바뀌면 여기서 취소됨
        await viewModel.loadProducts(keyword: keyword)  // Debounce 없는 async 함수
    } catch {
        // CancellationError — 다음 입력이 들어옴
    }
}
```

단, `.task(id:)`가 해 주는 것은 취소 요청까지다. 결과 반영 전 검증은 여전히 ViewModel의 몫이다.

## 핵심 정리

- Debounce는 일정 시간 동안 추가 입력이 없을 때 작업을 실행하는 방식이다.
- `Task.sleep()`을 이용해 Debounce를 구현할 수 있다.
- `Task.sleep()`은 cancellation-aware API이므로 취소 시 `CancellationError`가 발생한다.
- `cancel()`은 협력적 취소 요청이며 강제 종료가 아니다.
- API 응답 이후 `Task.checkCancellation()`으로 취소 여부를 확인할 수 있다.
- Request ID를 이용해 오래된 요청의 결과 반영을 방지할 수 있다.
- Cancellation은 작업 중단을 위한 수단이고 Request ID는 결과 유효성 검증을 위한 수단이다.
- `defer`를 이용한 정리 작업도 최신 요청인지 확인해야 한다.
- `searchTask = nil`은 Task 취소가 아니라 Handle 참조 정리다.
- `@MainActor`에서 `await` 이후에는 상태가 변경되었을 수 있으므로 필요한 경우 재검증해야 한다.
- 취소 시점에 따라 오류 종류가 다르다. 요청 중 취소는 `URLError.cancelled`로 오므로, `catch`의 Request ID 검사가 이를 걸러 준다.
- SwiftUI에서는 `.task(id:)` + `Task.sleep`으로 같은 Debounce를 더 짧게 구현할 수 있다.

## 참고 자료

**공식**

- [Swift — Task.sleep(nanoseconds:)](https://developer.apple.com/documentation/swift/task/sleep(nanoseconds:)) — 취소 시 CancellationError, 스레드를 막지 않음
- [Swift — Task.sleep(until:tolerance:clock:)](https://developer.apple.com/documentation/swift/task/sleep(until:tolerance:clock:)) — iOS 16+
- [Swift — Task.checkCancellation()](https://developer.apple.com/documentation/swift/task/checkcancellation())
- [SwiftUI — task(id:priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)) — id가 바뀌면 취소 후 재시작, iOS 15+
- [Combine — debounce(for:scheduler:options:)](https://developer.apple.com/documentation/combine/publisher/debounce(for:scheduler:options:))
- [Swift Async Algorithms — Debounce 가이드](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Debounce.md)
- [WWDC22 — Meet Swift Async Algorithms](https://developer.apple.com/videos/play/wwdc2022/110355)

**외부**

- [Hacking with Swift — How to make a task sleep](https://www.hackingwithswift.com/books/concurrency/how-to-make-a-task-sleep) — sleep은 "최소" 시간만 보장
- [Ole Begemann — Cancellation can come in many forms (2022)](https://oleb.net/2022/cancellation-forms/) — URLSession은 URLError.cancelled를 던짐
- [Swift Forums — CancellationError (2022)](https://forums.swift.org/t/cancellationerror/60009) — 요청 중 취소 시 NSURLErrorDomain -999
