package com.microsoft.codepush.react;

import java.io.*;

/**
 * Pure Java implementation of bspatch algorithm
 * Based on bsdiff/bspatch by Colin Percival
 */
public class BsPatch {
    
    public static void patch(String oldFile, String patchFile, String newFile) throws IOException {
        patch(new File(oldFile), new File(patchFile), new File(newFile));
    }
    
    public static void patch(File oldFile, File patchFile, File newFile) throws IOException {
        RandomAccessFile oldRaf = null;
        RandomAccessFile newRaf = null;
        DataInputStream patchStream = null;
        
        try {
            // Read old file
            oldRaf = new RandomAccessFile(oldFile, "r");
            byte[] oldBytes = new byte[(int) oldRaf.length()];
            oldRaf.readFully(oldBytes);
            
            // Read patch
            patchStream = new DataInputStream(new BufferedInputStream(new FileInputStream(patchFile)));
            
            // Read header
            byte[] header = new byte[8];
            patchStream.readFully(header);
            
            // Check magic
            if (header[0] != 'B' || header[1] != 'S' || header[2] != 'D' || 
                header[3] != 'I' || header[4] != 'F' || header[5] != 'F' || 
                header[6] != '4' || header[7] != '0') {
                throw new IOException("Invalid bsdiff patch format");
            }
            
            // Read control block length, diff block length, new file length
            long ctrlBlockLen = readLong(patchStream);
            long diffBlockLen = readLong(patchStream);
            long newSize = readLong(patchStream);
            
            // Validate
            if (ctrlBlockLen < 0 || diffBlockLen < 0 || newSize < 0) {
                throw new IOException("Invalid patch header");
            }
            
            // Read blocks
            byte[] ctrlBlock = new byte[(int) ctrlBlockLen];
            byte[] diffBlock = new byte[(int) diffBlockLen];
            
            patchStream.readFully(ctrlBlock);
            patchStream.readFully(diffBlock);
            
            // Apply patch
            byte[] newBytes = new byte[(int) newSize];
            
            int oldPos = 0;
            int newPos = 0;
            int ctrlPos = 0;
            int diffPos = 0;
            
            while (newPos < newSize) {
                // Read control data
                if (ctrlPos + 24 > ctrlBlock.length) {
                    break;
                }
                
                long diffLen = readLongFromBytes(ctrlBlock, ctrlPos);
                long extraLen = readLongFromBytes(ctrlBlock, ctrlPos + 8);
                long seekAmount = readLongFromBytes(ctrlBlock, ctrlPos + 16);
                ctrlPos += 24;
                
                // Add diff block
                for (int i = 0; i < diffLen && newPos < newSize; i++) {
                    int oldByte = (oldPos + i < oldBytes.length) ? (oldBytes[oldPos + i] & 0xFF) : 0;
                    int diffByte = (diffPos < diffBlock.length) ? diffBlock[diffPos++] : 0;
                    newBytes[newPos++] = (byte) (oldByte + diffByte);
                }
                oldPos += (int) diffLen;
                
                // Add extra block
                int extraStart = (int) (patchStream.available() - (newSize - newPos));
                for (int i = 0; i < extraLen && newPos < newSize; i++) {
                    newBytes[newPos++] = (byte) patchStream.read();
                }
                
                // Seek
                oldPos += (int) seekAmount;
            }
            
            // Write new file
            newRaf = new RandomAccessFile(newFile, "rw");
            newRaf.write(newBytes);
            
        } finally {
            if (oldRaf != null) oldRaf.close();
            if (newRaf != null) newRaf.close();
            if (patchStream != null) patchStream.close();
        }
    }
    
    private static long readLong(DataInputStream in) throws IOException {
        long value = 0;
        for (int i = 0; i < 8; i++) {
            value |= ((long) (in.read() & 0xFF)) << (i * 8);
        }
        // Handle sign
        if ((value & 0x8000000000000000L) != 0) {
            value = -(value & 0x7FFFFFFFFFFFFFFFL);
        }
        return value;
    }
    
    private static long readLongFromBytes(byte[] bytes, int offset) {
        long value = 0;
        for (int i = 0; i < 8; i++) {
            value |= ((long) (bytes[offset + i] & 0xFF)) << (i * 8);
        }
        // Handle sign
        if ((value & 0x8000000000000000L) != 0) {
            value = -(value & 0x7FFFFFFFFFFFFFFFL);
        }
        return value;
    }
}
