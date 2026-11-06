# AsyncSequence

> 작성일: 2026-11-06

## 큰 그림

```
생산자 (콜백·이벤트 기반 API)
 → continuation.yield(value)          ← 여러 번 호출 가능
 → 버퍼 (BufferingPolicy가 크기와 버릴 요소를 결정)
 → 소비자 Task: for await value in stream
      → 내부에서 iterator.next() 반복 호출
      → 요소가 있으면 바로 반환, 없으면 Task 중단 (스레드는 막지 않음)
 → 종료
      → 생산자가 끝냄: finish() / finish(throwing:)
      → 소비자가 끝냄: 소비 Task 취소
      → onTermination 호출 → 외부 구독 해제는 여기서 직접
```

Continuation이 "결과 하나를 한 번 전달하는 다리"라면, AsyncStream은 "요소 여러 개를 계속 흘려보내는 파이프"다.

## 1. AsyncSequence란?

`AsyncSequence`는 여러 요소를 비동기적으로 순회할 수 있도록 제공하는 프로토콜이다.

일반적인 `Sequence`는 다음 요소를 동기적으로 가져오지만, `AsyncSequence`는 다음 요소가 준비될 때까지 비동기적으로 기다릴 수 있다.

대표적인 활용 사례:

- 서버에서 실시간으로 전달되는 데이터
- 타이머 이벤트
- 위치 정보 업데이트
- 사용자 입력 및 시스템 이벤트
- 대용량 데이터의 순차적인 처리

### Sequence vs AsyncSequence

| 구분 | Sequence | AsyncSequence |
|---|---|---|
| 순회 방식 | `for-in` | `for await-in` |
| 다음 요소 획득 | 동기적 | 비동기적 |
| 대기 가능성 | 일반적으로 없음 | 다음 요소를 기다릴 수 있음 |
| 대표 타입 | Array, Set | AsyncStream, URLSession.AsyncBytes |

```swift
// Sequence
for number in [1, 2, 3] {
    print(number)
}

// AsyncSequence
for await value in asyncSequence {
    print(value)
}
```

`for await`는 내부적으로 AsyncIterator의 `next()`를 반복 호출하면서 요소를 순회한다.

```
for await value in sequence { body }

→ var iterator = sequence.makeAsyncIterator()
→ while let value = await iterator.next() { body }
```

`map`, `filter`, `compactMap`, `prefix` 같은 연산자도 `Sequence`처럼 쓸 수 있다. 결과는 다시 AsyncSequence다.

### AsyncIteratorProtocol

`AsyncSequence`는 `AsyncIteratorProtocol`을 통해 다음 요소를 제공한다.

핵심 메서드:

```swift
mutating func next() async throws -> Element?
```

- 다음 요소가 준비되면 해당 요소 반환
- 다음 요소를 기다려야 하면 비동기적으로 대기
- 더 이상 요소가 없으면 `nil` 반환
- 오류가 발생하면 throw 가능

다음 요소가 준비되지 않았다면 현재 Task는 Suspended 상태가 될 수 있다.

이때 스레드를 점유한 채 대기하는 것은 아니다. 요소가 준비되면 Swift Concurrency Runtime이 Task를 다시 실행할 수 있도록 스케줄링한다.

### 버전 차이 (Swift 6.0, SE-0421)

Swift 6.0부터 프로토콜이 일반화됐다.

| 구분 | Swift 5.x | Swift 6.0+ |
|---|---|---|
| 오류 타입 | `@rethrows`로 표현 | `Failure` 연관 타입 (typed throws) |
| 요구 메서드 | `next()` | `next(isolation:)` 추가, `next()`는 기본 구현 제공 |
| 불투명 타입 | `some AsyncSequence<Int>` 불가 | `some AsyncSequence<Int, Never>` 가능 |

```swift
mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element?
```

`isolation` 파라미터는 호출한 쪽의 격리(예: MainActor)를 유지한 채 다음 요소를 가져오게 해서, 순회할 때 생기던 Sendable 경고를 줄이기 위한 것이다. 직접 iterator를 구현하는 게 아니라면 `next()`로 이해해도 충분하다.

## 2. AsyncStream

`AsyncStream`은 기존의 Completion Handler 기반 API나 이벤트 기반 API를 AsyncSequence 형태로 연결할 수 있도록 제공하는 타입이다.

기존 API가 여러 번 호출되는 Completion Handler를 제공한다면, 이를 `AsyncStream`으로 감싸 비동기 순회 방식으로 사용할 수 있다.

### 기본 구조

```swift
func observeValue(
    handler: @escaping (Int) -> Void
) {
    // 이벤트가 발생할 때마다 handler 호출
}

let stream = AsyncStream<Int> { continuation in
    observeValue { value in
        continuation.yield(value)
    }
}

for await value in stream {
    print(value)
}
```

### Continuation과 비교

| 구분 | CheckedContinuation | AsyncStream.Continuation |
|---|---|---|
| 전달 | `resume` 정확히 한 번 | `yield` 여러 번 |
| 결과 | 값 하나 (`await` 한 번) | 요소의 흐름 (`for await`) |
| 종료 | `resume`이 곧 종료 | `finish()`를 따로 호출 |
| 호출을 빠뜨리면 | Task가 영원히 중단, 누수 경고 | 소비자가 다음 요소를 계속 기다림 |
| 두 번 부르면 | 크래시 | 정상 (요소가 하나 더 전달됨) |

### 주요 기능

#### 1) yield()

`continuation.yield(value)`는 스트림에 새로운 요소를 전달한다.

```swift
continuation.yield(1)
continuation.yield(2)
continuation.yield(3)
```

생산자가 여러 번 호출할 수 있으며, 소비자는 전달된 요소를 순차적으로 소비한다.

`yield`는 결과(`YieldResult`)를 반환한다. 보통은 무시하지만 디버깅할 때 유용하다.

| 결과 | 의미 |
|---|---|
| `.enqueued(remaining:)` | 버퍼에 들어감. 남은 버퍼 칸 수 |
| `.dropped(element)` | 버퍼가 가득 차서 버려진 요소 |
| `.terminated` | 이미 종료된 스트림이라 전달 안 됨 |

#### 2) finish()

`continuation.finish()`는 스트림을 정상적으로 종료한다.

```swift
let stream = AsyncStream<Int> { continuation in
    continuation.yield(1)
    continuation.yield(2)
    continuation.finish()
}
```

종료 시 주의사항:

- 이미 버퍼에 들어간 요소는 소비할 수 있다.
- `finish()` 이후 새로운 요소는 전달되지 않는다.
- 버퍼의 요소를 모두 소비하면 `for await` 순회가 종료된다.

#### 3) yield()와 finish()의 관계

```swift
let stream = AsyncStream<Int> { continuation in
    continuation.yield(1)
    continuation.yield(2)

    continuation.finish()

    continuation.yield(3)
}
```

소비자는 `1`, `2`만 전달받는다.

`finish()` 이후 호출된 `yield(3)`은 새로운 요소를 전달하지 못하고 `.terminated`를 반환한다. 크래시는 나지 않는다.

### 2.1 makeStream(of:) — Swift 5.9, SE-0388

클로저 밖(다른 메서드, 델리게이트)에서 continuation을 써야 할 때, 예전에는 클로저 안에서 continuation을 프로퍼티로 빼내야 했다.

```swift
// Swift 5.9 이전
var continuation: AsyncStream<Int>.Continuation!
let stream = AsyncStream<Int> { continuation = $0 }

// Swift 5.9+
let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
```

`@backDeployed`로 제공돼 iOS 15 타깃에서도 쓸 수 있다.

델리게이트 기반 API(CLLocationManager 등)를 감쌀 때 특히 편하다. 델리게이트 메서드에서 `continuation.yield(_:)`를 호출하면 된다.

### 실무에서

**AsyncStream은 소비자 하나를 전제로 한다.** 같은 스트림을 여러 Task에서 `for await` 하면 Combine처럼 모두에게 복사돼 전달되지 않는다.

| 타입 | 여러 Task에서 동시에 순회하면 |
|---|---|
| `AsyncStream` | 요소가 소비자들 사이에 나눠서 전달됨 (각자 일부만 받음) |
| `AsyncThrowingStream` | 둘 이상이 동시에 대기하면 `fatalError` ("attempt to await next() on more than one task") |

증상: "화면 A, B에서 같은 스트림을 구독했더니 이벤트가 번갈아 한쪽에만 온다", "throwing 버전으로 바꿨더니 크래시".

해결: 소비자마다 스트림을 따로 만들어 준다. 브로드캐스트가 필요하면 스트림 목록을 관리하는 타입을 직접 만들거나 다른 도구를 쓴다.

## 3. AsyncStream의 BufferingPolicy

AsyncStream은 생산자와 소비자가 서로 다른 속도로 동작할 수 있다.

생산자가 소비자보다 빠르게 요소를 전달하면 소비되지 않은 요소가 버퍼에 계속 쌓일 수 있다.

이로 인해 메모리 사용량이 증가할 수 있으므로 BufferingPolicy를 통해 버퍼 동작을 제어할 수 있다.

### 주요 정책

| 정책 | 동작 |
|---|---|
| `.unbounded` | 버퍼 크기 제한 없이 저장 |
| `.bufferingOldest(n)` | 버퍼가 가득 차면 새 요소를 버림 |
| `.bufferingNewest(n)` | 버퍼가 가득 차면 오래된 요소를 버리고 최신 요소 유지 |

기본 정책은 `.unbounded`이다.

### bufferingOldest

버퍼 크기가 2이고 다음 요소가 순서대로 전달된다고 가정한다.

```text
1 → 2 → 3

버퍼: [1, 2]
3: 버림
```

기존에 들어온 요소를 우선 보존한다.

### bufferingNewest

```text
1 → 2 → 3

버퍼: [2, 3]
1: 버림
```

최신 요소를 우선 보존한다.

버퍼는 "소비자가 아직 기다리고 있지 않을 때" 쌓이는 곳이다. 소비자가 이미 `next()`에서 대기 중이면 요소는 버퍼를 거치지 않고 바로 전달된다.

### 활용 사례

실시간 위치 정보처럼 과거 데이터보다 최신 데이터가 중요한 경우 `.bufferingNewest`가 적합할 수 있다.

반면 먼저 발생한 이벤트를 우선 보존해야 한다면 `.bufferingOldest`를 고려할 수 있다.

모든 요소를 보존해야 한다면 `.unbounded`를 사용할 수 있지만, 메모리 증가에 주의해야 한다.

### 설정 예시

```swift
let stream = AsyncStream<Int>(
    bufferingPolicy: .bufferingNewest(10)
) { continuation in
    // 요소 전달
}
```

### 실무에서

- "최신 값만 의미 있는" 상태(진행률, 위치, 가격)는 `.bufferingNewest(1)`이 자주 쓰인다. 소비자가 느려도 최신 값 하나만 남는다
- BufferingPolicy는 버릴 요소를 정할 뿐, 생산자를 느리게 만들지는 않는다 (backpressure 아님). 생산 자체를 늦춰야 하면 `yield` 결과를 보거나 다른 설계가 필요하다
- 요소가 빠진다면 `yield`의 반환값에서 `.dropped`가 나오는지 찍어 본다

## 4. AsyncThrowingStream

`AsyncStream`은 여러 요소를 전달할 수 있지만 스트림 자체에서 오류를 throw하는 방식은 지원하지 않는다.

비동기적으로 여러 요소를 전달하면서 오류 종료도 표현해야 한다면 `AsyncThrowingStream`을 사용할 수 있다.

대표적인 상황:

- 네트워크 연결 중단
- 파일 읽기 오류
- 외부 SDK에서 발생하는 오류
- 실시간 데이터 수신 중 오류

### AsyncStream vs AsyncThrowingStream

| 구분 | AsyncStream | AsyncThrowingStream |
|---|---|---|
| 요소 전달 | `yield(value)` | `yield(value)` |
| 정상 종료 | `finish()` | `finish()` |
| 오류 종료 | 직접 지원하지 않음 | `finish(throwing:)` |
| 소비 방식 | `for await` | `for try await` |

### 사용 예시

```swift
let stream = AsyncThrowingStream<Int, Error> { continuation in
    continuation.yield(1)
    continuation.yield(2)

    continuation.finish(
        throwing: URLError(.notConnectedToInternet)
    )
}

do {
    for try await value in stream {
        print(value)
    }
} catch {
    print("Error:", error)
}
```

오류 종료 시에도 이미 버퍼에 들어간 요소는 먼저 소비할 수 있다.

이후 다음 요소를 요청하는 과정에서 오류가 전달되고 `catch` 블록이 실행된다.

```
yield(1) → yield(2) → finish(throwing:)

소비자: 1 출력 → 2 출력 → next()에서 throw → catch
```

`for try await`는 비동기 순회 과정에서 발생할 수 있는 오류를 호출부에서 처리하기 위해 사용한다.

## 5. Stream 종료와 Cancellation

Task Cancellation은 취소 요청이며, 외부 리소스나 기존 이벤트 기반 API를 자동으로 종료하는 기능은 아니다.

이는 [Continuation 학습](05_continuation.md)에서 다룬 Cancellation과 같은 원리다.

예를 들어 다음과 같은 리소스를 직접 정리해야 할 수 있다.

- NotificationCenter Observer
- 기존 Completion Handler 기반 구독
- 외부 SDK의 이벤트 구독
- 네트워크 연결 및 작업

### 스트림 자체는 취소에 반응한다

Continuation과 다른 점이다. 소비 Task가 취소되면 AsyncStream은 스스로 종료 상태가 된다.

```
소비 Task 취소
 → 대기 중인 next()가 nil 반환 → for await 루프 종료
 → onTermination(.cancelled) 호출
 → 이후 yield는 .terminated (요소 버려짐)
```

즉 "순회가 멈추는 것"은 자동이고, "외부 구독을 끊는 것"은 직접 해야 한다.

### onTermination

`AsyncStream.Continuation`과 `AsyncThrowingStream.Continuation`은 `onTermination`을 제공한다.

스트림이 종료될 때 정리 작업을 수행할 수 있다.

```swift
let stream = AsyncStream<Int> { continuation in

    let observer = NotificationCenter.default.addObserver(
        forName: .someEvent,
        object: nil,
        queue: nil
    ) { notification in
        continuation.yield(1)
    }

    continuation.onTermination = { termination in
        NotificationCenter.default.removeObserver(observer)
    }
}
```

소비 Task의 취소 등으로 스트림이 종료되면 `onTermination`을 통해 Observer를 제거할 수 있다.

`onTermination`이 불리는 경우:

| 원인 | 전달되는 값 |
|---|---|
| 생산자가 `finish()` | `.finished` |
| 생산자가 `finish(throwing:)` (Throwing 버전) | `.finished(error)` |
| 소비 Task 취소 | `.cancelled` |
| 스트림이 소비되지 않고 해제됨 | `.cancelled` |

어느 경로든 한 번만 불리므로, 정리 코드를 한 곳에 모을 수 있다.

주의사항:

- `onTermination`은 종료 통지 및 정리 작업을 위한 지점이다.
- 외부 리소스를 자동으로 취소해 주는 것은 아니다.
- 실제 네트워크 구독 해제나 Observer 제거는 직접 구현해야 한다.
- `onTermination` 클로저는 `@Sendable`이고 임의의 스레드에서 불릴 수 있다. UI 정리가 필요하면 MainActor로 넘긴다.

### 실무에서

증상별로 보면:

- 화면을 나갔는데 로그가 계속 찍힌다 → `onTermination`에서 구독 해제를 안 함
- 화면을 나갔는데 화면 객체가 해제되지 않는다 → `Task { for await … }`를 저장·취소하지 않음. 무한 스트림이면 Task가 `self`를 계속 잡고 있다
- SwiftUI `.task`는 뷰가 사라질 때 자동으로 취소된다. UIKit에서는 Task를 프로퍼티에 저장했다가 `viewDidDisappear` 등에서 `cancel()` 한다

## 6. 실무에서 활용하는 AsyncSequence

AsyncSequence는 직접 만든 AsyncStream뿐 아니라 Apple 프레임워크에서도 활용된다.

### 6.1 URLSession.bytes(for:) / bytes(from:) — iOS 15+

`URLSession.data(for:)`는 전체 응답을 `Data`로 반환한다.

반면 `URLSession.bytes(for:)`는 응답을 바이트 스트림 형태로 순차적으로 처리할 수 있다. `for:`는 `URLRequest`, `from:`은 `URL`을 받는다.

```swift
let (bytes, response) = try await URLSession.shared.bytes(
    from: url
)

for try await line in bytes.lines {
    print(line)
}
```

`bytes(from:)`는 응답 헤더를 받은 시점에 반환되고, 본문은 이후 `bytes`를 순회하면서 받는다.

비교:

| 구분 | data(for:) | bytes(for:) |
|---|---|---|
| 반환 형태 | Data | URLSession.AsyncBytes |
| 반환 시점 | 본문까지 모두 받은 뒤 | 헤더를 받은 뒤 |
| 데이터 처리 | 전체 응답 수신 후 처리 | 수신되는 데이터 순차 처리 |
| 활용 | 일반적인 API 응답 | 대용량 응답, 스트리밍 응답 (SSE 등) |

스트리밍 방식은 전체 응답이 도착하기 전부터 데이터를 처리할 수 있다는 장점이 있다.

단, 순회 중 오류가 throw되면 스트림 순회는 종료되고, 이미 처리한 데이터를 자동으로 보존해 주지는 않는다. 오류 이후에도 쓰려면 소비자가 처리한 데이터를 별도로 보관해야 한다.

### 6.2 NotificationCenter.notifications — iOS 15+

NotificationCenter의 이벤트를 AsyncSequence 방식으로 순회할 수 있다.

```swift
let notifications = NotificationCenter.default.notifications(
    named: UIApplication.didBecomeActiveNotification
)

for await notification in notifications {
    print("App became active")
}
```

기존 Observer 기반 이벤트 처리와 달리 비동기 순회 방식으로 이벤트를 소비할 수 있다.

순회하는 Task가 취소되면 구독도 끝나므로, `removeObserver`를 따로 부를 필요가 없다.

### 실무에서

`Notification`은 Sendable이 아니다 (`object`, `userInfo` 때문). 그래서 Strict Concurrency를 켜면 순회할 때 "Non-sendable type 'Notification?' … cannot cross actor boundary" 같은 경고가 날 수 있다.

Apple 문서가 권하는 해결은 `map`/`compactMap`으로 Sendable한 값만 뽑아서 순회하는 것이다.

```swift
for await _ in NotificationCenter.default
    .notifications(named: UIApplication.didBecomeActiveNotification)
    .map({ $0.name }) {
    print("App became active")
}
```

### 6.3 Timer와 AsyncSequence

기존 Combine에서는 Timer Publisher를 사용할 수 있다.

```swift
let timer = Timer.publish(
    every: 1.0,
    on: .main,
    in: .common
).autoconnect()
```

Swift Concurrency 환경에서는 AsyncSequence 기반 타이머를 사용할 수도 있다.

예를 들어 Swift Async Algorithms 패키지는 `AsyncTimerSequence`를 제공한다.

이는 Swift 표준 라이브러리 자체에 포함된 타입은 아니며 별도 패키지를 통해 활용한다.

```swift
import AsyncAlgorithms

for await _ in AsyncTimerSequence.repeating(every: .seconds(1)) {
    print("tick")
}
```

`AsyncTimerSequence`는 `Clock`/`Duration`을 쓰므로 iOS 16+다. iOS 15 타깃이면 `Task.sleep(nanoseconds:)` 루프나 Combine Timer를 쓴다.

```swift
// iOS 15에서 쓸 수 있는 형태
while !Task.isCancelled {
    try await Task.sleep(nanoseconds: 1_000_000_000)
    print("tick")
}
```

## 7. 실전 적용 예시: 실시간 주식 가격

실시간 주식 가격을 서버에서 지속적으로 전달받는 기능을 생각해 보자.

요구사항:

- 서버에서 가격 데이터가 지속적으로 전달된다.
- 클라이언트는 가격을 화면에 표시한다.
- 네트워크 연결이 끊기면 오류를 처리한다.
- 화면을 벗어나면 구독을 종료한다.

이때 활용할 수 있는 개념은 다음과 같다.

| 요구사항 | 활용 개념 |
|---|---|
| 가격 데이터 전달 | `continuation.yield(price)` |
| 네트워크 오류 종료 | `continuation.finish(throwing: error)` |
| 데이터 소비 | `for try await` |
| 구독 종료 감지 | `continuation.onTermination` |
| 외부 리소스 정리 | 네트워크 구독 해제 및 Observer 제거 |
| 데이터 과다 발생 제어 | `BufferingPolicy` |

```swift
// PriceSocket: 콜백 기반 SDK라고 가정
func priceStream(symbol: String) -> AsyncThrowingStream<Double, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let socket = PriceSocket(symbol: symbol)

        socket.onPrice = { price in
            continuation.yield(price)
        }
        socket.onError = { error in
            continuation.finish(throwing: error)
        }

        continuation.onTermination = { _ in
            socket.disconnect()
        }

        socket.connect()
    }
}

// SwiftUI
.task {
    do {
        for try await price in priceStream(symbol: "AAPL") {
            currentPrice = price
        }
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

```
화면 진입 → .task 시작 → socket.connect()
가격 수신 → yield → 버퍼 1칸 (최신만) → 화면 갱신
연결 끊김 → finish(throwing:) → catch → 오류 표시
화면 이탈 → .task 취소 → onTermination(.cancelled) → socket.disconnect()
```

핵심은 데이터 생산과 소비를 분리하고, 스트림의 생명주기와 외부 리소스의 생명주기를 함께 관리하는 것이다.

## 핵심 정리

1. `AsyncSequence`는 여러 요소를 비동기적으로 순회하는 프로토콜이다.
2. `for await`는 다음 요소가 준비될 때까지 비동기적으로 기다릴 수 있다.
3. `AsyncStream`은 기존 이벤트 기반 API를 AsyncSequence 형태로 연결할 때 유용하다.
4. `yield()`는 스트림에 요소를 전달하고, `finish()`는 스트림을 종료한다.
5. `BufferingPolicy`는 생산자와 소비자의 속도 차이로 발생하는 버퍼 증가를 제어한다.
6. `AsyncThrowingStream`은 여러 요소를 전달하면서 오류 종료도 표현할 수 있다.
7. `onTermination`은 스트림 종료 시 외부 리소스를 정리하는 데 활용할 수 있다.
8. Task Cancellation은 외부 작업을 자동으로 취소하지 않으므로 실제 리소스 정리는 직접 구현해야 한다.
9. URLSession과 NotificationCenter 등 Apple 프레임워크에서도 AsyncSequence 기반 API를 활용할 수 있다.
10. AsyncStream은 소비자 하나를 전제로 한다. 여러 곳에서 구독하려면 스트림을 따로 만든다.
11. 소비 Task가 취소되면 순회는 자동으로 끝나고 `onTermination(.cancelled)`가 불린다. 외부 구독 해제는 그 안에서 직접 한다.

**핵심 관점:** AsyncSequence는 하나의 비동기 결과를 기다리는 것을 넘어, 지속적으로 발생하는 여러 비동기 이벤트와 데이터를 순차적으로 처리하기 위한 추상화다.

## 참고 자료

**공식**

- [Swift — AsyncSequence](https://developer.apple.com/documentation/swift/asyncsequence)
- [Swift — AsyncStream](https://developer.apple.com/documentation/swift/asyncstream)
- [Swift — AsyncStream.Continuation.YieldResult](https://developer.apple.com/documentation/swift/asyncstream/continuation/yieldresult)
- [Swift — AsyncThrowingStream](https://developer.apple.com/documentation/swift/asyncthrowingstream)
- [Foundation — URLSession.bytes(from:delegate:)](https://developer.apple.com/documentation/foundation/urlsession/bytes(from:delegate:)) — iOS 15+
- [Foundation — NotificationCenter.notifications(named:object:)](https://developer.apple.com/documentation/foundation/notificationcenter/notifications(named:object:)) — Notification 비 Sendable과 map 해결법
- [WWDC21 — Meet AsyncSequence](https://developer.apple.com/videos/play/wwdc2021/10058)
- [WWDC21 — Use async/await with URLSession](https://developer.apple.com/videos/play/wwdc2021/10095) — bytes, lines
- [WWDC22 — Meet Swift Async Algorithms](https://developer.apple.com/videos/play/wwdc2022/110355)
- [SE-0298 Async/Await: Sequences](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0298-asyncsequence.md)
- [SE-0314 AsyncStream and AsyncThrowingStream](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md)
- [SE-0388 Convenience Async[Throwing]Stream.makeStream methods](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0388-async-stream-factory.md)
- [SE-0421 Generalize effect polymorphism for AsyncSequence and AsyncIteratorProtocol](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0421-generalize-async-sequence.md)
- [Swift Async Algorithms — Timer 가이드](https://github.com/apple/swift-async-algorithms/blob/main/Sources/AsyncAlgorithms/AsyncAlgorithms.docc/Guides/Timer.md)
- [Apple Developer Forums — Non-sendable Warning for notifications(named:) (Quinn 답변)](https://developer.apple.com/forums/thread/718565)

**외부**

- [Hacking with Swift — makeStream (Swift 5.9)](https://www.hackingwithswift.com/swift/5.9/convenience-asyncthrowingstream-makestream)
- [Donny Wals — Building an AsyncSequence with AsyncStream.makeStream (2024)](https://www.donnywals.com/building-an-asyncsequence-with-asyncstream-makestream/) — 델리게이트 감싸기, 생명주기 문제
- [Swift Forums — Consuming an AsyncStream from multiple Tasks Redux (2024)](https://forums.swift.org/t/consuming-an-asyncstream-from-multiple-tasks-redux/69818) — 다중 소비자 동작 차이
- [Swift Forums — re-introduce concurrent iteration runtime error for AsyncStream (2024)](https://forums.swift.org/t/question-how-to-re-introduce-concurrent-iteration-runtime-error-for-asyncstream/71831) — Swift 5.7에서 AsyncStream의 fatalError가 빠진 경위
- [Swift Forums — [Pitch] MultiProducerSingleConsumerAsyncChannel](https://forums.swift.org/t/pitch-multiproducersingleconsumerasyncchannel/78932) — 한 소비자 취소가 전체를 종료시키는 문제
- [Swift Forums — AsyncSequences and cooperative task cancellation](https://forums.swift.org/t/asyncsequences-and-cooperative-task-cancellation/62657) — 취소 후 yield가 .terminated 되는 실행 결과
