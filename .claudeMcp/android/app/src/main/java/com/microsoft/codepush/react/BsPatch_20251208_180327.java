package com.microsoft.codepush.react;

import java.io.*;
import io.sigpipe.jbsdiff.Patch;
import org.apache.commons.compress.compressors.CompressorException;

/**
 * Wrapper for jbsdiff library
 */
public class BsPatch {
    
    public static void patch(String oldFile, String patchFile, String newFile) throws IOException {
        patch(new File(oldFile), new File(patchFile), new File(newFile));
    }
    
    public static void patch(File oldFile, File patchFile, File newFile) throws IOException {
        try {
            // Read old file
            byte[] oldBytes = readFile(oldFile);
            
            // Read patch file  
            byte[] patchBytes = readFile(patchFile);
            
            // Apply patch
            try (FileOutputStream newStream = new FileOutputStream(newFile)) {
                Patch.patch(oldBytes, patchBytes, newStream);
            }
        } catch (CompressorException e) {
            throw new IOException("Failed to apply bsdiff patch", e);
        }
    }
    
    private static byte[] readFile(File file) throws IOException {
        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            fis.read(bytes);
            return bytes;
        }
    }
}
