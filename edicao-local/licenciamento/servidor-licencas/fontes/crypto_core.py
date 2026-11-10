"""P-256 signatures, high entropy codes and encrypted portable server backups."""
import base64, hashlib, io, json, os, secrets, sqlite3, zipfile, tempfile, subprocess
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

APP_ID = 'com.campo.agrogestao.localpilot'
FORMAT = 'agrogestor-local-license'
BACKUP_MAGIC = b'AGRO-LICENSE-BACKUP-V1\n'

def b64(data): return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')
def unb64(value): return base64.b64decode(value+'='*(-len(value)%4), altchars=b'-_', validate=True)
def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()
def public_bytes(key): return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
def fingerprint(key): return hashlib.sha256(public_bytes(key)).hexdigest()
def load_public(encoded):
    raw=unb64(encoded)
    key=serialization.load_der_public_key(raw)
    if not isinstance(key,ec.EllipticCurvePublicKey) or not isinstance(key.curve,ec.SECP256R1): raise ValueError('P-256 required')
    if public_bytes(key)!=raw: raise ValueError('Non canonical key')
    return key
def normalize_code(code):
    import re
    value=re.sub(r'[\s-]', '', code).upper()
    if not re.fullmatch(r'AGRO[A-Z2-7]{32}',value): raise ValueError('Invalid code format')
    return value
def code_hash(code): return hashlib.sha256(normalize_code(code).encode('ascii')).hexdigest()
def new_code():
    value=base64.b32encode(secrets.token_bytes(20)).decode()
    return 'AGRO-'+'-'.join(value[i:i+8] for i in range(0,32,8))
def proof(challenge, nonce, request_id, code_digest, key_fp):
    return '\n'.join(['AGROGESTOR-ACTIVATE-V1',challenge,nonce,request_id,code_digest,key_fp,APP_ID]).encode('ascii')
def sign_license(key, payload):
    raw=canonical(payload)
    return {'payload':b64(raw),'signature':b64(key.sign(raw,ec.ECDSA(hashes.SHA256()))),'keyId':fingerprint(key.public_key())[:16]}
def verify_license(public, document):
    raw=unb64(document['payload'])
    public.verify(unb64(document['signature']),raw,ec.ECDSA(hashes.SHA256()))
    payload=json.loads(raw)
    if payload['format']!=FORMAT or payload['schemaVersion']!=1 or payload['appId']!=APP_ID or payload['kind']!='free_perpetual' or payload['expiresAt'] is not None: raise ValueError('Invalid license claims')
    if document['keyId']!=fingerprint(public)[:16]: raise ValueError('Wrong issuer')
    return payload

def dpapi(data, decrypt=False):
    if os.name!='nt': raise RuntimeError('Use Windows DPAPI for the real server')
    import ctypes
    from ctypes import wintypes
    class Blob(ctypes.Structure): _fields_=[('size',wintypes.DWORD),('data',ctypes.POINTER(ctypes.c_byte))]
    buffer=ctypes.create_string_buffer(data);source=Blob(len(data),ctypes.cast(buffer,ctypes.POINTER(ctypes.c_byte)));out=Blob()
    crypt=ctypes.WinDLL('crypt32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    method=crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    method.argtypes=[ctypes.POINTER(Blob),ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(Blob)]
    method.restype=wintypes.BOOL;kernel.LocalFree.argtypes=[ctypes.c_void_p]
    if not method(ctypes.byref(source),None,None,None,None,1,ctypes.byref(out)): raise OSError(ctypes.get_last_error(),'DPAPI failed')
    try:return ctypes.string_at(out.data,out.size)
    finally:kernel.LocalFree(out.data)

def write_issuer(folder, key, testing=False):
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=True)
    if not testing:protect_folder(folder)
    raw=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption())
    (folder/'issuer-key.dpapi').write_bytes(raw if testing else dpapi(raw))
    os.chmod(folder/'issuer-key.dpapi',0o600)
    (folder/'issuer-public.json').write_text(json.dumps({'appId':APP_ID,'keyId':fingerprint(key.public_key())[:16],'publicKey':b64(public_bytes(key.public_key()))},indent=2),encoding='utf-8')
def read_issuer(folder, testing=False):
    raw=(Path(folder)/'issuer-key.dpapi').read_bytes()
    return serialization.load_pem_private_key(raw if testing else dpapi(raw,True),password=None)

def validate_data_folder(folder):
    target=Path(folder).resolve();home=Path.home().resolve()
    protected={Path(target.anchor),home,home/'Documents',home/'Desktop',Path(os.environ.get('SystemRoot',r'C:\Windows')).resolve(),Path(__file__).resolve().parents[1]}
    if target in protected:raise ValueError('Use a dedicated licensing data subdirectory, never a drive, profile or system root')
    return target

def protect_folder(folder):
    if os.name!='nt':raise RuntimeError('Real licensing data requires Windows protection')
    target=validate_data_folder(folder)
    account=subprocess.check_output(['whoami'],text=True,creationflags=0x08000000).strip()
    subprocess.run(['icacls.exe',str(target),'/inheritance:r','/grant:r',account+':(OI)(CI)F','SYSTEM:(OI)(CI)F'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True,creationflags=0x08000000)

def make_backup(folder, key, password):
    if len(password)<12:raise ValueError('Use at least 12 characters')
    folder=Path(folder)
    # A disk snapshot can leave WAL mode before serialization; an in-memory clone
    # of a WAL database otherwise needs a nonexistent WAL file on deserialize.
    with tempfile.TemporaryDirectory(prefix='snapshot-',dir=folder) as temporary:
        path=Path(temporary)/'snapshot.sqlite3'
        source=sqlite3.connect(folder/'licencas.sqlite3');snapshot=sqlite3.connect(path)
        try:
            source.backup(snapshot);snapshot.execute('PRAGMA journal_mode=DELETE');snapshot.commit()
        finally:source.close();snapshot.close()
        database=path.read_bytes()
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w',zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('database.sqlite3',database)
        archive.writestr('issuer.pem',key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        archive.writestr('manifest.json',canonical({'format':1,'keyId':fingerprint(key.public_key())[:16],'databaseSha256':hashlib.sha256(database).hexdigest()}))
    salt=secrets.token_bytes(16);nonce=secrets.token_bytes(12)
    derived=Scrypt(salt=salt,length=32,n=32768,r=8,p=1).derive(password.encode())
    return BACKUP_MAGIC+salt+nonce+AESGCM(derived).encrypt(nonce,stream.getvalue(),BACKUP_MAGIC)

def decode_backup(data, password):
    if len(data)>128*1024*1024 or not data.startswith(BACKUP_MAGIC):raise ValueError('Invalid backup')
    raw=data[len(BACKUP_MAGIC):];salt,nonce,cipher=raw[:16],raw[16:28],raw[28:]
    derived=Scrypt(salt=salt,length=32,n=32768,r=8,p=1).derive(password.encode())
    plain=AESGCM(derived).decrypt(nonce,cipher,BACKUP_MAGIC)
    with zipfile.ZipFile(io.BytesIO(plain)) as archive:
        if set(archive.namelist())!={'database.sqlite3','issuer.pem','manifest.json'} or sum(i.file_size for i in archive.infolist())>128*1024*1024:raise ValueError('Invalid backup members')
        database=archive.read('database.sqlite3');key=serialization.load_pem_private_key(archive.read('issuer.pem'),password=None);manifest=json.loads(archive.read('manifest.json'))
    if manifest!={'format':1,'keyId':fingerprint(key.public_key())[:16],'databaseSha256':hashlib.sha256(database).hexdigest()}:raise ValueError('Invalid backup integrity')
    verify=sqlite3.connect(':memory:')
    try:
        verify.deserialize(database)
        if verify.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Corrupt SQLite')
        if not verify.execute('SELECT count(*) FROM administrators').fetchone()[0]:raise ValueError('No administrator')
        verify.execute('DELETE FROM sessions');verify.execute('DELETE FROM challenges');verify.execute('DELETE FROM limits');verify.commit()
        database=verify.serialize()
    finally:verify.close()
    return database,key
