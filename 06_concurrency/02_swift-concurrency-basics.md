# Swift Concurrency 기본

> 작성일: 2026-11-03

## 큰 그림

```
async 함수 호출
 → await 지점에서 중단될 수 있음 (스레드를 막지 않음)
 → 누가 실행하나: Task
      ├ Structured   async let, TaskGroup → 부모가 자식을 기다리고, 취소가 전파됨
      └ Unstructured Task { }, Task.detached → 생명주기·취소를 직접 관리
 → 어디서 실행하나: 격리(isolation)
      ├ actor / @MainActor → 상태를 보호, 밖에서 들어올 땐 await
      └ nonisolated        → 격리 영역 밖
```

`async`는 "중단될 수 있다"만 말하고, 어느 스레드에서 도는지는 격리가 정한다.

## 1. Swift Concurrency란?

Swift Concurrency는 비동기 작업을 중단하고 재개하는 기능과 여러 작업을 효율적으로 관리할 수 있는 동시성 프로그래밍 모델을 제공한다.

주요 목적은 다음과 같다.

- 비동기 작업을 간결하게 표현
- 여러 작업의 동시 실행 관리
- 작업의 생명주기와 취소 관리
- 공유 상태에 대한 동시 접근 보호
- 컴파일러를 통한 동시성 안전성 검사

### 주요 키워드

| 키워드 | 설명 |
|---|---|
| `async` | 함수가 비동기적으로 실행될 수 있음을 나타냄 |
| `await` | 비동기 작업의 결과를 기다리는 지점을 나타냄 |
| `Task` | 새로운 비동기 작업을 생성 |
| `actor` | 격리된 상태에 대한 동시 접근을 관리 |
| `@MainActor` | 메인 액터에 코드와 상태를 격리 |
| `nonisolated` | Actor의 격리 영역에 속하지 않는 선언을 나타냄 |

```swift
func fetchProfile() async {
    let profile = await loadProfile()
    print(profile)
}

Task {
    await fetchProfile()
}
```

**주의 사항**

- `async`가 반드시 백그라운드 스레드 실행을 의미하지는 않는다.
- `await`는 현재 Task가 중단될 수 있는 지점이다. 반드시 실제 suspension이 발생하는 것은 아니다.
- `Task`를 사용했다고 반드시 새로운 스레드가 생성되는 것은 아니다.
- Task와 Thread는 서로 다른 개념이다.
- async 함수를 호출한다고 새 Task가 생기지는 않는다. 호출한 쪽의 Task 안에서 실행된다.

## 2. Structured Concurrency

부모 작업과 자식 작업의 관계를 구조적으로 관리하는 동시성 모델이다.

주요 특징:

- 부모 작업의 구조 안에서 자식 작업을 생성한다.
- 부모와 자식 Task 사이에 구조적인 생명주기 관계가 형성된다.
- 부모 작업은 자식 작업의 완료를 기다린다.
- 부모가 취소되면 자식 작업도 자동으로 취소된다.
- 작업의 시작과 종료 시점을 명확하게 관리할 수 있다.
- 자식 작업은 부모의 우선순위와 Task-local 값을 상속한다.

주요 API:

- `async let`
- `withTaskGroup`
- `withThrowingTaskGroup`

### async let

여러 비동기 작업을 독립적으로 시작하고 결과를 기다릴 수 있다.

```swift
func loadDashboard() async {
    async let user = fetchUser()
    async let posts = fetchPosts()

    let result = await (user, posts)

    print(result)
}
```

실행 흐름:

1. `fetchUser()`와 `fetchPosts()`를 각각 자식 작업으로 시작한다.
2. 두 작업은 서로 독립적으로 진행될 수 있다.
3. `await (user, posts)`에서 두 작업의 결과를 기다린다.
4. 두 자식 작업은 부모 작업의 생명주기 안에서 관리된다.

즉, 독립적인 `Task` 두 개를 생성하는 것과 달리 부모 작업이 자식 작업의 생명주기를 구조적으로 관리할 수 있다.

### 스코프를 벗어날 때

| | `async let` | TaskGroup |
|---|---|---|
| await하지 않고 스코프를 벗어나면 | 자식을 취소 표시한 뒤 끝날 때까지 기다림 | 정상 종료 시 취소하지 않고 남은 자식을 기다림 |
| 자식 하나가 에러를 던지면 (throwing) | 그 에러가 부모로 올라갈 때 나머지 자식 취소 | 나머지 자식 취소 |
| 직접 취소 | 없음 | `group.cancelAll()` |

어느 쪽이든 자식이 끝나기 전에 부모 함수가 반환되지는 않는다.

### 실무에서

- `async let`을 선언만 하고 결과를 안 쓰면, 함수가 끝날 때 암묵적 취소 + 대기가 일어난다. "왜 함수가 늦게 끝나지?"의 원인이 될 수 있다
- 독립적인 API 호출 여러 개를 `Task { }` 여러 개로 흩어 놓은 코드는 `async let`이나 TaskGroup으로 바꾸면 취소·에러 처리가 자동으로 묶인다

## 3. Unstructured Concurrency

기존 작업 구조와 별개로 새로운 Task를 생성하는 동시성 모델이다.

주요 특징:

- 부모 Task와 구조적인 생명주기 관계를 맺지 않는다.
- 작업의 취소와 생명주기를 개발자가 별도로 관리해야 하는 부분이 많다.
- 작업을 시작한 함수가 해당 Task의 완료를 자동으로 기다리지 않는다.
- async가 아닌 함수에서도 시작할 수 있다. 동기 코드(버튼 액션 등)에서 비동기 세계로 들어가는 입구다.

주요 API:

- `Task { }`
- `Task.detached { }`

### Task { }와 Task.detached { }의 차이

| 구분 | Task { } | Task.detached { } |
|---|---|---|
| 동시성 유형 | Unstructured | Unstructured |
| Actor 실행 문맥 | 상속할 수 있음 | 상속하지 않음 |
| Task-local 값 | 상속 | 상속하지 않음 |
| 우선순위 | 기본적으로 상속 | 기본적으로 상속하지 않음 |

#### Task { }

생성 위치의 실행 문맥을 상속할 수 있다.

```swift
@MainActor
func screenAction() {
    Task {
        updateUI()
    }
}
```

`screenAction()`이 MainActor에 격리되어 있으므로 생성된 Task도 MainActor 실행 문맥을 상속한다.

따라서 `updateUI()`가 MainActor에 격리된 메서드라면 별도의 `await` 없이 호출할 수 있다.

#### Task.detached { }

생성 위치의 Actor 실행 문맥을 상속하지 않는다.

```swift
@MainActor
func screenAction() {
    Task.detached {
        await updateUI()
    }
}
```

`Task.detached` 내부에서는 MainActor 격리 문맥을 상속하지 않으므로 MainActor에 격리된 메서드를 호출하려면 격리 경계를 고려해야 한다.

**주의 사항**

`Task.detached`가 반드시 백그라운드 스레드에서 실행된다는 의미는 아니다.

일반적인 비동기 작업에 무조건 `Task.detached`를 사용할 필요는 없다. 별도의 실행 문맥이 필요한 이유가 명확할 때 고려하는 것이 좋다.

Apple 문서도 자식 작업 같은 구조적 동시성으로 표현할 수 있다면 detached Task를 쓰지 말라고 권한다. 우선순위·Task-local 상속과 자동 취소를 직접 처리해야 하기 때문이다.

### Structured와 Unstructured 비교

| 구분 | Structured | Unstructured |
|---|---|---|
| 부모·자식 관계 | 구조적으로 형성 | 구조적으로 형성되지 않음 |
| 생명주기 | 구조적으로 관리 | 개발자가 별도 관리 |
| 취소 | 부모 취소 시 자동 | Task 핸들의 `cancel()`로 직접 |
| 대표 API | `async let`, Task Group | `Task`, `Task.detached` |

**중요:** Structured / Unstructured 여부와 실행 문맥 상속 여부는 서로 다른 개념이다.

`Task { }`는 Unstructured Concurrency이지만 생성 위치의 Actor 실행 문맥을 상속할 수 있다.

### 실무에서

- **화면을 나갔는데 네트워크 응답 처리·로그가 계속 찍힌다**: `Task { }`는 화면 생명주기와 무관하게 끝까지 돈다. 핸들(`Task<Void, Never>`)을 프로퍼티에 저장해 두고 화면이 사라질 때 `cancel()`한다
- **같은 요청이 여러 번 나간다**: 버튼 연타마다 새 `Task { }`가 생긴다. 이전 핸들을 취소하거나 진행 중이면 무시한다
- **"백그라운드에서 돌리려고" `Task.detached`를 쓴 코드**: 대부분은 의도가 "MainActor에서 벗어나기"다. Swift 버전에 따라 다른 방법이 있다 (→ 7절 버전 차이)

### 확인 필요

일반 `actor`의 메서드 안에서 만든 `Task { }`가 클로저에서 `self`를 쓰지 않을 때도 그 actor의 격리를 상속하는지. 샘플 프로젝트(Swift 5 · Complete)에서 `Task { }` 안 코드를 컴파일러 진단으로 확인한다.

## 4. Task Cancellation

Swift Concurrency의 취소는 작업을 강제로 종료하는 방식이 아니라, 작업이 취소 요청에 협력하도록 설계된 방식이다.

즉, 취소 요청이 들어왔다고 해서 Task가 즉시 종료되는 것은 아니다.

### Task.checkCancellation()

현재 Task가 취소된 상태인지 확인한다.

```swift
func performWork() async throws {
    for i in 0..<100 {
        try Task.checkCancellation()

        print(i)
    }
}
```

- 현재 Task가 취소된 상태라면 `CancellationError`를 던진다.
- 취소 상태가 아니라면 다음 코드를 실행한다.
- 현재 Task의 취소 상태를 확인하는 것이며 다른 Task의 취소 상태를 확인하는 것은 아니다.
- 에러를 던지지 않고 분기만 하려면 `Task.isCancelled`를 쓴다. 부분 결과를 반환하고 끝내고 싶을 때 쓴다.

### 취소의 전파

Structured Concurrency에서는 부모 Task가 취소되면 자식 Task에도 취소가 전파된다.

다만 취소 전파와 실제 작업 중단은 구분해야 한다.

- 취소 전파: 자식 Task에도 취소 요청이 전달됨.
- 취소 확인: 자식 Task가 취소 상태를 확인함.
- 작업 중단: 자식 Task가 취소에 반응하여 실행을 종료함.

자식 Task가 취소 요청을 받더라도 취소를 확인하거나 취소에 반응하는 API를 사용하지 않는다면 계속 실행될 수 있다.

`Task.sleep`처럼 취소에 반응하는 API도 있으므로 모든 작업에 `Task.checkCancellation()`을 무조건 넣을 필요는 없다.

Unstructured Task(`Task { }`, `Task.detached`)는 이 전파 대상이 아니다. 만든 쪽이 취소돼도 자동으로 취소되지 않는다.

**핵심:** 모든 Task에 취소 확인 코드를 넣는 것이 아니라, 취소 요청에 반응해야 하는 작업에서 취소를 확인하고 적절하게 종료하도록 구현하는 것이다.

### 실무에서

- **화면을 닫았더니 "요청 실패" 알럿이 뜬다**: 취소로 생긴 에러를 일반 실패와 같은 `catch`에서 처리한 경우다. `CancellationError`는 따로 걸러서 무시한다
- **`cancel()`을 불렀는데 작업이 계속 돈다**: 긴 반복문·이미지 처리처럼 중단 지점이 없는 코드에 취소 확인이 없는지 본다

## 5. Actor Isolation

Actor는 자신의 내부 상태에 대한 동시 접근을 막고 상태 접근을 직렬화하는 참조 타입이다.

```swift
actor Counter {
    var count = 0

    func increment() {
        count += 1
    }
}
```

Actor의 주요 특징:

- 내부 상태를 Actor의 격리 규칙으로 보호한다.
- 외부에서는 내부의 격리된 상태에 직접 접근할 수 없다.
- 외부에서 Actor의 격리된 메서드나 프로퍼티에 접근할 때 격리 경계를 고려해야 한다. 동기 메서드라도 밖에서 부르면 `await`가 필요하다.
- Actor 내부에서는 격리된 상태에 접근할 수 있다.

Actor Isolation이 보장하는 것은 Actor가 보호하는 상태에 대한 안전한 접근이지, 여러 비즈니스 로직 단계를 하나의 원자적인 작업으로 만드는 것은 아니다.

### Actor Reentrancy

Actor 내부에서 `await`를 만나 작업이 중단되면 다른 작업이 같은 Actor에서 실행될 수 있는 특성이다.

```swift
actor Inventory {
    var stock = 10

    func purchase(_ quantity: Int) async -> Bool {
        guard stock >= quantity else {
            return false
        }

        await processPayment()

        stock -= quantity
        return true
    }
}
```

두 요청이 각각 `purchase(7)`을 호출한다면 다음과 같은 상황이 발생할 수 있다.

1. 첫 번째 요청이 재고 10을 확인한다.
2. 첫 번째 요청이 결제 과정에서 중단된다.
3. 두 번째 요청도 재고 10을 확인한다.
4. 두 번째 요청도 결제 과정에서 중단된다.
5. 두 요청 모두 결제를 마치고 재고를 차감한다.
6. 최종 재고가 음수가 될 수 있다.

Actor Isolation이 적용되어 있어도 `await` 전후의 여러 단계가 하나의 원자적 작업으로 보장되는 것은 아니다.

Reentrancy를 허용하는 이유는 데드락을 막고 작업이 계속 진행되게 하기 위해서다. 서로를 기다리는 두 actor가 멈추지 않는다.

**관련 개념 구분**

| 개념 | 설명 |
|---|---|
| Actor Isolation | Actor가 보호하는 상태에 대한 동시 접근을 방지 |
| Actor Reentrancy | `await`에서 중단된 동안 다른 작업이 같은 Actor에서 실행될 수 있는 특성 |
| Data Race | 동기화 없이 같은 메모리에 동시에 접근하며 적어도 하나가 쓰기인 문제 |
| Logical Race Condition | 작업 실행 순서나 타이밍으로 인해 비즈니스 로직이 잘못 동작하는 문제 |

Actor Isolation은 Data Race를 방지하는 데 도움을 주지만 Logical Race Condition까지 자동으로 해결하지는 않는다.

### 실무에서

WWDC21 "Protect mutable state with Swift actors"의 가이드는 두 가지다.

- 상태 변경은 동기 코드 안에서 끝낸다
- `await` 뒤에는 상태가 바뀌었을 수 있다고 보고 가정을 다시 확인한다

위 예제라면 확인과 차감을 `await` 앞의 동기 구간에서 함께 처리하고, 결제가 실패하면 되돌린다.

```swift
func purchase(_ quantity: Int) async -> Bool {
    guard stock >= quantity else { return false }
    stock -= quantity                 // await 전에 먼저 차감 (예약)

    let success = await processPayment()
    if !success { stock += quantity } // 실패 시 되돌림
    return success
}
```

- **증상**: 크래시 없이 숫자가 맞지 않는다(재고 음수, 중복 다운로드, 캐시 중복 저장). TSan에도 잡히지 않는다. Data Race가 아니기 때문이다
- **디버깅 포인트**: actor 메서드 안의 `await` 앞뒤로 같은 상태를 읽고 쓰는 곳을 찾는다

## 6. @MainActor

`@MainActor`는 메인 액터에 코드와 상태를 격리하는 역할을 한다.

주요 목적:

- UI와 관련된 상태를 여러 실행 흐름에서 동시에 변경하거나 읽는 상황을 방지한다.
- UI 상태에 대한 일관된 접근 규칙을 유지한다.
- 메인 액터에 격리된 상태와 코드에 대한 접근을 관리한다.

```swift
@MainActor
final class UserViewModel {
    var username = ""

    func updateUsername(_ name: String) {
        username = name
    }
}
```

`UserViewModel`은 MainActor에 격리되어 있다.

따라서 `username`에 접근하거나 `updateUsername()`을 호출할 때 MainActor의 격리 규칙을 따라야 한다. `init()`도 MainActor에 격리되므로 MainActor 밖에서 생성할 때도 `await`가 필요하다.

### @MainActor와 DispatchQueue.main 비교

| 구분 | DispatchQueue.main | @MainActor |
|---|---|---|
| 개념 | 메인 큐에 작업 제출 | 메인 액터에 코드와 상태 격리 |
| 주요 역할 | 작업 실행 순서와 큐 관리 | 격리 규칙과 동시성 안전성 관리 |
| 컴파일러 격리 검사 | 제공하지 않음 | 제공 |

`@MainActor`는 단순히 메인 스레드에서 코드를 실행하기 위한 장치가 아니라, 메인 액터에 격리된 상태와 코드에 대한 접근을 관리하는 동시성 모델의 일부다.

### 실무에서

- `UIViewController`, `UIView`, UIKit 델리게이트 프로토콜은 `@MainActor`로 선언되어 있다. 이 프로토콜을 채택한 클래스도 MainActor로 추론된다. 그래서 테스트 코드 같은 nonisolated async 문맥에서 이런 객체를 만들 때 "expression is 'async' but is not marked with 'await'" 에러를 만난다
- Xcode 26 새 프로젝트는 Default Actor Isolation이 MainActor일 수 있다. 실무 프로젝트는 빌드 설정에서 직접 확인한다 (로드맵 0주차 항목)

## 7. Actor 실행 문맥 상속

`Task { }`는 생성 위치의 Actor 실행 문맥을 상속할 수 있다.

```swift
@MainActor
func example() {
    Task {
        await someAsyncFunction()
        updateUI()
    }
}
```

실행 흐름:

1. `example()`은 MainActor에 격리되어 있다.
2. `Task { }`는 생성 위치의 MainActor 실행 문맥을 상속한다.
3. `await someAsyncFunction()`에서 작업이 중단될 수 있다.
4. 작업이 재개된 이후에도 MainActor 격리 문맥은 유지된다.
5. `updateUI()`도 MainActor의 격리 규칙에 따라 실행된다.

**중요:** `await`는 Actor 격리를 해제하는 키워드가 아니다.

비동기 작업이 중단되고 재개될 수 있음을 나타내는 것이며, 이후 코드의 Actor 격리 규칙이 자동으로 바뀌는 것은 아니다.

### someAsyncFunction()은 어디서 도나 (버전 차이)

Task가 상속한 격리는 Task 클로저 본문에만 적용된다. 클로저가 호출한 nonisolated async 함수가 어디서 도는지는 Swift 버전·설정에 따라 다르다.

| | Swift 5.7 ~ 6.1 (SE-0338) | Swift 6.2+ `NonisolatedNonsendingByDefault` 켬 (SE-0461) |
|---|---|---|
| nonisolated async 함수 | 호출자 actor에서 벗어나 global concurrent executor에서 실행 | 호출자의 actor에서 실행 (`nonisolated(nonsending)`) |
| 액터에서 벗어나고 싶으면 | 기본 동작 | `@concurrent` 표시 |
| nonisolated 동기 함수 | 항상 호출자 actor에서 실행 | 같음 |

```
@MainActor Task 본문
 → await someAsyncFunction()      ← nonisolated async
      6.1 이하 / 기능 꺼짐: MainActor를 떠나서 실행
      6.2+ 기능 켬:          MainActor에서 그대로 실행
 → 재개 후 updateUI()             ← 둘 다 MainActor
```

컴파일러가 Swift 6.3이어도 이 동작은 upcoming feature 설정을 따른다. Swift 5 언어 모드인 실무 프로젝트에서 Approachable Concurrency(`SWIFT_APPROACHABLE_CONCURRENCY`) 설정이 켜져 있는지 확인해야 어느 열인지 알 수 있다. 자세한 내용은 로드맵 6주차에서 다룬다.

### 격리 경계와 await

다른 Actor에 격리된 메서드나 프로퍼티에 접근할 때는 격리 경계를 고려해야 한다.

```swift
@MainActor
final class UserViewModel {
    var username = "Minjun"

    func getUsername() -> String {
        return username
    }
}
```

MainActor 외부의 비동기 문맥에서 호출한다면 다음과 같이 작성한다.

```swift
func fetchUserName() async {
    let viewModel = await UserViewModel()   // init도 MainActor 격리라 await 필요

    let name = await viewModel.getUsername()
}
```

반면 이미 MainActor에 격리된 코드라면 별도의 격리 경계를 넘을 필요가 없다.

```swift
@MainActor
func screenAction() {
    let viewModel = UserViewModel()

    let name = viewModel.getUsername()
}
```

**주의 사항**

- `await`가 항상 실제 suspension을 발생시키는 것은 아니다.
- `await`는 특정 스레드로 이동하라는 명령이 아니다.
- 같은 Actor 격리 문맥 안에서 호출한다면 격리 경계를 넘을 필요가 없다.
- 다른 Actor의 격리된 코드에 접근할 때 일반적인 비동기 호출에서는 `await`가 필요하다.

### Task와 await의 관계

```swift
@MainActor
func screenAction() {
    Task {
        await fetchData()
        updateUI()
    }
}
```

여기서 `await fetchData()`는 생성된 Task가 `fetchData()`의 완료를 기다린다는 의미다.

하지만 `screenAction()` 자체는 생성한 Task의 완료를 자동으로 기다리지 않는다.

이유는 `Task { }`가 Unstructured Concurrency이기 때문이다.

즉, `await`는 현재 실행 중인 Task의 관점에서 이해해야 한다.

### 실무에서

- **`screenAction()` 직후 상태를 검사하는 테스트가 실패한다**: Task가 아직 안 끝났기 때문이다. 테스트에서는 Task 핸들을 받아 `await task.value`로 기다린다
- **실제로 어디서 도는지 확인**: 함수 안에 `MainActor.assertIsolated()`를 넣거나 브레이크포인트에서 스레드를 본다. 단, 스레드는 결과일 뿐이고 기준은 격리다

## 8. nonisolated

`nonisolated`는 Actor의 격리 영역에 속하지 않는 선언임을 나타내는 키워드다.

```swift
@MainActor
final class UserViewModel {
    var username = "Minjun"

    nonisolated func getIdentifier() -> String {
        return "UserViewModel"
    }

    func getUsername() -> String {
        return username
    }
}
```

두 메서드의 차이:

| 메서드 | 격리 여부 | 특징 |
|---|---|---|
| `getIdentifier()` | Nonisolated | MainActor 외부에서도 동기적으로 호출 가능 |
| `getUsername()` | MainActor-isolated | MainActor 격리 규칙에 따라 호출해야 함 |

### nonisolated의 특징

- Actor의 격리 영역에 속하지 않는다.
- Actor의 격리된 내부 상태에 직접 접근할 수 없다.
- 동기 메서드라면 외부에서 `await` 없이 호출할 수 있다. async 메서드라면 호출할 때 여전히 `await`가 필요하다.
- Actor의 격리된 상태를 보호하는 규칙을 우회하는 용도가 아니다.

```swift
nonisolated func getUsername() -> String {
    return username // 컴파일 오류
}
```

`username`은 MainActor에 격리된 상태이므로 `nonisolated` 메서드에서 직접 접근할 수 없다.

`let`으로 선언된 Sendable 상수는 바뀌지 않으므로 nonisolated 문맥에서도 읽을 수 있다. Data Race는 적어도 하나가 쓰기일 때만 생기기 때문이다.

**핵심:** `nonisolated`는 단순히 `await`를 생략하기 위한 키워드가 아니라, 해당 선언이 Actor의 격리된 상태에 의존하지 않는다는 것을 표현하는 수단이다.

### 실무에서

- `Hashable`, `CustomStringConvertible`처럼 동기 요구사항이 있는 프로토콜을 actor나 `@MainActor` 타입이 채택할 때 `nonisolated`로 구현하는 경우가 많다. 이때 구현은 `let` 상수만 써야 한다

## 핵심 정리

| 개념 | 핵심 역할 |
|---|---|
| `async` | 비동기 함수 선언 |
| `await` | 비동기 작업의 suspension point |
| `Task` | 새로운 비동기 작업 생성 |
| Structured Concurrency | 부모·자식 작업의 생명주기 관리 |
| Unstructured Concurrency | 구조적인 부모·자식 관계 없이 작업 생성 |
| Task Cancellation | 협력적 취소 |
| Actor Isolation | 공유 상태에 대한 동시 접근 보호 |
| Actor Reentrancy | `await`에서 중단된 Actor가 다른 작업을 처리할 수 있는 특성 |
| `@MainActor` | 메인 액터에 코드와 상태 격리 |
| 실행 문맥 상속 | 생성 위치의 Actor 실행 문맥 등을 이어받는 것 |
| `nonisolated` | Actor 격리 영역에 속하지 않는 선언 |

1. `async`는 "중단될 수 있음"이고, 실행 위치는 격리가 정한다.
2. 부모가 자식을 기다리고 취소가 전파되는 건 Structured(`async let`, TaskGroup)뿐이다. `Task { }`는 직접 관리한다.
3. 취소는 표시일 뿐이고, 작업이 확인해야 멈춘다.
4. actor는 Data Race를 막지만 `await`를 사이에 둔 로직의 원자성은 보장하지 않는다.
5. nonisolated async 함수의 실행 위치는 Swift 6.2의 SE-0461 설정 여부에 따라 다르다.

## 셀프 체크

**Q1. `Task { }`와 `async let`은 둘 다 작업을 동시에 돌리는데, 무엇이 다른가?**

- `async let`은 자식 작업이라 부모가 끝나기 전에 반드시 기다리고, 부모 취소가 전파된다. `Task { }`는 unstructured라 만든 함수가 기다리지 않고 취소도 직접 해야 한다

**Q2. 부모 Task를 취소했는데 자식 작업이 계속 돈다. 왜인가?**

- 취소는 협력적이다. 자식에 취소 표시는 전파됐지만, 자식이 `Task.checkCancellation()`·`Task.isCancelled`나 취소에 반응하는 API를 쓰지 않으면 계속 실행된다

**Q3. actor 안에 상태를 넣었는데 재고가 음수가 됐다. Data Race인가?**

- 아니다. `await` 중에 다른 작업이 같은 actor에 들어온 reentrancy로 생긴 Logical Race Condition이다. 상태 변경을 `await` 앞 동기 구간에서 끝내거나 `await` 뒤에 가정을 다시 확인한다

**Q4. `@MainActor` Task 안에서 nonisolated async 함수를 await하면 그 함수는 메인 스레드에서 도나?**

- Swift 5.7~6.1 동작(SE-0338)이면 MainActor를 떠나 실행된다. Swift 6.2+에서 `NonisolatedNonsendingByDefault`를 켰다면 MainActor에서 실행된다. 재개 후 Task 본문은 어느 쪽이든 MainActor다

**Q5. MainActor 밖 async 함수에서 `UserViewModel()`을 `await` 없이 만들면?**

- 컴파일 에러다. `@MainActor` 클래스의 `init`도 MainActor에 격리되어 있어서 격리 경계를 넘는 호출이 된다

## 참고 자료

**공식**

- [Swift — Task](https://developer.apple.com/documentation/swift/task)
- [Swift — Task.detached(name:executorPreference:priority:operation:)](https://developer.apple.com/documentation/swift/task/detached(name:executorpreference:priority:operation:)-75ffe) — 구조적 동시성으로 가능하면 detached를 쓰지 말라는 권고
- [The Swift Programming Language — Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [WWDC21 — Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134/) — Task 종류별 상속·취소 비교표
- [WWDC21 — Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) — reentrancy, await 뒤 가정 재확인
- [WWDC23 — Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170/) — 스코프 종료 시 암묵적 취소
- [SE-0338 Clarify the Execution of Non-Actor-Isolated Async Functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md)
- [SE-0461 Run nonisolated async functions on the caller's actor by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [Apple Developer Forums — MainActor 델리게이트 채택 클래스의 init에 await가 필요한 이유](https://developer.apple.com/forums/thread/722246)

**외부**

- [WWDC Notes — Explore structured concurrency in Swift](https://wwdcnotes.com/documentation/wwdc21-10134-explore-structured-concurrency-in-swift/) — Task 비교표 정리
- [Swift Forums — Actor with Task (2022)](https://forums.swift.org/t/actor-with-task/58667) — Task { } 상속 범위, SE-0338 언급
- [Swift Forums — Is Task.detached still useful? (2025)](https://forums.swift.org/t/is-task-detached-still-useful/83580)
- [Swift Forums — Structured Concurrency (async let) - Cancellation (2022)](https://forums.swift.org/t/structured-concurrency-async-let-cancellation/58576) — async let 취소 시점 사례
- [Donny Wals — Structured concurrency in Swift explained (2025-07 갱신)](https://www.donnywals.com/the-basics-of-structured-concurrency-in-swift-explained/) — await 안 한 async let의 암묵적 취소·대기
- [Donny Wals — Exploring concurrency changes in Swift 6.2](https://donnywals.com/exploring-concurrency-changes-in-swift-6-2) — nonisolated(nonsending), @concurrent
