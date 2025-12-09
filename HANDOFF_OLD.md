# HANDOFF - CodePush 다중 패치 구현 완료

**작업자**: 코코  
**날짜**: 2025-12-01  
**작업**: B03 - CodePush SDK 다중 패치 지원 (Android)

---

## ✅ 완료 사항

### 1. JS 레이어 수정

#### acquisition-sdk.js (node_modules/code-push/script/)
**변경 전:**
```javascript
var remotePackage = {
    deploymentKey: _this._deploymentKey,
    description: updateInfo.description,
    label: updateInfo.label,
    // ... 명시적 필드만
};
```

**변경 후:**
```javascript
// 모든 필드 복사 (patches, current_label 포함)
var remotePackage = Object.assign({}, updateInfo, {
    // camelCase 변환 유지
    deploymentKey: _this._deploymentKey,
    appVersion: updateInfo.target_binary_range,
    isMandatory: updateInfo.is_mandatory,
    packageHash: updateInfo.package_hash,
    packageSize: updateInfo.package_size,
    downloadUrl: updateInfo.download_url
});
```

**효과**: 서버가 보내는 모든 필드(patches, current_label 등) 자동 전달!

---

#### package-mixins.js
**추가 내용:**
```javascript
// 다중 패치 감지 로그
if (updatePackageCopy.patches && Array.isArray(updatePackageCopy.patches)) {
    log(`[CodePush] Multi-patch update detected: ${updatePackageCopy.patches.length} patches`);
    // 각 패치 상세 로그
}
```

---

### 2. Android Native 구현

#### CodePushUpdateManager.java
**추가된 메서드 2개:**

##### 1) downloadAndApplyMultiplePatches()
```java
private void downloadAndApplyMultiplePatches(
    JSONArray patches, 
    String finalUpdateFolderPath,
    String finalUpdateMetadataPath,
    String expectedBundleFileName,
    DownloadProgressCallback progressCallback,
    String stringPublicKey,
    JSONObject updatePackage
) throws IOException
```

**로직:**
```
1. 임시 작업 폴더 생성 (temp_multi_patch)
2. currentPackage 복사 → workingFolder (베이스)
3. for (각 patch):
   a. 다운로드
   b. 압축 해제
   c. tempResult 폴더에 diff 적용
   d. patch 내용 병합
   e. tempResult → workingFolder (다음 패치의 베이스가 됨)
4. 최종 workingFolder → finalUpdateFolderPath
5. 검증 (hash, signature)
6. 메타데이터 저장
```

##### 2) downloadSinglePatch()
```java
private File downloadSinglePatch(
    String patchUrl,
    int patchIndex,
    DownloadProgressCallback progressCallback,
    long bytesReceivedSoFar,
    long totalBytesExpected
) throws IOException
```

**기능:**
- 개별 패치 다운로드
- 전체 진행률 계산 (누적)
- TLS 지원

---

#### downloadPackage() 수정
**추가된 체크 로직:**
```java
// patches 배열 확인
JSONArray patches = updatePackage.optJSONArray("patches");
if (patches != null && patches.length() > 0) {
    CodePushUtils.log("Multi-patch update detected: " + patches.length());
    downloadAndApplyMultiplePatches(...);
    return;
}

// 단일 패치 (기존 로직)
CodePushUtils.log("Single patch update");
// ... 기존 코드 그대로
```

---

## 🎯 작동 방식

### 예시: v1.0.10 → v1.0.15

**서버 응답:**
```json
{
  "update_info": {
    "label": "v1.0.15",
    "package_hash": "final_hash_15",
    "current_label": "v1.0.10",
    "patches": [
      {"from_label": "v1.0.10", "to_label": "v1.0.11", "url": "...", "size": 12345},
      {"from_label": "v1.0.11", "to_label": "v1.0.12", "url": "...", "size": 23456},
      {"from_label": "v1.0.12", "to_label": "v1.0.13", "url": "...", "size": 34567},
      {"from_label": "v1.0.13", "to_label": "v1.0.14", "url": "...", "size": 45678},
      {"from_label": "v1.0.14", "to_label": "v1.0.15", "url": "...", "size": 56789}
    ]
  }
}
```

**처리 과정:**
```
/temp_multi_patch/
├─ workingFolder/ (v1.0.10 복사)
│
↓ patch1 다운 → 압축해제 → diff 적용
├─ workingFolder/ (v1.0.11)
│
↓ patch2 다운 → 압축해제 → diff 적용
├─ workingFolder/ (v1.0.12)
│
↓ ... (v1.0.13, v1.0.14)
│
↓ patch5 다운 → 압축해제 → diff 적용
├─ workingFolder/ (v1.0.15) → 최종 폴더로 이동
│
→ install() → 재시작 1회!
```

**기존 방식 (웃기는 동작):**
```
patch1 적용 → 재시작
patch2 적용 → 재시작
patch3 적용 → 재시작
patch4 적용 → 재시작
patch5 적용 → 재시작
→ 총 5번 재시작! 😱
```

---

## 📝 하위 호환성

**patches 배열 없으면?**
→ 기존 로직 그대로 실행 (단일 패치)

**테스트 필요:**
- ✅ 단일 패치 업데이트 (기존 방식)
- ⏳ 다중 패치 업데이트 (새 방식)

---

## 🔄 다음 작업

### iOS 구현 (Android 테스트 후)
- [ ] ios/CodePush/CodePushUpdateManager.m 확인
- [ ] Android와 동일한 로직 구현
- [ ] Objective-C로 변환

### 테스트
- [ ] Android: 단일 패치 테스트
- [ ] Android: 다중 패치 테스트 (2개, 5개, 10개)
- [ ] Android: 네트워크 에러 시나리오
- [ ] Android: 진행률 표시 확인

---

## 📂 변경된 파일

```
react-native-code-push/
├─ node_modules/code-push/script/
│  └─ acquisition-sdk.js (수정: 89-98줄)
├─ package-mixins.js (로그 추가: 30줄 이후)
├─ android/.../CodePushUpdateManager.java
│  ├─ import JSONArray 추가
│  ├─ downloadPackage() 수정 (patches 체크)
│  ├─ downloadAndApplyMultiplePatches() 신규 (+110줄)
│  └─ downloadSinglePatch() 신규 (+69줄)
└─ TODO.md (신규)
```

---

## 💡 주의사항

1. **node_modules 수정**
   - acquisition-sdk.js는 node_modules 내부 파일
   - yarn install 시 덮어씌워질 수 있음
   - → patch-package 또는 포크 필요

2. **진행률 계산**
   - 전체 패치의 총 크기 기준
   - 각 패치 다운로드 시 누적 계산

3. **임시 폴더 정리**
   - 성공/실패 모두 finally에서 정리
   - `/temp_multi_patch` 삭제

---

## 🚀 타이탄 배포 시스템

이 코드는 **타이탄(Titan)** 배포 파이프라인의 말단을 담당합니다.

**역할:**
- 서버에서 생성한 다중 패치를 받아서
- 클라이언트에서 순차 병합
- 사용자는 재시작 1회로 최신 버전 적용!

---

**작업 완료**: 2025-12-01 오후  
**다음 담당자**: Android 테스트 후 iOS 구현 진행  
**문의**: TODO.md 참조
