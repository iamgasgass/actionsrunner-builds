#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
codesign-verify: checks a signed arm64 Mach-O the way XNU and AMFI look at it, without a Mac.

  codesign-verify.py <file.dylib> [CA.pem]

- the SuperBlob and its slots; the CodeDirectory's fields against XNU's cs_validate_codedirectory rules;
- every page hash and the special slots (requirements), the CDHash;
- the CMS: messageDigest, Apple's 100.9.1 (cdhashes plist) and 100.9.2 attributes against the CDHash, the signer's
  algorithms; then `openssl cms -verify` for the signature (and the chain, given the CA).
Exit status 0 only when all of it holds.
"""
import hashlib, os, plistlib, struct, subprocess, sys, tempfile

bad = 0
def check(ok, what):
    global bad
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok: bad += 1

def der(b, i):
    t = b[i]; l = b[i + 1]; h = 2
    if l & 0x80:
        k = l & 0x7f; l = int.from_bytes(b[i + 2:i + 2 + k], 'big'); h += k
    return t, i + h, l          # tag, start of contents, length

def children(b, start, length):
    i, end = start, start + length
    while i < end:
        t, s, l = der(b, i); yield t, i, s, l; i = s + l

OIDS = {
    bytes.fromhex('2a864886f70d010903'): 'contentType', bytes.fromhex('2a864886f70d010905'): 'signingTime',
    bytes.fromhex('2a864886f70d010904'): 'messageDigest', bytes.fromhex('2a864886f763640901'): 'apple-cdhashes-plist',
    bytes.fromhex('2a864886f763640902'): 'apple-cdhashes', bytes.fromhex('2a864886f70d010101'): 'rsaEncryption',
    bytes.fromhex('2a864886f70d01010b'): 'sha256WithRSAEncryption', bytes.fromhex('2a8648ce3d040302'): 'ecdsa-with-SHA256',
    bytes.fromhex('608648016503040201'): 'sha256',
}

def main():
    path = sys.argv[1]; ca = sys.argv[2] if len(sys.argv) > 2 else None
    f = open(path, 'rb').read()
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<IiiIIIII', f, 0)
    check(magic == 0xfeedfacf, 'a 64-bit Mach-O')
    at = 32; cs = None; segs = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', f, at)
        if cmd == 0x19:
            name = f[at + 8:at + 24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize, maxprot, initprot = struct.unpack_from('<QQQQii', f, at + 24)
            segs.append((name, fileoff, filesize, initprot))
        elif cmd == 0x1d:
            cs = struct.unpack_from('<II', f, at + 8)
        at += size
    check(cs is not None, 'LC_CODE_SIGNATURE present')
    if not cs: return
    dataoff, datasize = cs
    link = [s for s in segs if s[0] == '__LINKEDIT']
    check(bool(link) and link[0][1] + link[0][2] == dataoff + datasize == len(f), '__LINKEDIT ends where the signature and the file end')
    check(dataoff % 16 == 0, 'signature 16-byte aligned')
    sb = f[dataoff:dataoff + datasize]
    m, length, count = struct.unpack_from('>III', sb, 0)
    check(m == 0xfade0cc0 and length <= datasize, 'embedded-signature SuperBlob')
    slots = {}
    for k in range(count):
        typ, off = struct.unpack_from('>II', sb, 12 + 8 * k)
        bm, bl = struct.unpack_from('>II', sb, off)
        slots[typ] = sb[off:off + bl]
        check(off + bl <= length, f'slot {typ:#x} (magic {bm:#x}) inside the SuperBlob')
    cds = [(t, slots[t]) for t in sorted(slots) if t == 0 or 0x1000 <= t < 0x1005]
    check(bool(cds) and cds[0][0] == 0, 'CodeDirectory in slot 0')
    hashers = {1: hashlib.sha1, 2: hashlib.sha256}
    cdinfo = {}
    for slot, cd in cds:
        check(cd[:4] == b'\xfa\xde\x0c\x02', f'slot {slot:#x} is a CodeDirectory')
        (cm, cl, ver, cflags, hashoff, identoff, nspecial, ncode, codelimit, hsize, htype, platform, pshift, _sp2,
         scatter, teamoff, _sp3, cl64, esbase, eslimit, esflags) = struct.unpack_from('>IIIIIIIIIBBBBIIIIQQQQ', cd, 0)
        H = hashers.get(htype)
        print(f'      CD {slot:#x}: version {ver:#x} flags {cflags:#x} pages {ncode} page 2^{pshift} codeLimit {codelimit:#x} hash {htype}/{hsize}')
        check(cl == len(cd), 'CD length')
        check(H is not None and hsize == H().digest_size, 'SHA-1 or SHA-256 hashes of the right size')
        if H is None: continue
        check(12 <= pshift <= 14, 'page size between 4 KiB and 16 KiB (XNU: PAGE_SHIFT_4K..PAGE_SHIFT)')
        check(pshift == 12, '4 KiB pages, as codesign, ldid and zsign write them for certificate signatures')
        check(codelimit == dataoff, 'codeLimit is the signature offset')
        ps = 1 << pshift
        check(ncode == (codelimit + ps - 1) // ps, 'nCodeSlots covers codeLimit')
        check(hashoff >= nspecial * hsize and hashoff + ncode * hsize <= cl, 'hash slots inside the CD')
        ident = cd[identoff:cd.index(b'\0', identoff)].decode()
        team = cd[teamoff:cd.index(b'\0', teamoff)].decode() if teamoff else ''
        print(f'      ident {ident!r} team {team!r} execSeg [{esbase:#x}, +{eslimit:#x}) flags {esflags:#x}')
        exe = [s_ for s_ in segs if s_[3] & 4]
        if exe:
            check(esbase == min(s_[1] for s_ in exe) and esbase + eslimit == max(s_[1] + s_[2] for s_ in exe), 'execSeg is the executable segments')
        check(all(cd[hashoff + i * hsize:hashoff + (i + 1) * hsize] == H(f[i * ps:min((i + 1) * ps, codelimit)]).digest()
                  for i in range(ncode)), f'all {ncode} page hashes')
        if 2 in slots and nspecial >= 2:
            check(cd[hashoff - 2 * hsize:hashoff - hsize] == H(slots[2]).digest(), 'requirements hash (slot -2)')
        check(cd[hashoff - hsize:hashoff] == b'\0' * hsize, 'slot -1 empty (no Info.plist)')
        cdinfo[slot] = (htype, H(cd).digest())
    for s_ in segs:
        if s_[3] & 2 and s_[2] and exe:
            check(not (s_[1] < esbase + eslimit and s_[1] + s_[2] > esbase), f'writable {s_[0]} outside execSeg')
    cd = slots[0]
    best = max(cdinfo.values(), key=lambda x: x[0]) if cdinfo else (0, b'')
    cdhash = best[1]
    print(f'      CDHashes ' + ', '.join(f'{k:#x}:{v[1].hex()[:16]}' for k, v in cdinfo.items()))
    cms = slots.get(0x10000)
    if not cms or len(cms) <= 8:
        print('      ad-hoc (no CMS)'); return
    cms = cms[8:]
    # ContentInfo -> [0] -> SignedData
    _, s, l = der(cms, 0)
    kids = list(children(cms, s, l))
    _, _, s2, l2 = kids[1]
    _, s3, l3 = der(cms, s2)
    sd = list(children(cms, s3, l3))
    certs = [k for k in sd if k[0] == 0xa0]
    check(len(certs) == 1, 'SignedData has its certificates')
    ncerts = len(list(children(cms, certs[0][2], certs[0][3]))) if certs else 0
    print(f'      {ncerts} certificate(s) in the CMS')
    signers = sd[-1]
    _, _, s4, l4 = signers
    si = list(children(cms, s4, l4))[0]
    sik = list(children(cms, si[2], si[3]))
    alg = lambda k: OIDS.get(cms[der(cms, k[2])[1]:der(cms, k[2])[1] + der(cms, k[2])[2]], '?')
    dig = alg(sik[2]); attrs = sik[3]; sigalg = alg(sik[4])
    print(f'      signer: digest {dig}, signature {sigalg}')
    check(dig == 'sha256', 'digestAlgorithm sha256')
    check(sigalg in ('rsaEncryption', 'ecdsa-with-SHA256'), 'signatureAlgorithm the one codesign writes (rsaEncryption / ecdsa-with-SHA256)')
    check(attrs[0] == 0xa0, 'signed attributes present')
    seen = []; last = b''
    for t, at_, s5, l5 in children(cms, attrs[2], attrs[3]):
        enc = cms[at_:s5 + l5]
        check(enc >= last, 'signed attributes in DER (SET OF) order'); last = enc
        ak = list(children(cms, s5, l5))
        oid = OIDS.get(cms[ak[0][2]:ak[0][2] + ak[0][3]], '?'); seen.append(oid)
        val = list(children(cms, ak[1][2], ak[1][3]))
        if oid == 'messageDigest':
            check(cms[val[0][2]:val[0][2] + val[0][3]] == hashlib.sha256(cd).digest(), 'messageDigest is SHA-256 of the slot-0 CodeDirectory')
        elif oid == 'apple-cdhashes-plist':
            pl = plistlib.loads(cms[val[0][2]:val[0][2] + val[0][3]])
            check(pl.get('cdhashes') == [v[1][:20] for k, v in sorted(cdinfo.items())], '100.9.1 plist holds every CDHash (20 bytes, slot order)')
        elif oid == 'apple-cdhashes':
            seq = list(children(cms, val[0][2], val[0][3]))
            check(OIDS.get(cms[seq[0][2]:seq[0][2] + seq[0][3]]) == 'sha256' and cms[seq[1][2]:seq[1][2] + seq[1][3]] == cdhash,
                  '100.9.2 holds sha256 and the SHA-256 CDHash')
    print('      attributes: ' + ', '.join(seen))
    for need in ('contentType', 'messageDigest', 'apple-cdhashes-plist'):
        check(need in seen, f'attribute {need}')
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, 'cms.der'), 'wb').write(cms); open(os.path.join(d, 'cd.bin'), 'wb').write(slots[0])
        args = ['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', os.path.join(d, 'cms.der'),
                '-content', os.path.join(d, 'cd.bin'), '-out', os.devnull]
        args += ['-CAfile', ca, '-purpose', 'any'] if ca else ['-noverify']
        r = subprocess.run(args, capture_output=True, text=True)
        check(r.returncode == 0, 'openssl cms -verify (' + ('signature and chain' if ca else 'signature') + ')'
              + ('' if r.returncode == 0 else ': ' + (r.stderr.strip().splitlines() or [''])[-1]))

main()
print('ALL GOOD' if not bad else f'{bad} PROBLEM(S)')
sys.exit(1 if bad else 0)
