import hashlib,hmac,ipaddress,json,os,re,secrets,time,uuid
from datetime import datetime,timezone
from pathlib import Path
from urllib.parse import urlsplit
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI,HTTPException,Request,Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse,JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware
from pydantic import BaseModel,ConfigDict,Field
from pwdlib import PasswordHash
from .crypto_core import APP_ID,FORMAT,b64,unb64,load_public,fingerprint,code_hash,new_code,proof,sign_license,read_issuer
from .database import initialize,connect,transaction

PASSWORDS=PasswordHash.recommended()
DUMMY_HASH=PASSWORDS.hash(secrets.token_urlsafe(32))
def utc():return datetime.now(timezone.utc).isoformat()
def digest(text):return hashlib.sha256(text.encode()).hexdigest()

class Strict(BaseModel): model_config=ConfigDict(extra='forbid')
class ChallengeInput(Strict):
    appId:str=Field(max_length=80)
    schemaVersion:int
    requestId:uuid.UUID
    codeHash:str=Field(pattern=r'^[0-9a-f]{64}$')
    publicKey:str=Field(min_length=80,max_length=256)
class ActivationInput(Strict):
    challengeId:uuid.UUID
    nonce:str=Field(min_length=40,max_length=60)
    code:str=Field(min_length=20,max_length=80)
    signature:str=Field(min_length=80,max_length=128)
class LoginInput(Strict):
    username:str=Field(min_length=1,max_length=80)
    password:str=Field(min_length=1,max_length=256)
class CodeInput(Strict):
    recipient:str=Field(min_length=1,max_length=160)
    notes:str=Field(default='',max_length=500)

class BodyLimitMiddleware:
    def __init__(self,app):self.app=app
    async def __call__(self,scope,receive,send):
        if scope['type']!='http' or scope.get('method')!='POST':
            return await self.app(scope,receive,send)
        messages=[];size=0
        while True:
            message=await receive()
            if message['type']=='http.disconnect':return
            size+=len(message.get('body',b''))
            if size>8192:
                return await JSONResponse({'error':'request_too_large','message':'Solicitacao muito grande.'},413)(scope,receive,send)
            messages.append(message)
            if not message.get('more_body',False):break
        async def replay():
            if messages:return messages.pop(0)
            return await receive()
        await self.app(scope,replay,send)

def create_app(folder=None,testing=False,clock=time.time,public_origin=None):
    folder=Path(folder or os.environ.get('AGRO_LOCAL_LICENSE_DATA') or Path(__file__).resolve().parents[1]/'dados-privados').resolve()
    initialize(folder)
    issuer=read_issuer(folder,testing)
    app=FastAPI(title='AgroGestor Local - ativacao',docs_url=None,redoc_url=None,openapi_url=None)
    public_origin=public_origin or os.environ.get('AGRO_LOCAL_PUBLIC_ORIGIN','')
    origin=urlsplit(public_origin)
    if public_origin and (origin.scheme!='https' or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ('','/')):raise RuntimeError('Public origin must be an HTTPS origin')
    allowed_hosts=['127.0.0.1','localhost']+([urlsplit(public_origin).hostname] if public_origin else [])
    app.add_middleware(TrustedHostMiddleware,allowed_hosts=allowed_hosts)
    app.add_middleware(BodyLimitMiddleware)
    web=Path(__file__).parent/'web'

    @app.exception_handler(RequestValidationError)
    async def validation_error(request,error):return JSONResponse({'error':'invalid_request','message':'Confira os dados informados.'},400)
    @app.exception_handler(HTTPException)
    async def http_error(request,error):
        detail=error.detail if isinstance(error.detail,dict) else {'error':'request_denied','message':str(error.detail)}
        return JSONResponse(detail,error.status_code,headers=error.headers)
    @app.exception_handler(Exception)
    async def internal_error(request,error):
        # Never log request bodies, passwords, codes, signatures or validation input.
        import logging
        logging.getLogger('agro.activation').error('request_failed type=%s',type(error).__name__)
        return JSONResponse({'error':'server_error','message':'Servidor indisponivel. Tente novamente.'},500)
    @app.middleware('http')
    async def safe_headers(request,call_next):
        try:size=int(request.headers.get('content-length','0') or '0')
        except ValueError:return JSONResponse({'error':'invalid_request'},400)
        if size>8192:return JSONResponse({'error':'request_too_large'},413)
        response=await call_next(request)
        response.headers.update({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"})
        return response

    def deny(status,code,message):raise HTTPException(status,{'error':code,'message':message})
    def throttle(request,scope,count,seconds):
        peer=request.client.host if request.client else 'unknown'
        key=digest(scope+'|'+peer);now=clock()
        with transaction(folder) as db:
            db.execute('DELETE FROM limits WHERE reset<?',(now-3600,))
            row=db.execute('SELECT count,reset FROM limits WHERE key=?',(key,)).fetchone()
            n=(row['count']+1) if row and row['reset']>now else 1
            reset=row['reset'] if row and row['reset']>now else now+seconds
            db.execute('INSERT OR REPLACE INTO limits VALUES(?,?,?)',(key,n,reset))
        if n>count:deny(429,'rate_limited','Muitas tentativas. Aguarde e tente novamente.')
    def local_admin(request):
        try:local=ipaddress.ip_address(request.client.host).is_loopback
        except (ValueError,AttributeError):local=False
        if not local:deny(403,'local_admin_only','Painel administrativo disponivel somente no Windows do servidor.')
    def session(request,write=False):
        local_admin(request)
        token=request.cookies.get('agro_local_admin','')
        db=connect(folder)
        try:row=db.execute('SELECT * FROM sessions WHERE token_hash=? AND expires>?',(digest(token),clock())).fetchone()
        finally:db.close()
        if not row:deny(401,'admin_required','Entre no painel administrativo.')
        if write:
            origin=request.headers.get('origin')
            if origin and origin!=str(request.base_url).rstrip('/'):deny(403,'invalid_origin','Origem nao autorizada.')
            if not hmac.compare_digest(row['csrf_hash'],digest(request.headers.get('x-csrf-token',''))):deny(403,'csrf_required','Atualize o painel e entre novamente.')
        return row
    def audit(db,action,obj,actor='administrator'):db.execute('INSERT INTO audit(created_at,action,object_id,actor) VALUES(?,?,?,?)',(utc(),action,obj,actor))

    @app.get('/health')
    def health():return {'status':'ok','service':'agrogestor-local-activation','schemaVersion':1}
    @app.get('/')
    def panel(request:Request):local_admin(request);return FileResponse(web/'index.html')
    @app.get('/panel.js')
    def js(request:Request):local_admin(request);return FileResponse(web/'panel.js',media_type='text/javascript')
    @app.get('/panel.css')
    def css(request:Request):local_admin(request);return FileResponse(web/'panel.css',media_type='text/css')
    @app.post('/admin/login')
    def login(body:LoginInput,request:Request,response:Response):
        local_admin(request);throttle(request,'login',5,300)
        origin=request.headers.get('origin')
        if origin and origin!=str(request.base_url).rstrip('/'):deny(403,'invalid_origin','Origem nao autorizada.')
        db=connect(folder)
        try:row=db.execute('SELECT * FROM administrators WHERE username=?',(body.username,)).fetchone()
        finally:db.close()
        try:valid=PASSWORDS.verify(body.password,row['password_hash'] if row else DUMMY_HASH)
        except Exception:valid=False
        if not row or not valid:deny(401,'invalid_credentials','Usuario ou senha incorretos.')
        token=secrets.token_urlsafe(32);csrf=secrets.token_urlsafe(32)
        with transaction(folder) as db:
            db.execute('DELETE FROM sessions WHERE expires<?',(clock(),))
            db.execute('INSERT INTO sessions VALUES(?,?,?)',(digest(token),digest(csrf),clock()+7200))
            audit(db,'admin_login','',body.username)
        response.set_cookie('agro_local_admin',token,httponly=True,secure=request.url.scheme=='https',samesite='strict',max_age=7200,path='/admin')
        return {'csrfToken':csrf}
    @app.post('/admin/logout')
    def logout(request:Request,response:Response):
        session(request,True)
        with transaction(folder) as db:db.execute('DELETE FROM sessions WHERE token_hash=?',(digest(request.cookies.get('agro_local_admin','')),))
        response.delete_cookie('agro_local_admin',path='/admin');return {'ok':True}
    @app.get('/admin/codes')
    def codes(request:Request):
        session(request);db=connect(folder)
        try:items=[dict(row) for row in db.execute('SELECT id,hint,recipient,notes,status,created_at,activated_at,license_id,key_fp FROM codes ORDER BY created_at DESC LIMIT 1000')]
        finally:db.close()
        return {'items':items,'notice':'Licencas offline sem vencimento nao podem ser revogadas em aparelhos desconectados. Nova autorizacao nao desativa a anterior.'}
    @app.post('/admin/codes')
    def generate(body:CodeInput,request:Request):
        session(request,True);throttle(request,'generate',60,60)
        if not body.recipient.strip():deny(400,'invalid_recipient','Informe a identificacao do destinatario.')
        code=new_code();id=str(uuid.uuid4())
        with transaction(folder) as db:
            db.execute('INSERT INTO codes(id,code_hash,hint,recipient,notes,status,created_at) VALUES(?,?,?,?,?,?,?)',(id,code_hash(code),code[-4:],body.recipient.strip(),body.notes.strip(),'available',utc()))
            audit(db,'code_generated',id)
        return {'id':id,'code':code,'message':'Copie agora. O codigo completo nao e armazenado e nao sera exibido novamente.'}
    @app.post('/admin/codes/{code_id}/replacement')
    def replacement(code_id:uuid.UUID,request:Request):
        session(request,True);throttle(request,'generate',60,60)
        code=new_code();new_id=str(uuid.uuid4())
        with transaction(folder) as db:
            previous=db.execute("SELECT * FROM codes WHERE id=? AND status='used'",(str(code_id),)).fetchone()
            if not previous:deny(409,'replacement_denied','Selecione uma autorizacao utilizada para registrar a troca de aparelho.')
            notes=('Troca de aparelho; licenca anterior '+previous['license_id']+'. '+previous['notes'])[:500]
            db.execute('INSERT INTO codes(id,code_hash,hint,recipient,notes,status,created_at) VALUES(?,?,?,?,?,?,?)',(new_id,code_hash(code),code[-4:],previous['recipient'],notes,'available',utc()))
            audit(db,'replacement_generated',new_id)
        return {'id':new_id,'code':code,'message':'Nova autorizacao criada. O aparelho anterior continua autorizado offline; combine sua retirada de uso.'}
    @app.post('/admin/codes/{code_id}/cancel')
    def cancel(code_id:uuid.UUID,request:Request):
        session(request,True)
        with transaction(folder) as db:
            changed=db.execute("UPDATE codes SET status='cancelled' WHERE id=? AND status='available'",(str(code_id),)).rowcount
            if not changed:deny(409,'cannot_cancel','Somente codigos disponiveis podem ser cancelados. Uma licenca offline ja emitida nao sera desativada.')
            audit(db,'code_cancelled',str(code_id))
        return {'ok':True}
    @app.post('/activation/v1/challenge')
    def challenge(body:ChallengeInput,request:Request):
        throttle(request,'challenge',20,60)
        if body.appId!=APP_ID or body.schemaVersion!=1:deny(400,'unsupported_app','Edicao ou formato de ativacao incompativel.')
        try:key=load_public(body.publicKey)
        except Exception:deny(400,'invalid_key','A chave desta instalacao nao pode ser validada.')
        id=str(uuid.uuid4());nonce=secrets.token_urlsafe(32)
        with transaction(folder) as db:
            db.execute('DELETE FROM challenges WHERE expires<?',(clock()-300,))
            db.execute('INSERT INTO challenges(id,nonce,request_id,code_hash,key_fp,public_key,expires) VALUES(?,?,?,?,?,?,?)',(id,nonce,str(body.requestId),body.codeHash,fingerprint(key),body.publicKey,clock()+120))
        return {'challengeId':id,'nonce':nonce,'expiresIn':120}
    @app.post('/activation/v1/activate')
    def activate(body:ActivationInput,request:Request):
        throttle(request,'activate',20,60)
        try:hashed=code_hash(body.code)
        except ValueError:deny(400,'invalid_code','Codigo invalido. Confira o codigo recebido.')
        with transaction(folder) as db:
            challenge=db.execute('SELECT * FROM challenges WHERE id=?',(str(body.challengeId),)).fetchone()
            if not challenge or challenge['consumed'] or challenge['expires']<clock():deny(409,'challenge_expired','Solicitacao expirada. Tente ativar novamente.')
            if not hmac.compare_digest(challenge['nonce'],body.nonce) or not hmac.compare_digest(challenge['code_hash'],hashed):deny(400,'invalid_proof','Solicitacao de ativacao invalida.')
            try:load_public(challenge['public_key']).verify(unb64(body.signature),proof(challenge['id'],body.nonce,challenge['request_id'],hashed,challenge['key_fp']),ec.ECDSA(hashes.SHA256()))
            except Exception:deny(400,'invalid_proof','Nao foi possivel confirmar a chave desta instalacao.')
            code=db.execute('SELECT * FROM codes WHERE code_hash=?',(hashed,)).fetchone()
            if not code:deny(400,'invalid_code','Codigo invalido. Confira o codigo recebido.')
            if code['status']=='cancelled':deny(409,'cancelled_code','Este codigo foi cancelado. Solicite outro ao responsavel.')
            if code['status']=='used':
                if code['key_fp']!=challenge['key_fp']:deny(409,'code_used','Este codigo ja foi utilizado em outra instalacao.')
                license=db.execute('SELECT document FROM licenses WHERE id=?',(code['license_id'],)).fetchone()
                if not license:deny(500,'server_error','Autorizacao indisponivel. Contate o administrador.')
                document=json.loads(license['document'])
            else:
                if db.execute('SELECT 1 FROM licenses WHERE key_fp=?',(challenge['key_fp'],)).fetchone():deny(409,'installation_active','Esta instalacao ja possui uma autorizacao. Recupere-a com o codigo original.')
                id=str(uuid.uuid4());issued=utc()
                payload={'format':FORMAT,'schemaVersion':1,'appId':APP_ID,'kind':'free_perpetual','licenseId':id,'issuedAt':issued,'expiresAt':None,'installationKeySha256':challenge['key_fp']}
                document=sign_license(issuer,payload)
                db.execute('INSERT INTO licenses VALUES(?,?,?,?,?)',(id,challenge['key_fp'],challenge['public_key'],json.dumps(document),issued))
                db.execute("UPDATE codes SET status='used',activated_at=?,license_id=?,key_fp=?,request_id=? WHERE id=? AND status='available'",(issued,id,challenge['key_fp'],challenge['request_id'],code['id']))
                audit(db,'license_issued',id,'installation')
            db.execute('UPDATE challenges SET consumed=1 WHERE id=?',(challenge['id'],))
        return {'license':document,'message':'Ativacao concluida. Piloto gratuito sem vencimento.'}
    return app

def application():return create_app()
