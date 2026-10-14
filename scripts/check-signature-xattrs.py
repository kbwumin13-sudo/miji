#!/usr/bin/env python3
"""Bounded fault injection for the file-signature getxattr stall, using only fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='miji-signature-') as temp:
    root = Path(temp)
    (root / 'block.c').write_text(r'''
#include <sys/xattr.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
static ssize_t blocked_getxattr(const char *path, const char *name, void *value,
                               size_t size, u_int32_t position, int options) {
    const char *target = getenv("MIJI_SIGNATURE_FIXTURE");
    if (target && strstr(path, target)) {
        const char *message = "FAIL: signature attempted getxattr\n";
        write(2, message, strlen(message));
        _exit(86);
    }
    return getxattr(path, name, value, size, position, options);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)blocked_getxattr, (const void *)getxattr}
};
''')
    (root / 'main.swift').write_text('''
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let regular = folder.appendingPathComponent("regular.txt")
let package = folder.appendingPathComponent("package.rtfd")
let expected = try FileSignature.read(regular)
guard expected.size == 7 else { fatalError("incorrect regular metadata") }
let contents = try FileSignature.read(package)
guard contents.size == 7 else { fatalError("incorrect package metadata") }
print("PASS: regular and package signatures need no extended attributes")
''')
    fixture = root / 'signature-fixture'
    fixture.mkdir()
    (fixture / 'regular.txt').write_text('fixture')
    (fixture / 'package.rtfd').mkdir()
    (fixture / 'package.rtfd/TXT.rtf').write_text('fixture')
    subprocess.run(['clang', '-dynamiclib', str(root / 'block.c'), '-o', str(root / 'block.dylib')], check=True, timeout=30)
    subprocess.run(['swiftc', str(project / 'Sources/MijiCore/Models.swift'),
                    str(project / 'Sources/MijiCore/FileSignature.swift'), str(root / 'main.swift'),
                    '-o', str(root / 'probe')], check=True, timeout=60)
    env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(root / 'block.dylib'), MIJI_SIGNATURE_FIXTURE=str(fixture))
    result = subprocess.run([str(root / 'probe'), str(fixture)], env=env, timeout=3)
    raise SystemExit(result.returncode)
