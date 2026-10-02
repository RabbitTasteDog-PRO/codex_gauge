# GitHub 릴리즈 업로드

대상 저장소: [RabbitTasteDog-PRO/codex_gauge](https://github.com/RabbitTasteDog-PRO/codex_gauge).

## 1. 릴리즈 파일 만들기

프로젝트 폴더에서 실행합니다.

```sh
bash scripts/package-release.sh
```

버전은 앱의 `CFBundleShortVersionString`에서, 아키텍처는 실제 실행 파일에서 읽습니다. 현재 Mac에서는 다음 파일이 생성됩니다.

```text
dist/releases/v0.1.0/
├── CodexGauge-0.1.0-macos-arm64.zip
└── SHA256SUMS.txt
```

ZIP에는 실행 앱과 고양이 리소스만 들어갑니다. 압축 해제한 앱의 서명, 실행 권한, 리소스와 체크섬을 자동으로 확인하며 앱을 실행하거나 로그인 상태를 바꾸지는 않습니다.

현재 패키징은 **개인용 임시 서명, 미공증, Codex CLI 별도 설치** 상태입니다. DMG/PKG 설치 파일이나 CLI를 포함한 버전은 아닙니다. 일반 배포용 서명·공증을 적용하려면 빌드 스크립트와 패키징 절차를 별도로 변경해야 합니다.

## 2. 소스를 GitHub에 먼저 올리기

새 저장소의 첫 업로드라면 터미널에서 아래 순서로 실행합니다. 릴리즈를 생성하려면 대상 브랜치에 커밋이 있어야 합니다.

```sh
cd /Users/choejiheum/Portfolio/codex_gauge_app
git status
git add .
git commit -m "Initial Codex Gauge release"
git push -u origin main
```

`.gitignore`가 빌드 캐시와 `dist`를 제외합니다. 배포 ZIP은 Git 커밋 대신 다음 단계의 **Release Assets**로 올립니다. 이미 소스를 올린 경우에는 이번 변경을 커밋·푸시한 뒤 진행하세요.

## 3. 웹에서 릴리즈 만들기

1. [새 릴리즈 작성 화면](https://github.com/RabbitTasteDog-PRO/codex_gauge/releases/new)을 엽니다.
2. **Choose a tag**에서 `v0.1.0`을 입력하고 새 태그를 만듭니다. **Target**은 방금 올린 `main`을 선택합니다.
3. **Release title**에 `Codex Gauge 0.1.0 — Preview`를 입력합니다.
4. 설명에는 [릴리즈 설명 문안](release-notes/v0.1.0.md)의 내용을 붙여 넣습니다.
5. 파일 첨부 영역에 ZIP과 `SHA256SUMS.txt`를 올립니다.
6. 현재 미공증 Preview 버전이므로 **This is a pre-release**를 체크합니다.
7. 검토용으로 보관하려면 **Save draft**, 다운로드를 공개하려면 **Publish release**를 누릅니다.

게시 후 Assets에 두 파일이 표시되는지 확인합니다. 사용자는 ZIP을 다운로드하고 압축을 풀어 앱을 응용 프로그램 폴더로 옮긴 뒤 실행합니다. 미로그인 상태면 브라우저 로그인이 시작됩니다.

## 다음 버전

앱 버전과 빌드 번호를 `Resources/Info.plist`에서 올리고, 해당 버전의 릴리즈 설명을 작성한 뒤 패키징을 다시 실행하세요. ZIP 파일 이름만 바꾸면 앱에 표시되는 버전과 달라질 수 있습니다.

공식 안내: [GitHub 릴리즈 관리](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository), [Apple Developer ID 배포](https://developer.apple.com/developer-id/).
