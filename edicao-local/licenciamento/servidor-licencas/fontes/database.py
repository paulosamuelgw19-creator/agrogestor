import sqlite3
from contextlib import contextmanager
from pathlib import Path

SCHEMA='''
CREATE TABLE IF NOT EXISTS administrators(username TEXT PRIMARY KEY,password_hash TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sessions(token_hash TEXT PRIMARY KEY,csrf_hash TEXT NOT NULL,expires REAL NOT NULL);
CREATE TABLE IF NOT EXISTS codes(id TEXT PRIMARY KEY,code_hash TEXT NOT NULL UNIQUE,hint TEXT NOT NULL,recipient TEXT NOT NULL,notes TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('available','used','cancelled')),created_at TEXT NOT NULL,activated_at TEXT,license_id TEXT,key_fp TEXT,request_id TEXT);
CREATE TABLE IF NOT EXISTS licenses(id TEXT PRIMARY KEY,key_fp TEXT NOT NULL UNIQUE,public_key TEXT NOT NULL,document TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS challenges(id TEXT PRIMARY KEY,nonce TEXT NOT NULL,request_id TEXT NOT NULL,code_hash TEXT NOT NULL,key_fp TEXT NOT NULL,public_key TEXT NOT NULL,expires REAL NOT NULL,consumed INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY,count INTEGER NOT NULL,reset REAL NOT NULL);
CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY,created_at TEXT NOT NULL,action TEXT NOT NULL,object_id TEXT NOT NULL,actor TEXT NOT NULL);
'''

def connect(folder):
    db=sqlite3.connect(Path(folder)/'licencas.sqlite3',timeout=15,isolation_level=None)
    db.row_factory=sqlite3.Row;db.execute('PRAGMA foreign_keys=ON');db.execute('PRAGMA busy_timeout=15000');db.execute('PRAGMA synchronous=FULL')
    return db
def initialize(folder):
    Path(folder).mkdir(parents=True,exist_ok=True)
    db=connect(folder)
    try:db.execute('PRAGMA journal_mode=WAL');db.executescript(SCHEMA)
    finally:db.close()
@contextmanager
def transaction(folder):
    db=connect(folder)
    try:
        db.execute('BEGIN IMMEDIATE');yield db;db.commit()
    except BaseException:db.rollback();raise
    finally:db.close()
