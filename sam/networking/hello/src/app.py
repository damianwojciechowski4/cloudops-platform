import os

def handler(event, context):
    return {"ok": True, "env": os.environ.get("ENV_NAME")}