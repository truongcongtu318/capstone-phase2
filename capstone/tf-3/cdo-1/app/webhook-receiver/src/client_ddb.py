import hashlib
import time
import boto3
from botocore.exceptions import ClientError
from src.config import settings


def build_lock_key(tenant_id: str, namespace: str, service_name: str, alert_name: str) -> str:
    key = f"{tenant_id}#{namespace}#{service_name}#{alert_name}"
    return hashlib.sha256(key.encode()).hexdigest()


def acquire_lock(lock_key: str, cooldown_seconds: int) -> bool:
    client = boto3.client(
        "dynamodb",
        region_name=settings.aws_region,
        endpoint_url=settings.dynamodb_endpoint_url
    )
    now = int(time.time())
    expiration = now + cooldown_seconds

    try:
        client.put_item(
            TableName=settings.dynamodb_table_name,
            Item={
                "lock_key":        {"S": lock_key},
                "expiration_time": {"N": str(expiration)},
                "status":          {"S": "ACTIVE"}
            },
            ConditionExpression="attribute_not_exists(lock_key) OR expiration_time < :now",
            ExpressionAttributeValues={
                ":now": {"N": str(now)}
            }
        )
        return True

    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise
