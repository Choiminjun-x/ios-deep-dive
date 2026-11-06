# Swift Concurrency 실전 3 — 화면 이탈과 비동기 작업

> 작성일: 2026-11-06

## 1. 문제 상황

상품 목록 화면에 진입하면 상품 API를 호출한다고 가정한다.

```swift
struct ProductListView: View {
    @State private var products: [Product] = []

    var body: some View {
        List(products) { product in
            Text(product.name)
        }
        .task {
            let products = try? await API.fetchProducts()
            self.products = products ?? []
        }
    }
}
```

여기서 고려해야 할 상황은 다음과 같다.

- 사용자가 API 응답 전에 화면을 이탈한다.
- 화면 이탈 후에도 API 요청이 계속 실행된다.
- 이전 요청이 늦게 완료되어 새로운 화면의 상태를 변경한다.
- 여러 API를 동시에 호출해야 한다.
- 한 API가 실패해도 다른 API의 결과는 사용하고 싶다.

이 코드는 `try?`로 오류를 `nil`로 바꾸므로, 실패와 취소가 모두 "빈 목록"으로 보인다. 화면 이탈로 취소된 경우에도 `products = []`가 실행된다.

### 실전 1·2와 달라진 점

| 구분 | 실전 1·2 | 실전 3 |
|---|---|---|
| 작업 생성 | ViewModel에서 `Task {}` | SwiftUI `.task` |
| 취소 주체 | 개발자 (`cancel()`) | SwiftUI (화면 이탈) |
| Handle 관리 | 직접 보관·정리 | 필요 없음 |
| 새 주제 | — | `async let` 병렬 호출, 부분 성공 |

## 2. `.task`와 View 생명주기

SwiftUI의 `.task`는 View의 생명주기에 연결된 비동기 작업을 실행한다.

```swift
.task {
    do {
        let products = try await API.fetchProducts()
        self.products = products
    } catch {
        // 오류 처리
    }
}
```

`.task`의 클로저는 오류를 던질 수 없는 `async` 클로저다. 그래서 `try`를 쓰려면 `do-catch`나 `try?`로 감싸야 한다.

화면이 사라지거나 해당 View의 Task가 더 이상 필요하지 않게 되면 SwiftUI는 Task에 취소를 요청한다.

중요한 점은 `.task`가 취소를 요청한다고 해서 작업이 즉시 강제 종료되는 것은 아니라는 것이다.

Swift Concurrency의 취소는 **협력적 취소(Cooperative Cancellation)** 방식이다.

즉, 실행 중인 작업이 취소 상태를 확인하고 스스로 종료해야 한다.

```
화면 진입 (onAppear 시점) → .task 시작
화면 이탈 (뷰 제거 또는 identity 변경)
 → SwiftUI가 Task에 cancel() 요청  ← "이탈 후 어느 시점에" (Apple 문서 표현)
 → 작업이 취소를 확인하는 지점에서만 멈춤
```

### Task 취소와 API 요청 취소

Task 취소와 실제 네트워크 요청 취소는 구분해야 한다.

- Task 취소: 현재 비동기 작업에 취소가 요청된 상태
- 네트워크 요청 취소: 실제 네트워크 요청이 중단된 상태

API가 취소에 협력해야 실제 네트워크 요청도 취소될 수 있다.

예를 들어 `URLSession`의 `data(for:)`와 같은 async API는 Task 취소에 협력한다.

반면 취소에 협력하지 않는 API라면 Task가 취소된 후에도 API 응답을 기다릴 수 있다.

| API 종류 | Task 취소 시 |
|---|---|
| `URLSession.data(for:)` 등 async API | 요청을 끊고 `URLError(.cancelled)`를 던짐 |
| `Task.sleep` | 즉시 `CancellationError`를 던짐 |
| Continuation으로 감싼 콜백 API (취소 처리 없음) | 응답이 올 때까지 계속 기다림 |
| Continuation + `withTaskCancellationHandler` | 직접 구현한 대로 취소 |

마지막 두 줄이 [Continuation](05_continuation.md)에서 다룬 내용이다. 직접 감싼 API는 취소 처리를 넣지 않으면 취소에 협력하지 않는다.

## 3. API 응답 후 취소 여부 확인

API가 취소에 협력하지 않거나 응답이 취소 요청보다 먼저 도착하는 상황을 고려해야 한다.

따라서 결과를 UI에 반영하기 전에 취소 여부를 한 번 더 확인할 수 있다.

```swift
.task {
    do {
        let products = try await API.fetchProducts()

        try Task.checkCancellation()

        self.products = products

    } catch is CancellationError {
        return
    } catch {
        print(error)
    }
}
```

`Task.checkCancellation()`은 현재 Task의 취소 상태를 확인한다.

취소된 상태라면 `CancellationError`를 발생시킨다.

주의할 점은 `Task.checkCancellation()`이 이미 실행 중인 API 요청 자체를 취소하는 기능은 아니라는 것이다.

API 호출 중 취소를 반영하는 것은 API 구현 또는 사용하는 비동기 API의 취소 협력에 달려 있다.

### 실무에서

`API.fetchProducts()`가 URLSession 기반이라면, 요청 도중 화면을 나갈 때 오는 오류는 `CancellationError`가 아니라 `URLError(.cancelled)`다. 그래서 두 번째 `catch`로 가서 `print(error)`가 찍힌다.

실전 1·2와 달리 여기에는 Request ID가 없어서 걸러지지 않는다. 오류를 화면에 표시하는 코드라면 "화면을 나가는 순간 에러 알럿"이 뜨는 증상이 된다.

```swift
} catch {
    guard !Task.isCancelled else { return }   // 취소는 오류로 보지 않음
    errorMessage = error.localizedDescription
}
```

## 4. 화면 재진입과 이전 Task

화면을 이탈했다가 다시 진입하면 새로운 `.task`가 실행된다.

이때 이전 Task와 새 Task는 서로 독립적이다.

예를 들어 다음 상황이 발생할 수 있다.

1. 화면 진입 → Task A 실행
2. 화면 이탈 → Task A 취소 요청
3. 화면 재진입 → Task B 실행
4. Task A의 API가 취소에 협력하지 않아 늦게 응답
5. Task A가 오래된 결과를 반영하려고 시도

이런 상황에서는 취소 여부 확인과 요청 식별자를 활용할 수 있다.

다만 모든 `.task`에 Request ID가 필요한 것은 아니다. 여러 요청이 같은 상태를 변경할 수 있는 구조에서 특히 유용하다.

### 상태가 어디에 있느냐에 따라 다르다

5번이 실제로 문제가 되는지는 Task A와 Task B가 **같은 상태**를 바라보는지에 달려 있다.

| 상태 위치 | 재진입 시 | Task A의 늦은 반영 |
|---|---|---|
| 화면 View의 `@State` (뷰가 제거됐다 새로 생성) | 새 `@State` 저장소가 생김 | 사라진 이전 저장소에 쓰므로 새 화면에 영향 없음 |
| 상위 View나 외부에서 주입한 ViewModel | 같은 ViewModel을 다시 씀 | 새 화면의 상태를 덮어쓸 수 있음 |
| `TabView` 탭 전환처럼 뷰가 유지되는 경우 | 같은 `@State`, `.task`만 다시 실행 | 덮어쓸 수 있음 |

그래서 "여러 요청이 같은 상태를 변경할 수 있는 구조"란 주로 상태가 View보다 오래 사는 구조다.

**Cancellation과 Request ID의 역할**

| 구분 | 역할 |
|---|---|
| Cancellation | 더 이상 필요하지 않은 작업을 중단하도록 요청 |
| Request ID | 현재 유효한 요청인지 확인하여 오래된 결과의 상태 변경 방지 |

두 가지는 목적이 다르므로 함께 사용할 수 있다.

### 실무에서

- 디버깅 포인트: `.task` 시작과 끝, 결과 반영 직전에 로그를 찍는다. 그 상태에서 화면 진입 → 즉시 뒤로 → 다시 진입을 반복해 본다. 취소된 Task A의 "결과 반영" 로그가 Task B보다 늦게 찍히면 덮어쓰기 위험이 있다
- Network Link Conditioner로 느린 네트워크를 만들면 재현하기 쉽다

## 5. 화면에 종속된 작업은 `.task` 활용

화면에 종속된 작업이라면 별도의 `Task {}`를 생성하기보다 `.task`를 사용하는 것이 적절하다.

```swift
// 이탈해도 취소되지 않음
.onAppear {
    Task {
        products = (try? await API.fetchProducts()) ?? []
    }
}

// 이탈하면 취소 요청됨
.task {
    products = (try? await API.fetchProducts()) ?? []
}
```

`Task {}`는 Unstructured Task이므로 개발자가 생명주기를 직접 관리해야 한다.

반면 `.task`는 SwiftUI View의 생명주기와 연결되어 화면이 사라질 때 취소 요청을 받을 수 있다.

화면과 무관하게 계속 실행되어야 하는 작업이라면 별도의 생명주기 설계가 필요하다.

| 작업 | 어디서 실행 |
|---|---|
| 화면에 보여 줄 데이터 조회 | `.task` |
| 입력값이 바뀔 때마다 다시 조회 | `.task(id:)` ([실전 2](08_swift-concurrency-practice-02.md)) |
| 버튼 탭으로 시작하는 일회성 작업 | `Task {}` + Handle 관리 ([실전 1](07_swift-concurrency-practice-01.md)) |
| 화면을 나가도 끝나야 하는 작업 (업로드, 결제) | 화면보다 오래 사는 객체(서비스·매니저)가 소유 |

## 6. 여러 API를 동시에 호출하기

상품 API와 추천 API가 서로 독립적이라면 순차적으로 호출할 필요가 없다.

`async let`을 활용하면 여러 비동기 작업을 동시에 시작할 수 있다.

```swift
.task {
    do {
        async let products = API.fetchProducts()
        async let recommendations = API.fetchRecommendations()

        let result = try await (products, recommendations)

        try Task.checkCancellation()

        self.products = result.0
        self.recommendations = result.1

    } catch {
        print(error)
    }
}
```

```
순차 호출:   [ 상품 1.0s ][ 추천 0.8s ]          → 1.8s
async let:   [ 상품 1.0s ]
             [ 추천 0.8s ]                        → 1.0s (가장 느린 쪽)
```

### `async let`의 특징

- 여러 독립적인 비동기 작업을 동시에 시작한다.
- 결과를 사용할 때 `await`으로 기다린다.
- 부모 Task의 취소가 자식 Task에 전파된다.
- 부모 Task는 자식 Task의 완료를 기다리는 구조다.
- `await`하지 않은 채 선언된 스코프를 벗어나면, 자식 Task는 자동으로 취소되고 끝날 때까지 기다린 뒤에 스코프를 빠져나간다.

`let result = try await (products, recommendations)`는 두 작업의 결과를 튜플로 받는다.

따라서 두 작업이 모두 완료되어야 다음 코드로 진행한다.

`.task`가 취소되면 이 부모 Task의 취소가 두 자식에게 전파된다. 그래서 화면을 나가면 두 요청이 모두 취소 요청을 받는다.

### 오류 발생 시 동작

이 코드에서는 두 API 중 하나라도 실패하면 오류가 발생한다.

오류가 던져져 `async let`이 선언된 스코프를 벗어나면, 아직 기다리지 않은 다른 자식 Task에는 취소가 전파된다.

반대로 각 자식의 오류를 부모가 개별적으로 `catch`하면 부모 Task는 계속 실행할 수 있다.

### 실무에서 — 튜플 await는 왼쪽부터 기다린다

`try await (products, recommendations)`는 두 결과를 "먼저 끝난 순서"가 아니라 **왼쪽부터 순서대로** 기다린다.

```
try await (a, b)  ≈  let x = try await a
                     let y = try await b

경우 1: a가 먼저 실패 → 바로 throw → 스코프 탈출 → b 취소
경우 2: b가 먼저 실패 → a가 끝날 때까지 기다림 → 그다음 b의 오류 확인 → throw
```

증상: 추천 API가 0.1초 만에 실패했는데, 상품 API(3초)가 끝날 때까지 에러 처리가 늦어진다. 그동안 상품 요청은 취소되지 않고 계속 진행된다.

먼저 실패한 쪽에서 바로 나머지를 취소해야 한다면 `withThrowingTaskGroup`을 쓴다. 태스크 그룹은 끝난 순서대로 결과를 받는다. 대부분의 화면 조회에서는 튜플 방식으로 충분하다.

## 7. 부분 성공 처리하기

실제 서비스에서는 모든 API가 반드시 성공해야 하는 것은 아니다.

예를 들어 다음과 같은 UX를 고려할 수 있다.

- 상품 API 성공 → 상품 목록 표시
- 추천 API 실패 → 추천 영역만 표시하지 않음
- 상품 API 실패 → 상품 영역만 표시하지 않음

이런 경우 각 API의 성공과 실패를 독립적으로 처리해야 한다.

`Result`를 활용하면 성공과 실패를 값으로 표현할 수 있다.

### 7-1. API 오류를 Result로 변환

```swift
func fetchProducts() async -> Result<[Product], Error> {
    do {
        let products = try await API.fetchProducts()
        return .success(products)
    } catch {
        return .failure(error)
    }
}

func fetchRecommendations() async -> Result<[Recommendation], Error> {
    do {
        let recommendations = try await API.fetchRecommendations()
        return .success(recommendations)
    } catch {
        return .failure(error)
    }
}
```

각 함수는 API 오류를 외부로 던지는 대신 `Result.failure`로 반환한다.

따라서 이 함수 자체는 오류를 던지지 않는 비동기 함수가 된다.

표준 라이브러리의 `Result(catching:)`는 동기 클로저만 받는다. 그래서 async 함수는 위처럼 `do-catch`로 직접 감싼다.

### 7-2. async let으로 병렬 실행

```swift
.task {
    async let productsResult = fetchProducts()
    async let recommendationsResult = fetchRecommendations()

    let (products, recommendations) = await (
        productsResult,
        recommendationsResult
    )

    switch products {
    case .success(let value):
        self.products = value

    case .failure(let error):
        print("상품 API 실패: \(error)")
    }

    switch recommendations {
    case .success(let value):
        self.recommendations = value

    case .failure(let error):
        print("추천 API 실패: \(error)")
    }
}
```

이 구조에서는 각 API의 실패가 `Result.failure`라는 값으로 전달된다.

따라서 한쪽 API가 실패해도 다른 API의 결과를 정상적으로 처리할 수 있다.

```
상품 ── success ──→ products 반영
추천 ── failure ──→ 추천 영역 숨김     (서로 영향 없음)
```

이 방식에서는 자식이 오류를 던지지 않는다. 그래서 6장과 달리 한쪽이 실패해도 다른 쪽이 취소되지 않고 끝까지 실행된다. 부분 성공에서는 그게 의도한 동작이다.

### 실무에서

- **취소도 failure로 들어온다.** 화면을 나가면 두 요청 모두 `.failure(URLError.cancelled)`가 된다. 그래서 "상품 API 실패" 로그가 찍히거나 에러 UI가 뜰 수 있다. `switch` 전에 `guard !Task.isCancelled else { return }`를 두면 취소와 실패를 구분할 수 있다
- 화면에 보여 줄 때는 "실패"와 "아직 로딩 중"을 구분해야 한다. 영역별 상태를 `enum LoadState { case loading, loaded([T]), failed }`처럼 두면 `Result`를 그대로 옮기기 쉽다

### 핵심 비교

| 방식 | 적합한 상황 |
|---|---|
| `try await (a, b)` | 두 작업이 모두 성공해야 하는 경우 |
| 각각의 `do-catch` | 각 작업의 오류를 독립적으로 처리하고 싶은 경우 |
| `Result` + `async let` | 각 작업의 성공과 실패를 값으로 받아 부분 성공을 허용하는 경우 |
| `withThrowingTaskGroup` | 먼저 실패한 쪽에서 즉시 나머지를 취소해야 하거나, 작업 개수가 동적인 경우 |

모든 `async let`에 `Result`가 필요한 것은 아니다. 서비스의 요구사항과 오류 처리 정책에 따라 선택한다.

## 핵심 정리

1. SwiftUI `.task`는 View 생명주기에 연결되어 있으며 화면 이탈 시 취소 요청을 받는다.
2. Task 취소는 협력적 취소이므로 즉시 강제 종료되는 것은 아니다.
3. `Task.checkCancellation()`은 현재 Task의 취소 상태를 확인하고, 취소됐다면 `CancellationError`를 던진다.
4. API가 취소에 협력하지 않으면 취소 요청 이후에도 응답이 도착할 수 있다.
5. 화면 재진입 시 이전 Task와 새 Task는 서로 독립적이다.
6. Cancellation은 불필요한 작업의 중단을 요청하고, Request ID는 오래된 결과의 반영을 방지한다.
7. 화면에 종속된 작업은 `.task`를 활용하는 것이 적절하다.
8. 독립적인 여러 API를 동시에 호출할 때는 `async let`을 활용할 수 있다.
9. 모든 API의 성공이 필요한 경우와 부분 성공을 허용하는 경우의 오류 처리 방식은 다르다.
10. 부분 성공을 허용한다면 `Result`로 각 작업의 성공과 실패를 독립적으로 표현할 수 있다.
11. 재진입 시 덮어쓰기가 문제 되는 건 상태가 View보다 오래 사는 경우(주입된 ViewModel, 탭 전환 등)다.
12. `try await (a, b)`는 왼쪽부터 기다리므로, 오른쪽이 먼저 실패해도 왼쪽이 끝나야 오류를 알 수 있다.
13. 화면 이탈로 인한 취소는 `URLError.cancelled`나 `Result.failure`로 들어올 수 있으므로 `Task.isCancelled`로 실패와 구분한다.

## 참고 자료

**공식**

- [SwiftUI — task(priority:_:)](https://developer.apple.com/documentation/swiftui/view/task(priority:_:)) — 뷰 제거·identity 변경 시 취소, "이탈 후 어느 시점에" 취소
- [Swift — Task.checkCancellation()](https://developer.apple.com/documentation/swift/task/checkcancellation())
- [Swift — withThrowingTaskGroup](https://developer.apple.com/documentation/swift/withthrowingtaskgroup(of:returning:body:))
- [WWDC21 — Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134) — async let, 취소 전파
- [SE-0317 async let bindings](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0317-async-let.md) — 스코프를 벗어날 때 암시적 취소·대기
- [Apple Developer Forums — The order matters for concurrent bindings with a tuple syntax](https://developer.apple.com/forums/thread/700777) — 튜플 await 순서에 따른 취소 차이

**외부**

- [Swift Forums — Async let cancellation - Bug? (confused) (2021)](https://forums.swift.org/t/async-let-cancellation-bug-confused/51384) — `try await a + b`가 왼쪽부터 기다리는 이유
- [Swift Forums — What is the idiomatic way to running two async methods in parallel?](https://forums.swift.org/t/what-is-the-idiomatic-way-to-running-two-async-methods-in-parallel/53952) — 튜플 await는 하나씩 기다림
- [Swift Forums — Question for Implicit async let awaiting (2024)](https://forums.swift.org/t/question-for-implicit-async-let-awaiting/72854) — 스코프 탈출 시 취소 후 대기
- [Ole Begemann — Cancellation can come in many forms (2022)](https://oleb.net/2022/cancellation-forms/) — URLSession 취소 오류
- [Antoine van der Lee — Calling async functions in parallel using async let](https://course-lessons.avanderlee.com/swift-concurrency/asyncawait-basics/calling-async-functions-in-parallel-using-async-let)
