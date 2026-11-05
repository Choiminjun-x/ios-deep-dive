# Actor

> 작성일: 2026-11-05

## 큰 그림

[02](02_swift-concurrency-basics.md)에서 actor를 개념으로 훑었고, [03](03_sendable.md)에서 경계를 넘는 값을 봤다. 이 노트는 actor 하나의 안쪽에서 무슨 일이 일어나는지를 다룬다.

```
Task A ─┐
Task B ─┼→ await로 진입 요청 → [ actor ] → 한 번에 하나씩 실행 (직렬화)
Task C ─┘                         │
                                  ├ 동기 구간: 끝까지 끊기지 않음 → Data Race 없음
                                  └ await 만남: 현재 Task만 중단
                                       → 그 사이 다른 Task가 진입 (Reentrancy)
                                       → 재개 후 상태가 바뀌어 있을 수 있음
                                       → Logical Race Condition 주의
```

actor가 보장하는 것은 "동시에 두 작업이 상태를 만지지 않는다"이다. "await를 사이에 둔 로직이 한 덩어리로 실행된다"는 보장하지 않는다.

## 1. Actor란?

Actor는 여러 동시성 작업이 하나의 공유 상태에 접근할 때 발생할 수 있는 Data Race를 방지하기 위한 참조 타입이다.

일반적인 Class와 달리 Actor는 내부 상태에 대한 접근을 Actor Isolation을 통해 직렬화한다.

```swift
actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }

    func getValue() -> Int {
        value
    }
}
```

여러 Task가 동시에 `increment()`를 호출하더라도 Actor는 내부 상태에 대한 접근을 직렬화하므로 `value`가 동시에 변경되는 Data Race를 방지할 수 있다.

### 핵심 특징

- Actor는 참조 타입이다.
- Actor 인스턴스는 독립적인 격리 영역을 가진다.
- 내부 상태는 기본적으로 Actor 외부에서 직접 접근할 수 없다.
- Actor 내부 상태에 접근하는 작업은 Actor의 실행 규칙에 따라 직렬화된다.
- 모든 Actor는 암시적으로 Sendable이다 ([03](03_sendable.md) 2.3절).
- class와 달리 상속을 지원하지 않는다. 프로토콜 채택과 extension은 된다.

### Class와 비교

| 구분 | class | actor |
|---|---|---|
| 타입 | 참조 | 참조 |
| 상속 | 됨 | 안 됨 |
| 가변 상태 보호 | 직접 (lock, serial queue) | 격리로 컴파일러가 강제 |
| 외부에서 메서드 호출 | 동기 | `await` 필요 (동기 메서드라도) |
| Sendable | 조건을 만족해야 함 | 항상 |

## 2. Actor Isolation

Actor Isolation은 Actor 내부 상태에 대한 접근을 보호하는 격리 메커니즘이다.

일반적인 Class는 여러 스레드에서 동시에 접근할 경우 별도의 동기화 수단이 필요하다.

반면 Actor는 내부 상태에 접근하는 작업을 직렬화하여 Data Race를 방지한다.

```swift
actor UserManager {
    var userName = ""

    func updateName(_ name: String) {
        userName = name
    }

    func getName() -> String {
        userName
    }
}
```

Actor 외부에서 내부 상태에 직접 접근하는 것은 허용되지 않는다.

```swift
let manager = UserManager()

// 컴파일 오류: 외부에서 actor의 프로퍼티를 변경할 수 없음 (await를 붙여도 불가)
// manager.userName = "Minjun"

// Actor의 메서드를 통해 접근
await manager.updateName("Minjun")
let name = await manager.getName()
```

다른 Actor 격리 영역에서 Actor의 격리된 메서드를 호출하려면 `await`가 필요하다.

여기서 `await`는 단순히 스레드를 전환하는 명령이 아니다. Actor에 진입할 차례를 기다리는 동안 현재 Task가 중단될 수 있음을 나타낸다.

`updateName(_:)`은 `async`가 아닌 동기 메서드지만, 외부에서 부르면 actor가 다른 작업을 처리 중일 수 있으므로 암시적으로 비동기 호출이 된다.

### 외부에서 접근할 때의 규칙

| 접근 | 같은 모듈 | 다른 모듈 |
|---|---|---|
| 격리된 메서드 호출 (동기·비동기) | `await` | `await` |
| `var` 프로퍼티 읽기 | `await` | `await` |
| `var` 프로퍼티 쓰기 | 불가 | 불가 |
| Sendable 타입의 `let` 읽기 | `await` 없이 가능 | `await` 필요 (`nonisolated let`이면 불필요) |
| `nonisolated` 메서드 | `await` 없이 (동기라면) | `await` 없이 (동기라면) |

외부에서 프로퍼티 쓰기를 막는 이유는, 읽기와 쓰기 사이에 중단 지점이 생겨 불변 조건이 깨지기 쉽기 때문이다. 상태 변경은 actor 안의 메서드로만 한다.

다른 모듈의 `let`에 `await`가 필요한 이유는, actor를 만든 쪽이 나중에 `let`을 `var`로 바꿔도 사용하는 쪽 코드가 깨지지 않게 하기 위해서다.

### 실무에서

- **"actor-isolated property 'x' can not be mutated from a nonisolated context"**: 외부에서 프로퍼티를 직접 바꾸려 한 경우다. `update…` 메서드를 actor 안에 만든다
- `private`을 붙인 프로퍼티라면 격리 이전에 접근 제어 에러가 먼저 난다. 격리 에러를 확인하려면 `private` 없이 시험해 본다

## 3. Actor와 동기화

Actor는 내부 상태에 대한 접근을 직렬화한다.

```swift
actor Counter {
    private var count = 0

    func increment() {
        count += 1
    }
}
```

여러 Task가 동시에 `increment()`를 호출하더라도 Actor는 해당 작업을 직렬화하여 처리한다.

따라서 여러 작업이 동시에 `count += 1`을 실행하면서 발생하는 Data Race를 방지할 수 있다.

다만 Actor가 모든 비즈니스 로직의 원자성을 보장하는 것은 아니다.

특히 `await`가 포함된 경우 주의해야 한다.

### 직렬화 ≠ 순서 보장

직렬화는 "한 번에 하나"라는 뜻이지 "들어온 순서대로"라는 뜻이 아니다. Swift의 기본 actor는 FIFO를 보장하지 않는다. 높은 우선순위 작업이 들어오면 먼저 실행될 수 있고, actor에서 실행 중인 작업의 우선순위가 일시적으로 올라가기도 한다 (priority escalation).

```
Task { await counter.increment(1) }
Task { await counter.increment(2) }   → 실행 순서가 1 → 2라는 보장 없음
```

### 실무에서

- **로그 순서·이벤트 순서가 가끔 뒤바뀐다**: 동기 코드에서 `Task { await actor.method() }`를 연달아 만들면 actor에 도착하는 순서가 보장되지 않는다. 순서가 중요하면 하나의 Task 안에서 차례로 `await`하거나 `AsyncStream`으로 한 줄로 받는다

## 4. Actor Reentrancy

Actor Reentrancy는 Actor 내부의 Task가 `await`에서 중단된 동안 다른 Task가 동일한 Actor에 진입하여 실행될 수 있는 특성이다.

Actor는 하나의 Task가 `await`에서 중단되었다고 해서 Actor 자체를 점유한 채 기다리지 않는다.

중단된 동안 다른 Task가 해당 Actor의 작업을 수행할 수 있다.

```swift
actor UserManager {
    func fetchUser() async {
        print("사용자 조회 시작")

        await fetchFromServer()

        print("사용자 조회 완료")
    }

    private func fetchFromServer() async {
        // 서버 요청
    }
}
```

실행 흐름:

1. 첫 번째 Task가 `fetchUser()` 실행
2. `await fetchFromServer()`에서 첫 번째 Task 중단
3. UserManager는 다른 Task를 처리할 수 있음
4. 다른 Task가 UserManager에 진입하여 작업 수행
5. 서버 요청 완료 후 첫 번째 Task가 실행 재개

중요한 점은 **Actor가 중단되는 것이 아니라 현재 Task가 중단된다는 것**이다.

이러한 특성 때문에 Actor는 여러 비동기 작업을 효율적으로 처리할 수 있다.

또 다른 이유는 데드락 방지다. actor A가 B를 기다리고 B가 A를 기다리는 상황에서도, 기다리는 동안 actor를 놓아주기 때문에 서로 멈추지 않는다.

```
[ 비재진입이라면 ]  A: await B.f() 동안 A 잠김 → B.f(): await A.g() → A 잠겨 있음 → 데드락
[ Swift actor   ]  A: await B.f() 동안 A 비어 있음 → A.g() 실행 가능 → 진행됨
```

반대로 동기 구간(await가 없는 구간)은 끝까지 끊기지 않고 실행된다. 그래서 상태 변경을 동기 구간에 모으는 것이 기본 설계 원칙이 된다.

## 5. Logical Race Condition

Actor는 Data Race를 방지하지만 Logical Race Condition까지 자동으로 방지하지는 않는다.

Logical Race Condition은 데이터에 동시에 접근하는 Data Race가 발생하지 않더라도, 비동기 작업의 실행 순서나 중간 상태 변경으로 인해 비즈니스 로직의 전제가 깨지는 상황이다.

다음 코드를 살펴보자.

```swift
actor LoginManager {
    private var isLoggedIn = false

    func login() async {
        guard !isLoggedIn else {
            return
        }

        await authenticate()

        isLoggedIn = true
    }

    private func authenticate() async {
        // 서버 인증 요청
    }
}
```

두 개의 Task가 거의 동시에 `login()`을 호출한다면 다음과 같은 상황이 발생할 수 있다.

1. 첫 번째 Task가 `isLoggedIn == false` 확인
2. 첫 번째 Task가 `await authenticate()`에서 중단
3. 두 번째 Task가 `login()` 실행
4. 두 번째 Task도 `isLoggedIn == false` 확인
5. 두 번째 Task도 인증 요청 시작

결과적으로 인증 요청이 중복 실행될 수 있다.

Actor가 상태 접근을 직렬화하더라도 `await` 전후의 여러 작업을 하나의 원자적인 작업으로 보장하지는 않기 때문이다.

### 실무에서: 진행 중인 작업을 공유하기

WWDC21 "Protect mutable state with Swift actors"의 이미지 다운로더 예제와 같은 패턴이다. 진행 중인 Task를 `await` 전에 동기 구간에서 저장해 두고, 나중에 온 호출은 그 Task의 결과를 함께 기다린다.

```swift
actor LoginManager {
    private var isLoggedIn = false
    private var loginTask: Task<Void, Never>?

    func login() async {
        if isLoggedIn { return }

        if let loginTask {                       // 이미 진행 중 → 같은 결과를 기다림
            await loginTask.value
            return
        }

        let task = Task { await authenticate() }
        loginTask = task                         // await 전 동기 구간에서 기록

        await task.value

        isLoggedIn = true
        loginTask = nil
    }

    private func authenticate() async {
        // 서버 인증 요청
    }
}
```

```
Task 1: isLoggedIn? 아니오 → loginTask 없음 → Task 생성·저장 → await (중단)
Task 2: isLoggedIn? 아니오 → loginTask 있음 → 그 Task를 await
인증 완료 → Task 1·2 모두 재개 → 요청은 1번만 나감
```

- **증상**: 토큰 갱신 API가 동시에 두 번 호출된다, 같은 이미지를 두 번 내려받는다
- **디버깅 포인트**: 서버 로그나 Network 인스펙터에서 같은 요청이 몇 ms 간격으로 겹치는지 본다

## 6. await 전후 상태 재검증

Logical Race Condition을 방지하려면 `await` 이후에도 기존 상태가 여전히 유효한지 확인해야 한다.

예를 들어 재고 차감 로직을 살펴보자.

```swift
actor Inventory {
    private var stock = 1

    func purchase() async {
        guard stock > 0 else {
            return
        }

        await processPayment()

        stock -= 1
    }

    private func processPayment() async {
        // 결제 처리
    }
}
```

현재 재고가 1개인 상황에서 두 개의 구매 요청이 들어오면 다음과 같은 문제가 발생할 수 있다.

1. 첫 번째 구매 요청이 `stock > 0` 확인
2. 첫 번째 요청이 결제 처리 중 중단
3. 두 번째 구매 요청도 `stock > 0` 확인
4. 두 번째 요청도 결제 처리 중 중단
5. 두 결제가 모두 완료
6. 두 요청 모두 재고 차감

재고가 1개인데 두 번 판매되는 문제가 발생할 수 있다.

따라서 `await` 이후 상태를 다시 검증해야 한다.

```swift
actor Inventory {
    private var stock = 1

    func purchase() async {
        guard stock > 0 else {
            return
        }

        await processPayment()

        // await 이후 상태 재검증
        guard stock > 0 else {
            return
        }

        stock -= 1
    }

    private func processPayment() async {
        // 결제 처리
    }
}
```

다만 이 코드만으로는 결제가 이미 완료된 후 재고가 부족한 상황이 발생할 수 있다.

실제 결제 시스템에서는 재고 예약, 결제 승인, 실패 시 보상 처리 등 비즈니스 요구사항에 맞는 별도의 트랜잭션 설계가 필요하다.

핵심은 `await` 전후로 Actor의 상태가 변경될 수 있으므로, 이전에 확인한 상태를 무조건 신뢰해서는 안 된다는 것이다.

### 재검증 vs 먼저 예약

| 방식 | 흐름 | 한계 |
|---|---|---|
| await 뒤 재검증 | 확인 → 결제 → 다시 확인 → 차감 | 결제 후 재고가 없을 수 있음 (환불 필요) |
| await 전 예약 | 확인 + 차감(예약) → 결제 → 실패 시 복구 | 실패 시 되돌리는 코드가 필요 |
| 진행 중 작업 공유 (5절) | 같은 요청을 하나로 합침 | 서로 다른 요청(다른 사용자)에는 해당 없음 |

예약 방식은 확인과 차감을 같은 동기 구간에서 끝내므로 두 번 판매는 생기지 않는다.

```swift
func purchase() async -> Bool {
    guard stock > 0 else { return false }
    stock -= 1                          // await 전 동기 구간에서 예약

    let success = await processPayment()
    if !success { stock += 1 }          // 실패 시 복구
    return success
}
```

WWDC21의 가이드도 같다. 상태 변경은 동기 코드에서 하고, `await` 뒤에는 가정을 다시 확인한다.

## 7. Data Race와 Logical Race Condition

두 개념은 발생 원인과 해결 방법이 다르다.

| 구분 | Data Race | Logical Race Condition |
|---|---|---|
| 원인 | 동기화되지 않은 동시 메모리 접근 | 비동기 작업 사이의 상태 변화와 실행 순서 |
| 메모리 안전성 | 손상될 수 있음 | 메모리 접근 자체는 안전할 수 있음 |
| Actor로 방지 가능 여부 | Actor Isolation으로 방지 가능 | 자동으로 방지하지 못함 |
| 대응 방법 | Actor, Lock 등 동기화 | 상태 재검증, 작업 상태 관리, 원자성 설계 |
| 발견 도구 | 컴파일러(Strict Concurrency), Thread Sanitizer | 도구로 잡히지 않음. 테스트·로그로 확인 |

Actor를 사용하면 Data Race를 방지할 수 있지만, `await` 전후의 상태 변화로 발생하는 Logical Race Condition은 개발자가 직접 고려해야 한다.

## 8. Actor 사용 시 주의사항

### 8.1 await는 스레드 전환을 의미하지 않는다

`await`는 비동기 작업이 중단될 수 있는 지점을 표현한다.

특정 스레드에서 다른 스레드로 이동하라는 명령이 아니다.

### 8.2 Actor는 하나의 스레드와 동일하지 않다

Actor는 특정 스레드에 고정되는 개념이 아니다.

Actor의 작업은 Swift Concurrency의 Executor 스케줄링 규칙에 따라 실행된다.

일반 actor는 기본적으로 Swift Concurrency의 협력 스레드 풀에서 실행된다. 같은 actor의 작업도 실행될 때마다 다른 스레드에 있을 수 있다. 예외는 MainActor다. MainActor는 메인 스레드에서 실행된다.

### 8.3 await 전후의 상태가 달라질 수 있다

Actor 내부에서 `await`가 발생하면 현재 Task가 중단되는 동안 다른 Task가 Actor에 진입할 수 있다.

따라서 `await` 이전에 확인한 상태가 이후에도 유효하다고 가정해서는 안 된다.

### 8.4 모든 메서드에 await가 필요한 것은 아니다

동일한 Actor 격리 영역 내부에서 동기 메서드를 호출하는 경우에는 `await`가 필요하지 않다.

다른 격리 영역에서 Actor의 격리된 메서드나 프로퍼티에 접근할 때는 동기 메서드라도 `await`가 필요하다. 예외는 2절 표의 `nonisolated` 선언과 같은 모듈의 Sendable `let`이다.

### 8.5 actor 안에서 오래 걸리는 동기 작업을 하지 않는다

동기 구간은 끊기지 않으므로, actor 안에서 큰 JSON 디코딩이나 이미지 처리를 동기로 오래 하면 그동안 다른 호출이 모두 기다린다.

### 실무에서

- **actor 메서드 호출이 이상하게 느리다**: 그 actor 안의 동기 작업이 길어서 다른 호출이 줄을 서 있는지 본다. Instruments의 Swift Concurrency 템플릿에서 actor별로 대기 중인 작업을 볼 수 있다
- 무거운 계산은 actor 밖 nonisolated 함수로 빼고, actor에는 결과만 반영한다

## 핵심 정리

- **Actor**: 공유 상태에 대한 Data Race를 방지하는 참조 타입
- **Actor Isolation**: Actor 내부 상태에 대한 접근을 직렬화하는 격리 메커니즘
- **await**: 비동기 작업의 중단 가능 지점을 나타내는 키워드
- **Actor Reentrancy**: 현재 Task가 `await`에서 중단된 동안 다른 Task가 동일한 Actor에 진입할 수 있는 특성
- **Logical Race Condition**: Data Race 없이도 비동기 실행 순서와 상태 변화로 인해 발생하는 논리적 오류
- **상태 재검증**: `await` 이후 기존 상태가 여전히 유효한지 확인하는 과정

Actor는 동시성 환경에서 공유 상태를 안전하게 보호하기 위한 중요한 도구다.

다만 Actor Isolation이 모든 비즈니스 로직의 원자성을 보장하는 것은 아니다. 특히 `await`를 기준으로 실행이 중단되고 재개되는 과정에서 상태가 변경될 수 있다는 점을 이해하는 것이 중요하다.

1. 외부에서는 동기 메서드도 `await`로 부르고, 프로퍼티는 읽기만 된다.
2. 직렬화는 "한 번에 하나"이지 "들어온 순서대로"가 아니다.
3. reentrancy는 데드락을 막는 대신 await 전후 상태가 바뀔 수 있게 한다.
4. 상태 변경은 동기 구간에서 끝내고, 같은 요청은 진행 중인 Task를 공유해 합친다.

## 셀프 체크

**Q1. actor의 동기 메서드를 외부에서 부를 때 왜 `await`가 필요한가?**

- actor가 다른 작업을 처리 중이면 차례를 기다려야 하므로, 호출이 중단 지점이 된다. 메서드가 `async`인지와 관계없다

**Q2. 외부에서 `await manager.userName = "A"`처럼 쓰면 되나?**

- 안 된다. 외부에서는 읽기만 된다. 변경은 actor 안의 메서드로 한다

**Q3. `Task { await actor.f(1) }`, `Task { await actor.f(2) }`를 연달아 만들면 1이 먼저 실행되나?**

- 보장되지 않는다. 기본 actor는 FIFO가 아니고, Task가 actor에 도착하는 순서 자체도 정해져 있지 않다

**Q4. Swift actor는 왜 재진입을 허용하나?**

- 데드락을 막고 작업이 계속 진행되게 하기 위해서다. 대신 await 뒤에는 상태가 바뀌었을 수 있다

**Q5. 로그인 요청이 동시에 두 번 나간다. actor로 바꿨는데도 그렇다. 어떻게 고치나?**

- 진행 중인 `Task`를 await 전에 프로퍼티로 저장하고, 나중에 온 호출은 그 Task를 기다리게 한다

**Q6. "재검증"과 "먼저 예약"은 무엇이 다른가?**

- 재검증은 결제 후 재고가 없을 수 있어 환불 처리가 필요하다. 예약은 확인과 차감을 같은 동기 구간에서 끝내 두 번 판매를 막고, 실패하면 복구한다

## 참고 자료

**공식**

- [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) — cross-actor reference, 외부 프로퍼티 쓰기 금지, 다른 모듈의 `let`
- [Swift Forums — [Amendment] SE-0306: Actors and nonisolated let](https://forums.swift.org/t/amendment-se-0306-actors-and-nonisolated-let/48386) — 같은 모듈에서만 `let` 동기 접근
- [WWDC21 — Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) — reentrancy, 이미지 다운로더 패턴
- [Swift — TaskPriority](https://developer.apple.com/documentation/swift/taskpriority) — actor 작업의 우선순위 상승
- [The Swift Programming Language — Concurrency (Actors)](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [Swift Forums — Is order of task execution deterministic? (ktoso, Apple)](https://forums.swift.org/t/task-is-order-of-task-execution-deterministic/51553/31) — 기본 actor는 FIFO가 아님

**외부**

- [Swift Forums — Actors that serialise file access (2023)](https://forums.swift.org/t/actors-that-serialise-file-access/66652/17) — 우선순위로 순서가 바뀌는 사례
- [Swift Forums — Question about Actor Isolation in SE-0306 (2025)](https://forums.swift.org/t/question-about-actor-isolation-in-se-0306/83246) — `let` 접근 규칙 해설
