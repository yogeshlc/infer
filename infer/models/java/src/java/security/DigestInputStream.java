/*
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

package java.security;

import com.facebook.infer.builtins.InferUndefined;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;


public class DigestInputStream extends FilterInputStream {

    public DigestInputStream(InputStream stream, MessageDigest digest) {
        super(stream);
    }

    public int read() throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(byte b[]) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }

    public int read(byte b[], int off, int len) throws IOException {
        return InferUndefined.can_throw_ioexception_int();
    }
}
