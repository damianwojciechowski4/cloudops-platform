import os

def handler(event, context):
    print("Testing Lambda function with environment variable")
    return {"ok": True, "env": os.environ.get("ENV_NAME")}