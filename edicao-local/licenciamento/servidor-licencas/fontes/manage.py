import argparse,getpass,json,os,re,shutil,sqlite3,sys,tempfile,time
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ec
from pwdlib import PasswordHash
from .crypto_core import write_issuer,read_issuer,make_backup,decode_backup,fingerprint,protect_folder,validate_data_folder
from .database import initialize,transaction

ROOT=Path(__file__).resolve().parents[1]

def read_admin_password(prompt,confirmation):
    print('A senha nao aparece enquanto voce digita. Digite e pressione Enter.')
    while True:
        password=getpass.getpass(prompt)
        if len(password)<8 or len(password)>256:
            print('Use de 8 a 256 caracteres. Uma senha de 8 digitos e aceita. Tente novamente.')
            continue
        if password!=getpass.getpass(confirmation):
            print('As senhas ficaram diferentes. Tente novamente; nada foi alterado.')
            continue
        return password
def main():
    parser=argparse.ArgumentParser(description='Administracao offline - AgroGestor Local')
    parser.add_argument('command',choices=['prepare-issuer','check-ready','protect-data','setup','backup','restore','reset-password'])
    parser.add_argument('--data',type=Path,default=ROOT/'dados-privados')
    parser.add_argument('--file',type=Path)
    args=parser.parse_args();folder=validate_data_folder(args.data)
    if args.command=='protect-data':
        protect_folder(folder)
        print('Pasta dedicada protegida.');return
    if args.command=='check-ready':
        if not (folder/'issuer-key.dpapi').exists() or not (folder/'licencas.sqlite3').exists():raise SystemExit(2)
        db=sqlite3.connect(folder/'licencas.sqlite3')
        try:ready=db.execute('SELECT count(*) FROM administrators').fetchone()[0]>0
        finally:db.close()
        raise SystemExit(0 if ready else 2)
    if args.command=='restore':
        if not args.file:parser.error('--file e obrigatorio')
        print('Pare o servidor antes de restaurar. A restauracao substitui a central e preserva a pasta anterior.')
        if input('Digite RESTAURAR para confirmar: ').strip()!='RESTAURAR':raise SystemExit('Cancelado.')
        password=getpass.getpass('Senha do backup: ')
        try:database,key=decode_backup(args.file.read_bytes(),password)
        except Exception:raise SystemExit('Backup invalido, incompleto ou senha incorreta. Os dados atuais nao foram alterados.')
        # Validate in an isolated staging directory before replacing the stopped service data.
        staging=Path(tempfile.mkdtemp(prefix='agro-restore-',dir=folder.parent))
        try:
            protect_folder(staging)
            (staging/'licencas.sqlite3').write_bytes(database)
            write_issuer(staging,key)
            initialize(staging)
            previous=folder.with_name(folder.name+'-anterior-'+str(time.time_ns()))
            if previous.resolve().parent!=folder.parent or staging.resolve().parent!=folder.parent:
                raise RuntimeError('Restore paths escaped the explicitly selected parent directory')
            if folder.exists():folder.rename(previous)
            try:staging.rename(folder)
            except BaseException:
                if previous.exists() and not folder.exists():previous.rename(folder)
                raise
        finally:
            if staging.exists():
                resolved_staging=staging.resolve()
                if resolved_staging.parent!=folder.parent or not resolved_staging.name.startswith('agro-restore-'):
                    raise RuntimeError('Unexpected cleanup path; staging preserved')
                shutil.rmtree(resolved_staging)
        print('Central restaurada. Guarde a pasta anterior em local privado. Nao use backups antigos para reutilizar codigos ja consumidos.')
        return
    initialize(folder)
    if not (folder/'issuer-key.dpapi').exists():
        db=sqlite3.connect(folder/'licencas.sqlite3')
        try:issued=db.execute('SELECT count(*) FROM licenses').fetchone()[0]
        finally:db.close()
        if issued:raise SystemExit('Chave emissora ausente. Restaure um backup; nao gere outra chave para esta central.')
        write_issuer(folder,ec.generate_private_key(ec.SECP256R1()))
    key=read_issuer(folder)
    if args.command=='prepare-issuer':
        print('Emissor preparado. Identificador publico: '+fingerprint(key.public_key())[:16]);return
    if args.command=='setup':
        with transaction(folder) as db:
            if db.execute('SELECT count(*) FROM administrators').fetchone()[0]:raise SystemExit('Administrador ja configurado. Nao foi substituido.')
        username=input('Nome do administrador (sem senha padrao): ').strip()
        if not re.fullmatch(r'[A-Za-z0-9_.@-]{3,80}',username):raise SystemExit('Use de 3 a 80 letras, numeros, ponto, @, _ ou -.')
        password=read_admin_password('Crie uma senha (minimo 8 caracteres): ','Repita a senha: ')
        with transaction(folder) as db:db.execute('INSERT INTO administrators VALUES(?,?)',(username,PasswordHash.recommended().hash(password)))
        print('Administrador configurado. Guarde um backup criptografado da central.')
    if args.command=='reset-password':
        username=input('Usuario administrativo existente: ').strip()
        password=read_admin_password('Nova senha (minimo 8 caracteres): ','Repita a nova senha: ')
        with transaction(folder) as db:
            changed=db.execute('UPDATE administrators SET password_hash=? WHERE username=?',(PasswordHash.recommended().hash(password),username)).rowcount
            if not changed:raise SystemExit('Administrador nao encontrado. Nenhuma conta criada.')
            db.execute('DELETE FROM sessions')
        print('Senha alterada e sessoes encerradas. Codigos, licencas e chave emissora foram preservados.')
    if args.command=='backup':
        if not args.file:parser.error('--file e obrigatorio')
        if args.file.exists():raise SystemExit('Escolha um nome novo; o backup anterior nao sera sobrescrito.')
        password=getpass.getpass('Crie uma senha para o backup (minimo 12 caracteres): ')
        if password!=getpass.getpass('Repita a senha: '):raise SystemExit('Confirmacao diferente.')
        data=make_backup(folder,key,password)
        args.file.parent.mkdir(parents=True,exist_ok=True);args.file.write_bytes(data);os.chmod(args.file,0o600)
        print('Backup criptografado salvo. Guarde a senha separadamente; sem ela nao ha recuperacao.')

if __name__=='__main__':main()
