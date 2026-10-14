#!/usr/bin/env python3
"""Check the age core against fixed vectors, generated SSH keys, and the reference age tool."""
from pathlib import Path
import base64
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

from build import ROOT, swift_compiler

CORE = [
    'ByteIO.swift', 'AgeFormat.swift', 'BigUInt.swift', 'Bech32.swift', 'Curve25519Conversion.swift',
    'Scrypt.swift', 'Blowfish.swift', 'BlowfishTables.swift', 'RSAOAEP.swift', 'OpenSSHKey.swift',
    'AgeRecipients.swift', 'AgeIdentities.swift', 'AgeEngine.swift', 'Localization.swift',
]
AGE = shutil.which('age') or ('/opt/homebrew/bin/age' if Path('/opt/homebrew/bin/age').is_file() else None)
AGE_KEYGEN = shutil.which('age-keygen') or ('/opt/homebrew/bin/age-keygen' if Path('/opt/homebrew/bin/age-keygen').is_file() else None)
EXPECT = shutil.which('expect')
SSH_KEYGEN = shutil.which('ssh-keygen') or '/usr/bin/ssh-keygen'


# hexstr(value): Minimal big-endian hex, empty for zero, as the Swift side encodes BigUInt.
def hexstr(value):
    return '' if value == 0 else format(value, 'x').rjust((value.bit_length() + 7) // 8 * 2, '0')


# bigint_vectors(rng): Random operand pairs with Python-computed results.
def bigint_vectors(rng):
    vectors = []
    sizes = [(8, 8), (64, 32), (65, 64), (2048, 1024), (4096, 2048), (33, 32), (96, 64), (257, 256)]
    # Three random pairs per width combination, from single-limb values up to RSA-sized ones.
    for bits_a, bits_b in sizes:
        for _ in range(3):
            a = rng.getrandbits(bits_a)
            b = rng.getrandbits(bits_b) | 1
            m = rng.getrandbits(bits_b) | 1
            # A divisor whose top limb is nearly all ones exercises the Knuth D correction path.
            if rng.random() < 0.3:
                b = (1 << bits_b) - rng.getrandbits(8) - 1
            vectors.append({
                'a': hexstr(a), 'b': hexstr(b), 'm': hexstr(m),
                'mul': hexstr(a * b), 'add': hexstr(a + b), 'div': hexstr(a // b), 'mod': hexstr(a % b),
                'pow': hexstr(pow(a, b, m)), 'sub': hexstr(a - b) if a >= b else '',
            })
    # Edge cases: equal operands, zero and one, and divisors whose low limb is zero.
    for a, b in [(1, 1), ((1 << 96) - 1, (1 << 64)), ((1 << 128), (1 << 64) + 1), (0, 1), (12345, 12345), ((1 << 2047) + 7, (1 << 1024))]:
        m = (1 << 100) + 3
        vectors.append({
            'a': hexstr(a), 'b': hexstr(b), 'm': hexstr(m),
            'mul': hexstr(a * b), 'add': hexstr(a + b), 'div': hexstr(a // b), 'mod': hexstr(a % b),
            'pow': hexstr(pow(a, b, m)), 'sub': hexstr(a - b) if a >= b else '',
        })
    return vectors


# ed25519_vectors(rng): Edwards public keys with their Montgomery u-coordinates, computed with
# the field arithmetic in Python.
def ed25519_vectors(rng):
    p = (1 << 255) - 19
    vectors = []
    # Twelve random y-coordinates mapped with u = (1 + y) / (1 - y) in the field.
    for _ in range(12):
        y = rng.randrange(2, p - 1)
        u = (1 + y) * pow(1 - y, p - 2, p) % p
        edwards = y.to_bytes(32, 'little')
        # A random sign bit must be ignored.
        edwards = bytes([*edwards[:31], edwards[31] | (0x80 if rng.random() < 0.5 else 0)])
        vectors.append({'edwards': edwards.hex(), 'montgomery': u.to_bytes(32, 'little').hex()})
    return vectors


# rsa_numbers(rng): A 2048-bit RSA key generated in Python for the OAEP round trip.
def rsa_numbers(rng):
    # is_probable_prime(n): Miller-Rabin with fixed bases, enough for test keys.
    def is_probable_prime(n):
        # Zero and one are not prime.
        if n < 2:
            return False
        # Trial division settles small inputs and rejects most composites cheaply.
        for small in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
            # A multiple of a small prime is prime only when it is that prime.
            if n % small == 0:
                return n == small
        # Write n - 1 as d * 2^r with d odd.
        d, r = n - 1, 0
        while d % 2 == 0:
            d //= 2
            r += 1
        # Each base is a witness of compositeness unless its sequence reaches -1.
        for a in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
            x = pow(a, d, n)
            # This base cannot disprove primality.
            if x in (1, n - 1):
                continue
            # Square up to r - 1 times looking for -1.
            for _ in range(r - 1):
                x = pow(x, 2, n)
                # Reached -1, so this base passes.
                if x == n - 1:
                    break
            # No -1 appeared, so n is composite.
            else:
                return False
        return True

    # prime(bits): A random prime of the given size.
    def prime(bits):
        # Draw odd candidates with the top bit set until one passes the primality test.
        while True:
            candidate = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
            # Stop at the first probable prime.
            if is_probable_prime(candidate):
                return candidate

    # Pick distinct primes whose p - 1 and q - 1 are coprime with the public exponent.
    e = 65537
    while True:
        p, q = prime(1024), prime(1024)
        # Both conditions are needed for the private exponent below to exist.
        if p != q and (p - 1) % e and (q - 1) % e:
            break
    # Derive the modulus, the private exponent, and the CRT coefficient the OAEP code needs.
    n = p * q
    d = pow(e, -1, (p - 1) * (q - 1))
    return {'n': hexstr(n), 'e': hexstr(e), 'd': hexstr(d), 'p': hexstr(p), 'q': hexstr(q), 'qinv': hexstr(pow(q, -1, p))}


# run(command, **kwargs): Run a command and return its stdout; exit with its output on failure.
def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    # Any failure aborts the whole run with the command's output for diagnosis.
    if result.returncode != 0:
        sys.exit(f'command failed: {" ".join(map(str, command))}\n{result.stdout}\n{result.stderr}')
    return result.stdout


# with_rounds(pem, rounds): The same protected OpenSSH private key text with its bcrypt round
# count replaced, to imitate a hostile key file. Everything else in the file is kept.
def with_rounds(pem, rounds):
    lines = pem.strip().splitlines()
    blob = bytearray(base64.b64decode(''.join(lines[1:-1])))
    offset = len(b'openssh-key-v1\0')
    # Skip the cipher and KDF names, then the KDF options' own length and the salt inside them.
    for _ in range(2):
        offset += 4 + int.from_bytes(blob[offset:offset + 4], 'big')
    offset += 4
    offset += 4 + int.from_bytes(blob[offset:offset + 4], 'big')
    blob[offset:offset + 4] = rounds.to_bytes(4, 'big')
    # Re-wrap the base64 body at 70 columns, as ssh-keygen writes it.
    body = base64.b64encode(bytes(blob)).decode()
    return '\n'.join([lines[0]] + [body[i:i + 70] for i in range(0, len(body), 70)] + [lines[-1]]) + '\n'


# rewrite_pem_blob(pem, transform): Decode one PEM body, transform its bytes, and wrap it again.
def rewrite_pem_blob(pem, transform):
    lines = pem.strip().splitlines()
    blob = transform(bytearray(base64.b64decode(''.join(lines[1:-1]))))
    body = base64.b64encode(bytes(blob)).decode()
    return '\n'.join([lines[0]] + [body[i:i + 70] for i in range(0, len(body), 70)] + [lines[-1]]) + '\n'


# age_passphrase(mode, input_path, output_path, passphrase): Drive the interactive age passphrase
# prompts with expect. Returns False when expect is missing or the run fails.
def age_passphrase(mode, input_path, output_path, passphrase):
    # Without expect, the interactive prompts cannot be answered.
    if not EXPECT:
        return False
    # Encryption asks for the passphrase twice.
    if mode == 'encrypt':
        script = (
            f'set timeout 60; spawn {AGE} -p -o {output_path} {input_path}; '
            f'expect -re "passphrase.*:"; send "{passphrase}\\r"; expect -re "Confirm.*:"; send "{passphrase}\\r"; '
            'expect eof; catch wait result; exit [lindex $result 3]'
        )
    # Decryption asks once.
    else:
        script = (
            f'set timeout 60; spawn {AGE} -d -o {output_path} {input_path}; '
            f'expect -re "passphrase.*:"; send "{passphrase}\\r"; '
            'expect eof; catch wait result; exit [lindex $result 3]'
        )
    # Succeed only when age exited cleanly and the output file exists.
    result = subprocess.run([EXPECT, '-c', script], capture_output=True, text=True)
    return result.returncode == 0 and Path(output_path).is_file()


# main(): Build the harness, then run the self-tests, key readers, and the interop rounds.
def main():
    # A fixed seed keeps the vectors and plaintexts reproducible between runs.
    rng = random.Random(20261013)
    with tempfile.TemporaryDirectory(prefix='agemin-core-', dir='/private/tmp') as directory:
        folder = Path(directory)
        # Build the harness from the core sources with optimization, since RSA and scrypt are slow
        # unoptimized.
        harness = folder / 'age-core'
        run(swift_compiler() + [
            '-O', '-parse-as-library', '-swift-version', '5', '-warnings-as-errors', '-target', 'arm64-apple-macos14.0',
            '-module-cache-path', str(folder / 'modules'),
            *[str(ROOT / 'Sources/AgeminApp' / name) for name in CORE], str(ROOT / 'scripts/test_age_core.swift'),
            '-o', str(harness),
        ])
        keys = folder / 'keys'
        keys.mkdir()
        # A throwaway HOME keeps ssh-keygen and age away from the real key directories.
        env = {**os.environ, 'HOME': str(folder)}
        # An age key pair, from age-keygen when it is installed, for the Bech32 checks and the
        # interop runs below.
        age_identity = keys / 'age.txt'
        # Prefer the reference generator so our Bech32 reader is checked against foreign output.
        if AGE_KEYGEN:
            output = run([AGE_KEYGEN, '-o', str(age_identity)], env=env)
        # Fall back to our own generator; the pair still serves the later rounds.
        else:
            output = run([str(harness), 'keygen', str(age_identity), str(keys / 'age.pub')])
        age_public = age_secret = None
        # Find the pair in the identity file's comment line or in the generator's output.
        for line in (age_identity.read_text().splitlines() + output.splitlines()):
            # The public key is the first age1 token found in either source.
            if 'age1' in line and not age_public:
                age_public = 'age1' + line.split('age1', 1)[1].split()[0]
            # The secret line is the identity itself.
            if line.startswith('AGE-SECRET-KEY-1'):
                age_secret = line.strip()
        assert age_public and age_secret, 'no age key pair found'
        # Hand every vector set and the key pair to the harness self-test.
        vectors = folder / 'vectors.json'
        vectors.write_text(json.dumps({
            'bigint': bigint_vectors(rng), 'ed25519': ed25519_vectors(rng), 'rsa': rsa_numbers(rng),
            'age_secret': age_secret, 'age_public': age_public,
        }))
        print(run([str(harness), 'selftest', str(vectors)]).strip())

        # Keys: SSH Ed25519 and RSA, protected and unprotected, an unsupported ECDSA key, and a
        # legacy PEM RSA key.
        run([SSH_KEYGEN, '-q', '-t', 'ed25519', '-N', '', '-C', 'ed test', '-f', str(keys / 'ed25519')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'rsa', '-b', '2048', '-N', '', '-C', 'rsa test', '-f', str(keys / 'rsa')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'rsa', '-b', '3072', '-N', 'correct horse', '-C', 'rsa protected', '-f', str(keys / 'rsa_protected')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'ed25519', '-N', 'battery staple', '-C', 'ed protected', '-f', str(keys / 'ed_protected')], env=env)
        # These comment lengths align the private section exactly to the unencrypted 8-byte and
        # encrypted 16-byte block sizes, so OpenSSH writes a valid key with no padding bytes.
        run([SSH_KEYGEN, '-q', '-t', 'ed25519', '-N', '', '-C', 'abcde', '-f', str(keys / 'ed_zero_padding')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'ed25519', '-N', 'zero padding', '-C', 'abcdefghijklm', '-f', str(keys / 'ed_protected_zero_padding')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'ecdsa', '-N', '', '-f', str(keys / 'ecdsa')], env=env)
        run([SSH_KEYGEN, '-q', '-t', 'rsa', '-b', '2048', '-m', 'PEM', '-N', '', '-f', str(keys / 'rsa_legacy')], env=env)

        # Our own key readers report the public keys ssh-keygen wrote, including protected ones.
        for name, passphrase, expected in [
            ('ed25519', None, 'ssh-ed25519'), ('rsa', None, 'ssh-rsa'), ('rsa_protected', 'correct horse', 'ssh-rsa'),
            ('ed_protected', 'battery staple', 'ssh-ed25519'), ('ed_zero_padding', None, 'ssh-ed25519'),
            ('ed_protected_zero_padding', 'zero padding', 'ssh-ed25519'), ('rsa_legacy', None, 'ssh-rsa'),
        ]:
            info = run([str(harness), 'keyinfo', str(keys / name)] + ([passphrase] if passphrase else [])).split()
            assert info[0] == expected, (name, info)
            public_line = (keys / f'{name}.pub').read_text().split()
            assert info[1:3] == public_line[:2], (name, info, public_line)
        # The age identity reads too, and three failures are reported by name: an unsupported key
        # type, a wrong passphrase, and a missing one.
        info = run([str(harness), 'keyinfo', str(age_identity)]).split()
        assert info == ['age', age_public], info
        unsupported = subprocess.run([str(harness), 'keyinfo', str(keys / 'ecdsa')], capture_output=True, text=True)
        assert unsupported.returncode != 0 and 'ecdsa' in unsupported.stderr + unsupported.stdout, unsupported
        wrong = subprocess.run([str(harness), 'keyinfo', str(keys / 'rsa_protected'), 'nope'], capture_output=True, text=True)
        assert wrong.returncode != 0 and 'passphrase is incorrect' in wrong.stderr + wrong.stdout, wrong
        missing = subprocess.run([str(harness), 'keyinfo', str(keys / 'ed_protected')], capture_output=True, text=True)
        assert missing.returncode != 0 and 'needs a passphrase' in missing.stderr + missing.stdout, missing
        # A key file that asks for an absurd number of bcrypt rounds is refused before any work,
        # while the same key with its real count still opens.
        hostile = keys / 'ed_hostile'
        hostile.write_text(with_rounds((keys / 'ed_protected').read_text(), 2 ** 31 - 1))
        slow = subprocess.run([str(harness), 'keyinfo', str(hostile), 'battery staple'], capture_output=True, text=True, timeout=30)
        assert slow.returncode != 0 and 'key derivation rounds' in slow.stderr + slow.stdout, slow
        # Container bytes, broken OpenSSH padding, and trailing DER data must be refused instead of
        # being accepted as alternative encodings of an otherwise valid private key.
        trailing = keys / 'ed_trailing'
        trailing.write_text(rewrite_pem_blob((keys / 'ed25519').read_text(), lambda blob: blob + b'\0'))
        bad_padding = keys / 'ed_bad_padding'
        bad_padding.write_text(rewrite_pem_blob(
            (keys / 'ed25519').read_text(),
            lambda blob: blob[:-1] + bytes([blob[-1] ^ 0xFF]),
        ))
        legacy_trailing = keys / 'rsa_legacy_trailing'
        legacy_trailing.write_text(rewrite_pem_blob((keys / 'rsa_legacy').read_text(), lambda blob: blob + b'\0'))
        for path in (trailing, bad_padding, legacy_trailing):
            malformed = subprocess.run([str(harness), 'keyinfo', str(path)], capture_output=True, text=True)
            assert malformed.returncode != 0 and 'malformed' in malformed.stderr + malformed.stdout, path
        print('key readers: generated SSH and age keys parsed')

        # Plaintexts around the chunk boundary.
        plain = folder / 'plain'
        plain.mkdir()
        sizes = [0, 1, 65535, 65536, 65537, 131072, 300000]
        for size in sizes:
            (plain / f'{size}.bin').write_bytes(rng.randbytes(size))
        # Every generated public key is a recipient, and every private key an identity.
        recipients = [
            (keys / 'ed25519.pub').read_text().strip(),
            (keys / 'rsa.pub').read_text().strip(),
            (keys / 'rsa_protected.pub').read_text().strip(),
            (keys / 'ed_protected.pub').read_text().strip(),
            (keys / 'rsa_legacy.pub').read_text().strip(),
            age_public,
        ]
        identities = [
            ('ed25519', None), ('rsa', None), ('rsa_protected', 'correct horse'), ('ed_protected', 'battery staple'),
            ('rsa_legacy', None), ('age.txt', None),
        ]

        # Our encryption, decrypted by every identity through our code, then by the reference tool.
        ours = folder / 'ours'
        ours.mkdir()
        for size in sizes:
            source = plain / f'{size}.bin'
            for armor in ('0', '1'):
                target = ours / f'{size}-{armor}.age'
                run([str(harness), 'encrypt', str(source), str(target), armor, *recipients])
                for name, passphrase in identities:
                    output = ours / f'{size}-{armor}-{name}.out'
                    run([str(harness), 'decrypt', str(target), str(output), str(keys / name)] + ([passphrase] if passphrase else []))
                    assert output.read_bytes() == source.read_bytes(), (size, armor, name)
                # The reference tool would prompt for the protected keys, so it uses the others.
                if AGE:
                    for name in ('ed25519', 'rsa', 'rsa_legacy', 'age.txt'):
                        output = ours / f'{size}-{armor}-{name}.ref'
                        run([AGE, '-d', '-i', str(keys / name), '-o', str(output), str(target)], env=env)
                        assert output.read_bytes() == source.read_bytes(), ('age -d', size, armor, name)
        print(f'our files: {len(sizes) * 2} encrypted, decrypted by {len(identities)} identities' + (' and by age' if AGE else ''))

        # The reference tool's encryption, decrypted by our code.
        if AGE:
            theirs = folder / 'theirs'
            theirs.mkdir()
            for size in sizes:
                source = plain / f'{size}.bin'
                for armor in (False, True):
                    target = theirs / f'{size}-{int(armor)}.age'
                    command = [AGE, '-o', str(target)] + (['-a'] if armor else [])
                    # age takes each recipient as its own -r option.
                    for recipient in recipients:
                        command += ['-r', recipient]
                    run(command + [str(source)], env=env)
                    # Our inspector must report the armor choice and all five SSH recipient stanzas.
                    inspected = run([str(harness), 'inspect', str(target)])
                    assert ('armored' if armor else 'binary') in inspected and inspected.count('ssh') == 5, inspected
                    for name, passphrase in identities:
                        output = theirs / f'{size}-{int(armor)}-{name}.out'
                        run([str(harness), 'decrypt', str(target), str(output), str(keys / name)] + ([passphrase] if passphrase else []))
                        assert output.read_bytes() == source.read_bytes(), ('age -e', size, armor, name)
            print(f'age files: {len(sizes) * 2} decrypted by {len(identities)} identities')

            # A stranger's key must be refused without writing output.
            stranger = folder / 'stranger'
            run([str(harness), 'keygen', str(stranger), str(folder / 'stranger.pub')])
            refused = subprocess.run([str(harness), 'decrypt', str(theirs / '1-0.age'), str(folder / 'refused.out'), str(stranger)], capture_output=True, text=True)
            assert refused.returncode != 0 and not (folder / 'refused.out').exists(), refused
            print('stranger refused without output')

            # Passphrase files in both directions, when expect can drive age's prompts.
            source = plain / '65537.bin'
            # Run the interop only when expect could answer age's encryption prompts.
            if age_passphrase('encrypt', source, folder / 'age-pass.age', 'correct horse battery'):
                output = folder / 'age-pass.out'
                run([str(harness), 'decrypt-passphrase', str(folder / 'age-pass.age'), str(output), 'correct horse battery'])
                assert output.read_bytes() == source.read_bytes()
                wrong = subprocess.run([str(harness), 'decrypt-passphrase', str(folder / 'age-pass.age'), str(folder / 'wrong.out'), 'nope'], capture_output=True, text=True)
                assert wrong.returncode != 0 and 'incorrect' in wrong.stdout + wrong.stderr, wrong
                run([str(harness), 'encrypt-passphrase', str(source), str(folder / 'our-pass.age'), 'battery staple horse', '12'])
                assert age_passphrase('decrypt', folder / 'our-pass.age', folder / 'our-pass.out', 'battery staple horse'), 'age could not decrypt our passphrase file'
                assert (folder / 'our-pass.out').read_bytes() == source.read_bytes()
                print('passphrase files: age and Agemin decrypt each other')
            # Without expect, report the skip instead of failing.
            else:
                print('passphrase interop skipped: expect could not drive age')

            # An age-encrypted identity file is usable with its passphrase.
            if age_passphrase('encrypt', age_identity, folder / 'identity.age', 'identity pass'):
                target = ours / '1-0.age'
                output = folder / 'identity.out'
                run([str(harness), 'decrypt', str(target), str(output), str(folder / 'identity.age'), 'identity pass'])
                assert output.read_bytes() == (plain / '1.bin').read_bytes()
                print('encrypted identity file: decrypted with its passphrase')
        # Without age, the self-contained checks below still run.
        else:
            print('age reference checks skipped: age is not installed')

        # An identity file encrypted with a passphrase is binary; it must be recognized and usable
        # with its passphrase. This needs no reference tool.
        encrypted_identity = folder / 'identity-local.age'
        run([str(harness), 'encrypt-passphrase', str(age_identity), str(encrypted_identity), 'identity pass', '10'])
        output = folder / 'identity-local.out'
        run([str(harness), 'decrypt', str(ours / '1-0.age'), str(output), str(encrypted_identity), 'identity pass'])
        assert output.read_bytes() == (plain / '1.bin').read_bytes()
        # The same file without its passphrase is refused, and keyinfo opens it with one.
        missing = subprocess.run([str(harness), 'decrypt', str(ours / '1-0.age'), str(folder / 'nopass.out'), str(encrypted_identity)], capture_output=True, text=True)
        assert missing.returncode != 0 and 'needs a passphrase' in missing.stdout + missing.stderr, missing
        info = run([str(harness), 'keyinfo', str(encrypted_identity), 'identity pass']).split()
        assert info == ['age', age_public], info
        print('encrypted identity file: binary identity file decrypted with its passphrase')

        # The decrypted output is private to the user.
        mode = (ours / '1-0-ed25519.out').stat().st_mode & 0o777
        assert mode == 0o600, oct(mode)
        # The harness prints the SHA-256 of what it wrote; it must match the plaintext.
        digest = hashlib.sha256((plain / '300000.bin').read_bytes()).hexdigest()
        reported = run([str(harness), 'decrypt', str(ours / '300000-0.age'), str(folder / 'digest.out'), str(keys / 'ed25519')]).split()
        assert reported[2] == digest, reported
        print('output permissions and checksum verified')


# Run the checks as a command.
if __name__ == '__main__':
    main()
