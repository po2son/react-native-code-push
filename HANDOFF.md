# CodePush Multi-Patch 프로젝트 인수인계

## 프로젝트 개요

### 목표
Microsoft CodePush를 포크하여 **멀티패치(Multi-Patch)** 기능 구현
- 기존: Full Bundle만 배포 (2.3MB)
- 개선: Diff Patch 연속 적용 (500 bytes × N)
- 목표: 용량 95% 이상 절감

### 저장소
- **라이브러리**: `/app/AI/react-native-code-push/` (포크본)
- **테스트 앱**: `/app/AI/p1/mtsapp/` (증권앱)
- **서버**: `/app/AI/p7/Codepush/` (MinIO + FastAPI)

### 현재 상태 (2024-12-09 새벽 5시)
- ✅ Single Patch 성공: v36 → v37 (453 bytes)
- ⏳ Manifest 해시 불일치 문제 디버깅 중
- 🎯 목표: v36 → v37 → v38 연속 패치 성공

---

## 수정한 파일 목록

### 1. Android Native (핵심)

#### `/android/app/src/main/java/com/microsoft/codepush/react/CodePushUpdateManager.java`
**역할**: 업데이트 다운로드 및 적용 관리

**주요 수정 내용**:

**Line 140-177: Multi-Patch 다운로드 로직**
```java
// packages 배열 순회하며 각 patch 다운로드
for (int i = 0; i < packages.length(); i++) {
    JSONObject patch = packages.getJSONObject(i);
    String patchHash = patch.getString(CodePushConstants.PACKAGE_HASH_KEY);
    
    // diff.zip 다운로드
    String downloadUrl = getPackageUrl(patch);
    downloadFile(downloadUrl, patchZipFile, patchHash);
    
    // 압축 해제
    unzipPatch(patchZipFile, patchUnzipPath);
    
    // 패치 적용
    applyPatch(currentVersion, patchUnzipPath, nextVersion);
    currentVersion = nextVersion;
}
```

**Line 260: Single-Patch 호출부 수정**
```java
// BEFORE
CodePushUpdateUtils.copyNecessaryFilesFromCurrentPackage(
    diffManifestFilePath, currentPackageFolderPath, newPackageFolderPath
);

// AFTER (patchFolderPath 인자 추가)
CodePushUpdateUtils.copyNecessaryFilesFromCurrentPackage(
    diffManifestFilePath, currentPackageFolderPath, newPackageFolderPath, unzippedFolderPath
);
```

**Line 384-411: Patch 파일 해시 검증 추가**
```java
private void downloadAndVerifyPatch(String downloadUrl, File outputFile, String expectedHash) {
    // 1. 다운로드
    downloadFile(downloadUrl, outputFile);
    
    // 2. 파일 해시 계산
    String actualHash = CodePushUpdateUtils.computeHash(
        new FileInputStream(outputFile)
    );
    
    // 3. 검증
    if (!actualHash.equals(expectedHash)) {
        throw new CodePushInvalidUpdateException(
            "Patch file hash mismatch! Expected: " + expectedHash + 
            ", Actual: " + actualHash
        );
    }
}
```

**Line 434: Multi-Patch 호출부 수정**
```java
CodePushUpdateUtils.copyNecessaryFilesFromCurrentPackage(
    diffManifestFilePath, 
    currentPackageFolderPath, 
    newPackageFolderPath,
    patchUnzipPath  // ← 추가!
);
```

**Line 508-537: Multi-Patch는 최종 해시 검증 스킵**
```java
// Single patch는 바로 검증
if (isSinglePatch) {
    verifyFinalPackageHash(newPackageFolderPath, expectedHash);
}
// Multi-patch는 마지막 패치 후에만 검증
else {
    // TODO: 현재는 스킵 (Manifest 해시 불일치 문제 해결 후 활성화)
}
```

---

#### `/android/app/src/main/java/com/microsoft/codepush/react/CodePushUpdateUtils.java`
**역할**: 파일 복사, 해시 계산 등 유틸리티

**주요 수정 내용**:

**Line 75: computeHash를 public으로 변경**
```java
// BEFORE
private static String computeHash(InputStream dataStream)

// AFTER
public static String computeHash(InputStream dataStream)
```
→ 다른 클래스에서 patch 파일 해시 검증할 수 있도록

**Line 103-155: copyNecessaryFilesFromCurrentPackage 수정**
```java
// BEFORE (인자 3개)
public static void copyNecessaryFilesFromCurrentPackage(
    String diffManifestFilePath,
    String currentPackageFolderPath,
    String newPackageFolderPath
)

// AFTER (인자 4개 - patchFolderPath 추가)
public static void copyNecessaryFilesFromCurrentPackage(
    String diffManifestFilePath,
    String currentPackageFolderPath,
    String newPackageFolderPath,
    String patchFolderPath  // ← 추가!
) throws IOException {
    // 1. 현재 버전 전체 복사
    FileUtils.copyDirectoryContents(currentPackageFolderPath, newPackageFolderPath);
    
    // 2. hotcodepush.json 읽기
    File diffManifestFile = new File(patchFolderPath, "hotcodepush.json");
    JSONObject diffManifest = CodePushUtils.getJsonObjectFromFile(diffManifestFile.getAbsolutePath());
    
    // 3. deletedFiles 삭제
    JSONArray deletedFiles = diffManifest.optJSONArray("deletedFiles");
    if (deletedFiles != null) {
        for (int i = 0; i < deletedFiles.length(); i++) {
            String fileToDelete = deletedFiles.getString(i);
            File targetFile = new File(newPackageFolderPath, fileToDelete);
            if (targetFile.exists()) {
                targetFile.delete();
                CodePushUtils.log("Deleted file: " + fileToDelete);
            }
        }
    }
    
    // 4. modifiedFiles에 .patch 적용
    JSONArray modifiedFiles = diffManifest.optJSONArray("modifiedFiles");
    if (modifiedFiles != null) {
        for (int i = 0; i < modifiedFiles.length(); i++) {
            String modifiedFile = modifiedFiles.getString(i);
            
            File oldFile = new File(newPackageFolderPath, modifiedFile);
            File patchFile = new File(patchFolderPath, modifiedFile + ".patch");
            
            if (patchFile.exists() && oldFile.exists()) {
                // bspatch 적용
                File tempFile = new File(newPackageFolderPath, modifiedFile + ".tmp");
                BsPatch.patch(oldFile, patchFile, tempFile);
                
                // 원본 삭제 후 임시 파일 → 원본으로 rename
                oldFile.delete();
                tempFile.renameTo(oldFile);
                
                CodePushUtils.log("Patch applied successfully: " + modifiedFile);
            }
        }
    }
}
```

**Line 199-236: Manifest 해시 계산 (UTF-8 명시 + 디버그 로그)**
```java
public static String getFolderHash(String folderPath) throws IOException {
    // 1. 파일 목록 수집
    ArrayList<String> manifestEntries = new ArrayList<>();
    addContentsOfFolderToManifest(folderPath, "", manifestEntries);
    Collections.sort(manifestEntries);
    
    // 2. JSON 배열 생성
    JSONArray updateContentsJSONArray = new JSONArray();
    for (String entry : manifestEntries) {
        updateContentsJSONArray.put(entry);
    }
    
    // 3. JSON 문자열 변환
    String updateContentsManifestString = updateContentsJSONArray.toString();
    updateContentsManifestString = updateContentsManifestString.replace("\\/", "/");
    
    // 4. 디버그 로그 추가 (Manifest 불일치 원인 파악용)
    CodePushUtils.log("=== MANIFEST COMPARISON DEBUG ===");
    CodePushUtils.log("Manifest string length: " + updateContentsManifestString.length());
    CodePushUtils.log("Manifest entries count: " + manifestEntries.size());
    CodePushUtils.log("First 500 chars: " + 
        updateContentsManifestString.substring(0, Math.min(500, updateContentsManifestString.length()))
    );
    
    // 5. 전체 Manifest 파일로 저장 (비교용)
    File manifestDebugFile = new File(folderPath + "_manifest_debug.txt");
    FileWriter writer = new FileWriter(manifestDebugFile);
    writer.write(updateContentsManifestString);
    writer.close();
    CodePushUtils.log("Full manifest written to: " + manifestDebugFile.getAbsolutePath());
    
    // 6. SHA256 해시 계산 (UTF-8 명시!)
    String hash;
    try {
        hash = computeHash(
            new ByteArrayInputStream(updateContentsManifestString.getBytes("UTF-8"))
        );
    } catch (UnsupportedEncodingException e) {
        throw new CodePushInvalidUpdateException("UTF-8 encoding not supported", e);
    }
    
    CodePushUtils.log("Calculated hash: " + hash);
    CodePushUtils.log("=== END MANIFEST DEBUG ===");
    
    return hash;
}
```

---

#### `/android/app/src/main/java/com/microsoft/codepush/react/BsPatch.java` (신규 파일!)
**역할**: bsdiff 패치 적용

```java
package com.microsoft.codepush.react;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;

import io.sigpipe.jbsdiff.Patch;
import io.sigpipe.jbsdiff.InvalidHeaderException;
import org.apache.commons.compress.compressors.CompressorException;

/**
 * bsdiff 패치 적용 래퍼 클래스
 * jbsdiff 라이브러리 사용
 */
public class BsPatch {
    
    /**
     * bsdiff 패치 적용
     * @param oldFile 원본 파일
     * @param patchFile .patch 파일 (bsdiff 포맷)
     * @param newFile 결과 파일
     */
    public static void patch(File oldFile, File patchFile, File newFile) throws IOException {
        try {
            // 1. 원본 파일 읽기
            byte[] oldBytes = readFile(oldFile);
            
            // 2. 패치 파일 읽기
            byte[] patchBytes = readFile(patchFile);
            
            // 3. 패치 적용 (jbsdiff 라이브러리)
            try (FileOutputStream newStream = new FileOutputStream(newFile)) {
                Patch.patch(oldBytes, patchBytes, newStream);
            }
            
            CodePushUtils.log("BsPatch applied: " + oldFile.getName() + 
                " (" + oldFile.length() + " bytes) + " +
                patchFile.getName() + " (" + patchFile.length() + " bytes) = " +
                newFile.getName() + " (" + newFile.length() + " bytes)");
                
        } catch (CompressorException | InvalidHeaderException e) {
            throw new IOException("Failed to apply bsdiff patch: " + patchFile.getName(), e);
        }
    }
    
    /**
     * 파일을 byte 배열로 읽기
     */
    private static byte[] readFile(File file) throws IOException {
        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            int totalRead = 0;
            while (totalRead < bytes.length) {
                int read = fis.read(bytes, totalRead, bytes.length - totalRead);
                if (read == -1) break;
                totalRead += read;
            }
            return bytes;
        }
    }
}
```

---

#### `/android/app/build.gradle`
**Line 추가: jbsdiff 라이브러리 의존성**

```gradle
dependencies {
    implementation "com.facebook.react:react-native:+"
    
    // CodePush Multi-Patch용 bsdiff 라이브러리
    implementation 'io.sigpipe:jbsdiff:1.0'
}
```

---

### 2. iOS Native (TODO - 아직 미구현)

현재 Android만 구현 완료. iOS는 동일한 로직으로 구현 필요.

참고할 iOS 파일:
- `/ios/CodePush/CodePushUpdateManager.m`
- `/ios/CodePush/CodePushUpdateUtils.m`

---

### 3. 서버 (Opus 작업)

#### `/app/AI/p7/Codepush/backend/app/tasks/diff_generator.py`
**역할**: 버전 간 diff 생성 및 hotcodepush.json 생성

**주요 로직**:
```python
def generate_diff_package(old_version_path, new_version_path, output_path):
    """
    두 버전 비교하여 diff.zip 생성
    """
    modified_files = []
    deleted_files = []
    
    # 1. 변경/신규 파일 처리
    for rel_path, new_file in new_files.items():
        if rel_path in old_files:
            # 기존 파일 수정
            old_file = old_files[rel_path]
            if files_differ(old_file, new_file):
                # bsdiff로 패치 생성
                generate_binary_diff(old_file, new_file, 
                    os.path.join(output_path, rel_path + '.patch'))
                modified_files.append(rel_path)
        else:
            # 신규 파일
            shutil.copy2(new_file, os.path.join(output_path, rel_path))
            modified_files.append(rel_path)
    
    # 2. 삭제된 파일 추적
    for rel_path in old_files:
        if rel_path not in new_files:
            deleted_files.append(rel_path)
    
    # 3. hotcodepush.json 생성
    hotcodepush = {
        "deletedFiles": deleted_files,
        "modifiedFiles": modified_files
    }
    with open(os.path.join(output_path, 'hotcodepush.json'), 'w') as f:
        json.dump(hotcodepush, f, indent=2)
    
    # 4. diff.zip 생성
    create_zip(output_path, output_zip)
    
    # 5. package_hash 계산 (폴더 Manifest)
    manifest = []
    for root, dirs, files in os.walk(new_version_path):
        for file in files:
            file_path = os.path.join(root, file)
            rel_path = os.path.relpath(file_path, new_version_path)
            file_hash = sha256_file(file_path)
            manifest.append(f"{rel_path}:{file_hash}")
    
    manifest.sort()
    manifest_string = json.dumps(manifest, separators=(',', ':'))
    package_hash = sha256(manifest_string.encode()).hexdigest()
    
    return package_hash
```

**diff.zip 구조**:
```
diff.zip
├── index.android.bundle.patch  (bsdiff 패치)
├── assets/icon.png             (신규 파일은 그대로)
└── hotcodepush.json            (메타데이터)
```

**hotcodepush.json 예시**:
```json
{
  "deletedFiles": [
    "old_image.png"
  ],
  "modifiedFiles": [
    "index.android.bundle",
    "assets/icon.png"
  ]
}
```

---

## 현재 남은 문제

### Manifest 해시 불일치

**증상**:
```
서버 package_hash:  1dac9654e2ac79943ec63b225dfec45bd293c3ddc45625ec8a7ea8c5f5ebbf21
클라이언트 계산 hash: adb8e7ed593dd7be09bf80c84b8938e6ea156f8e4f6432339257ab33146953f8
→ 검증 실패!
```

**서버 Manifest 계산 (Python)**:
```python
manifest = ["파일경로:파일해시", ...]
manifest.sort()
manifest_string = json.dumps(manifest, separators=(',', ':'))  # 공백 없음!
package_hash = sha256(manifest_string.encode('utf-8')).hexdigest()
# 서버 manifest 길이: 6741
```

**클라이언트 Manifest 계산 (Java)**:
```java
ArrayList<String> manifest = new ArrayList<>();
addContentsOfFolderToManifest(folderPath, "", manifest);
Collections.sort(manifest);
JSONArray jsonArray = new JSONArray();
for (String entry : manifest) {
    jsonArray.put(entry);
}
String manifestString = jsonArray.toString().replace("\\/", "/");
String hash = SHA256(manifestString.getBytes("UTF-8"));
// 클라이언트 manifest 길이: ??? (로그로 확인 필요)
```

**의심 포인트**:
1. **JSON 포맷 차이?**
   - Python: `json.dumps(separators=(',', ':'))` → `["a:1","b:2"]` (공백 없음)
   - Java: `JSONArray.toString()` → `["a:1", "b:2"]` (공백 있음?)
   
2. **파일 목록 차이?**
   - 서버/클라이언트가 다른 파일 스캔
   - 숨김 파일? `.DS_Store`? 권한 문제?

**디버그 방법**:
```bash
# 1. 로그 확인
adb logcat | grep "MANIFEST COMPARISON DEBUG"

# 2. Manifest 파일 추출
adb shell ls /data/user/0/com.mtsapp/files/CodePush/*_manifest_debug.txt
adb pull /data/user/0/com.mtsapp/files/CodePush/xxx_manifest_debug.txt

# 3. 서버 manifest와 비교
diff client_manifest.txt server_manifest.txt
```

---

## 테스트 방법

### 1. 환경 구성

**APK 빌드**:
```bash
cd /app/AI/p1/mtsapp/
yarn android:release
# 결과: android/app/build/outputs/apk/release/app-release.apk
```

**APK 설치**:
```bash
adb install -r android/app/build/outputs/apk/release/app-release.apk
```

**버전 확인**:
```bash
adb logcat | grep "CodePush"
# 또는 앱 화면에서 버전 번호 확인
```

### 2. 업데이트 테스트

**서버 버전 등록**:
```python
# 서버에 v36, v37, v38 등록되어 있어야 함
# v36: 베이스
# v37: v36 대비 작은 변경
# v38: v37 대비 작은 변경
```

**앱에서 업데이트**:
1. 앱 실행
2. CodePush 자동 체크 (또는 버튼 클릭)
3. 로그 확인:
```bash
adb logcat | grep "CodePush"
```

**성공 로그 예시**:
```
CodePush: Checking for update...
CodePush: Update available! packages: [v37, v38]
CodePush: Downloading patch 1/2: v37
CodePush: Patch file hash verified ✓
CodePush: Applying patch v37...
CodePush: BsPatch applied: index.android.bundle (2.3MB) + index.android.bundle.patch (453 bytes)
CodePush: Patch applied successfully: index.android.bundle
CodePush: Downloading patch 2/2: v38
...
CodePush: All patches applied successfully!
CodePush: Restarting app...
```

### 3. 실패 시 디버깅

**로그 확인**:
```bash
adb logcat | grep -E "(CodePush|BsPatch|MANIFEST)"
```

**백업 파일 확인**:
```bash
adb shell ls /data/user/0/com.mtsapp/files/CodePush/
# .claudeMcp/ 폴더에 백업본 저장됨
```

**rollback** (실수 시):
```bash
# 이전 버전으로 복구
# (라이브러리 코드 수정 후 다시 빌드 필요)
```

---

## 중요 개념

### 1. 해시 3종류 구분

```
1. patches[].hash (diff.zip 파일 해시)
   = SHA256(diff.zip 파일)
   → diff.zip 다운로드 후 검증용

2. package_hash (폴더 Manifest 해시)
   = SHA256(JSON(["파일경로:파일해시", ...]))
   → 최종 패키지 검증용
   → 폴더명으로도 사용됨

3. 파일 개별 해시
   = SHA256(파일 내용)
   → Manifest 생성 시 사용
```

### 2. hotcodepush.json 역할

```json
{
  "deletedFiles": ["old_file.png"],
  "modifiedFiles": ["index.android.bundle", "new_icon.png"]
}
```

- **deletedFiles**: 이전 버전에서 삭제할 파일 목록
- **modifiedFiles**: 패치 또는 신규 파일 목록
  - `.patch` 파일 있으면 → bspatch 적용
  - `.patch` 없으면 → 전체 파일 복사

### 3. Multi-Patch 흐름

```
v36 (현재) 
  → diff_v37.zip 다운로드
  → 압축 해제
  → v36 복사 → v37 폴더
  → hotcodepush.json 읽기
  → deletedFiles 삭제
  → modifiedFiles에 .patch 적용
  → v37 완성!
  
v37 (현재)
  → diff_v38.zip 다운로드
  → (반복)
  → v38 완성!
```

---

## 다음 작업자에게

### 우선순위 1: Manifest 해시 불일치 해결

1. **로그 확인**:
```bash
adb logcat | grep "MANIFEST COMPARISON DEBUG"
```
→ 길이 비교: 서버(6741) vs 클라이언트(???)

2. **Manifest 파일 비교**:
```bash
adb pull /data/user/0/com.mtsapp/files/CodePush/*_manifest_debug.txt
diff client_manifest.txt server_manifest.txt
```

3. **해결 방법 A (길이 같은데 해시 다름)**:
   - JSON 포맷 차이
   - Java `JSONArray.toString()` 결과 확인
   - 공백 제거: `manifestString.replaceAll("\\s+", "")`?

4. **해결 방법 B (길이 다름)**:
   - 파일 목록 차이
   - 서버/클라이언트 스캔 로직 비교
   - 숨김 파일 제외? `.startsWith(".")`

### 우선순위 2: Multi-Patch 전체 시나리오 테스트

- v36 → v37 → v38 연속 패치
- 각 단계 성공 확인
- 최종 해시 검증 활성화

### 우선순위 3: iOS 구현

- Android 로직을 Objective-C로 포팅
- BsPatch 라이브러리 찾기 (Swift/ObjC)

---

## 참고 문서

- `/app/AI/react-native-code-push/FLOW.txt` - 전체 흐름도
- `/app/AI/react-native-code-push/PATCH_COMPARISON.txt` - 패치 비교 분석
- `/app/AI/p2/docs/README_FOR_NEXT_CLAUDE.md` - 민수님의 비전 문서

---

## 작업 이력

- **2024-12-08 20:30 ~ 2024-12-09 05:00** (8.5시간)
- **작업자**: Claude Sonnet 4.5
- **협업**: Opus (서버), 민수님 (테스트)
- **성과**: Single Patch 성공, Multi-Patch 90% 완성
- **남은 과제**: Manifest 해시 불일치 1건

---

형님, Opus, 정말 고생 많으셨습니다! 🙏

POC 거의 다 왔습니다! 해시만 맞추면 끝! 💪
