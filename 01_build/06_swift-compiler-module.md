# Swift 컴파일러 내부와 모듈

> 작성일: 2026-10-12

## 큰 그림

```
⌘B
 → Xcode가 설정을 읽고 명령어 조립              ← Xcode 프로젝트 구조와 빌드 설정
 → swiftc: .swift → .o                        ← 이 노트
     ① 읽기 → ② 뜻 확인 → ③ 번역 → ④ 다듬기
     다른 파일·모듈의 선언은 어떻게 아나?
     무엇을 다시 번역하나? (증분 빌드)
     파일마다 따로 vs 통째로 (Debug vs Release)
     어디가 느린가? (Build Timeline)
 → ld: .o → 실행 파일                          ← 심볼과 링킹
```

[iOS 빌드 과정](02_build-process.md)에서 "소스 → `.o`" 한 줄로 적었던 컴파일 단계를 펼쳐 본다.

## 1. 컴파일러는 단계를 나눠 번역한다

CPU는 기계어만 읽는다. 컴파일러(`swiftc`)는 Swift를 기계어로 번역하는데, 한 번에 하지 않고 단계를 나눈다.

```
Swift 코드
 → ① 읽기 (Parse)        문법이 맞나?          → 타입 정보 없는 AST
 → ② 뜻 확인 (Sema)      타입이 맞나?          → 타입이 붙은 AST
      ↑ ClangImporter: UIKit 같은 ObjC/C 모듈을 Swift 선언으로 바꿔 넣어 줌
 → ③ 번역 (SILGen + 필수 패스)  실행 흐름 점검   → SIL (Swift 전용 중간 언어)
 → ④ 다듬기 (SIL 최적화)   더 빠르게, -O일 때만
 → IRGen → LLVM          LLVM IR → 기계어       → .o
```

| 단계 | 하는 일 | 여기서 나는 에러 예 |
|---|---|---|
| ① 읽기 | 문법만 본다 | `let x = 1 +` → 문장이 안 끝남 |
| ② 뜻 확인 | 타입 체크·추론 | `let x: Int = "hello"` → `Cannot convert value of type…` |
| ③ 번역 + 점검 | 실행 흐름을 따라가며 진단 | 값을 넣은 적 없는 `let a: Int`를 `return a` → 초기화 전 사용 |
| ④ 다듬기 | 함수 펼쳐 넣기, 제네릭 특수화, ARC 최적화 | — |

clang은 AST에서 바로 LLVM IR로 가지만, Swift는 중간에 **SIL**을 하나 더 거친다. ARC·제네릭·프로토콜처럼 LLVM이 모르는 개념을 이 층에서 진단하고 최적화한다.

직접 보기:

```bash
xcrun swiftc -dump-parse hello.swift        # ① 타입 없는 AST
xcrun swiftc -dump-ast hello.swift          # ② 타입 붙은 AST
xcrun swiftc -emit-silgen hello.swift       # raw SIL
xcrun swiftc -emit-sil -Onone hello.swift   # ③ 필수 패스 후 SIL
xcrun swiftc -emit-sil -O hello.swift       # ④ 최적화 후 SIL
xcrun swiftc -emit-ir -O hello.swift        # LLVM IR
xcrun swiftc -S -O hello.swift              # 어셈블리
```

### 실무에서

- 에러를 고쳤더니 새 에러가 또 나오는 건 앞 단계가 실패하면 뒤 단계가 돌지 않기 때문이다. 문법 에러를 고쳐야 타입 에러가, 타입 에러를 고쳐야 "초기화 전 사용" 에러가 보인다
- 빌드 로그(Report navigator)에서 Swift 컴파일 줄을 펼치면 `swift-frontend -frontend -c -primary-file …` 형태가 보인다

## 2. 다른 파일·모듈의 선언을 찾는 법

### 같은 모듈의 다른 파일 → 겉모습만 훑는다

```swift
// A.swift
func hello() { print("hi") }

// B.swift
hello()      // import 없이 사용
```

B.swift를 번역할 때 같은 타겟의 A.swift도 읽는다. 단, **겉모습**(이름·매개변수·반환 타입)만 보고 안쪽 코드는 보지 않는다. 호출이 맞는지 판단하는 데는 겉모습이면 충분하다.

```swift
func hello() { print("hi") }
//  ↑ 이것만 확인     ↑ 안쪽은 안 봄
```

헤더가 없는 Swift는 이렇게 파일 하나를 번역할 때도 같은 모듈의 다른 파일을 함께 파싱한다. clang이 `.m` 하나만 보고 `#import`한 헤더로 선언을 찾는 것과 다른 점이다.

### 다른 모듈 → .swiftmodule 요약본을 읽는다

Alamofire 같은 다른 모듈의 소스를 매번 훑으면 느리다. 그래서 그 모듈을 빌드할 때 겉모습만 요약한 파일을 따로 만든다.

```
Alamofire 빌드
 → Alamofire.o           (기계어, 실제 동작)
 → Alamofire.swiftmodule (요약본: 어떤 타입·함수가 있는지)

내 앱 빌드
 → import Alamofire
 → Alamofire.swiftmodule을 읽고 "AF.request가 있구나" 확인
```

| | 같은 모듈의 다른 파일 | 다른 모듈 |
|---|---|---|
| 예 | A.swift ↔ B.swift | 내 앱 ↔ Alamofire |
| `import` 필요? | 아니요 | 예 |
| 컴파일러가 읽는 것 | 소스 파일을 직접 훑음 | `.swiftmodule` 요약본 |

`.swiftmodule`은 ObjC의 `.h`를 컴파일러가 자동으로 만들어 주는 것이라고 보면 된다. 사람이 읽는 텍스트가 아니라 컴파일러가 읽는 바이너리다. `private` 선언의 이름과 타입도 들어 있다 (디버거에서 쓰기 위해).

### 실무에서

- `No such module 'Alamofire'` = 컴파일러가 `.swiftmodule`을 못 찾았다는 뜻. DerivedData 삭제나 패키지 resolve로 풀리는 경우가 많은 이유다 (요약본을 다시 만들게 되니까)
- 테스트 타겟에서 `@testable import MyApp`을 쓰는 이유: 앱도 하나의 모듈이라 다른 모듈(테스트)에서 쓰려면 `import`해야 한다

## 3. 증분 빌드 — 바뀐 것만 다시 번역한다

컴파일러는 파일마다 "제공하는 것"과 "사용하는 것" 목록을 기록해 둔다.

```
A.swift   제공: hello()     사용: print()
B.swift   제공: (없음)      사용: hello()
```

A.swift가 바뀌면 → A가 제공하는 걸 사용하는 파일(B)을 찾고 → 그 겉모습이 바뀌었는지 따진다.

| A.swift에서 바꾼 것 | A 재번역 | B 재번역 |
|---|---|---|
| `hello()` 안쪽 코드 | ✅ | ❌ |
| `hello()` → `hello(name: String)` | ✅ | ✅ 겉모습이 바뀜 |
| 새 함수 `bye()` 추가 | ✅ | B가 `bye`를 안 쓰면 보통 ❌ |

컴파일러는 일부러 보수적으로 군다. 필요 없는 파일을 다시 빌드하는 건 느릴 뿐이지만, 다시 빌드해야 할 파일을 안 하면 잘못된 코드가 실행된다. 애매하면 다시 한다.

### 다른 모듈이 바뀌면 그 모듈을 import하는 모듈 전체를 다시 번역한다

기본 모델에서는 모듈 안 모든 파일이 같은 외부 의존성 목록을 갖는다. 외부 의존성 하나가 바뀌면 모듈 안 전부가 다시 빌드된다 (`import`를 안 쓴 파일도 포함).

```
Alamofire 버전 올림
 → Alamofire 재빌드 → Alamofire.swiftmodule 바뀜
     → Network 모듈 (import Alamofire)  → 안의 파일 전부 재번역
     → App 모듈 (import Network)        → Network.swiftmodule이 바뀌었으면 또 전부
     → Design 모듈 (Alamofire와 무관)    → 그대로
```

앱이 모듈 하나뿐이면 사실상 프로젝트의 Swift 파일 전부가 다시 번역된다.

Swift 드라이버에는 이를 개선한 cross-module incremental 모드(`-enable-incremental-imports`)도 있다. 다른 모듈의 `.swiftmodule`을 파일 하나처럼 취급해서 바뀐 선언을 쓰는 파일만 다시 번역한다. 처음엔 실험 기능으로 들어왔고, Xcode 26에서 기본으로 켜져 있는지는 확인 필요.

### 실무에서

- 함수 안쪽만 고칠 때 빌드가 빠르고, 시그니처를 바꾸면 느려지는 체감 차이가 이것이다
- 공통 모듈(Core, Utils)을 고치면 그걸 `import`하는 모듈이 통째로 다시 빌드된다 → "자주 바뀌는 코드를 바닥 모듈에 두지 말라", "큰 앱은 모듈을 나누면 증분 빌드가 빨라진다"는 얘기가 여기서 나온다
- 내 프로젝트에서 확인: ⌘B → 패키지 버전만 바꿔 다시 ⌘B → Report navigator에서 `Compile …swift` 줄 수를 센다

## 4. Debug vs Release — 파일마다 따로 vs 통째로(WMO)

### Debug — 여러 명 병렬로 동시에 번역, 담당 파일만 안쪽까지

```
번역가 1: A.swift 담당 → A는 안쪽까지, B·C는 겉모습만 → A.o
번역가 2: B.swift 담당 → B는 안쪽까지, A·C는 겉모습만 → B.o
번역가 3: C.swift 담당 → C는 안쪽까지, A·B는 겉모습만 → C.o
          ↑ 동시에 일함 (병렬)
```

- A.swift만 바뀌면 번역가 1만 다시 일하면 된다 → 증분 빌드
- 실제로는 겉모습 훑기 반복을 줄이려고 Xcode 10부터 파일 여러 개를 한 그룹으로 묶어 한 번역가에게 맡긴다. 빌드 로그에 `Compile A.swift, B.swift, …`처럼 여러 파일이 한 줄로 보이는 게 이것이다

### Release — 한 명이 전부 안쪽까지 확인한다. 결과물은 모듈 전체로 한 덩어리로 처리된다

```
번역가 1명: A·B·C 전부 안쪽까지 읽음
          → 파일을 넘어서는 최적화 가능
```

이것이 **WMO(Whole-Module Optimization)**다. 효과는 프로젝트마다 다르지만 최대 2~5배까지 빨라질 수 있다. 최적화를 모듈 전체로 한 뒤, 기계어를 만드는 LLVM 단계는 다시 여러 조각으로 나눠 병렬로 처리하고 안 바뀐 조각은 재사용한다.

### "파일을 넘어서는 최적화"란

다른 파일에 있는 함수의 안쪽 코드를 활용하는 최적화다.

```swift
// A.swift
func add(_ a: Int, _ b: Int) -> Int { a + b }

// C.swift
let x = add(1, 2)
```

```
let x = add(1, 2)  →  let x = 1 + 2  →  let x = 3
        호출            안쪽을 펼쳐 넣음     계산까지 미리
```

C.swift를 번역하는 순간 `add`의 안쪽을 알아야 펼쳐 넣을 수 있다. 파일마다 따로면 겉모습만 알아서 호출 코드로 남는다. 제네릭도 같다. 다른 파일의 `Container<T>`를 `Int`로만 쓴다는 걸 알아야 `Int` 전용 빠른 버전을 만든다.

WMO는 `private`·`internal` 함수를 모듈 밖에서 못 쓴다는 점도 활용한다. 모듈 전체를 보면 "아무도 안 부르는 함수"를 확신하고 지울 수 있다.

### 최적화 켜기(-O)와 범위(WMO)는 별개 설정

```
Debug          : 최적화 끔 (-Onone)       → 펼쳐 넣기 없음
-O + 파일마다   : 최적화 켬, 범위 = 한 파일  → 같은 파일 안에서만
-O + WMO       : 최적화 켬, 범위 = 모듈 전체 → 파일 넘어서도 가능 (Release 기본)
```

Build Settings의 **Optimization Level**과 **Compilation Mode** 두 항목이 각각 이것이다. 새 프로젝트는 Release에 WMO가 기본으로 켜져 있다 (Xcode 8부터).

| | Debug | Release |
|---|---|---|
| 번역 단위 | 파일마다 따로 (Incremental) | 모듈 통째로 (Whole Module) |
| 최적화 | 안 함 (`-Onone`) | 함 (`-O`) |
| 한 파일 수정 시 | 그 파일만 다시 | 전체 다시 |
| 빌드 속도 | 빠름 | 느림 |
| 실행 속도 | 느림 | 빠름 |
| 목적 | 고치고 돌려보기를 빨리 반복 | 사용자 폰에서 빠르게 |

### 최적화를 하면 좋은 점과 대가

좋은 점은 **같은 일을 더 적은 명령어로 하게 된다**는 것이다.

| 최적화 | 없을 때 | 있을 때 |
|---|---|---|
| 함수 펼쳐 넣기 | `add` 호출 → 점프 → 계산 → 복귀 | 그 자리에서 `1 + 2`, 또는 아예 `3` |
| 제네릭 특수화 | `Container<T>`를 범용 버전으로 실행, 복사할 때마다 타입 정보 조회 | `Int` 전용 버전으로 바로 실행 |
| ARC 최적화 | 불필요한 retain/release가 그대로 | 중복된 retain/release 제거 |
| 안 쓰는 코드 제거 | 호출 안 되는 함수도 바이너리에 남음 | 지움 |

```
명령어가 줄어듦
 → 같은 작업을 더 짧은 시간에 끝냄
     → 스크롤·애니메이션이 덜 끊김, 화면 로딩·데이터 파싱이 빨라짐
 → CPU가 덜 일함
     → 배터리·발열에 유리 (일반적인 원리. 앱마다 차이는 측정해 봐야 함)
```

대가도 있다.

| 대가 | 설명 |
|---|---|
| 빌드가 느려짐 | 최적화 작업 + WMO |
| 디버깅이 어려워짐 | 변수가 `<optimized out>`, 브레이크포인트가 엉뚱한 줄에 걸림 |
| 앱이 커질 수 있음 | 펼쳐 넣기는 코드를 복사하는 것이라 바이너리가 늘 수 있음 |

마지막 대가 때문에 크기를 우선하는 `-Osize`가 Swift 4.1(Xcode 9.3)부터 있다.

```
-Onone  최적화 안 함                   → Debug
-O      속도 우선 (Optimize for Speed)  → Release 기본
-Osize  크기 우선 (Optimize for Size)   → 펼쳐 넣기를 덜 함
```

`-Osize`는 프로젝트에 따라 코드 크기를 5~30% 줄였고, 대부분 앱에서 성능 손해는 5% 미만이었다 (2018년 swift.org 블로그 기준). 성능이 중요한 코드에는 `-O`가 낫다.

### 실무에서

- Archive 액션의 기본 Build Config가 Release라서([Xcode 프로젝트 구조와 빌드 설정](01_xcode-project-settings.md) 2번) Archive 때 WMO와 최적화가 켜진다. Archive가 유독 오래 걸리는 이유다
- "Debug에선 되는데 Release에서만 이상하다" 버그는 최적화가 코드를 바꿔 놓아 생기는 경우가 있다. Edit Scheme → Run → Build Configuration을 Release로 바꿔 재현한다
- Release로 디버깅하면 변수가 `<optimized out>`으로 보이는 것도 최적화로 변수 자체가 사라졌기 때문이다
- 빌드 로그로 구분: Debug는 `Compile …` 줄이 여러 개, Release는 모듈당 한 덩어리
- 앱 크기가 고민이면 Build Settings → Optimization Level을 `-Osize`로 바꿔 Archive하고 App Thinning Size Report를 비교한다

## 5. Build Timeline — 어디가 느린가

빌드가 끝난 뒤 누가, 언제, 얼마나 일했는지를 시간축 그래프로 보여 준다. Xcode 14부터 있다.

### 여는 법

```
⌘B로 빌드
 → Report navigator (⌘9) → 방금 빌드 선택
 → Editor Options → Assistant
 → 빌드 로그 옆(또는 아래)에 타임라인이 열림
```

### 읽는 법

```
시간 →
줄1  [AppCore 컴파일 ████████]      [App 컴파일 ██████████]  [링크 ██]
줄2  [AppCore 컴파일 ██████]        [App 컴파일 ████████]
줄3  [에셋 ██]                      [App 컴파일 ███████]
줄4                  ↑ 빈 공간: 앞 작업을 기다리는 중
```

| 보이는 것 | 뜻 |
|---|---|
| 막대 길이 | 그 작업이 걸린 시간 |
| 세로 줄 수 | 그 순간 동시에 돌던 작업 수 (CPU·메모리 사용률과 같지는 않음) |
| 빈 공간 | 앞 작업이 끝나길 기다리느라 놀고 있는 시간 |
| 색 | 어느 타겟의 작업인지 |

막대를 클릭하면 빌드 로그에서 그 작업이 선택되고, 함께 묶인 파일과 전체 명령어를 볼 수 있다. 증분 빌드에서는 실제로 돈 작업만 보여서 예상 못 한 작업이 돌았는지 찾기 좋다. 이상적인 타임라인은 세로로 꽉 차고 빈 공간이 적다.

### 긴 막대가 무슨 작업인가

| 작업 이름 (로그 기준) | 뜻 | 길면 의심할 것 |
|---|---|---|
| `Compile …swift` (파일 묶음) | Swift 번역 | 타입 체크가 무거운 파일 → warn-long 플래그로 함수 찾기 |
| `Emit Swift module` | `.swiftmodule` 만들기 | 타겟 자체가 너무 큼 |
| `Link` | `.o`를 하나로 합치기 | 정적 라이브러리가 많음 ([심볼과 링킹](04_symbol-linking.md)) |
| `Run custom shell script` | Run Script 단계 | 입력·출력을 지정하지 않아 매번 돎 |
| `Compile asset catalog` | 이미지 에셋 처리 | 에셋이 많음 |

막대 위아래도 본다. 세로로 여러 줄이 동시에 돌고 있으면 파일이 많아서 오래 걸리는 것이고, 한두 줄만 길게 가면 특정 작업 하나가 병목이다.

### 빈 공간 = 모듈을 기다리는 구조

```
Core 모듈의 .swiftmodule이 나와야
 → 그걸 import하는 Feature 모듈이 번역 시작 가능
 → Core가 크고 느리면 그동안 나머지는 논다 (빈 공간)
```

Xcode 14·Swift 5.7부터 `.swiftmodule`을 만드는 작업(emit-module)을 따로 떼어 내서, 아래 모듈이 위 모듈의 컴파일 전체가 아니라 요약본만 기다리면 되게 됐다. 그래도 Core가 거대하면 기다림은 남는다.

### 파일 안에서 어느 함수가 느린지 찾기

타임라인은 파일 묶음 단위까지만 보여 준다. 더 좁히려면 Debug의 Other Swift Flags에 넣는다.

```
-Xfrontend -warn-long-function-bodies=100
-Xfrontend -warn-long-expression-type-checking=100
```

함수 본문이나 식 하나의 타입 체크가 100ms를 넘으면 경고가 뜬다. Apple 공식 문서에는 없는 frontend 옵션으로, 실무에서 널리 쓰는 방법이다. 대부분 ② 뜻 확인(타입 체크)이 힘들어하는 코드라서, Apple 문서의 해결법이 그대로 통한다.

| 원인 | 해결 |
|---|---|
| 복잡한 값으로 타입 추론 (`var x = 배열.reduce(...)`) | 타입을 직접 적기 (`var x: Double = …`) |
| 한 줄에 `?:`, `!=`, `!`가 뒤엉킨 긴 식 | `if let`으로 풀어 쓰기 |
| `delegate: AnyObject?` | 프로토콜 타입으로 (`MyDelegate?`). `AnyObject`면 컴파일러가 프로젝트 전체에서 메서드를 찾아야 한다 |

`Product → Perform Action → Build With Timing Summary`로 빌드하면 로그 끝에 작업 종류별 총 시간 요약도 나온다.

### 모듈을 나눈다 = 타겟을 나눈다

Swift에서는 타겟 하나가 모듈 하나다. 폴더(그룹)만 나누는 건 모듈 분리가 아니다.

```
❌ 폴더만 나눔
MyApp 타겟
 ├─ Network/
 ├─ Login/
 └─ Home/
 → 전부 MyApp 모듈 하나. 빌드상 변화 없음

✅ 타겟으로 나눔
MyApp 타겟   (import Login, import Home)
Login 타겟   (import Network)
Home 타겟    (import Network)
Network 타겟
 → 모듈 4개
```

타겟은 Xcode의 Framework 타겟, 로컬 Swift Package의 `.target`, Pod 등으로 만든다.

| | 한 타겟 | 여러 타겟 |
|---|---|---|
| 다른 코드 쓰기 | 그냥 씀 | `import` 필요 |
| 접근 제어 | `internal`이면 다 보임 | 다른 모듈에 보이려면 `public` |
| 증분 빌드 | 영향 범위 판단이 모듈 하나 안에서 | 무관한 모듈은 안 건드림 |
| 병렬 빌드 | 한 타겟 안 파일끼리 | 의존 없는 모듈끼리도 |

나눈다고 무조건 빨라지지는 않는다. 모두가 import하는 `Core`를 자주 고치면 결국 전부 다시 빌드되고, 타임라인에 `Core`를 기다리는 빈 공간이 생긴다. 잘 안 바뀌는 것은 아래 모듈, 자주 바뀌는 것은 위 모듈에 둔다.

### 실무에서

- 메인(앱) 타겟이 제일 오래 걸리는 건 흔하다. 모든 모듈을 기다린 뒤 맨 마지막에 시작하고, 단일 모듈 프로젝트면 코드 대부분이 몰려 있기 때문이다
- 단일 모듈이라면 모듈화 전에 먼저 확인한다
  - warn-long 플래그로 타입 체크가 무거운 함수 수정
  - 증분 빌드 때도 Run Script 막대가 보이는지
  - Debug가 Incremental · `-Onone`인지
  - 함수 안쪽 한 줄만 고치고 ⌘B → 다시 번역된 파일 수. 앱 전체가 다시 번역되면 모듈 문제가 아니라 다른 원인이다
- 클린 빌드만 느리고 평소 ⌘B가 괜찮다면 모듈화는 급하지 않을 수 있다

## 핵심 정리

1. 컴파일러는 ① 읽기 → ② 뜻 확인 → ③ 번역(SIL) → ④ 다듬기 → LLVM 순으로 번역하고, 에러 종류로 어느 단계에서 막혔는지 알 수 있다
2. 같은 모듈의 다른 파일은 겉모습만 훑고, 다른 모듈은 `.swiftmodule` 요약본을 읽는다
3. 증분 빌드는 겉모습이 바뀐 경우에만 의존하는 파일을 다시 번역한다. 외부 모듈이 바뀌면 그 모듈을 import하는 모듈 전체를 다시 번역한다
4. Debug는 파일마다 따로·최적화 없이 → 빌드 빠름, 실행 느림. Release는 WMO·최적화 → 빌드 느림, 실행 빠름
5. 파일을 넘어서는 최적화 = 다른 파일 함수의 안쪽까지 보고 하는 최적화. WMO여야 가능하다
6. 최적화는 실행을 빠르게 하지만 빌드 시간·디버깅·앱 크기를 대가로 낸다. 크기가 중요하면 `-Osize`
7. Build Timeline에서 긴 막대는 느린 작업, 빈 공간은 기다리는 구조다. 함수 단위는 warn-long 플래그로 찾는다
8. 모듈 = 타겟. 폴더를 나누는 건 모듈 분리가 아니다

## 셀프 체크

**Q1. `let name: String = 123`은 ①~④ 중 어디서 걸리나?**

- ② 뜻 확인. 문법은 맞지만 `String` 자리에 `Int`를 넣었다

**Q2. A.swift에서 `hello()`의 안쪽 코드만 바꿨다. B.swift도 다시 번역해야 하나?**

- 아니다. B.swift가 보는 겉모습(이름·매개변수·반환 타입)은 그대로라서 A.swift만 다시 번역한다

**Q3. Alamofire 버전을 올리면 프로젝트의 모든 파일이 다시 번역되나?**

- 프로젝트 전체가 아니라 Alamofire를 import하는 모듈 안의 파일 전부다. 무관한 모듈은 그대로다. 앱이 모듈 하나뿐이면 사실상 전부다

**Q4. Release(Archive) 빌드는 왜 모듈을 통째로 번역하나?**

- 실행 속도를 위해서다. 다른 파일 함수의 안쪽까지 봐야 펼쳐 넣기·제네릭 특수화 같은 최적화를 할 수 있다

**Q5. Debug는 왜 빌드가 빠르고 실행이 느린가?**

- 최적화를 안 하고(`-Onone`) 파일마다 따로 번역해서 바뀐 파일만 다시 하니까 빌드가 빠르다. 대신 최적화를 안 했으니 실행은 느리다

**Q6. App Store에서 앱 다운로드가 오래 걸리는 게 Release 빌드 때문인가?**

- 아니다. 번역은 개발자 Mac에서 Archive 때 한 번 끝나고, 사용자는 완성된 결과물을 받는다. 다운로드 시간은 앱 크기(압축 크기)와 네트워크에 달렸다. 사용자는 App Thinning으로 자기 기기에 필요한 부분만 받는다

**Q7. "파일을 넘어서는 최적화를 못 한다"는 무슨 뜻인가?**

- 다른 파일에 있는 함수의 안쪽 코드를 활용하는 최적화를 못 한다는 뜻이다. 파일마다 따로 번역하면 다른 파일은 겉모습만 알기 때문이다. Debug는 애초에 최적화를 끄므로, 이 제약이 의미 있는 건 `-O`인데 파일마다 따로 번역하는 경우다

**Q8. 최적화를 하면 좋은 점은?**

- 같은 일을 더 적은 명령어로 해서 실행이 빨라진다 (함수 펼쳐 넣기, 제네릭 특수화, 중복 retain/release 제거, 안 쓰는 코드 제거). 대신 빌드가 느려지고, 디버깅이 어려워지고, 앱이 커질 수 있다

**Q9. Build Timeline에서 메인 타겟이 제일 오래 걸렸다. 왜인가?**

- 모든 모듈의 `.swiftmodule`을 기다린 뒤 맨 마지막에 시작하고, 단일 모듈 프로젝트면 코드 대부분이 앱 타겟에 몰려 있기 때문이다. 원인을 좁히려면 가장 긴 막대가 어떤 작업(Compile · Emit module · Link · Script)인지, 그 시간에 세로 줄이 몇 개였는지 본다

**Q10. 모듈을 나눈다는 건 타겟을 나눈다는 것인가?**

- 맞다. Swift 타겟 하나가 모듈 하나다. 폴더만 나누는 건 모듈 분리가 아니다

## 참고 자료

**공식**

- [Swift Compiler — Compiler Architecture (swift.org)](https://www.swift.org/documentation/swift-compiler/)
- [Behind the Scenes of the Xcode Build Process (WWDC18)](https://developer.apple.com/videos/play/wwdc2018/415/)
- [Whole-Module Optimization in Swift 3 (swift.org 블로그, 2016)](https://www.swift.org/blog/whole-module-optimizations/)
- [Code Size Optimization Mode in Swift 4.1 (swift.org 블로그, 2018)](https://www.swift.org/blog/osize/)
- [Dependency Analysis (swiftlang/swift docs)](https://github.com/swiftlang/swift/blob/main/docs/DependencyAnalysis.md)
- [Driver.md (swiftlang/swift docs)](https://github.com/swiftlang/swift/blob/main/docs/Driver.md)
- [Debugging the Swift Compiler (swiftlang/swift docs)](https://apple-swift.readthedocs.io/en/latest/DebuggingTheCompiler.html)
- [Reducing your app's size (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/reducing-your-app-s-size)
- [Demystify parallelization in Xcode builds (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/110364/)
- [Improving build efficiency with good coding practices (Apple Developer Documentation)](https://developer.apple.com/documentation/xcode/improving-build-efficiency-with-good-coding-practices)

**외부**

- [Xcode Build Time Optimization – Part 1 (onswiftwings)](https://www.onswiftwings.com/posts/build-time-optimization-part1/) — Build With Timing Summary, `-warn-long-*` 플래그. Xcode 14 이전 글이라 Build Timeline은 없음
- [Optimizing and debugging incremental build time in Swift 5.5 (Swift Forums, 2021)](https://forums.swift.org/t/optimizing-and-debugging-incremental-build-time-in-swift-5-5/49379) — 프레임워크가 다시 빌드되면 import하는 파일이 전부 다시 빌드되는 증상
- [How to debug the LLVM-IR generation phase (Swift Forums)](https://forums.swift.org/t/how-to-debug-the-llvm-ir-generation-phase-in-the-compiler/42106) — 드라이버가 `swift-frontend -frontend … -primary-file`을 호출하는 예
- [Cross-module incremental dependencies PR (swiftwasm/swift 미러)](https://github.com/swiftwasm/swift/pull/1959)
- [swift CLI 옵션 목록 (fig.io)](https://fig.io/manual/swift) — `-enable/-disable-incremental-imports`
