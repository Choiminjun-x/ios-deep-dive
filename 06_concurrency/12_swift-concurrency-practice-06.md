# Swift Concurrency 실전 6 — 캐시와 중복 요청

> 작성일: 2026-11-10

## 1. 문제 상황

상품 상세 정보를 캐싱하는 Actor를 가정한다.

```swift
actor ProductCache {
    private var cache: [Int: Product] = [:]

    func fetchProduct(id: Int) async throws -> Product {
        if let cached = cache[id] {
            return cached
        }

        let product = try await API.fetchProduct(id: id)

        cache[id] = product
        return product
    }
}
```

동일한 상품을 거의 동시에 요청하는 상황이다.

```swift
async let first = cache.fetchProduct(id: 100)
async let second = cache.fetchProduct(id: 100)

let (product1, product2) = try await (first, second)
```

Actor를 사용하고 있지만 API가 두 번 호출될 수 있다.

### 실전 5와 달라진 점

| 구분 | 실전 5 (장바구니) | 실전 6 (캐시) |
|---|---|---|
| 재진입으로 생기는 문제 | 값이 덮어써짐 (Lost Update) | 같은 요청이 중복 실행됨 |
| 해결 방향 | 읽기·쓰기를 `await` 뒤 한 동기 구간으로 | 진행 중인 요청을 저장해 공유 |
| 새 주제 | — | 공유 요청의 정리와 취소 |

## 2. 중복 요청이 발생하는 이유

첫 번째 작업이 API 응답을 기다리는 동안 Actor가 다른 작업을 처리할 수 있기 때문이다.

### 실행 흐름

1. 작업 A가 캐시를 확인한다. → 없음
2. 작업 A가 API를 호출하고 `await`에서 대기한다.
3. 작업 B가 캐시를 확인한다. → 없음
4. 작업 B도 API를 호출하고 대기한다.
5. 두 작업이 각각 API 응답을 받아 캐시에 저장한다.

결국 동일한 상품에 대한 API 요청이 두 번 발생한다.

이는 Actor Reentrancy로 인해 발생하는 논리적 경쟁 상태다.

```
작업 A: [캐시 확인: 없음] ─await API─────────────── [cache[100] = P1]
작업 B:                  [캐시 확인: 없음] ─await API────────── [cache[100] = P2]
                          ↑ A가 await 중이라 B가 actor에 들어옴
```

값은 결국 같은 상품이라 화면은 정상으로 보인다. 그래서 이 버그는 서버 로그나 네트워크 탭에서 "같은 요청이 두 번"으로만 드러난다.

WWDC21 "Protect mutable state with Swift actors"의 이미지 다운로더 예제가 같은 문제를 다룬다. 개념 정리는 [04_actor.md의 5장](04_actor.md)에 있다.

## 3. In-flight Request Deduplication

이 문제를 해결하려면 캐시뿐 아니라 현재 진행 중인 요청도 관리해야 한다.

```swift
actor ProductCache {
    private var cache: [Int: Product] = [:]

    private var inFlightTasks: [Int: Task<Product, Error>] = [:]
}
```

각 저장소의 역할은 다음과 같다.

| 저장소 | 역할 |
|---|---|
| `cache` | 이미 가져온 상품 저장 |
| `inFlightTasks` | 현재 가져오는 중인 상품의 Task 저장 |

### 요청 처리 흐름

1. 캐시에 상품이 있는지 확인한다.
2. 캐시에 없다면 진행 중인 요청이 있는지 확인한다.
3. 기존 요청이 있다면 해당 Task의 `value`를 기다린다.
4. 진행 중인 요청도 없다면 새로운 Task를 생성한다.
5. `await` 전에 Task를 `inFlightTasks`에 등록한다.
6. 요청 결과를 캐시에 저장하고 진행 중인 요청 정보를 정리한다.

### 핵심 코드 구조

```swift
if let cached = cache[id] {
    return cached
}

if let existingTask = inFlightTasks[id] {
    return try await existingTask.value
}

let task = Task {
    try await API.fetchProduct(id: id)
}

// 반드시 await 전에 등록
inFlightTasks[id] = task

let product = try await task.value
cache[id] = product

return product
```

위 코드는 핵심 흐름을 보여주는 개념 예제다. 실제 구현에서는 성공과 실패에 따른 정리, 동시 취소, 요청 교체까지 처리해야 한다.

```
작업 A: [캐시 없음 → 진행 중 없음 → Task 생성 → 등록] ─await task.value──── [cache 저장]
작업 B:                                  [캐시 없음 → 진행 중 있음!] ─await 같은 task.value─
         ↑ 확인부터 등록까지 await 없이 한 동기 구간 → B는 반드시 등록된 Task를 본다
```

"반드시 await 전에 등록"이 핵심인 이유는 실전 5와 같다. 확인과 등록 사이에 중단 지점이 없어야 다른 작업이 끼어들지 못한다.

### 실무에서 — 이 코드에는 정리가 없다

위 코드는 `inFlightTasks[id]`를 한 번도 지우지 않는다. 그래서 두 가지 문제가 생긴다.

| 경우 | 증상 |
|---|---|
| 성공 | 캐시와 `inFlightTasks` 양쪽에 남는다. 캐시를 비워도(무효화해도) 끝난 Task의 값이 계속 재사용된다 |
| 실패 | 실패한 Task가 계속 남는다. 이후 같은 id 요청은 모두 그 Task를 기다리고 **같은 오류를 즉시 다시 받는다** (재시도 불가) |

실패 쪽이 특히 위험하다. 네트워크가 잠깐 끊겼을 때 한 번 실패한 상품은 앱을 다시 켤 때까지 계속 실패한다. 성공이든 실패든 끝나면 지우고, 성공했을 때만 캐시에 저장한다. 실패는 캐시하지 않는다.

### 실무에서 — 내부 Task는 호출자의 취소를 물려받지 않는다

actor 안에서 만든 `Task { }`는 Unstructured Task다. 이 Task를 만든 호출자가 취소돼도 함께 취소되지 않는다.

또한 `await task.value`는 기다리는 쪽이 취소돼도 Task를 취소하지 않고, 기다림을 끝내지도 않는다. Task가 끝날 때까지 계속 기다린다.

| 성질 | 장점 | 단점 |
|---|---|---|
| 호출자 취소가 공유 Task로 전파되지 않음 | 화면 A가 나가도 화면 B의 요청이 살아 있음 (5장 요구사항) | 모두 나가도 요청이 계속 실행됨 |
| `await task.value`가 취소에 반응하지 않음 | — | 취소된 호출자도 결과가 올 때까지 반환되지 않음 |

이 성질 때문에 5·6장의 구독자 관리가 필요하다. 호출자의 취소를 감지하려면 `withTaskCancellationHandler`로 `task.value`를 감싼다 ([05_continuation.md](05_continuation.md)에서 다룬 API).

## 4. 요청 정리와 Request ID

진행 중인 요청이 완료되면 `inFlightTasks`에서 해당 요청을 제거해야 한다.

하지만 이전 요청의 정리 코드가 새로운 요청을 제거하지 않도록 주의해야 한다.

예를 들어 다음 상황이 가능하다.

1. 상품 100번에 대한 이전 요청 A가 실패한다.
2. 새로운 요청 B가 상품 100번에 등록된다.
3. 요청 A의 정리 코드가 실행된다.
4. 단순히 `inFlightTasks[100] = nil`을 수행하면 요청 B까지 제거할 수 있다.

2번이 가능하려면 A의 항목이 A의 정리 코드보다 먼저 다른 경로로 지워져 있어야 한다. 예를 들어 6장의 구독 해제(구독자 0 → 제거), 강제 새로고침으로 요청 교체, 다른 대기자가 먼저 정리한 경우다. 정리 경로가 여러 개라서 생기는 문제다.

```
A 등록 → 다른 경로가 A 항목 제거 → B 등록 → A의 정리 코드 실행
                                              inFlightTasks[100] = nil  ← B가 지워짐
                                              → 다음 요청 C가 B를 못 보고 중복 요청
```

이를 방지하려면 요청별 식별자를 사용한다.

```swift
private var inFlightTasks: [Int: (requestID: UUID, task: Task<Product, Error>)] = [:]

let requestID = UUID()

inFlightTasks[id] = (requestID, task)

// 요청 완료 후
if inFlightTasks[id]?.requestID == requestID {
    inFlightTasks[id] = nil
}
```

Request ID를 비교하여 현재 등록된 요청과 자신이 정리하려는 요청이 동일한 경우에만 제거한다.

`?.requestID`로 접근하려면 딕셔너리 값을 이름 붙은 튜플(또는 구조체)로 선언해야 한다.

### UUID 대신 Task 자체를 비교해도 된다

`Task`는 `Hashable`(`Equatable`)을 따른다. 같은 Task 인스턴스인지 비교할 수 있으므로, 별도의 UUID 없이도 확인할 수 있다.

```swift
if inFlightTasks[id] == task {
    inFlightTasks[id] = nil
}
```

실전 1·2의 Request ID와 같은 역할이다. "내가 등록한 그것이 아직 그 자리에 있을 때만 정리한다."

## 5. 공유 Task와 취소

이번 실습에서는 여러 화면이 하나의 API 요청을 공유하는 상황도 다뤘다.

### 상황

1. 화면 A가 상품 100번을 요청한다.
2. 화면 B도 상품 100번을 요청한다.
3. 두 화면이 동일한 Task를 기다린다.
4. 화면 A가 이탈한다.

이때 화면 A의 취소가 공유 Task까지 취소해서는 안 된다.

화면 B는 여전히 결과를 기다리고 있기 때문이다.

따라서 다음 두 가지를 분리해야 한다.

- 개별 구독자의 대기 작업 취소
- 공유 API 요청 자체의 취소

```
화면 A (.task) ─┐
                ├─→ fetchProduct(100) 대기 ─→ 공유 Task ─→ API 요청 1번
화면 B (.task) ─┘

화면 A 이탈 → A의 대기만 취소 (공유 Task 유지)
화면 B 이탈 → 남은 구독자 0 → 공유 Task 취소
```

## 6. Reference Count를 이용한 취소 관리

공유 요청을 기다리는 구독자 수를 관리하는 방법을 사용할 수 있다.

```swift
struct InFlightRequest {
    let task: Task<Product, Error>
    var subscriberCount: Int
}
```

예시:

| 이벤트 | 구독자 수 |
|---|---:|
| 화면 A 요청 | 1 |
| 화면 B 요청 | 2 |
| 화면 A 이탈 | 1 |
| 화면 B 이탈 | 0 |

구독자가 남아 있다면 공유 Task를 유지한다.

구독자 수가 0이 되면 공유 Task를 취소할 수 있다.

개념적으로는 다음과 같다.

```swift
func unsubscribe(id: Int) {
    guard var request = inFlightRequests[id] else {
        return
    }

    request.subscriberCount -= 1

    if request.subscriberCount == 0 {
        request.task.cancel()
        inFlightRequests[id] = nil
    } else {
        inFlightRequests[id] = request
    }
}
```

`InFlightRequest`는 값 타입(struct)이다. 그래서 `var request`로 꺼내 수정한 뒤 다시 딕셔너리에 넣어야 반영된다. 마지막 `else`의 재할당이 빠지면 구독자 수가 줄지 않는다.

이 코드는 개념 설명용이다. 실제 구현에서는 다음 사항을 추가로 고려해야 한다.

- 구독자별 식별자를 통한 중복 해제 방지
- 요청 완료와 구독 해제가 동시에 발생하는 상황
- 완료된 요청의 구독자 정보 정리
- 취소된 요청의 결과가 늦게 도착하는 상황
- 이전 요청이 새로운 요청의 상태를 제거하지 않도록 하는 Request ID 검증

또한 `Task.cancel()`은 협력적 취소 요청이므로 실제 네트워크 요청이 즉시 중단되는지는 API의 취소 지원 여부에 달려 있다.

### 실무에서 — 통합 구현 예시

위 고려 사항을 반영한 형태다. 학습용 예시이며, 이 정리 환경에 Swift 툴체인이 없어 컴파일은 확인하지 못했다 (샘플 프로젝트에서 확인 필요).

```swift
actor ProductCache {
    private struct InFlightRequest {
        let requestID: UUID
        let task: Task<Product, Error>
        var subscriberCount: Int
    }

    private var cache: [Int: Product] = [:]
    private var inFlightRequests: [Int: InFlightRequest] = [:]

    func fetchProduct(id: Int) async throws -> Product {
        // 1. 캐시 확인
        if let cached = cache[id] {
            return cached
        }

        // 2. 진행 중인 요청에 합류하거나 새로 만든다 (여기까지 await 없음)
        let request: InFlightRequest
        if var existing = inFlightRequests[id] {
            existing.subscriberCount += 1
            inFlightRequests[id] = existing
            request = existing
        } else {
            request = InFlightRequest(
                requestID: UUID(),
                task: Task { try await API.fetchProduct(id: id) },
                subscriberCount: 1
            )
            inFlightRequests[id] = request
        }

        let requestID = request.requestID
        let task = request.task

        // 3. 기다린다. 호출자가 취소되면 구독만 해제한다
        do {
            let product = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.unsubscribe(id: id, requestID: requestID) }
            }
            finish(id: id, requestID: requestID, product: product)
            return product
        } catch {
            finish(id: id, requestID: requestID, product: nil)
            throw error
        }
    }

    // 완료 정리: 성공이면 캐시, 실패면 캐시하지 않음. 내 요청일 때만 제거
    private func finish(id: Int, requestID: UUID, product: Product?) {
        guard inFlightRequests[id]?.requestID == requestID else { return }
        if let product {
            cache[id] = product
        }
        inFlightRequests[id] = nil
    }

    // 구독 해제: 이미 끝났거나 교체된 요청이면 아무것도 하지 않음
    private func unsubscribe(id: Int, requestID: UUID) {
        guard var request = inFlightRequests[id],
              request.requestID == requestID else { return }

        request.subscriberCount -= 1

        if request.subscriberCount == 0 {
            request.task.cancel()
            inFlightRequests[id] = nil
        } else {
            inFlightRequests[id] = request
        }
    }
}
```

| 고려 사항 | 이 코드에서 처리한 곳 |
|---|---|
| 성공·실패 정리 | `finish` — 성공만 캐시, 둘 다 제거 |
| 요청 완료와 구독 해제가 동시에 | `unsubscribe`의 `requestID` 가드 — 이미 끝나 제거됐으면 무시 |
| 이전 요청이 새 요청을 지우지 않게 | `finish`·`unsubscribe` 모두 `requestID` 비교 |
| 중복 해제 | `onCancel`은 호출자 Task마다 최대 한 번 불린다 |
| 취소된 요청의 결과가 늦게 도착 | 공유 Task가 취소되면 `task.value`가 throw → `finish`에서 가드에 걸려 무시 |

남는 한계:

- `onCancel`은 동기 클로저라 actor 메서드를 바로 부를 수 없다. 그래서 `Task { await self.unsubscribe(...) }`로 넘긴다. 이 Task는 약간 늦게 실행될 수 있지만, `requestID` 가드 덕분에 순서가 바뀌어도 안전하다
- 취소된 호출자도 공유 Task가 끝날 때까지는 반환되지 않는다(`task.value`가 취소에 반응하지 않으므로). 화면 이탈 용도라면 보통 문제없다. 즉시 반환이 필요하면 구독자마다 continuation을 두는 더 복잡한 구조가 필요하다
- 구독자가 남아 있는데 취소된 호출자는 정상 결과를 받는다. 호출하는 쪽에서 반영 전에 `Task.isCancelled`를 확인한다 (실전 3)

### 실무에서 — 디버깅

- `API.fetchProduct` 진입 시 로그를 찍고, 1장의 `async let` 두 개로 호출한다. 수정 전에는 2번, 수정 후에는 1번 찍혀야 한다
- 비행기 모드로 한 번 실패시킨 뒤 네트워크를 켜고 다시 요청한다. 실패 정리가 없으면 다시 요청해도 계속 실패한다
- 화면 A·B를 띄우고 A만 닫았을 때 B에 결과가 오는지, 둘 다 닫았을 때 요청이 cancelled로 끊기는지 Network 탭에서 본다

## 7. 세 가지 생명주기

캐시와 중복 요청 관리는 단순히 데이터를 저장하는 문제가 아니다.

동일한 비동기 작업을 여러 호출자가 공유할 때는 다음 세 가지 생명주기를 구분해야 한다.

1. 캐시 데이터의 생명주기
2. 공유 API 요청의 생명주기
3. 개별 호출자 또는 구독자의 생명주기

이 세 가지를 명확하게 분리해야 중복 요청, 잘못된 취소, 오래된 요청의 상태 정리 문제를 방지할 수 있다.

| 생명주기 | 시작 | 끝 | 이 노트에서 관리하는 곳 |
|---|---|---|---|
| 캐시 데이터 | 첫 성공 응답 | 무효화(만료, 로그아웃, 메모리 경고) | `cache` |
| 공유 API 요청 | 첫 호출자가 Task 생성 | 완료·실패, 또는 구독자 0 → 취소 | `inFlightRequests` + `requestID` |
| 개별 호출자 | `fetchProduct` 호출 | 결과 반환 또는 호출자 Task 취소 | `subscriberCount` + `withTaskCancellationHandler` |

### 실무에서

- 이 노트의 `cache`는 계속 커진다. 실제 앱에서는 만료 시간(TTL), 개수 제한, 메모리 경고 시 비우기, 로그아웃 시 초기화 같은 정책이 필요하다
- 캐시를 무효화할 때 진행 중인 요청도 함께 버릴지 정해야 한다. 버린다면 `inFlightRequests`도 비우고, 늦게 끝난 요청이 다시 캐시에 쓰지 않도록 `finish`의 `requestID` 가드가 이를 막는다

## 핵심 정리

- Actor를 사용해도 캐시 확인과 API 응답 사이에 Reentrancy가 발생한다.
- 캐시만으로는 진행 중인 중복 요청을 방지할 수 없다.
- `inFlightTasks`로 현재 실행 중인 요청을 관리한다.
- 동일한 요청이 이미 있다면 기존 Task의 `value`를 기다린다.
- 새로운 Task는 `await` 전에 등록해야 한다.
- 요청 정리 시 Request ID를 비교해 다른 요청을 제거하지 않도록 한다.
- 공유 Task의 취소와 개별 구독자의 취소는 분리해야 한다.
- 구독자 수가 0이 된 경우 공유 요청 취소를 고려할 수 있다.
- 완료된 요청은 성공·실패 모두 정리한다. 정리가 없으면 한 번 실패한 요청이 계속 같은 오류를 돌려준다.
- actor 안의 `Task {}`는 호출자의 취소를 물려받지 않고, `await task.value`는 취소에 반응하지 않는다. 취소 감지는 `withTaskCancellationHandler`로 한다.
- `Task`는 `Hashable`이므로 UUID 대신 Task 자체를 비교해 "내 요청인지" 확인할 수도 있다.

## 참고 자료

**공식**

- [WWDC21 — Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) — 이미지 다운로더, 진행 중 Task를 캐시에 저장하는 패턴
- [WWDC23 — Beyond the basics of structured concurrency](https://developer.apple.com/videos/play/wwdc2023/10170) — Unstructured Task는 명시적으로 취소, withTaskCancellationHandler
- [Swift — Task](https://developer.apple.com/documentation/swift/task) — Equatable·Hashable 준수, value
- [Swift — withTaskCancellationHandler(operation:onCancel:isolation:)](https://developer.apple.com/documentation/swift/withtaskcancellationhandler(operation:oncancel:isolation:))
- [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md) — Actor reentrancy

**외부**

- [Swift Forums — Why doesn't `await task.value` set up a cancellation handler?](https://forums.swift.org/t/why-doesnt-await-task-value-set-up-a-cancellation-handler/57740) — task.value가 취소를 전파하지 않는 이유와 우회법
- [Swift Forums — Understanding Task cancellation (2024)](https://forums.swift.org/t/understanding-task-cancellation/75329) — withTaskCancellationHandler로 Unstructured Task에 취소 전파
- [Swift Forums — Structured caching in an actor](https://forums.swift.org/t/structured-caching-in-an-actor/65501)
- [Donny Wals — Actor reentrancy in Swift explained (2024)](https://donnywals.com/actor-reentrancy-in-swift-explained) — 진행 중 Task를 저장하는 캐시
