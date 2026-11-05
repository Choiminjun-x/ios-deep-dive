# Continuation

> 작성일: 2026-11-05

## 큰 그림

```
async 함수 (Task)
 → withChecked(Throwing)Continuation { continuation in … }
      → 클로저 본문은 즉시 실행: 기존 API 호출, continuation 전달
      → Task는 여기서 중단 (스레드는 막지 않음)
 → 기존 API의 completion handler 호출 (어느 스레드든)
      → continuation.resume(...)   ← 정확히 한 번
 → Task가 중단 지점에서 재개, 값 반환 또는 throw

취소가 끼어들면
 → withTaskCancellationHandler의 onCancel이 다른 스레드에서 동시에 실행
 → completion과 onCancel이 같은 continuation을 두고 경합
 → Bridge 객체 + lock으로 "먼저 확정한 쪽만" resume
```

Continuation은 콜백 세계와 async 세계 사이의 다리다. 다리는 한 번만 건넌다.

## 1. Continuation이란?

Continuation은 기존 Completion Handler 기반 비동기 API를 Swift Concurrency의 `async/await` 인터페이스로 연결하는 Adapter 역할을 한다.

기존 비동기 API는 작업이 완료되면 Completion Handler를 호출하여 결과를 전달한다. Continuation을 사용하면 해당 결과를 중단된 Task에 전달하여 `async/await` 방식으로 사용할 수 있다.

즉, 기존 비동기 API를 제거하거나 대체하는 것이 아니라 기존 API를 Swift Concurrency 환경에서 사용할 수 있도록 연결하는 것이다.

### 기존 Completion Handler 방식

```swift
func requestData(completion: @escaping (Data?) -> Void) {
    let url = URL(string: "https://example.com/data")!

    URLSession.shared.dataTask(with: url) { data, _, error in
        guard error == nil else {
            completion(nil)
            return
        }

        completion(data)
    }.resume()
}
```

사용할 때마다 Completion Handler를 전달해야 한다.

```swift
requestData { data in
    print(data)
}
```

### Continuation을 이용한 async 인터페이스

```swift
func requestData() async -> Data? {
    await withCheckedContinuation { continuation in
        requestData { data in
            continuation.resume(returning: data)
        }
    }
}
```

이제 다음과 같이 사용할 수 있다.

```swift
Task {
    let data = await requestData()
    print(data)
}
```

기존 `requestData(completion:)`을 Continuation으로 감싸 `requestData() async`라는 새로운 인터페이스를 제공하는 것이다.

### 실행 순서

1. `withCheckedContinuation`의 클로저 본문이 바로 실행된다. 여기서 기존 API를 호출한다.
2. 본문이 끝나면 현재 Task가 중단된다.
3. 나중에 completion handler가 어느 스레드에서든 `resume`을 호출한다.
4. Task가 재개되어 `resume`에 넘긴 값이 `withCheckedContinuation`의 반환값이 된다.

continuation은 클로저 밖으로 꺼내 저장해 두었다가 나중에 resume해도 된다. delegate 기반 API(예: 위치 권한 요청)를 감쌀 때 이렇게 쓴다. continuation 자체가 Sendable이라 다른 스레드에서 resume해도 된다.

## 2. Continuation 종류

Swift Concurrency는 크게 두 가지 종류의 Continuation을 제공한다. 런타임 검사를 하는 Checked와 하지 않는 Unsafe이고, 각각 오류를 던지지 않는 버전과 던지는 버전이 있다.

| 함수 | 얻는 타입 | 결과 |
|---|---|---|
| `withCheckedContinuation` | `CheckedContinuation<T, Never>` | 값 반환 |
| `withCheckedThrowingContinuation` | `CheckedContinuation<T, any Error>` | 값 반환 또는 throw |
| `withUnsafeContinuation` | `UnsafeContinuation<T, Never>` | 값 반환 |
| `withUnsafeThrowingContinuation` | `UnsafeContinuation<T, any Error>` | 값 반환 또는 throw |

### 2.1 CheckedContinuation

`withCheckedContinuation`을 사용하며, 런타임에서 Continuation의 재개 규칙을 검사한다.

```swift
func requestData() async -> Data? {
    await withCheckedContinuation { continuation in
        requestData { data in
            continuation.resume(returning: data)
        }
    }
}
```

주요 특징:

- 성공 결과를 반환하는 비동기 작업에 사용한다.
- `resume(returning:)`으로 결과를 전달한다.
- 런타임에서 중복 재개와 미재개를 검사한다. 중복 재개는 크래시, 미재개는 continuation이 해제될 때 경고 로그로 알려 준다.

### 2.2 Throwing 버전 (withCheckedThrowingContinuation)

`withCheckedThrowingContinuation`을 사용하며, 비동기 작업의 성공과 실패를 모두 표현할 수 있다. 별도 타입이 아니라 오류 타입이 `any Error`인 `CheckedContinuation`이다.

```swift
func login() async throws -> Token {
    try await withCheckedThrowingContinuation { continuation in
        login { result in
            continuation.resume(with: result)
        }
    }
}
```

기존 API가 `Result<T, Error>`를 반환하는 경우 유용하다.

`resume(with:)`은 다음과 같이 동작한다.

- `.success(value)` → 값을 반환한다.
- `.failure(error)` → 오류를 throw한다.

호출하는 쪽에서는 일반적인 `do-try-catch`로 처리할 수 있다.

```swift
do {
    let token = try await login()
} catch {
    print(error)
}
```

resume 메서드 정리:

| 메서드 | 쓰는 경우 |
|---|---|
| `resume(returning:)` | 값 전달 |
| `resume()` | 반환 타입이 `Void`일 때 |
| `resume(throwing:)` | 오류 전달 (throwing 버전만) |
| `resume(with:)` | `Result`를 그대로 전달 |

### 2.3 UnsafeContinuation

`withUnsafeContinuation`, `withUnsafeThrowingContinuation`을 사용한다.

CheckedContinuation과 마찬가지로 비동기 작업의 결과를 Task에 전달하지만, 런타임에서 재개 횟수를 검사하지 않는다.

주요 특징:

- 런타임 검사 비용이 없다.
- 중복 재개 또는 미재개에 대한 런타임 보호가 없다.
- 개발자가 정확한 재개 규칙을 보장해야 한다.

CheckedContinuation과 UnsafeContinuation 모두 정확히 한 번 재개해야 한다.

일반적으로는 런타임 검사를 제공하는 CheckedContinuation을 우선 사용한다. 두 API의 사용법이 같으므로, 성능 측정으로 필요가 확인된 뒤에 Unsafe로 바꾸면 된다.

| 구분 | CheckedContinuation | UnsafeContinuation |
|---|---|---|
| 런타임 검사 | 제공 | 제공하지 않음 |
| 중복 재개 감지 | 크래시 (fatalError) | 감지 없음, 정의되지 않은 동작 |
| 미재개 감지 | 해제 시 경고 로그 | 감지 없음 |
| 재개 규칙 | 정확히 한 번 | 정확히 한 번 |
| 일반적인 선택 | 우선 사용 | 특별한 이유가 있을 때 |

## 3. Continuation의 resume 규칙

Continuation은 반드시 정확히 한 번 재개해야 한다.

| 재개 횟수 | 결과 |
|---|---|
| 0회 | 해당 Continuation을 기다리는 Task가 영원히 중단된 상태로 남는다. CheckedContinuation은 continuation이 해제될 때 경고 로그를 남긴다. |
| 1회 | 정상적으로 결과가 전달된다. |
| 2회 이상 | CheckedContinuation은 중복 재개를 감지해 크래시를 낸다. UnsafeContinuation은 정의되지 않은 동작이다. |

특히 기존 Completion Handler API를 감쌀 때 주의해야 한다.

기존 API가 성공, 실패, 취소 등 여러 경로에서 Completion Handler를 호출할 수 있다면 모든 경로에서 Continuation이 정확히 한 번만 재개되도록 설계해야 한다.

### 실무에서

| 콘솔·크래시 메시지 | 의미 | 확인할 곳 |
|---|---|---|
| `SWIFT TASK CONTINUATION MISUSE: f() leaked its continuation!` | resume 없이 continuation이 해제됨. 호출한 Task는 영원히 대기 | `guard … else { return }`처럼 resume 없이 빠져나가는 경로 |
| `Fatal error: SWIFT TASK CONTINUATION MISUSE: f() tried to resume its continuation more than once` | 두 번 resume | completion이 여러 번 불리는 API(진행률 콜백 등), 취소와 완료의 경합 |

- **화면 로딩 인디케이터가 영원히 돈다**: leaked 로그가 있는지 먼저 본다. 로그가 없는데 멈췄다면 continuation이 어딘가에 저장된 채 resume되지 않은 경우다
- **콜백이 여러 번 오는 API**(진행률, 스트림)는 continuation으로 감싸지 않는다. 여러 값을 내보내는 경우는 `AsyncStream`으로 감싼다

## 4. Continuation과 Task Cancellation

Continuation은 Task Cancellation과 자동으로 연동되지 않는다.

Task가 취소되더라도 다음 작업이 자동으로 수행되지 않는다.

- 기존 네트워크 요청 취소
- Continuation 자동 재개
- `CancellationError` 자동 발생

따라서 기존 Completion Handler 기반 API를 Continuation으로 감쌀 때는 취소 처리를 별도로 설계해야 한다.

### 4.1 withTaskCancellationHandler

Task Cancellation에 대응하기 위해 `withTaskCancellationHandler`를 사용할 수 있다.

```swift
await withTaskCancellationHandler {
    // 실제 비동기 작업
} onCancel: {
    // Task 취소 시 수행할 작업
}
```

각 클로저의 역할은 다음과 같다.

- `operation`: 실제 작업을 수행한다.
- `onCancel`: Task가 취소되었을 때 취소 처리를 수행한다.

주의사항:

- `onCancel`은 동기 클로저다.
- `operation`과 `onCancel`의 실행 시점이 경합할 수 있다. 작업 도중 취소되면 `onCancel`은 `operation`과 동시에(다른 스레드에서) 실행된다.
- CancellationHandler가 Continuation을 자동으로 재개해 주지는 않는다.
- Task가 이미 취소된 상태에서 호출하면 `onCancel`이 `operation`보다 먼저 즉시 실행된다. 그다음 `operation`도 실행된다.
- `onCancel`은 취소될 때 최대 한 번 호출되고, 취소되지 않으면 호출되지 않는다.

따라서 기존 네트워크 요청을 취소하고 Continuation에도 취소 결과를 전달하는 처리가 필요하다.

```
[ 작업 중 취소 ]      operation 실행 중 ──────────→
                       onCancel        ──→ (다른 스레드에서 동시에)

[ 이미 취소된 Task ]  onCancel → operation   (onCancel이 먼저)
```

### 버전 차이

| 시점 | `onCancel` 파라미터 |
|---|---|
| Swift 5.x ~ 6.1 SDK | `@Sendable () -> Void` |
| Xcode 26 SDK 문서 | `sending () -> Void`, 함수 전체는 `nonisolated(nonsending)` |

어느 쪽이든 `onCancel`은 다른 스레드에서 실행될 수 있으므로, 캡처하는 값은 동시 접근에 안전해야 한다. 5절의 Bridge가 `@unchecked Sendable` + lock인 이유다.

## 5. Continuation Bridge

기존 네트워크 요청을 Continuation으로 연결하면서 Cancellation까지 처리하려면 여러 실행 경로의 상태를 관리해야 한다.

대표적인 문제는 다음과 같다.

1. 네트워크 요청이 완료되면서 Completion Handler가 호출된다.
2. 거의 동시에 Task Cancellation이 발생한다.
3. 두 경로가 각각 Continuation을 재개하려고 할 수 있다.

Continuation은 정확히 한 번만 재개해야 하므로 동기화가 필요하다.

이를 위해 Bridge 객체를 만들어 Continuation과 네트워크 요청의 상태를 함께 관리할 수 있다.

### 5.1 Bridge의 역할

Bridge는 다음 책임을 가진다.

1. Continuation을 보관한다.
2. 네트워크 요청 객체를 보관한다.
3. 취소 및 완료 상태를 관리한다.
4. 정상 완료와 취소 중 먼저 처리된 경로만 유효하게 만든다.
5. Continuation을 정확히 한 번 재개한다.

### 5.2 주요 상태

| 프로퍼티 | 역할 |
|---|---|
| `lock` | 공유 상태에 대한 동시 접근을 보호한다. |
| `continuation` | 중단된 Task에 결과를 전달할 객체 |
| `dataTask` | 실제 네트워크 요청 객체 |
| `isCancelled` | 취소 요청 발생 여부 |
| `isFinished` | 결과 처리가 이미 끝났는지 여부 |

`isFinished`가 핵심이다.

정상 완료 또는 취소 중 하나가 먼저 처리되면 `isFinished = true`로 변경한다. 이후 도착하는 이벤트는 무시한다.

### 5.3 주요 메서드의 역할

- `installContinuation()`: Continuation을 Bridge에 등록한다. 이미 취소된 상태라면 바로 `CancellationError`로 재개한다.
- `installTask()`: 네트워크 요청 객체를 Bridge에 등록한다.
- `complete()`: 정상 완료 또는 오류 결과를 Continuation에 전달한다.
- `cancel()`: 네트워크 요청을 취소하고 Continuation에 `CancellationError`를 전달한다.

### 5.4 installTask에서 취소 여부를 확인하는 이유

Continuation 등록 이후 네트워크 요청 객체가 Bridge에 등록되기 전에 Task Cancellation이 발생할 수 있다.

이때 `cancel()`은 아직 등록되지 않은 네트워크 요청 객체를 취소할 수 없다.

따라서 `installTask()`에서 이미 취소되었는지 확인해야 한다.

```swift
let shouldCancel = isCancelled

if shouldCancel {
    task.cancel()
}
```

즉, 네트워크 요청 객체 등록보다 취소 요청이 먼저 도착하는 상황까지 처리하기 위한 것이다.

같은 이유로 `installContinuation()`에서도 취소 여부를 확인해야 한다. 4.1절처럼 이미 취소된 Task에서는 `onCancel`이 `operation`보다 먼저 실행된다. 그러면 `cancel()`이 호출되는 시점에는 재개할 continuation이 아직 없다.

```
취소 시점별로 누가 처리하나
 ① continuation 등록 전 → installContinuation이 CancellationError로 resume
 ② 등록 후, 요청 등록 전 → cancel()이 resume, installTask가 요청을 시작하지 않음
 ③ 요청 진행 중         → cancel()이 요청 취소 + resume, 늦게 온 complete()는 무시
```

### 5.5 Lock과 resume의 실행 순서

```swift
lock.lock()

guard !isFinished else {
    lock.unlock()
    return
}

isFinished = true

let continuation = self.continuation
self.continuation = nil

lock.unlock()

continuation?.resume(returning: data)
```

Lock 안에서 resume하면 안 되는 이유는 Apple 문서의 `withTaskCancellationHandler` 설명에 있다. `onCancel`은 Task 내부 lock을 잡은 상태로 호출될 수 있고, continuation의 resume도 같은 내부 lock을 잡는다. 그래서 다음과 같이 lock 순서가 엇갈리면 교착 상태가 된다.

```
스레드 A (취소):  Task 내부 lock 획득 → onCancel → bridge.cancel() → 내 lock 대기
스레드 B (완료):  내 lock 획득 → continuation.resume → Task 내부 lock 대기
→ 서로 상대가 가진 lock을 기다림 → 데드락
```

Apple 문서도 취소 핸들러가 lock을 잡는다면, 다른 코드는 그 lock을 잡은 채로 Task를 취소하거나 continuation을 resume하지 말라고 안내한다. resume과 `task.cancel()`을 모두 lock 밖에서 호출하는 이유다.

이러한 문제를 피하기 위해 다음 순서를 지킨다.

1. Lock 획득
2. 완료 상태 확인 및 변경
3. Continuation 참조 확보
4. Lock 해제
5. Continuation 재개

### 5.6 취소와 정상 완료의 경합

두 실행 경로 중 먼저 완료 처리를 획득한 경로만 유효하다.

**상황 A: 취소가 먼저 처리된 경우**

1. `cancel()` 실행
2. `isFinished = true`로 변경
3. 네트워크 요청 취소
4. Continuation에 `CancellationError` 전달
5. 이후 `complete()`가 호출되어도 이미 완료된 상태이므로 무시

최종 결과: `CancellationError`

**상황 B: 정상 완료가 먼저 처리된 경우**

1. `complete()` 실행
2. `isFinished = true`로 변경
3. 정상 데이터를 Continuation에 전달
4. 이후 `cancel()`이 호출되어도 이미 완료된 상태이므로 무시

최종 결과: 정상 데이터

여기서 먼저 처리된다는 것은 실제 이벤트가 발생한 시각이 아니라 Lock을 획득하여 완료 상태를 먼저 확정한 경로를 의미한다.

### 5.7 전체 코드

위 규칙을 모은 예시다. 학습용이며, 샘플 프로젝트에서 세 가지 취소 시점(5.4절)을 직접 재현해 확인하는 것을 권한다.

```swift
final class DataTaskBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var dataTask: URLSessionDataTask?
    private var isCancelled = false
    private var isFinished = false

    /// false를 반환하면 이미 취소되어 resume까지 끝난 상태
    func installContinuation(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        let alreadyCancelled = isCancelled
        if alreadyCancelled {
            isFinished = true
        } else {
            self.continuation = continuation
        }
        lock.unlock()

        if alreadyCancelled {
            continuation.resume(throwing: CancellationError())   // lock 밖
            return false
        }
        return true
    }

    /// false를 반환하면 요청을 시작하지 않는다
    func installTask(_ task: URLSessionDataTask) -> Bool {
        lock.lock()
        dataTask = task
        let shouldCancel = isCancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
        return !shouldCancel
    }

    func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        dataTask = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation   // ①이면 nil → installContinuation이 처리
        self.continuation = nil
        let task = dataTask
        dataTask = nil
        lock.unlock()

        task?.cancel()                                          // lock 밖
        continuation?.resume(throwing: CancellationError())     // lock 밖
    }
}

func requestData(from url: URL) async throws -> Data {
    let bridge = DataTaskBridge()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard bridge.installContinuation(continuation) else { return }

            let task = URLSession.shared.dataTask(with: url) { data, _, error in
                if let error {
                    bridge.complete(.failure(error))
                } else {
                    bridge.complete(.success(data ?? Data()))
                }
            }

            if bridge.installTask(task) {
                task.resume()
            }
        }
    } onCancel: {
        bridge.cancel()
    }
}
```

①의 경우 `cancel()`이 `isFinished = true`로 바꾸지만 resume할 continuation이 없다. 그래서 `installContinuation()`은 `isFinished`가 아니라 `isCancelled`를 보고 직접 resume한다.

### 실무에서

- 실제 네트워크라면 이 Bridge는 필요 없다. `URLSession.data(from:)`(iOS 15+)이 이미 취소를 지원한다. Bridge는 취소 가능한 객체(요청 핸들, 토큰)를 돌려주는 서드파티·레거시 API를 감쌀 때 쓴다
- iOS 16+이면 `NSLock` 대신 `OSAllocatedUnfairLock`, iOS 18+이면 `Mutex`로 바꿀 수 있다. `Mutex`를 쓰면 `@unchecked` 없이 Sendable이 된다 ([03](03_sendable.md) 5절)

## 6. 실무 적용 시 주의사항

- 기존 Completion Handler 기반 API를 async/await로 연결할 때 Continuation을 활용한다.
- CheckedContinuation을 우선 사용한다.
- 모든 성공, 실패, 취소 경로에서 정확히 한 번 재개되는지 확인한다.
- Task Cancellation은 Continuation에 자동으로 전달되지 않으므로 별도 처리가 필요하다.
- 취소와 완료가 경합할 수 있으므로 공유 상태를 동기화해야 한다.
- `@unchecked Sendable`을 사용한다면 내부 공유 가변 상태의 스레드 안전성을 직접 보장해야 한다.
- 이미 async 인터페이스를 제공하는 API라면 불필요하게 Continuation으로 다시 감쌀 필요가 없다.
- Objective-C의 completion handler 메서드는 Swift가 async 버전을 자동으로 만들어 준다(SE-0297). Apple 프레임워크 API는 감싸기 전에 async 버전이 있는지 먼저 확인한다.
- lock을 잡은 채로 resume하거나 Task를 취소하지 않는다.

## 핵심 정리

| 개념 | 핵심 내용 |
|---|---|
| Continuation | 기존 Completion Handler API를 async/await로 연결하는 Adapter |
| CheckedContinuation | 런타임에서 재개 규칙을 검사하는 Continuation |
| UnsafeContinuation | 런타임 검사 없이 개발자가 재개 규칙을 보장하는 Continuation |
| `resume()` | 중단된 Task에 결과를 전달하고 재개할 수 있도록 한다. |
| `withTaskCancellationHandler` | Task Cancellation에 대응하는 처리 영역을 제공한다. |
| Continuation Bridge | 취소와 정상 완료의 경합을 관리하고 정확히 한 번 재개하도록 보장하는 구조 |

**가장 중요한 원칙**

Continuation은 정확히 한 번 재개해야 한다. 또한 Task Cancellation과 Continuation 재개는 별개이므로 기존 비동기 API를 감쌀 때는 취소 처리와 상태 동기화를 함께 설계해야 한다.

1. 중복 resume은 크래시, 누락은 경고 로그와 영원한 대기다.
2. `onCancel`은 operation과 동시에 돌 수 있고, 이미 취소된 Task에서는 operation보다 먼저 돈다.
3. 취소 시점은 세 가지(continuation 등록 전, 요청 등록 전, 진행 중)이고 모두 처리해야 한다.
4. resume과 취소 호출은 lock 밖에서 한다.

## 셀프 체크

**Q1. continuation을 resume하지 않으면 어떻게 되나? Checked와 Unsafe의 차이는?**

- Task가 영원히 중단된다. Checked는 continuation이 해제될 때 "leaked its continuation" 경고를 남기고, Unsafe는 아무 표시도 없다

**Q2. `withCheckedThrowingContinuation`이 넘겨주는 타입은?**

- `CheckedContinuation<T, any Error>`이다. throwing 전용 타입이 따로 있는 게 아니다

**Q3. Task를 취소하면 continuation으로 감싼 요청도 취소되나?**

- 아니다. continuation은 취소를 모른다. `withTaskCancellationHandler`의 `onCancel`에서 요청을 취소하고 continuation을 직접 resume해야 한다

**Q4. 이미 취소된 Task에서 `withTaskCancellationHandler`를 호출하면 순서는?**

- `onCancel`이 먼저 즉시 실행되고, 그다음 `operation`이 실행된다. 그래서 continuation 등록 단계에서도 취소 여부를 확인해야 한다

**Q5. 왜 lock을 푼 뒤에 resume하나?**

- `onCancel`은 Task 내부 lock을 잡은 채 호출될 수 있고, resume도 그 내부 lock을 잡는다. 내 lock을 쥔 채 resume하면 lock 순서가 엇갈려 데드락이 날 수 있다

**Q6. 완료와 취소가 동시에 오면 결과는 무엇으로 정해지나?**

- 이벤트 발생 시각이 아니라, lock을 먼저 잡고 `isFinished`를 확정한 쪽의 결과다

## 참고 자료

**공식**

- [Swift — withCheckedContinuation](https://developer.apple.com/documentation/swift/withcheckedcontinuation(isolation:function:_:))
- [Swift — CheckedContinuation](https://developer.apple.com/documentation/swift/checkedcontinuation)
- [Swift — withTaskCancellationHandler(operation:onCancel:isolation:)](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:)) — 이미 취소된 경우의 순서, 동시 실행, "Cancellation handlers and locks"
- [SE-0300 Continuations for interfacing async tasks with synchronous code](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0300-continuation.md)
- [SE-0297 Concurrency Interoperability with Objective-C](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0297-concurrency-objc.md)
- [Apple Developer Forums — leaked its continuation (Quinn 답변)](https://developer.apple.com/forums/thread/732249) — 해제 시 경고의 의미
- [swift-nio PR #2558](https://github.com/apple/swift-nio/pull/2558) — lock 안에서 resume해 생긴 데드락을 제거한 Apple 저장소 사례

**외부**

- [Hacking with Swift — How to use continuations](https://www.hackingwithswift.com/quick-start/concurrency/how-to-use-continuations-to-convert-completion-handlers-into-async-functions) — 중복 resume 크래시, 누락 경고
- [Swift Forums — Deadlock with AsyncStreams and a single Mutex (2026, Swift 6.2.3)](https://forums.swift.org/t/deadlock-with-asyncstream-s-and-a-single-mutex/84584) — 취소 lock과 resume lock이 엇갈리는 실제 사례
- [Swift Forums — Automatically cancelling continuations (2024)](https://forums.swift.org/t/automatically-cancelling-continuations/72960) — 취소 가능한 continuation 래퍼 구현
- [Swift Forums — How to prevent SWIFT TASK CONTINUATION MISUSE (2022)](https://forums.swift.org/t/how-to-prevent-swift-task-continuation-misuse/57581) — 콜백을 여러 번 부르는 서드파티 API 사례
- [zenn — withTaskCancellationHandler](https://zenn.dev/holoholo/articles/2e9608003e9ac2) — 이미 취소된 Task에서 onCancel → operation 순서 실행 결과
