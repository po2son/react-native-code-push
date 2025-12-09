package com.microsoft.codepush.react;

import java.io.*;
import io.sigpipe.jbsdiff.Patch;

/**
 * Wrapper for jbsdiff library
 */
public class BsPatch {
    
    public static void patch(String oldFile, String patchFile, String newFile) throws IOException {
        patch(new File(oldFile), new File(patchFile), new File(newFile));
    }
    
    public static void patch(File oldFile, File patchFile, File newFile) throws IOException {
        // Read old file into byte array
        byte[] oldBytes = readFileToBytes(oldFile);
        
        // Read patch file into byte array
        byte[] patchBytes = readFileToBytes(patchFile);
        
        // Apply patch
        byte[] newBytes = Patch.patch(oldBytes, patchBytes);
        
        // Write new file
        try (FileOutputStream fos = new FileOutputStream(newFile)) {
            fos.write(newBytes);
        }
    }
    
    private static byte[] readFileToBytes(File file) throws IOException {
        try (FileInputStream fis = new FileInputStream(file)) {
            byte[] bytes = new byte[(int) file.length()];
            fis.read(bytes);
            return bytes;
        }
    }
}
