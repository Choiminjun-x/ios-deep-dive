# Xcode 프로젝트 구조와 빌드 설정

> 작성일: 2026-10-07

## 큰 그림

```
⌘R / ⌘B
 → Xcode가 읽는 것                                        ← 이 노트
     .xcodeproj / .xcworkspace    어떤 프로젝트들을
     Scheme                       어떤 타겟을, 어떤 Build Config로
     Build Settings / .xcconfig   어떤 플래그로
 → 명령어 조립 → swiftc · clang · ld 실행                  ← iOS 빌드 과정
 → 산출물은 DerivedData에 쌓임                             ← 이 노트
```

빌드 버튼을 누르면 컴파일보다 먼저 Xcode가 **프로젝트 · 스킴 · 빌드 세팅**을 읽어 "무엇을, 어떤 플래그로 빌드할지"를 정한다.

## 1. 프로젝트 구조

### .xcodeproj

프로젝트 하나

```
.xcodeproj/
├── project.pbxproj    ← 빌드 세팅이 여기 다 들어있음 (→ 3번)
├── xcshareddata/      ← 공유 스킴 (git에 올림)
└── xcuserdata/        ← 내 개인 설정, 공유 안 한 스킴 (git에 안 올림)
```

### .xcworkspace

- 여러 프로젝트를 한 창에 묶은 상위 컨테이너
- CocoaPods 있으면 workspace로 열어야 함 (→ 3번)

### 실무에서

- 스킴은 Manage Schemes에서 **Shared**를 체크해야 `xcshareddata/`에 저장되어 git으로 공유된다. 체크하지 않으면 내 `xcuserdata/`에만 있어서 팀원이나 CI에서 보이지 않을 수 있다
- `project.pbxproj`는 파일·타겟을 추가할 때마다 바뀌어서 팀 작업 시 머지 충돌이 잦다 → XcodeGen · Tuist 같은 도구가 나온 이유

## 2. 스킴 · 타겟 · 빌드 컨피그

### Xcode에서 ⌘R을 누르면 무슨 일이 일어나는가?

1. **Scheme** — "무엇을", "어떤 설정으로", "어디서" 실행할 지 정하는 실행 계획서
2. **Target** — 실제로 빌드되는 단위. 소스 파일 목록, 포함할 리소스, 의존성, 서명 설정을 들고 있다. 앱 하나 = 타겟 하나, 여기에 테스트 타겟, 위젯 타겟이 붙는다
3. **Build Config (Debug, Release)** — 같은 코드를 다른 플래그로 컴파일. 최적화를 켤지, 디버그 심볼을 남길지, 어떤 서버 주소를 박을지
4. **컴파일** — Swift 소스 → 기계어
5. **.app 번들** — 실행 파일 + 이미지 + Info.plist를 한 폴더에 담은 것. 실체는 폴더
6. **서명** — 이게 없으면 실기기에 안 올라간다
7. **실행** — 앱 하나가 프로세스 하나로 뜬다

→ 1~3은 이 노트, 4~5는 [iOS 빌드 과정](02_build-process.md), 6은 [iOS 코드 서명](03_code-signing.md), 7은 [Launch, Prewarming, Watchdog, Jetsam](../02_app-lifecycle/03_launch-watchdog-jetsam.md)

### 스킴은 액션마다 Build Config를 정해 둔다

| 액션 | 단축키 | 기본 Build Config |
|---|---|---|
| Run | ⌘R | Debug |
| Test | ⌘U | Debug |
| Profile | ⌘I | Release |
| Analyze | ⇧⌘B | Debug |
| Archive | Product → Archive | Release |

- 같은 스킴이라도 ⌘R은 Debug로, Archive는 Release로 빌드된다 → `#if DEBUG` 코드가 배포본에서 빠지는 이유 ([iOS 빌드 과정](02_build-process.md) 1번)
- 액션별 Build Config는 Edit Scheme에서 바꿀 수 있다

```bash
xcodebuild -list    # 프로젝트의 타겟 · Build Config · 스킴 목록
```

### 실무에서

- 서버 환경(개발 · QA · 운영)을 나눌 때는 Build Config를 추가하고 환경마다 스킴을 둔다
- Config마다 Bundle ID를 다르게 주면 한 기기에 여러 환경의 앱을 같이 설치할 수 있다. 대신 Bundle ID마다 App ID · 프로필이 따로 필요하다 ([iOS 코드 서명](03_code-signing.md) 3번)

## 3. 빌드 세팅과 .xcconfig

### 빌드 세팅 = 빌드 도구에 넘기는 인자 뭉치

Xcode의 Build Settings에 수백 개 항목이 있다. 그건 키-값 딕셔너리이다.

```
SWIFT_VERSION              = 6.0
IPHONEOS_DEPLOYMENT_TARGET = 17.0
HEADER_SEARCH_PATHS        = ...
OTHER_LDFLAGS              = ...
FRAMEWORK_SEARCH_PATHS     = ...
```

⌘R 클릭 → Xcode가 이 딕셔너리를 읽음 → 실제 커맨드라인 명령어를 조립. 대충 아래와 같은 내용이 만들어진다.

```
swiftc -sdk ... -target arm64-apple-ios17.0 -I /경로/... ViewController.swift
ld -o MyApp -L /경로/... -lPods-MyApp -framework UIKit ...
```

GUI의 체크박스와 텍스트 필드는 전부 이 명령어의 플래그를 채우는 폼일 뿐. 터미널에서 `xcodebuild`를 돌려보면 이 조립된 명령어가 그대로 쏟아져 나온다.

이 값들이 저장되는 곳이 `project.pbxproj` = `.xcodeproj` 안에 들어있는 파일이다.

- 조립된 작업 목록을 순서대로 실행하는 쪽이 llbuild다 ([iOS 빌드 과정](02_build-process.md) 5번)

### .xcconfig — 빌드 세팅을 평문 파일로 빼낸 것

그 딕셔너리를 바깥의 텍스트 파일에 적어두고, 타겟이 그걸 가리키게 하는 장치이다.

연결 지점 — Info > Configurations

### 값이 정해지는 순서

같은 키가 여러 곳에 적혀 있으면 위쪽이 이긴다.

```
높음  타겟 Build Settings          (project.pbxproj)
 │    타겟에 연결한 .xcconfig
 │    프로젝트 Build Settings      (project.pbxproj)
 │    프로젝트에 연결한 .xcconfig
낮음  iOS 기본값
```

- Build Settings 화면을 **Levels**로 보면 단계별 값과 최종값(Resolved)이 한 줄에 보인다
- `$(inherited)` = 한 단계 아래의 값을 이어받는다. 빼고 적으면 아래 값을 통째로 덮어쓴다

```
OTHER_LDFLAGS = $(inherited) -ObjC    ← 아래 단계 값 + -ObjC
OTHER_LDFLAGS = -ObjC                 ← 아래 단계 값은 사라지고 -ObjC만
```

### 응용 사례: CocoaPods

`pod install` → `Pods/Pods.xcodeproj` 생성

```
MyApp/
├── MyApp.xcodeproj       ← 내 프로젝트
├── MyApp.xcworkspace     ← pod install이 만들어준 묶음
├── Podfile
└── Pods/
    ├── Pods.xcodeproj    ← 라이브러리들이 사는 두 번째 프로젝트
    ├── Alamofire/
    └── Target Support Files/
```

- `Pods.xcodeproj` 안에는 라이브러리 하나당 타겟이 하나씩 들어있다
- 그것들을 한 덩어리로 묶는 `Pods-{Target}`이 추가된다
- 앱 타겟이 의존하는 대상은 개별 라이브러리가 아니라 이 묶음 타겟이다

#### workspace가 왜 필요한가?

핵심은 **빌드 컨텍스트**. 지금 상황은 MyApp 타겟이 Pods-MyApp 타겟에 의존한다. 의존을 해결하기 위해서 아래 두 가지가 필요하다.

1. **두 프로젝트가 같은 창 안에 있을 것** — 그래야 "Pods를 먼저 빌드하고 그 산출물을 MyApp에 넘긴다"는 순서가 가능하다
2. **두 프로젝트가 같은 빌드 산출물 폴더를 공유할 것** — workspace 안의 프로젝트들은 DerivedData의 같은 `Build/Products`를 쓴다. Pods가 만든 `.framework` / `.a`를 MyApp이 바로 집어갈 수 있는 이유다

#### CocoaPods가 워크스페이스를 만들면서 추가로 손대는 세 가지

→ "Pods는 마법 같다"는 인상의 실체

- **.xcconfig 주입** — `Target Support Files/`에 생성된 설정 파일을 내 앱 타겟의 Debug/Release 빌드 컨피그에 연결한다. 헤더 검색 경로, 링커 플래그, 프레임워크 검색 경로가 여기 들어있다
- **빌드 페이즈 추가** — `[CP] Check Pods Manifest.lock`(Podfile.lock과 실제 설치본이 어긋났는지 검사), `[CP] Embed Pods Frameworks`, `[CP] Copy Pods Resources`
- **의존성 연결** — 앱 타겟이 `Pods-MyApp`을 참조하도록 설정

### 실무에서

- `pod install` 때 `… target overrides the OTHER_LDFLAGS build setting defined in …xcconfig` 경고가 나오면, 타겟 Build Settings에 직접 적은 값이 CocoaPods가 주입한 .xcconfig를 덮고 있다는 뜻이다 → 타겟 값에 `$(inherited)`를 넣는다
- 지금 실제로 적용되는 최종값은 터미널에서 확인할 수 있다

```bash
xcodebuild -showBuildSettings -workspace MyApp.xcworkspace -scheme MyApp
```

## 4. DerivedData — 산출물이 쌓이는 곳

프로젝트를 Xcode로 처음 열 때 자동 생성된다.

```
~/Library/Developer/Xcode/DerivedData/HelloDevice-abcdefghijklmn/
├── Build/
│   ├── Products/          ← 최종 산출물. .app 이 여기
│   │   ├── Debug-iphonesimulator/
│   │   └── Debug-iphoneos/
│   └── Intermediates.noindex/    ← .o, .swiftmodule 등 중간 산출물
├── Index.noindex/         ← 코드 인덱스 (자동완성, 심볼 점프)
├── Logs/                  ← 빌드·테스트 로그
└── ModuleCache.noindex/   ← 컴파일된 모듈 캐시
```

- 폴더명 뒤의 난수는 **프로젝트 경로를 해시한 값** → 같은 이름의 프로젝트가 여러 곳에 있어도 캐시가 안 섞인다. 반대로 프로젝트를 다른 경로로 옮기면 새 폴더가 생겨 풀 빌드가 된다
- `.noindex` — Spotlight 색인 제외 표시. 파일이 수만 개 생기는 곳이라

### 두 가지 역할

- **증분 빌드** — 파일마다 해시·타임스탬프를 기록해두고 안 바뀐 것은 기존 `.o` 재사용. 두 번째 빌드부터 빨라지는 이유
  - 무엇을 다시 빌드할지 판단하는 쪽이 llbuild다 ([iOS 빌드 과정](02_build-process.md) 5번)
- **인덱싱** — 자동완성, `⌘+클릭` 심볼 점프, 리팩토링이 `Index.noindex`에 의존. 빌드와 별개로 도는 작업

### 실무에서

**지워도 되나 — 된다**

소스에서 다시 만들 수 있는 것만 들어있다.

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/*
```

- Product > Clean Build Folder(⇧⌘K)는 `Build/`만 비우고 인덱스는 남긴다
- **"DerivedData 지워보세요"가 만능 처방처럼 도는 이유** — 증분 빌드의 전제가 깨지면 증상이 기괴해진다. 고쳤는데 옛 코드가 실행됨 / 존재하는 심볼이 없다고 함 / 브랜치 전환 후 말도 안 되는 에러 / 삭제한 함수를 자동완성이 계속 제안
- 단 지우면 다음 빌드가 풀 빌드. 큰 프로젝트에선 비싸다
- 로컬 캐시라 사람마다 다르다 → "**제 컴에선 되는데요**"의 원인 중 하나. CI가 매번 깨끗한 환경에서 빌드하는 이유
- `-derivedDataPath ./build` 로 프로젝트 안에 둘 수도 있다(CI에서 자주 씀). `.gitignore` 에 `DerivedData/` 와 `build/` 를 둘 다 넣는 건 이 두 경우를 다 덮으려는 것

## 핵심 정리

1. ⌘R은 컴파일보다 먼저 **스킴**을 읽는다. 스킴이 어떤 타겟을, 어떤 Build Config로 빌드할지 정한다.
2. **타겟**은 산출물을 만드는 빌드 단위, **스킴**은 타겟을 부리는 실행 계획서, **Build Config**는 같은 코드를 다른 플래그로 빌드하는 설정 묶음이다.
3. **빌드 세팅**은 빌드 도구 명령어의 플래그를 채우는 키-값이다. 타겟 > 타겟 .xcconfig > 프로젝트 > 프로젝트 .xcconfig > 기본값 순으로 덮어쓰고, `$(inherited)`로 아래 값을 이어받는다.
4. **workspace**는 여러 프로젝트를 같은 빌드 컨텍스트(같은 `Build/Products`)에 둔다. CocoaPods는 여기에 .xcconfig · 빌드 페이즈 · 의존성을 주입한다.
5. **DerivedData**는 증분 빌드와 인덱싱을 위한 로컬 캐시다. 지워도 되지만 다음 빌드는 풀 빌드가 된다.

## 셀프 체크

**Q1. 스킴과 타겟은 뭐가 다른가**

- **타겟** — 빌드 단위. 소스 목록, 리소스, 서명 설정, 빌드 세팅을 들고 있다. 산출물을 만드는 쪽
- **스킴** — 실행 계획서. "어떤 타겟들을 / 어떤 config로 / 무엇을 할 때 쓸지"를 묶어둔 것. 타겟을 부리는 쪽
