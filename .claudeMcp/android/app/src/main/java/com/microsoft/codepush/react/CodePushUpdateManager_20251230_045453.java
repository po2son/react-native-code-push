package com.microsoft.codepush.react;

import android.os.Build;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.MalformedURLException;
import java.net.URL;
import java.nio.ByteBuffer;

import javax.net.ssl.HttpsURLConnection;

public class CodePushUpdateManager {

    private String mDocumentsDirectory;

    public CodePushUpdateManager(String documentsDirectory) {
        mDocumentsDirectory = documentsDirectory;
    }

    private String getDownloadFilePath() {
        return CodePushUtils.appendPathComponent(getCodePushPath(), CodePushConstants.DOWNLOAD_FILE_NAME);
    }

    private String getUnzippedFolderPath() {
        return CodePushUtils.appendPathComponent(getCodePushPath(), CodePushConstants.UNZIPPED_FOLDER_NAME);
    }

    private String getDocumentsDirectory() {
        return mDocumentsDirectory;
    }

    private String getCodePushPath() {
        String codePushPath = CodePushUtils.appendPathComponent(getDocumentsDirectory(), CodePushConstants.CODE_PUSH_FOLDER_PREFIX);
        if (CodePush.isUsingTestConfiguration()) {
            codePushPath = CodePushUtils.appendPathComponent(codePushPath, "TestPackages");
        }

        return codePushPath;
    }

    private String getStatusFilePath() {
        return CodePushUtils.appendPathComponent(getCodePushPath(), CodePushConstants.STATUS_FILE);
    }

    public JSONObject getCurrentPackageInfo() {
        String statusFilePath = getStatusFilePath();
        if (!FileUtils.fileAtPathExists(statusFilePath)) {
            return new JSONObject();
        }

        try {
            return CodePushUtils.getJsonObjectFromFile(statusFilePath);
        } catch (IOException e) {
            // Should not happen.
            throw new CodePushUnknownException("Error getting current package info", e);
        }
    }

    public void updateCurrentPackageInfo(JSONObject packageInfo) {
        try {
            CodePushUtils.writeJsonToFile(packageInfo, getStatusFilePath());
        } catch (IOException e) {
            // Should not happen.
            throw new CodePushUnknownException("Error updating current package info", e);
        }
    }

    public String getCurrentPackageFolderPath() {
        JSONObject info = getCurrentPackageInfo();
        String packageHash = info.optString(CodePushConstants.CURRENT_PACKAGE_KEY, null);
        if (packageHash == null) {
            return null;
        }

        return getPackageFolderPath(packageHash);
    }

    public String getCurrentPackageBundlePath(String bundleFileName) {
        String packageFolder = getCurrentPackageFolderPath();
        if (packageFolder == null) {
            return null;
        }

        JSONObject currentPackage = getCurrentPackage();
        if (currentPackage == null) {
            return null;
        }

        String relativeBundlePath = currentPackage.optString(CodePushConstants.RELATIVE_BUNDLE_PATH_KEY, null);
        if (relativeBundlePath == null) {
            return CodePushUtils.appendPathComponent(packageFolder, bundleFileName);
        } else {
            return CodePushUtils.appendPathComponent(packageFolder, relativeBundlePath);
        }
    }

    public String getPackageFolderPath(String packageHash) {
        return CodePushUtils.appendPathComponent(getCodePushPath(), packageHash);
    }

    public String getCurrentPackageHash() {
        JSONObject info = getCurrentPackageInfo();
        return info.optString(CodePushConstants.CURRENT_PACKAGE_KEY, null);
    }

    public String getPreviousPackageHash() {
        JSONObject info = getCurrentPackageInfo();
        return info.optString(CodePushConstants.PREVIOUS_PACKAGE_KEY, null);
    }

    public JSONObject getCurrentPackage() {
        String packageHash = getCurrentPackageHash();
        if (packageHash == null) {
            return null;
        }

        return getPackage(packageHash);
    }

    public JSONObject getPreviousPackage() {
        String packageHash = getPreviousPackageHash();
        if (packageHash == null) {
            return null;
        }

        return getPackage(packageHash);
    }

    public JSONObject getPackage(String packageHash) {
        String folderPath = getPackageFolderPath(packageHash);
        String packageFilePath = CodePushUtils.appendPathComponent(folderPath, CodePushConstants.PACKAGE_FILE_NAME);
        try {
            return CodePushUtils.getJsonObjectFromFile(packageFilePath);
        } catch (IOException e) {
            return null;
        }
    }

    public void downloadPackage(JSONObject updatePackage, String expectedBundleFileName,
                                DownloadProgressCallback progressCallback,
                                String stringPublicKey) throws IOException {
        String newUpdateHash = updatePackage.optString(CodePushConstants.PACKAGE_HASH_KEY, null);
        String newUpdateFolderPath = getPackageFolderPath(newUpdateHash);
        String newUpdateMetadataPath = CodePushUtils.appendPathComponent(newUpdateFolderPath, CodePushConstants.PACKAGE_FILE_NAME);
        if (FileUtils.fileAtPathExists(newUpdateFolderPath)) {
            // This removes any stale data in newPackageFolderPath that could have been left
            // uncleared due to a crash or error during the download or install process.
            FileUtils.deleteDirectoryAtPath(newUpdateFolderPath);
        }

        // Check for multi-patch update
        CodePushUtils.log("=== PATCH DEBUG ===");
        CodePushUtils.log("UpdatePackage keys: " + updatePackage.keys());
        JSONArray patches = updatePackage.optJSONArray("patches");
        CodePushUtils.log("Patches field: " + (patches != null ? patches.toString() : "NULL"));
        
        if (patches != null && patches.length() > 0) {
            CodePushUtils.log("Multi-patch update detected: " + patches.length() + " patches");
            downloadAndApplyMultiplePatches(patches, newUpdateFolderPath, newUpdateMetadataPath, 
                expectedBundleFileName, progressCallback, stringPublicKey, updatePackage);
            return;
        }

        // Single patch update (existing logic)
        CodePushUtils.log("Single patch update");

        String downloadUrlString = updatePackage.optString(CodePushConstants.DOWNLOAD_URL_KEY, null);
        HttpURLConnection connection = null;
        BufferedInputStream bin = null;
        FileOutputStream fos = null;
        BufferedOutputStream bout = null;
        File downloadFile = null;
        boolean isZip = false;

        // Download the file while checking if it is a zip and notifying client of progress.
        try {
            URL downloadUrl = new URL(downloadUrlString);
            connection = (HttpURLConnection) (downloadUrl.openConnection());

            if (android.os.Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP &&
                downloadUrl.toString().startsWith("https")) {
                try {
                    ((HttpsURLConnection)connection).setSSLSocketFactory(new TLSSocketFactory());
                } catch (Exception e) {
                    throw new CodePushUnknownException("Error set SSLSocketFactory. ", e);
                }
            }

            connection.setRequestProperty("Accept-Encoding", "identity");
            bin = new BufferedInputStream(connection.getInputStream());

            long totalBytes = connection.getContentLength();
            long receivedBytes = 0;

            File downloadFolder = new File(getCodePushPath());
            downloadFolder.mkdirs();
            downloadFile = new File(downloadFolder, CodePushConstants.DOWNLOAD_FILE_NAME);
            fos = new FileOutputStream(downloadFile);
            bout = new BufferedOutputStream(fos, CodePushConstants.DOWNLOAD_BUFFER_SIZE);
            byte[] data = new byte[CodePushConstants.DOWNLOAD_BUFFER_SIZE];
            byte[] header = new byte[4];

            int numBytesRead = 0;
            while ((numBytesRead = bin.read(data, 0, CodePushConstants.DOWNLOAD_BUFFER_SIZE)) >= 0) {
                if (receivedBytes < 4) {
                    for (int i = 0; i < numBytesRead; i++) {
                        int headerOffset = (int) (receivedBytes) + i;
                        if (headerOffset >= 4) {
                            break;
                        }

                        header[headerOffset] = data[i];
                    }
                }

                receivedBytes += numBytesRead;
                bout.write(data, 0, numBytesRead);
                progressCallback.call(new DownloadProgress(totalBytes, receivedBytes));
            }

            if (totalBytes !=-1 && totalBytes != receivedBytes) {
                throw new CodePushUnknownException("Received " + receivedBytes + " bytes, expected " + totalBytes);
            }

            isZip = ByteBuffer.wrap(header).getInt() == 0x504b0304;
        } catch (MalformedURLException e) {
            throw new CodePushMalformedDataException(downloadUrlString, e);
        } finally {
            try {
                if (bout != null) bout.close();
                if (fos != null) fos.close();
                if (bin != null) bin.close();
                if (connection != null) connection.disconnect();
            } catch (IOException e) {
                throw new CodePushUnknownException("Error closing IO resources.", e);
            }
        }

        if (isZip) {
            // Unzip the downloaded file and then delete the zip
            String unzippedFolderPath = getUnzippedFolderPath();
            FileUtils.unzipFile(downloadFile, unzippedFolderPath);
            FileUtils.deleteFileOrFolderSilently(downloadFile);

            // Merge contents with current update based on the manifest
            String diffManifestFilePath = CodePushUtils.appendPathComponent(unzippedFolderPath,
                    CodePushConstants.DIFF_MANIFEST_FILE_NAME);
            boolean isDiffUpdate = FileUtils.fileAtPathExists(diffManifestFilePath);
            if (isDiffUpdate) {
                String currentPackageFolderPath = getCurrentPackageFolderPath();
                CodePushUpdateUtils.copyNecessaryFilesFromCurrentPackage(diffManifestFilePath, currentPackageFolderPath, newUpdateFolderPath, unzippedFolderPath);
                File diffManifestFile = new File(diffManifestFilePath);
                diffManifestFile.delete();
            }

            FileUtils.copyDirectoryContents(unzippedFolderPath, newUpdateFolderPath);
            FileUtils.deleteFileAtPathSilently(unzippedFolderPath);

            // For zip updates, we need to find the relative path to the jsBundle and save it in the
            // metadata so that we can find and run it easily the next time.
            String relativeBundlePath = CodePushUpdateUtils.findJSBundleInUpdateContents(newUpdateFolderPath, expectedBundleFileName);

            if (relativeBundlePath == null) {
                throw new CodePushInvalidUpdateException("Update is invalid - A JS bundle file named \"" + expectedBundleFileName + "\" could not be found within the downloaded contents. Please check that you are releasing your CodePush updates using the exact same JS bundle file name that was shipped with your app's binary.");
            } else {
                if (FileUtils.fileAtPathExists(newUpdateMetadataPath)) {
                    File metadataFileFromOldUpdate = new File(newUpdateMetadataPath);
                    metadataFileFromOldUpdate.delete();
                }

                if (isDiffUpdate) {
                    CodePushUtils.log("Applying diff update.");
                } else {
                    CodePushUtils.log("Applying full update.");
                }

                boolean isSignatureVerificationEnabled = (stringPublicKey != null);

                String signaturePath = CodePushUpdateUtils.getSignatureFilePath(newUpdateFolderPath);
                boolean isSignatureAppearedInBundle = FileUtils.fileAtPathExists(signaturePath);

                if (isSignatureVerificationEnabled) {
                    if (isSignatureAppearedInBundle) {
                        CodePushUpdateUtils.verifyFolderHash(newUpdateFolderPath, newUpdateHash);
                        CodePushUpdateUtils.verifyUpdateSignature(newUpdateFolderPath, newUpdateHash, stringPublicKey);
                    } else {
                        throw new CodePushInvalidUpdateException(
                                "Error! Public key was provided but there is no JWT signature within app bundle to verify. " +
                                "Possible reasons, why that might happen: \n" +
                                "1. You've been released CodePush bundle update using version of CodePush CLI that is not support code signing.\n" +
                                "2. You've been released CodePush bundle update without providing --privateKeyPath option."
                        );
                    }
                } else {
                    if (isSignatureAppearedInBundle) {
                        CodePushUtils.log(
                                "Warning! JWT signature exists in codepush update but code integrity check couldn't be performed because there is no public key configured. " +
                                "Please ensure that public key is properly configured within your application."
                        );
                        CodePushUpdateUtils.verifyFolderHash(newUpdateFolderPath, newUpdateHash);
                    } else {
                        if (isDiffUpdate) {
                            CodePushUpdateUtils.verifyFolderHash(newUpdateFolderPath, newUpdateHash);
                        }
                    }
                }

                CodePushUtils.setJSONValueForKey(updatePackage, CodePushConstants.RELATIVE_BUNDLE_PATH_KEY, relativeBundlePath);
            }
        } else {
            // File is a jsbundle, move it to a folder with the packageHash as its name
            FileUtils.moveFile(downloadFile, newUpdateFolderPath, expectedBundleFileName);
        }

        // Save metadata to the folder.
        CodePushUtils.writeJsonToFile(updatePackage, newUpdateMetadataPath);
    }


    private void downloadAndApplyMultiplePatches(JSONArray patches, String finalUpdateFolderPath,
                                                  String finalUpdateMetadataPath, String expectedBundleFileName,
                                                  DownloadProgressCallback progressCallback,
                                                  String stringPublicKey, JSONObject updatePackage) throws IOException {
        // Create temporary working directory
        String tempWorkingPath = CodePushUtils.appendPathComponent(getCodePushPath(), "temp_multi_patch");
        if (FileUtils.fileAtPathExists(tempWorkingPath)) {
            FileUtils.deleteDirectoryAtPath(tempWorkingPath);
        }
        new File(tempWorkingPath).mkdirs();

        try {
            // Start with current package as base
            String currentPackageFolderPath = getCurrentPackageFolderPath();
            String workingFolderPath = CodePushUtils.appendPathComponent(tempWorkingPath, "working");
            new File(workingFolderPath).mkdirs();

            // DEBUG: Check current package
            CodePushUtils.log("=== BASE PACKAGE DEBUG ===");
            // CodePushUtils.log("currentPackageFolderPath: " + currentPackageFolderPath);
            if (currentPackageFolderPath != null && FileUtils.fileAtPathExists(currentPackageFolderPath)) {
                File currentDir = new File(currentPackageFolderPath);
                File[] currentFiles = currentDir.listFiles();
                CodePushUtils.log("Current package files: " + 
                    (currentFiles != null ? currentFiles.length : 0) + " items");
            } else {
                CodePushUtils.log("Current package: NOT FOUND");
            }
            
            if (currentPackageFolderPath != null && FileUtils.fileAtPathExists(currentPackageFolderPath)) {
                CodePushUtils.log("Copying current package as base for multi-patch update");
                FileUtils.copyDirectoryContents(currentPackageFolderPath, workingFolderPath);

            // DEBUG: Verify working folder after base copy
            File workingDirAfterCopy = new File(workingFolderPath);
            if (workingDirAfterCopy.exists()) {
                File[] workingFilesAfterCopy = workingDirAfterCopy.listFiles();
                CodePushUtils.log("=== AFTER BASE COPY ===");
                CodePushUtils.log("Working folder files: " + 
                    (workingFilesAfterCopy != null ? workingFilesAfterCopy.length : 0) + " items");
            }
            }

            // Apply each patch sequentially
            int totalPatches = patches.length();
            long totalBytesExpected = 0;
            long totalBytesReceived = 0;

            // Calculate total size for progress reporting
            for (int i = 0; i < totalPatches; i++) {
                JSONObject patch = patches.getJSONObject(i);
                totalBytesExpected += patch.optLong("size", 0);
            }

            // Check if first patch is a patches.zip bundle (contains manifest.json)
            JSONObject firstPatch = patches.getJSONObject(0);
            String firstPatchUrl = firstPatch.optString("url", null);
            String firstPatchHash = firstPatch.optString("hash", null);
            long firstPatchSize = firstPatch.optLong("size", 0);

            // Download first patch
            File firstPatchFile = downloadSinglePatch(firstPatchUrl, 0, progressCallback, 0, totalBytesExpected);
            totalBytesReceived += firstPatchSize;

            // Verify first patch hash
            if (firstPatchHash != null) {
                String actualHash = CodePushUpdateUtils.computeHash(new FileInputStream(firstPatchFile));
                if (!firstPatchHash.equals(actualHash)) {
                    throw new CodePushInvalidUpdateException(
                        "Patch file hash mismatch. Expected: " + firstPatchHash + ", Actual: " + actualHash
                    );
                }
            }

            // Unzip first patch
            String firstPatchUnzipPath = CodePushUtils.appendPathComponent(tempWorkingPath, "patch_0");
            FileUtils.unzipFile(firstPatchFile, firstPatchUnzipPath);
            firstPatchFile.delete();

            // Check for manifest.json (patches.zip bundle mode)
            String manifestPath = CodePushUtils.appendPathComponent(firstPatchUnzipPath, "manifest.json");
            boolean isPatchesBundle = FileUtils.fileAtPathExists(manifestPath);

            if (isPatchesBundle) {
                // === PATCHES.ZIP BUNDLE MODE ===
                CodePushUtils.log("Patches bundle detected (manifest.json found). Processing bundled patches...");
                
                // Read manifest.json
                String manifestContent = FileUtils.readFileToString(manifestPath);
                JSONObject manifest = new JSONObject(manifestContent);
                JSONArray bundledPatches = manifest.getJSONArray("patches");
                int bundledPatchCount = bundledPatches.length();
                
                CodePushUtils.log("Bundle contains " + bundledPatchCount + " patches");

                // Apply each patch from the bundle
                for (int i = 0; i < bundledPatchCount; i++) {
                    JSONObject bundledPatch = bundledPatches.getJSONObject(i);
                    String filename = bundledPatch.getString("filename");
                    String patchHash = bundledPatch.optString("hash", null);
                    
                    CodePushUtils.log("Applying bundled patch " + (i + 1) + "/" + bundledPatchCount + ": " + filename);

                    // Get the diff file from the extracted bundle
                    String diffFilePath = CodePushUtils.appendPathComponent(firstPatchUnzipPath, filename);
                    File diffFile = new File(diffFilePath);
                    
                    if (!diffFile.exists()) {
                        throw new CodePushInvalidUpdateException("Patch file not found in bundle: " + filename);
                    }

                    // Verify individual patch hash
                    if (patchHash != null) {
                        String actualPatchHash = CodePushUpdateUtils.computeHash(new FileInputStream(diffFile));
                        if (!patchHash.equals(actualPatchHash)) {
                            throw new CodePushInvalidUpdateException(
                                "Bundled patch hash mismatch for " + filename + ". Expected: " + patchHash + ", Actual: " + actualPatchHash
                            );
                        }
                    }

                    // Unzip the individual diff
                    String patchUnzipPath = CodePushUtils.appendPathComponent(tempWorkingPath, "bundled_patch_" + i);
                    FileUtils.unzipFile(diffFile, patchUnzipPath);

                    // Apply this patch using existing logic
                    applyPatchToWorkingFolder(patchUnzipPath, workingFolderPath, tempWorkingPath, i);
                    
                    FileUtils.deleteDirectoryAtPath(patchUnzipPath);
                }

                // Clean up bundle extract folder
                FileUtils.deleteDirectoryAtPath(firstPatchUnzipPath);

            } else {
                // === INDIVIDUAL PATCHES MODE (existing logic) ===
                CodePushUtils.log("Individual patches mode (no manifest.json). Processing " + totalPatches + " patches...");

                // Apply first patch (already downloaded and unzipped)
                applyPatchToWorkingFolder(firstPatchUnzipPath, workingFolderPath, tempWorkingPath, 0);
                FileUtils.deleteDirectoryAtPath(firstPatchUnzipPath);

                // Process remaining patches
                for (int i = 1; i < totalPatches; i++) {
                    JSONObject patch = patches.getJSONObject(i);
                    String patchUrl = patch.optString("url", null);
                    String fromLabel = patch.optString("from_label", "");
                    String toLabel = patch.optString("to_label", "");
                    String patchHash = patch.optString("hash", null);
                    long patchSize = patch.optLong("size", 0);

                    CodePushUtils.log("Applying patch " + (i + 1) + "/" + totalPatches + ": " + fromLabel + " -> " + toLabel);

                    // Download patch
                    File patchFile = downloadSinglePatch(patchUrl, i, progressCallback, totalBytesReceived, totalBytesExpected);
                    totalBytesReceived += patchSize;
                    
                    // Verify patch file hash
                    if (patchHash != null) {
                        String actualPatchHash = CodePushUpdateUtils.computeHash(new FileInputStream(patchFile));
                        if (!patchHash.equals(actualPatchHash)) {
                            throw new CodePushInvalidUpdateException(
                                "Patch file hash mismatch. Expected: " + patchHash + ", Actual: " + actualPatchHash
                            );
                        }
                    }

                    // Unzip patch to temporary folder
                    String patchUnzipPath = CodePushUtils.appendPathComponent(tempWorkingPath, "patch_" + i);
                    FileUtils.unzipFile(patchFile, patchUnzipPath);
                    patchFile.delete();

                    // Apply this patch
                    applyPatchToWorkingFolder(patchUnzipPath, workingFolderPath, tempWorkingPath, i);
                    FileUtils.deleteDirectoryAtPath(patchUnzipPath);
                }
            }

            // Move final result to target location
            // CodePushUtils.log("Moving final multi-patch result to: " + finalUpdateFolderPath);
            new File(finalUpdateFolderPath).mkdirs();
            FileUtils.copyDirectoryContents(workingFolderPath, finalUpdateFolderPath);

            // Find JS bundle and verify

            // DEBUG: Verify final folder before hash check
            File finalDir = new File(finalUpdateFolderPath);
            if (finalDir.exists()) {
                File[] finalFiles = finalDir.listFiles();
                CodePushUtils.log("=== Final folder files: " + 
                    (finalFiles != null ? finalFiles.length : 0) + " items");
                if (finalFiles != null) {
                    for (File f : finalFiles) {
                        CodePushUtils.log("  - " + f.getName() + 
                            (f.isDirectory() ? " (dir)" : " (" + f.length() + " bytes)"));
                    }
                }
            }
            String relativeBundlePath = CodePushUpdateUtils.findJSBundleInUpdateContents(finalUpdateFolderPath, expectedBundleFileName);
            if (relativeBundlePath == null) {
                throw new CodePushInvalidUpdateException("Update is invalid - A JS bundle file named \"" + expectedBundleFileName + "\" could not be found within the downloaded contents.");
            }

            // Multi-patch: skip final hash verification (already verified each patch)
            // Single-patch: verify hash and signature below
            boolean isMultiPatch = updatePackage.has("patches");
            String newUpdateHash = updatePackage.optString(CodePushConstants.PACKAGE_HASH_KEY, null);
            boolean isSignatureVerificationEnabled = (stringPublicKey != null);
            String signaturePath = CodePushUpdateUtils.getSignatureFilePath(finalUpdateFolderPath);
            boolean isSignaturePresent = FileUtils.fileAtPathExists(signaturePath);

            if (!isMultiPatch) {
                // Single-patch: verify full package hash
                if (isSignatureVerificationEnabled) {
                    if (isSignaturePresent) {
                        CodePushUpdateUtils.verifyFolderHash(finalUpdateFolderPath, newUpdateHash);
                        CodePushUpdateUtils.verifyUpdateSignature(finalUpdateFolderPath, newUpdateHash, stringPublicKey);
                    } else {
                        throw new CodePushInvalidUpdateException("Error! Public key was provided but there is no JWT signature within app bundle to verify.");
                    }
                } else {
                    if (isSignaturePresent) {
                        CodePushUtils.log("Warning! JWT signature exists but no public key configured.");
                    }
                    CodePushUpdateUtils.verifyFolderHash(finalUpdateFolderPath, newUpdateHash);
                }
            } else {
                CodePushUtils.log("Multi-patch update: skipping final hash verification (patches already verified)");
            }

            // Save metadata
            CodePushUtils.setJSONValueForKey(updatePackage, CodePushConstants.RELATIVE_BUNDLE_PATH_KEY, relativeBundlePath);

            // DEBUG: Log update completion
            CodePushUtils.log("=== UPDATE COMPLETION DEBUG ===");
            CodePushUtils.log("finalUpdateFolderPath: " + finalUpdateFolderPath);
            CodePushUtils.log("finalUpdateMetadataPath: " + finalUpdateMetadataPath);
            CodePushUtils.log("updatePackage label: " + updatePackage.optString("label", "unknown"));
            CodePushUtils.log("Metadata saved successfully");
            CodePushUtils.writeJsonToFile(updatePackage, finalUpdateMetadataPath);

            CodePushUtils.log("Multi-patch update completed successfully!");

        } catch (Exception e) {
            // Clean up on error
            if (FileUtils.fileAtPathExists(finalUpdateFolderPath)) {
                FileUtils.deleteDirectoryAtPath(finalUpdateFolderPath);
            }
            throw new IOException("Multi-patch update failed: " + e.getMessage(), e);
        } finally {
            // Clean up temporary directory
            if (FileUtils.fileAtPathExists(tempWorkingPath)) {
                FileUtils.deleteDirectoryAtPath(tempWorkingPath);
            }
        }
    }

    private File downloadSinglePatch(String patchUrl, int patchIndex,
                                     DownloadProgressCallback progressCallback,
                                     long bytesReceivedSoFar, long totalBytesExpected) throws IOException {
        HttpURLConnection connection = null;
        BufferedInputStream bin = null;
        FileOutputStream fos = null;
        BufferedOutputStream bout = null;

        try {
            URL downloadUrl = new URL(patchUrl);
            connection = (HttpURLConnection) downloadUrl.openConnection();

            if (android.os.Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP &&
                downloadUrl.toString().startsWith("https")) {
                try {
                    ((HttpsURLConnection)connection).setSSLSocketFactory(new TLSSocketFactory());
                } catch (Exception e) {
                    throw new CodePushUnknownException("Error set SSLSocketFactory.", e);
                }
            }

            connection.setRequestProperty("Accept-Encoding", "identity");
            bin = new BufferedInputStream(connection.getInputStream());

            long patchBytes = connection.getContentLength();
            long receivedBytes = 0;

            // DEBUG: Download info
            CodePushUtils.log("=== DOWNLOAD DEBUG ===");
            CodePushUtils.log("URL: " + patchUrl);
            CodePushUtils.log("Expected size: " + patchBytes + " bytes");
            CodePushUtils.log("HTTP Status: " + connection.getResponseCode());

            File downloadFolder = new File(getCodePushPath());
            File downloadFile = new File(downloadFolder, "patch_" + patchIndex + ".zip");
            fos = new FileOutputStream(downloadFile);
            bout = new BufferedOutputStream(fos, CodePushConstants.DOWNLOAD_BUFFER_SIZE);

            byte[] data = new byte[CodePushConstants.DOWNLOAD_BUFFER_SIZE];
            int numBytesRead;

            while ((numBytesRead = bin.read(data, 0, CodePushConstants.DOWNLOAD_BUFFER_SIZE)) >= 0) {
                receivedBytes += numBytesRead;
                bout.write(data, 0, numBytesRead);
                
                if (progressCallback != null && totalBytesExpected > 0) {
                    long totalReceived = bytesReceivedSoFar + receivedBytes;
                    progressCallback.call(new DownloadProgress(totalBytesExpected, totalReceived));
                }
            }

            if (patchBytes != -1 && patchBytes != receivedBytes) {
                throw new CodePushUnknownException("Received " + receivedBytes + " bytes, expected " + patchBytes);
            }

            return downloadFile;

        } catch (MalformedURLException e) {
            throw new CodePushMalformedDataException(patchUrl, e);
        } finally {
            try {
                if (bout != null) bout.close();
                if (fos != null) fos.close();
                if (bin != null) bin.close();
                if (connection != null) connection.disconnect();
            } catch (IOException e) {
                throw new CodePushUnknownException("Error closing IO resources.", e);
            }
        }
    }

    public void installPackage(JSONObject updatePackage, boolean removePendingUpdate) {
        String packageHash = updatePackage.optString(CodePushConstants.PACKAGE_HASH_KEY, null);
        JSONObject info = getCurrentPackageInfo();

        String currentPackageHash = info.optString(CodePushConstants.CURRENT_PACKAGE_KEY, null);
        if (packageHash != null && packageHash.equals(currentPackageHash)) {
            // The current package is already the one being installed, so we should no-op.
            return;
        }

        if (removePendingUpdate) {
            String currentPackageFolderPath = getCurrentPackageFolderPath();
            if (currentPackageFolderPath != null) {
                FileUtils.deleteDirectoryAtPath(currentPackageFolderPath);
            }
        } else {
            String previousPackageHash = getPreviousPackageHash();
            if (previousPackageHash != null && !previousPackageHash.equals(packageHash)) {
                FileUtils.deleteDirectoryAtPath(getPackageFolderPath(previousPackageHash));
            }

            CodePushUtils.setJSONValueForKey(info, CodePushConstants.PREVIOUS_PACKAGE_KEY, info.optString(CodePushConstants.CURRENT_PACKAGE_KEY, null));
        }

        CodePushUtils.setJSONValueForKey(info, CodePushConstants.CURRENT_PACKAGE_KEY, packageHash);
        updateCurrentPackageInfo(info);
    }

    public void rollbackPackage() {
        JSONObject info = getCurrentPackageInfo();
        String currentPackageFolderPath = getCurrentPackageFolderPath();
        FileUtils.deleteDirectoryAtPath(currentPackageFolderPath);
        CodePushUtils.setJSONValueForKey(info, CodePushConstants.CURRENT_PACKAGE_KEY, info.optString(CodePushConstants.PREVIOUS_PACKAGE_KEY, null));
        CodePushUtils.setJSONValueForKey(info, CodePushConstants.PREVIOUS_PACKAGE_KEY, null);
        updateCurrentPackageInfo(info);
    }

    public void downloadAndReplaceCurrentBundle(String remoteBundleUrl, String bundleFileName) throws IOException {
        URL downloadUrl;
        HttpURLConnection connection = null;
        BufferedInputStream bin = null;
        FileOutputStream fos = null;
        BufferedOutputStream bout = null;
        try {
            downloadUrl = new URL(remoteBundleUrl);
            connection = (HttpURLConnection) (downloadUrl.openConnection());
            bin = new BufferedInputStream(connection.getInputStream());
            File downloadFile = new File(getCurrentPackageBundlePath(bundleFileName));
            downloadFile.delete();
            fos = new FileOutputStream(downloadFile);
            bout = new BufferedOutputStream(fos, CodePushConstants.DOWNLOAD_BUFFER_SIZE);
            byte[] data = new byte[CodePushConstants.DOWNLOAD_BUFFER_SIZE];
            int numBytesRead = 0;
            while ((numBytesRead = bin.read(data, 0, CodePushConstants.DOWNLOAD_BUFFER_SIZE)) >= 0) {
                bout.write(data, 0, numBytesRead);
            }
        } catch (MalformedURLException e) {
            throw new CodePushMalformedDataException(remoteBundleUrl, e);
        } finally {
            try {
                if (bout != null) bout.close();
                if (fos != null) fos.close();
                if (bin != null) bin.close();
                if (connection != null) connection.disconnect();
            } catch (IOException e) {
                throw new CodePushUnknownException("Error closing IO resources.", e);
            }
        }
    }

    public void clearUpdates() {
        FileUtils.deleteDirectoryAtPath(getCodePushPath());
    }
}
