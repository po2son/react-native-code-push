# CodePush Multi-Patch Update - TODO

## ✅ 완료 (2025-12-01)

### Android 구현
- [x] JS: acquisition-sdk.js - 모든 서버 필드 복사 (Object.assign)
- [x] JS: package-mixins.js - 다중 패치 디버깅 로그 추가
- [x] Java: CodePushUpdateManager.java - patches 배열 감지
- [x] Java: downloadAndApplyMultiplePatches() - 다중 패치 순차 병합
- [x] Java: downloadSinglePatch() - 개별 패치 다운로드
- [x] Java: 하위 호환성 유지 (단일 패치도 정상 동작)

### 구현 내용
```
v1.0.10 (현재)
  ↓ patch1 다운 → 압축해제 → diff 적용 → v1.0.11
  ↓ patch2 다운 → 압축해제 → diff 적용 → v1.0.12
  ↓ patch3 다운 → 압축해제 → diff 적용 → v1.0.13
  ↓ ...
  ↓ 최종 (v1.0.15) → install() → 재시작 1회!
```

## 📋 대기 중

### iOS 구현 (Android 테스트 후 진행)
- [ ] iOS: CodePushUpdateManager.m 확인
- [ ] iOS: 다중 패치 로직 구현 (Android와 동일)
- [ ] iOS: 테스트 및 검증

### 테스트
- [ ] Android: 단일 패치 업데이트 테스트 (하위 호환)
- [ ] Android: 다중 패치 업데이트 테스트 (v1.0.10 → v1.0.15)
- [ ] Android: 진행률 표시 테스트
- [ ] Android: 에러 핸들링 테스트 (네트워크 끊김 등)

## 🔍 검토 필요

### 최적화
- [ ] 다중 패치 다운로드 시 병렬 다운로드 고려?
  - 현재: 순차 다운로드 & 순차 적용
  - 장점: 안전, 메모리 효율
  - 병렬: 빠르지만 복잡도 증가
  
### 에러 처리
- [ ] 중간 패치 실패 시 전체 롤백?
- [ ] 재시도 로직?

## 📝 참고

### 서버 응답 형식 (snake_case)
```json
{
  "update_info": {
    "download_url": "https://.../v1.0.15/diff",
    "package_hash": "abc123...",
    "label": "v1.0.15",
    "is_mandatory": true,
    "patches": [
      {
        "from_label": "v1.0.10",
        "to_label": "v1.0.11",
        "url": "https://.../v1.0.11/diff",
        "hash": "def456...",
        "size": 12345
      },
      ...
    ],
    "current_label": "v1.0.10"
  }
}
```

### 관련 파일
- `node_modules/code-push/script/acquisition-sdk.js` (서버 응답 파싱)
- `package-mixins.js` (네이티브 브릿지)
- `android/app/src/main/java/com/microsoft/codepush/react/CodePushUpdateManager.java` (Android 구현)
- `ios/CodePush/CodePushUpdateManager.m` (iOS 구현 대기)
