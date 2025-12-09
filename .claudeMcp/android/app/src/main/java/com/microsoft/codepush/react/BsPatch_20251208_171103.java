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
        try (FileInputStream oldStream = new FileInputStream(oldFile);
             FileInputStream patchStream = new FileInputStream(patchFile);
             FileOutputStream newStream = new FileOutputStream(newFile)) {
            
            // Use jbsdiff library to apply patch
            Patch.patch(oldStream, newStream, patchStream);
        }
    }
}
