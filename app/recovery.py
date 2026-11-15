"""Disaster recovery for the transaction ledger.

Every transfer is written to the S3 backup bucket and replicated to the DR
bucket. This module compares the database with the DR copy, measures the
recovery point (replication lag), keeps an event log in S3, and rebuilds
missing ledger rows from the DR bucket.

Run inside the app container:
    python recovery.py status
    python recovery.py restore
    python recovery.py simulate-loss --yes
    python recovery.py backfill
    python recovery.py event <info|alert|ok> "text" [seconds]
"""
import os
import sys
import json
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config

AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
S3_BUCKET = os.environ.get('S3_BUCKET', 'securebank-backups-akshata-2026')
DR_BUCKET = os.environ.get('DR_BUCKET', 'securebank-dr-backup-akshata-2026')
TXN_PREFIX = 'transactions/'
EVENT_PREFIX = 'dr-events/'

_s3 = boto3.client('s3', region_name=AWS_REGION,
                   config=Config(connect_timeout=2, read_timeout=4, retries={'max_attempts': 2}))
_parsed = {}  # S3 key -> transaction record (objects never change, so this cache is safe)


def _list(bucket, prefix):
    out, kwargs = [], {'Bucket': bucket, 'Prefix': prefix}
    while True:
        r = _s3.list_objects_v2(**kwargs)
        out += r.get('Contents', [])
        if not r.get('IsTruncated'):
            return out
        kwargs['ContinuationToken'] = r['NextContinuationToken']


def dr_records():
    """Transactions held in the DR bucket, one per transaction id."""
    records = {}
    for obj in _list(DR_BUCKET, TXN_PREFIX):
        key = obj['Key']
        if not key.endswith('.json'):
            continue
        if key not in _parsed:
            try:
                body = _s3.get_object(Bucket=DR_BUCKET, Key=key)['Body'].read()
                _parsed[key] = json.loads(body)
            except Exception:
                _parsed[key] = {}
        rec = _parsed[key]
        if rec.get('id'):
            records[rec['id']] = rec
    return records


def db_ids(db_connect):
    conn = db_connect()
    try:
        with conn.cursor() as c:
            c.execute("SELECT id FROM transactions")
            return {row['id'] for row in c.fetchall()}
    finally:
        conn.close()


def log_event(level, text, seconds=None, kind=None):
    """Append an event to the DR timeline (stored in S3, so it survives a database failure)."""
    now = datetime.now(timezone.utc)
    event = {'time': now.isoformat(), 'level': level, 'text': text}
    if seconds is not None:
        event['seconds'] = round(float(seconds), 1)
    if kind:
        event['kind'] = kind
    key = f"{EVENT_PREFIX}{now.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}.json"
    _s3.put_object(Bucket=S3_BUCKET, Key=key, Body=json.dumps(event), ContentType='application/json')
    return event


def events(limit=12):
    objs = sorted(_list(S3_BUCKET, EVENT_PREFIX), key=lambda o: o['Key'], reverse=True)[:limit]
    out = []
    for o in objs:
        try:
            e = json.loads(_s3.get_object(Bucket=S3_BUCKET, Key=o['Key'])['Body'].read())
            e['time'] = datetime.fromisoformat(e['time'])
            out.append(e)
        except Exception:
            continue
    return out


def recovery_point(evts):
    """How far the DR vault trails a new transfer.

    S3 gives a replica the same timestamp as the original, so the lag can't be read from object dates.
    While the newest backup is still copying we show how long it has waited; otherwise we show the
    lag measured by the last replication drill (an event with kind 'rpo').
    """
    live = _list(S3_BUCKET, TXN_PREFIX + 'live/')
    if live:
        newest = max(live, key=lambda o: o['LastModified'])
        try:
            _s3.head_object(Bucket=DR_BUCKET, Key=newest['Key'])
        except Exception:
            waited = (datetime.now(timezone.utc) - newest['LastModified']).total_seconds()
            return {'seconds': waited, 'pending': True}
    measured = next((e for e in evts if e.get('kind') == 'rpo' and e.get('seconds') is not None), None)
    return {'seconds': measured['seconds'], 'pending': False, 'at': measured['time']} if measured else None


def status(db_connect):
    report = {'db_ok': True, 'dr_ok': True}
    try:
        ids = db_ids(db_connect)
        report['db_count'] = len(ids)
    except Exception as e:
        ids, report['db_ok'], report['db_error'] = set(), False, str(e)[:160]
    try:
        dr = dr_records()
        report['dr_count'] = len(dr)
    except Exception as e:
        dr, report['dr_ok'], report['dr_error'] = {}, False, str(e)[:160]
    report['missing'] = sorted(set(dr) - ids) if report['db_ok'] else []
    report['not_in_dr'] = sorted(ids - set(dr)) if report['dr_ok'] else []
    try:
        report['events'] = events()
    except Exception:
        report['events'] = []
    try:
        report['rpo'] = recovery_point(report['events'])
    except Exception:
        report['rpo'] = None
    report['rto'] = next((e for e in report['events'] if e.get('seconds') is not None and e.get('kind') != 'rpo'), None)
    if not report['db_ok']:
        report['state'] = 'down'
    elif report['missing']:
        report['state'] = 'loss'
    else:
        report['state'] = 'safe'
    return report


def restore(db_connect):
    """Insert every transaction that exists in the DR bucket but not in the database."""
    t0 = time.time()
    dr = dr_records()
    have = db_ids(db_connect)
    missing = [dr[i] for i in sorted(set(dr) - have)]
    conn = db_connect()
    try:
        with conn.cursor() as c:
            c.execute("SELECT username, account FROM users")
            accounts = {r['username']: r['account'] for r in c.fetchall()}
            for t in missing:
                ts = str(t.get('timestamp') or '')[:19] or None
                c.execute("""INSERT IGNORE INTO transactions
                             (id, from_user, to_user, from_account, to_account, amount, note, timestamp, backed_up)
                             VALUES (%s, %s, %s, %s, %s, %s, %s, %s, TRUE)""",
                          (t['id'], t['from_user'], t['to_user'],
                           t.get('from_account') or accounts.get(t['from_user'], ''),
                           t.get('to_account') or accounts.get(t['to_user'], ''),
                           int(t['amount']), t.get('note') or '', ts))
    finally:
        conn.close()
    took = time.time() - t0
    if missing:
        log_event('ok', f"Ledger rebuilt from the DR bucket: {len(missing)} transactions restored", took)
    return len(missing), took


def simulate_loss(db_connect):
    conn = db_connect()
    try:
        with conn.cursor() as c:
            n = c.execute("DELETE FROM transactions")
    finally:
        conn.close()
    log_event('alert', f"Disaster drill: transaction ledger wiped ({n} records deleted from RDS)")
    return n


def backfill():
    """Copy backups made before replication was switched on into the DR bucket."""
    have = {o['Key'] for o in _list(DR_BUCKET, TXN_PREFIX)}
    copied = 0
    for o in _list(S3_BUCKET, TXN_PREFIX):
        if o['Key'].endswith('.json') and o['Key'] not in have:
            _s3.copy_object(Bucket=DR_BUCKET, Key=o['Key'], CopySource={'Bucket': S3_BUCKET, 'Key': o['Key']})
            copied += 1
    return copied


def _main(argv):
    import app  # the app module holds the database connection settings
    cmd = argv[1] if len(argv) > 1 else 'status'
    if cmd == 'status':
        r = status(app.db)
        print(f"state={r['state']} db={r.get('db_count')} dr={r.get('dr_count')} "
              f"missing={len(r['missing'])} not_in_dr={len(r['not_in_dr'])}")
    elif cmd == 'restore':
        n, took = restore(app.db)
        print(f"restored {n} transactions from the DR bucket in {took:.1f} s")
    elif cmd == 'simulate-loss':
        if '--yes' not in argv:
            sys.exit("refusing: add --yes to delete every transaction row")
        print(f"deleted {simulate_loss(app.db)} transactions from RDS")
    elif cmd == 'backfill':
        print(f"copied {backfill()} older backups into the DR bucket")
    elif cmd == 'event':
        print(log_event(argv[2], argv[3], float(argv[4]) if len(argv) > 4 else None))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    _main(sys.argv)
