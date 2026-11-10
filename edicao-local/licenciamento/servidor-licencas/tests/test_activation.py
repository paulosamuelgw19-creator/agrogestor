import concurrent.futures,hashlib,json,logging,secrets,sqlite3,tempfile,unittest,uuid,os,io,sys,contextlib
from unittest.mock import patch
from pathlib import Path
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient
from fontes.app import create_app,PASSWORDS
from fontes.crypto_core import APP_ID,b64,public_bytes,code_hash,proof,fingerprint,verify_license,write_issuer,new_code,make_backup,decode_backup,read_issuer
from fontes.database import initialize,connect,transaction

class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='agro-activation-test-');self.root=Path(self.temp.name)
        self.issuer=ec.generate_private_key(ec.SECP256R1());write_issuer(self.root,self.issuer,testing=True);initialize(self.root)
        self.password=secrets.token_urlsafe(24)
        with transaction(self.root) as db:db.execute('INSERT INTO administrators VALUES(?,?)',('administrator-test',PASSWORDS.hash(self.password)))
        self.now=1000000.0
        self.app=create_app(self.root,testing=True,clock=lambda:self.now)
        self.client=TestClient(self.app,base_url='http://127.0.0.1',client=('127.0.0.1',40000))
        response=self.client.post('/admin/login',json={'username':'administrator-test','password':self.password})
        self.assertEqual(response.status_code,200);self.csrf={'X-CSRF-Token':response.json()['csrfToken']}
    def tearDown(self):self.client.close();self.temp.cleanup()
    def code(self):
        response=self.client.post('/admin/codes',json={'recipient':'Produtor TESTE','notes':''},headers=self.csrf)
        self.assertEqual(response.status_code,200);return response.json()
    def request(self,code,key=None,request_id=None):
        key=key or ec.generate_private_key(ec.SECP256R1());request_id=request_id or str(uuid.uuid4())
        response=self.client.post('/activation/v1/challenge',json={'appId':APP_ID,'schemaVersion':1,'requestId':request_id,'codeHash':code_hash(code),'publicKey':b64(public_bytes(key.public_key()))})
        self.assertEqual(response.status_code,200);challenge=response.json()
        raw=proof(challenge['challengeId'],challenge['nonce'],request_id,code_hash(code),fingerprint(key.public_key()))
        return key,{'challengeId':challenge['challengeId'],'nonce':challenge['nonce'],'code':code,'signature':b64(key.sign(raw,ec.ECDSA(hashes.SHA256())))}
    def activate(self,code,key=None):
        key,body=self.request(code,key);return key,self.client.post('/activation/v1/activate',json=body)
    def count(self,table):
        db=connect(self.root)
        try:return db.execute('SELECT count(*) FROM '+table).fetchone()[0]
        finally:db.close()

    def test_valid_perpetual_license_is_signed_and_bound(self):
        issued=self.code();key,response=self.activate(issued['code']);self.assertEqual(response.status_code,200)
        payload=verify_license(self.issuer.public_key(),response.json()['license'])
        self.assertIsNone(payload['expiresAt']);self.assertEqual(payload['installationKeySha256'],fingerprint(key.public_key()))
        self.assertEqual(self.count('licenses'),1)
    def test_code_cannot_authorize_second_installation(self):
        code=self.code()['code'];self.activate(code);_,response=self.activate(code)
        self.assertEqual(response.status_code,409);self.assertEqual(response.json()['error'],'code_used');self.assertEqual(self.count('licenses'),1)
    def test_concurrent_activations_issue_exactly_once(self):
        code=self.code()['code'];_,a=self.request(code);_,b=self.request(code)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda body:self.client.post('/activation/v1/activate',json=body),[a,b]))
        self.assertEqual(sorted(r.status_code for r in results),[200,409]);self.assertEqual(self.count('licenses'),1)
    def test_lost_response_recovers_same_document(self):
        code=self.code()['code'];key,response=self.activate(code);_,again=self.activate(code,key)
        self.assertEqual(again.status_code,200);self.assertEqual(response.json()['license'],again.json()['license']);self.assertEqual(self.count('licenses'),1)
    def test_used_challenge_cannot_be_replayed(self):
        key,body=self.request(self.code()['code']);self.assertEqual(self.client.post('/activation/v1/activate',json=body).status_code,200)
        self.assertEqual(self.client.post('/activation/v1/activate',json=body).json()['error'],'challenge_expired')
    def test_wrong_possession_proof_is_rejected(self):
        _,body=self.request(self.code()['code']);body['signature']=b64(ec.generate_private_key(ec.SECP256R1()).sign(b'incorrect',ec.ECDSA(hashes.SHA256())))
        self.assertEqual(self.client.post('/activation/v1/activate',json=body).json()['error'],'invalid_proof');self.assertEqual(self.count('licenses'),0)
    def test_expired_challenge_is_rejected(self):
        _,body=self.request(self.code()['code']);self.now+=121
        self.assertEqual(self.client.post('/activation/v1/activate',json=body).json()['error'],'challenge_expired')
    def test_invalid_and_cancelled_codes_do_not_issue(self):
        _,response=self.activate(new_code());self.assertEqual(response.json()['error'],'invalid_code')
        code=self.code();self.assertEqual(self.client.post('/admin/codes/'+code['id']+'/cancel',json={},headers=self.csrf).status_code,200)
        _,response=self.activate(code['code']);self.assertEqual(response.json()['error'],'cancelled_code');self.assertEqual(self.count('licenses'),0)
    def test_administrative_routes_require_auth_and_csrf(self):
        stranger=TestClient(self.app,base_url='http://127.0.0.1',client=('127.0.0.1',50000))
        self.assertEqual(stranger.get('/admin/codes').status_code,401)
        self.assertEqual(stranger.post('/admin/codes',json={'recipient':'X'}).status_code,401)
        self.assertEqual(self.client.post('/admin/codes',json={'recipient':'X'}).status_code,403)
        self.assertEqual(self.client.post('/admin/codes',json={'recipient':'X'},headers={**self.csrf,'Origin':'https://untrusted.invalid'}).status_code,403)
        remote=TestClient(self.app,base_url='http://127.0.0.1',client=('192.0.2.20',50000))
        self.assertEqual(remote.get('/').status_code,403);self.assertEqual(remote.post('/admin/login',json={'username':'x','password':'x'}).status_code,403)
        stranger.close();remote.close()
    def test_codes_and_passwords_are_not_stored_plaintext_or_echoed(self):
        code=self.code()['code'];db=connect(self.root)
        try:dump='\n'.join(db.iterdump())
        finally:db.close()
        self.assertNotIn(code,dump);self.assertNotIn(code.replace('-',''),dump);self.assertNotIn(self.password,dump)
        response=self.client.post('/activation/v1/activate',json={'code':code,'unexpected':'X'})
        self.assertNotIn(code,response.text);self.assertNotIn('input',response.text)
        self.assertNotIn(code,self.client.get('/admin/codes').text)
    def test_rate_limits_and_host_validation(self):
        for i in range(5):response=self.client.post('/admin/login',json={'username':'bad','password':'bad'})
        self.assertEqual(response.status_code,429)
        self.assertEqual(self.client.get('/health',headers={'Host':'untrusted.invalid'}).status_code,400)
    def test_oversized_request_and_application_identity_rejected(self):
        self.assertEqual(self.client.post('/activation/v1/challenge',content=b'x'*8193,headers={'Content-Type':'application/json'}).status_code,413)
        key=ec.generate_private_key(ec.SECP256R1())
        response=self.client.post('/activation/v1/challenge',json={'appId':'other.app','schemaVersion':1,'requestId':str(uuid.uuid4()),'codeHash':'a'*64,'publicKey':b64(public_bytes(key.public_key()))})
        self.assertEqual(response.status_code,400);self.assertEqual(response.json()['error'],'unsupported_app')
    def test_tampered_license_or_wrong_issuer_is_rejected(self):
        _,response=self.activate(self.code()['code']);document=response.json()['license'];document['payload']=document['payload'][:-1]+('A' if document['payload'][-1]!='A' else 'B')
        with self.assertRaises(Exception):verify_license(self.issuer.public_key(),document)
        _,response=self.activate(self.code()['code'])
        with self.assertRaises(Exception):verify_license(ec.generate_private_key(ec.SECP256R1()).public_key(),response.json()['license'])
    def test_replacement_preserves_old_permanent_authorization(self):
        code=self.code();_,response=self.activate(code['code']);old=response.json()['license']
        replacement=self.client.post('/admin/codes/'+code['id']+'/replacement',json={},headers=self.csrf)
        self.assertEqual(replacement.status_code,200);self.assertNotEqual(replacement.json()['code'],code['code'])
        self.assertEqual(self.client.post('/admin/codes/'+code['id']+'/cancel',json={},headers=self.csrf).status_code,409)
        self.activate(replacement.json()['code']);self.assertEqual(self.count('licenses'),2);verify_license(self.issuer.public_key(),old)
    def test_encrypted_backup_restores_issuer_and_used_codes(self):
        code=self.code()['code'];key,response=self.activate(code);password=secrets.token_urlsafe(24)
        backup=make_backup(self.root,self.issuer,password)
        self.assertNotIn(b'PRIVATE KEY',backup)
        with self.assertRaises(Exception):decode_backup(backup,'wrong password')
        database,issuer=decode_backup(backup,password)
        restored=self.root/'restored';restored.mkdir();(restored/'licencas.sqlite3').write_bytes(database);write_issuer(restored,issuer,testing=True)
        app=create_app(restored,testing=True,clock=lambda:self.now)
        client=TestClient(app,base_url='http://127.0.0.1',client=('127.0.0.1',40000));previous=self.client;self.client=client
        try:
            _,again=self.activate(code,key);self.assertEqual(again.json()['license'],response.json()['license'])
            _,other=self.activate(code);self.assertEqual(other.json()['error'],'code_used')
            verify_license(issuer.public_key(),again.json()['license'])
            self.assertEqual(client.get('/admin/codes').status_code,401)
        finally:self.client=previous;client.close()
    @unittest.skipUnless(os.name=='nt','Windows DPAPI integration')
    def test_initial_setup_has_no_default_account_and_hashes_chosen_password(self):
        from fontes.manage import main
        from fontes.crypto_core import protect_folder
        folder=self.root/'initial-setup';initialize(folder);write_issuer(folder,self.issuer)
        db=connect(folder)
        try:self.assertEqual(db.execute('SELECT count(*) FROM administrators').fetchone()[0],0)
        finally:db.close()
        chosen=secrets.token_urlsafe(24)
        with patch.object(sys,'argv',['manage','setup','--data',str(folder)]),patch('builtins.input',return_value='chosen-user-test'),patch('getpass.getpass',return_value=chosen),contextlib.redirect_stdout(io.StringIO()):main()
        db=connect(folder)
        try:
            row=db.execute('SELECT * FROM administrators').fetchone()
            self.assertEqual(row['username'],'chosen-user-test');self.assertNotEqual(row['password_hash'],chosen)
            self.assertTrue(PASSWORDS.verify(chosen,row['password_hash']))
        finally:db.close()
        with patch('fontes.crypto_core.subprocess.run') as change_permissions:
            with self.assertRaises(ValueError):protect_folder(Path(folder.anchor))
            with self.assertRaises(ValueError):protect_folder(Path.home())
            change_permissions.assert_not_called()
    @unittest.skipUnless(os.name=='nt','Windows DPAPI integration')
    def test_setup_and_reset_accept_eight_digits_and_retry_invalid_input(self):
        from fontes.manage import main
        folder=self.root/'eight-character-login';initialize(folder);write_issuer(folder,self.issuer)
        password=''.join(secrets.choice('0123456789') for _ in range(8))
        with patch.object(sys,'argv',['manage','setup','--data',str(folder)]),patch('builtins.input',return_value='eight-digit-test'),patch('getpass.getpass',side_effect=[password[:7],password,password]),contextlib.redirect_stdout(io.StringIO()):main()
        db=connect(folder)
        try:stored=db.execute('SELECT password_hash FROM administrators').fetchone()[0]
        finally:db.close()
        self.assertTrue(PASSWORDS.verify(password,stored))
        app=create_app(folder,testing=False,clock=lambda:self.now)
        client=TestClient(app,base_url='http://127.0.0.1',client=('127.0.0.1',40000))
        self.assertEqual(client.post('/admin/login',json={'username':'eight-digit-test','password':password}).status_code,200)
        replacement=''.join(secrets.choice('0123456789') for _ in range(8))
        with patch.object(sys,'argv',['manage','reset-password','--data',str(folder)]),patch('builtins.input',return_value='eight-digit-test'),patch('getpass.getpass',side_effect=[replacement,password,replacement,replacement]),contextlib.redirect_stdout(io.StringIO()):main()
        self.assertEqual(client.get('/admin/codes').status_code,401)
        self.assertEqual(client.post('/admin/login',json={'username':'eight-digit-test','password':replacement}).status_code,200)
        client.close()
    @unittest.skipUnless(os.name=='nt','Windows DPAPI integration')
    def test_windows_dpapi_and_interactive_backup_restore_cli(self):
        from fontes.manage import main
        code=self.code()['code'];key,response=self.activate(code)
        windows=self.root/'windows-private';windows.mkdir();write_issuer(windows,self.issuer)
        source=connect(self.root);target=sqlite3.connect(windows/'licencas.sqlite3')
        try:source.backup(target)
        finally:source.close();target.close()
        self.assertEqual(fingerprint(read_issuer(windows).public_key()),fingerprint(self.issuer.public_key()))
        self.assertNotIn(b'PRIVATE KEY',(windows/'issuer-key.dpapi').read_bytes())
        backup_file=self.root/'portable.agrolicensebackup';backup_password=secrets.token_urlsafe(24)
        with patch.object(sys,'argv',['manage','backup','--data',str(windows),'--file',str(backup_file)]),patch('getpass.getpass',return_value=backup_password),contextlib.redirect_stdout(io.StringIO()):main()
        self.assertTrue(backup_file.exists())
        with transaction(windows) as db:db.execute("UPDATE codes SET recipient='Alterado depois do backup'")
        with patch.object(sys,'argv',['manage','restore','--data',str(windows),'--file',str(backup_file)]),patch('builtins.input',return_value='RESTAURAR'),patch('getpass.getpass',return_value=backup_password),contextlib.redirect_stdout(io.StringIO()):main()
        restored=read_issuer(windows);self.assertEqual(fingerprint(restored.public_key()),fingerprint(self.issuer.public_key()))
        db=connect(windows)
        try:
            row=db.execute('SELECT status,recipient FROM codes').fetchone();self.assertEqual(row['status'],'used');self.assertEqual(row['recipient'],'Produtor TESTE')
            self.assertEqual(db.execute('SELECT count(*) FROM sessions').fetchone()[0],0)
        finally:db.close()
        self.assertTrue(list(self.root.glob('windows-private-anterior-*')))
        verify_license(restored.public_key(),response.json()['license'])

if __name__=='__main__':unittest.main()
