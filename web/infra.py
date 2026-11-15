"""Live infrastructure checks for the /infra page.

Every check is wrapped so that a missing permission or an unreachable service
shows up as a red/grey card instead of breaking the page.
"""
import os
import socket
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
S3_BUCKET = os.environ.get('S3_BUCKET', 'securebank-backups-akshata-2026')
DR_BUCKET = os.environ.get('DR_BUCKET', 'securebank-dr-backup-akshata-2026')
TARGET_GROUP_ARN = os.environ.get('TARGET_GROUP_ARN', '')
HEALTH_CHECK_ID = os.environ.get('HEALTH_CHECK_ID', '')
TRAIL_NAME = os.environ.get('TRAIL_NAME', 'securebank-audit-trail')
ON_KUBERNETES = 'KUBERNETES_SERVICE_HOST' in os.environ

_cfg = Config(connect_timeout=2, read_timeout=3, retries={'max_attempts': 1})
_s3 = boto3.client('s3', region_name=AWS_REGION, config=_cfg)
_elb = boto3.client('elbv2', region_name=AWS_REGION, config=_cfg)
_r53 = boto3.client('route53', config=_cfg)
_ec2 = boto3.client('ec2', region_name=AWS_REGION, config=_cfg)
_ct = boto3.client('cloudtrail', region_name=AWS_REGION, config=_cfg)

_instance_names = {}


def _imds(path):
    """Read EC2 instance metadata (IMDSv2). Returns '' when not on EC2."""
    try:
        req = urllib.request.Request('http://169.254.169.254/latest/api/token', method='PUT',
                                     headers={'X-aws-ec2-metadata-token-ttl-seconds': '60'})
        token = urllib.request.urlopen(req, timeout=0.5).read().decode()
        req = urllib.request.Request('http://169.254.169.254/latest/meta-data/' + path,
                                     headers={'X-aws-ec2-metadata-token': token})
        return urllib.request.urlopen(req, timeout=0.5).read().decode()
    except Exception:
        return ''


def _name_of(instance_id):
    if instance_id not in _instance_names:
        try:
            r = _ec2.describe_instances(InstanceIds=[instance_id])
            tags = r['Reservations'][0]['Instances'][0].get('Tags', [])
            _instance_names[instance_id] = next((t['Value'] for t in tags if t['Key'] == 'Name'), instance_id)
        except Exception:
            return instance_id
    return _instance_names[instance_id]


def compute():
    iid = _imds('instance-id')
    info = {
        'platform': 'Kubernetes pod (k3s)' if ON_KUBERNETES else ('EC2 + Docker' if iid else 'Local'),
        'container': socket.gethostname(),
        'node': os.environ.get('NODE_NAME', ''),
        'instance_id': iid,
        'instance_name': _name_of(iid) if iid else '',
        'az': _imds('placement/availability-zone'),
        'private_ip': _imds('local-ipv4'),
        'instance_type': _imds('instance-type'),
    }
    info['ok'] = True
    return info


def database(stats):
    """Database figures come from passbook-management: the web tier has no database access."""
    return stats()


def backups():
    try:
        keys = []
        kwargs = {'Bucket': S3_BUCKET, 'Prefix': 'transactions/live/'}
        while True:
            r = _s3.list_objects_v2(**kwargs)
            keys += r.get('Contents', [])
            if not r.get('IsTruncated'):
                break
            kwargs['ContinuationToken'] = r['NextContinuationToken']
        if not keys:
            return {'ok': True, 'count': 0}
        latest = max(keys, key=lambda o: o['LastModified'])
        head = _s3.head_object(Bucket=S3_BUCKET, Key=latest['Key'])
        result = {'ok': True, 'count': len(keys), 'latest_key': latest['Key'].rsplit('/', 1)[-1],
                  'latest_time': latest['LastModified'], 'replication': head.get('ReplicationStatus', 'NOT CONFIGURED'),
                  'versioned': 'VersionId' in head and head['VersionId'] != 'null'}
        try:
            _s3.head_object(Bucket=DR_BUCKET, Key=latest['Key'])
            result['in_dr'] = True
        except Exception:
            result['in_dr'] = False
        return result
    except Exception as e:
        return {'ok': False, 'error': str(e)[:160]}


def load_balancer():
    if not TARGET_GROUP_ARN:
        return {'ok': None, 'error': 'TARGET_GROUP_ARN not set'}
    try:
        r = _elb.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN)
        targets = []
        for t in r['TargetHealthDescriptions']:
            iid = t['Target']['Id']
            targets.append({'id': iid, 'name': _name_of(iid), 'state': t['TargetHealth']['State'],
                            'reason': t['TargetHealth'].get('Reason', '')})
        healthy = sum(1 for t in targets if t['state'] == 'healthy')
        return {'ok': healthy > 0, 'targets': targets, 'healthy': healthy, 'total': len(targets)}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:160]}


def dns():
    if not HEALTH_CHECK_ID:
        return {'ok': None, 'error': 'HEALTH_CHECK_ID not set'}
    try:
        r = _r53.get_health_check_status(HealthCheckId=HEALTH_CHECK_ID)
        obs = r['HealthCheckObservations']
        healthy = sum(1 for o in obs if o['StatusReport']['Status'].startswith('Success'))
        return {'ok': healthy >= len(obs) / 2, 'healthy': healthy, 'total': len(obs),
                'record': 'app.securebank-akshata.com', 'routing': 'Failover: Sydney, then Mumbai, then the S3 static page'}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:160]}


def security():
    try:
        trail = _ct.get_trail(Name=TRAIL_NAME)['Trail']
        status = _ct.get_trail_status(Name=TRAIL_NAME)
        last = status.get('LatestDeliveryTime')
        return {'ok': bool(status.get('IsLogging')), 'trail': TRAIL_NAME, 'logging': bool(status.get('IsLogging')),
                'multi_region': trail.get('IsMultiRegionTrail', False),
                'kms': (trail.get('KmsKeyId') or '').rsplit('/', 1)[-1][:13] + ('...' if trail.get('KmsKeyId') else 'none'),
                'validation': trail.get('LogFileValidationEnabled', False), 'last_delivery': last}
    except Exception as e:
        return {'ok': False, 'error': str(e)[:160]}


def snapshot(stats):
    """Run all checks in parallel so the page stays fast."""
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {
            'compute': pool.submit(compute),
            'database': pool.submit(database, stats),
            'backups': pool.submit(backups),
            'lb': pool.submit(load_balancer),
            'dns': pool.submit(dns),
            'security': pool.submit(security),
        }
        return {k: f.result() for k, f in futures.items()}
